"""Synchronous command execution and managed background processes."""

from __future__ import annotations

import dataclasses
import json
import os
import signal
import subprocess
import threading
import time
import uuid
from collections import deque
from pathlib import Path
from typing import Annotated, Any, Callable, Literal

from pydantic import Field

from .config import ServerConfig, check_access, get_effective_policy, normalize_path
from .file_tools import DESTRUCTIVE_ANN, decode_bytes_smart, truncate_head_tail
from .logging_utils import LOGGER, abbrev


@dataclasses.dataclass
class ManagedProcess:
    process_id: str
    command: str
    cwd: str
    proc: subprocess.Popen[bytes]
    started_at: float
    lines: deque[str] = dataclasses.field(default_factory=lambda: deque(maxlen=5000))
    lock: threading.Lock = dataclasses.field(default_factory=threading.Lock)
    ended_at: float | None = None


class ProcessManager:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._procs: dict[str, ManagedProcess] = {}

    def _build_popen_kwargs(
        self, command: str, cwd: Path, shell: str, env: dict[str, str] | None
    ) -> tuple[Any, dict[str, Any]]:
        merged_env = os.environ.copy()
        merged_env.setdefault("PYTHONIOENCODING", "utf-8")
        if env:
            merged_env.update({str(k): str(v) for k, v in env.items()})

        kwargs: dict[str, Any] = {
            "cwd": str(cwd),
            "env": merged_env,
            "stdin": subprocess.PIPE,
            "stdout": subprocess.PIPE,
            "stderr": subprocess.STDOUT,
        }

        if os.name == "nt":
            kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW
            si = subprocess.STARTUPINFO()
            si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            si.wShowWindow = 0  # SW_HIDE
            kwargs["startupinfo"] = si
            if shell == "powershell":
                args: Any = ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command]
                kwargs["shell"] = False
            elif shell == "cmd":
                args = ["cmd.exe", "/c", command]
                kwargs["shell"] = False
            else:
                args = command
                kwargs["shell"] = True
        else:
            kwargs["start_new_session"] = True
            if shell in ("bash", "sh", "zsh"):
                args = [shell, "-c", command]
                kwargs["shell"] = False
            else:
                args = command
                kwargs["shell"] = True
        return args, kwargs

    def start(
        self, command: str, cwd: Path, shell: str = "auto", env: dict[str, str] | None = None
    ) -> ManagedProcess:
        args, kwargs = self._build_popen_kwargs(command, cwd, shell, env)
        proc = subprocess.Popen(args, **kwargs)
        pid_str = uuid.uuid4().hex[:8]
        mp = ManagedProcess(
            process_id=pid_str,
            command=command,
            cwd=str(cwd),
            proc=proc,
            started_at=time.time(),
        )
        with self._lock:
            self._procs[pid_str] = mp

        def _reader() -> None:
            assert proc.stdout is not None
            try:
                for raw_line in iter(proc.stdout.readline, b""):
                    decoded = decode_bytes_smart(raw_line).rstrip("\r\n")
                    with mp.lock:
                        mp.lines.append(decoded)
            finally:
                rc_done = proc.wait()
                mp.ended_at = time.time()
                LOGGER.info(
                    "[PROC EXIT] id=%s pid=%s exit_code=%s cmd=%s",
                    mp.process_id,
                    proc.pid,
                    rc_done,
                    abbrev(mp.command, 80),
                )

        threading.Thread(target=_reader, daemon=True).start()
        return mp

    def kill_tree(self, proc: subprocess.Popen[bytes]) -> None:
        if proc.poll() is not None:
            return
        if os.name == "nt":
            subprocess.run(
                ["taskkill", "/F", "/T", "/PID", str(proc.pid)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                creationflags=subprocess.CREATE_NO_WINDOW,
                check=False,
            )
        else:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
            except Exception:
                proc.kill()

    def get(self, process_id: str) -> ManagedProcess | None:
        with self._lock:
            return self._procs.get(process_id)

    def list_all(self) -> list[dict[str, Any]]:
        with self._lock:
            items = list(self._procs.values())
        out = []
        for mp in items:
            rc = mp.proc.poll()
            out.append(
                {
                    "process_id": mp.process_id,
                    "pid": mp.proc.pid,
                    "command": mp.command,
                    "cwd": mp.cwd,
                    "status": "running" if rc is None else f"exited ({rc})",
                    "buffered_lines": len(mp.lines),
                    "elapsed_sec": round((mp.ended_at or time.time()) - mp.started_at, 2),
                }
            )
        return out


def register_process_tools(tool: Callable[[dict[str, Any]], Any], config: ServerConfig, proc_mgr: ProcessManager) -> None:
    has_writable_profile = any(
        p.get("enabled", True) and not (config.read_only if p.get("inherit_permissions", True) else p.get("read_only", False))
        for p in (config.profiles or [])
    )
    if config.read_only and not has_writable_profile:
        return

    @tool(DESTRUCTIVE_ANN)
    def run_command(
        command: Annotated[str, Field(description="Shell command to execute.")],
        cwd: Annotated[str | None, Field(description="Working directory (defaults to server cwd or first root).")] = None,
        timeout: Annotated[int, Field(description="Timeout in seconds.", ge=1, le=600)] = config.default_timeout,
        shell: Annotated[Literal["auto", "cmd", "powershell", "bash", "sh"], Field(description="Shell to invoke.")] = "auto",
        env: Annotated[dict[str, str] | None, Field(description="Extra environment variables.")] = None,
    ) -> str:
        """Execute a command synchronously with UTF-8/GBK decoding, head+tail truncation, and process-tree timeout kill."""
        roots = get_effective_policy(config).roots
        work_dir = normalize_path(cwd, roots) if cwd else (roots[0] if roots else Path.cwd())
        if err := check_access(work_dir, config):
            return f"Error: {err}"
        if not work_dir.is_dir():
            return f"Error: cwd is not a directory: {work_dir}"

        mp = proc_mgr.start(command=command, cwd=work_dir, shell=shell, env=env)
        try:
            rc = mp.proc.wait(timeout=timeout)
            timed_out = False
        except subprocess.TimeoutExpired:
            proc_mgr.kill_tree(mp.proc)
            rc = -1
            timed_out = True

        time.sleep(0.05)
        with mp.lock:
            output = "\n".join(mp.lines)
        output, _ = truncate_head_tail(output, config.max_cmd_chars)

        status = f"TIMEOUT after {timeout}s (process tree killed)" if timed_out else f"exit_code={rc}"
        header = f"[{status}] cwd={work_dir}"
        return f"{header}\n{output}" if output else f"{header}\n(no output)"

    @tool(DESTRUCTIVE_ANN)
    def start_process(
        command: Annotated[str, Field(description="Long-running command to start in the background.")],
        cwd: Annotated[str | None, Field(description="Working directory.")] = None,
        shell: Annotated[Literal["auto", "cmd", "powershell", "bash", "sh"], Field(description="Shell to invoke.")] = "auto",
        env: Annotated[dict[str, str] | None, Field(description="Extra environment variables.")] = None,
    ) -> str:
        """Start a background process (e.g. build, dev server) and return its process_id."""
        roots = get_effective_policy(config).roots
        work_dir = normalize_path(cwd, roots) if cwd else (roots[0] if roots else Path.cwd())
        if err := check_access(work_dir, config):
            return f"Error: {err}"
        if not work_dir.is_dir():
            return f"Error: cwd is not a directory: {work_dir}"

        mp = proc_mgr.start(command=command, cwd=work_dir, shell=shell, env=env)
        return json.dumps(
            {"process_id": mp.process_id, "pid": mp.proc.pid, "cwd": str(work_dir), "status": "running"},
            indent=2,
        )

    @tool(DESTRUCTIVE_ANN)
    def manage_process(
        action: Annotated[Literal["list", "read", "write", "kill"], Field(description="Action on managed background processes.")],
        process_id: Annotated[str | None, Field(description="Target process_id (required for read/write/kill).")] = None,
        input_text: Annotated[str | None, Field(description="Text to send to stdin (for action='write').")] = None,
        tail_lines: Annotated[int, Field(description="Number of recent output lines to return (for action='read').", ge=1, le=2000)] = 100,
    ) -> str:
        """List, read output from, send stdin to, or terminate background processes."""
        if action == "list":
            return json.dumps(proc_mgr.list_all(), indent=2, ensure_ascii=False)

        if not process_id:
            return f"Error: 'process_id' is required for action='{action}'."
        mp = proc_mgr.get(process_id)
        if mp is None:
            return f"Error: Unknown process_id '{process_id}'."

        rc = mp.proc.poll()
        if action == "read":
            with mp.lock:
                recent = list(mp.lines)[-tail_lines:]
            body, _ = truncate_head_tail("\n".join(recent), config.max_cmd_chars)
            status = "running" if rc is None else f"exited ({rc})"
            return f"[{mp.process_id} | pid={mp.proc.pid} | {status}]\n{body or '(no output yet)'}"

        if action == "write":
            if rc is not None:
                return f"Error: Process {process_id} already exited ({rc})."
            if input_text is None:
                return "Error: 'input_text' is required for action='write'."
            assert mp.proc.stdin is not None
            mp.proc.stdin.write(input_text.encode("utf-8"))
            mp.proc.stdin.flush()
            return f"Sent {len(input_text)} chars to process {process_id}."

        if action == "kill":
            proc_mgr.kill_tree(mp.proc)
            return f"Terminated process {process_id} (pid={mp.proc.pid})."

        return f"Error: Unsupported action '{action}'."
