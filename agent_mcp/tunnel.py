"""Cloudflare Tunnel (cloudflared) manager supporting Token (named) and Quick Tunnel modes."""

from __future__ import annotations

import json
import os
import platform
import re
import shutil
import subprocess
import tarfile
import threading
import time
import urllib.request
from pathlib import Path
from typing import Any

from .config import DATA_DIR, PROJECT_ROOT, TUNNEL_STATE_PATH, ensure_storage_layout

BIN_DIR = PROJECT_ROOT / "bin"
_QUICK_URL_RE = re.compile(r"https://[a-z0-9-]+\.trycloudflare\.com", re.IGNORECASE)

_INSTALL_LOCK = threading.Lock()
_INSTALL_PAUSE = threading.Event()
_INSTALL_CANCEL = threading.Event()
_INSTALL_STATE: dict[str, Any] = {
    "active": False,
    "paused": False,
    "downloaded": 0,
    "total": 0,
    "percent": 0,
    "status": "",
    "error": "",
}


def get_cloudflared_download_info() -> dict[str, Any]:
    """Return official GitHub release asset, URL, and local target path for current OS/arch."""
    machine = platform.machine().lower()
    if os.name == "nt":
        asset = "cloudflared-windows-amd64.exe" if ("64" in machine or "amd64" in machine) else "cloudflared-windows-386.exe"
        target = BIN_DIR / "cloudflared.exe"
    elif platform.system().lower() == "darwin":
        asset = "cloudflared-darwin-arm64.tgz" if "arm" in machine else "cloudflared-darwin-amd64.tgz"
        target = BIN_DIR / "cloudflared"
    else:
        asset = "cloudflared-linux-arm64" if ("arm" in machine or "aarch64" in machine) else "cloudflared-linux-amd64"
        target = BIN_DIR / "cloudflared"
    return {
        "asset": asset,
        "target": target,
        "download_url": f"https://github.com/cloudflare/cloudflared/releases/latest/download/{asset}",
        "releases_url": "https://github.com/cloudflare/cloudflared/releases/latest",
    }


def get_install_status() -> dict[str, Any]:
    with _INSTALL_LOCK:
        return dict(_INSTALL_STATE)


def _set_install_state(**kwargs: Any) -> None:
    with _INSTALL_LOCK:
        _INSTALL_STATE.update(kwargs)


def find_cloudflared() -> Path | None:
    """Locate cloudflared binary in project bin/, PATH, or standard Windows install locations."""
    exe = "cloudflared.exe" if os.name == "nt" else "cloudflared"
    local_bin = BIN_DIR / exe
    if local_bin.is_file():
        return local_bin
    found = shutil.which("cloudflared")
    if found:
        return Path(found)
    if os.name == "nt":
        for p in (
            Path(r"C:\Program Files (x86)\cloudflared\cloudflared.exe"),
            Path(r"C:\Program Files\cloudflared\cloudflared.exe"),
            Path(os.path.expandvars(r"%LOCALAPPDATA%\Microsoft\WinGet\Links\cloudflared.exe")),
        ):
            if p.is_file():
                return p
    else:
        for p in (
            Path("/opt/homebrew/bin/cloudflared"),
            Path("/usr/local/bin/cloudflared"),
            Path("/usr/bin/cloudflared"),
        ):
            if p.is_file():
                return p
    return None


_VER_CACHE: dict[str, Any] = {"path": "", "version": ""}


def get_cloudflared_version(binary: Path | None) -> str:
    if not binary or not binary.is_file():
        return ""
    p_str = str(binary)
    if _VER_CACHE["path"] == p_str and _VER_CACHE["version"]:
        return _VER_CACHE["version"]
    try:
        kw: dict[str, Any] = {"capture_output": True, "timeout": 5, "check": False}
        if os.name == "nt":
            kw["creationflags"] = subprocess.CREATE_NO_WINDOW
        res = subprocess.run([p_str, "--version"], **kw)
        out = res.stdout.decode("utf-8", errors="ignore").strip() or res.stderr.decode("utf-8", errors="ignore").strip()
        m = re.search(r"version\s+([0-9]+\.[0-9]+\.[0-9]+)", out, re.IGNORECASE)
        ver = m.group(1) if m else (out.splitlines()[0][:40] if out else "")
        _VER_CACHE["path"] = p_str
        _VER_CACHE["version"] = ver
        return ver
    except Exception:
        return ""


def uninstall_cloudflared() -> dict[str, Any]:
    """Remove project-local bin/cloudflared (never touches system-installed binaries)."""
    TUNNEL_MANAGER.stop_all()
    exe = "cloudflared.exe" if os.name == "nt" else "cloudflared"
    local_bin = BIN_DIR / exe
    if not local_bin.is_file():
        return {"ok": False, "error": "仅支持移除项目 bin/ 目录内由本应用下载的 cloudflared。"}
    try:
        local_bin.unlink()
        _VER_CACHE["path"] = ""
        _VER_CACHE["version"] = ""
        return {"ok": True, "message": "已移除本地 cloudflared"}
    except Exception as exc:
        return {"ok": False, "error": f"移除失败: {exc}"}


def _download_worker(force_update: bool, resume: bool) -> None:
    info = get_cloudflared_download_info()
    asset: str = info["asset"]
    target: Path = info["target"]
    url: str = info["download_url"]
    BIN_DIR.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(".downloading")
    existing_bytes = tmp.stat().st_size if (resume and tmp.is_file()) else 0
    if not resume:
        tmp.unlink(missing_ok=True)
        existing_bytes = 0

    try:
        headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0.0.0"}
        if existing_bytes > 0:
            headers["Range"] = f"bytes={existing_bytes}-"
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=60) as resp:
            status_code = getattr(resp, "status", 200)
            if existing_bytes > 0 and status_code == 206:
                mode = "ab"
                downloaded = existing_bytes
                cl = int(resp.headers.get("Content-Length") or 0)
                total = (existing_bytes + cl) if cl > 0 else 0
            else:
                mode = "wb"
                downloaded = 0
                total = int(resp.headers.get("Content-Length") or 0)

            pct = int(min(99, round(downloaded * 100 / total))) if total > 0 else 0
            _set_install_state(active=True, paused=False, total=total, downloaded=downloaded, percent=pct, status="正在下载 cloudflared...", error="")

            with tmp.open(mode) as f:
                while True:
                    if _INSTALL_CANCEL.is_set():
                        break
                    if _INSTALL_PAUSE.is_set():
                        break
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    f.write(chunk)
                    downloaded += len(chunk)
                    pct = int(min(99, round(downloaded * 100 / total))) if total > 0 else 0
                    mb_done = downloaded / 1_048_576
                    if total > 0:
                        mb_tot = total / 1_048_576
                        st_txt = f"下载中 {mb_done:.1f} / {mb_tot:.1f} MB ({pct}%)"
                    else:
                        st_txt = f"下载中 {mb_done:.1f} MB..."
                    _set_install_state(downloaded=downloaded, total=total, percent=pct, status=st_txt)

        if _INSTALL_CANCEL.is_set():
            tmp.unlink(missing_ok=True)
            _set_install_state(active=False, paused=False, downloaded=0, total=0, percent=0, status="", error="")
            return

        if _INSTALL_PAUSE.is_set():
            mb_done = downloaded / 1_048_576
            if total > 0:
                mb_tot = total / 1_048_576
                st_txt = f"已暂停 {mb_done:.1f} / {mb_tot:.1f} MB ({pct}%)"
            else:
                st_txt = f"已暂停 {mb_done:.1f} MB"
            _set_install_state(active=False, paused=True, downloaded=downloaded, total=total, percent=pct, status=st_txt, error="")
            return

        if asset.endswith(".tgz"):
            _set_install_state(status="正在解压安装包...", percent=99)
            with tarfile.open(tmp, "r:gz") as tf:
                member = next((m for m in tf.getmembers() if m.isfile() and Path(m.name).name == "cloudflared"), None)
                if member is None:
                    raise RuntimeError("压缩包中未找到 cloudflared 可执行文件")
                src_f = tf.extractfile(member)
                if src_f is None:
                    raise RuntimeError("无法解压 cloudflared")
                with target.open("wb") as out_f:
                    shutil.copyfileobj(src_f, out_f)
            tmp.unlink(missing_ok=True)
        else:
            tmp.replace(target)
        if os.name != "nt":
            os.chmod(target, 0o755)
        _VER_CACHE["path"] = ""
        _VER_CACHE["version"] = ""
        _set_install_state(active=False, paused=False, percent=100, status="安装完成", error="")
    except Exception as exc:
        if _INSTALL_CANCEL.is_set():
            tmp.unlink(missing_ok=True)
            _set_install_state(active=False, paused=False, downloaded=0, total=0, percent=0, status="", error="")
            return
        if _INSTALL_PAUSE.is_set():
            _set_install_state(active=False, paused=True, status="已暂停", error="")
            return
        err_msg = f"下载失败: {exc}"
        _set_install_state(active=False, paused=False, error=err_msg, status="")


def start_cloudflared_download(force_update: bool = False, resume: bool = False) -> dict[str, Any]:
    """Start or resume background download of official cloudflared binary."""
    existing = find_cloudflared()
    if existing and not force_update and not resume:
        _set_install_state(active=False, paused=False, percent=100, status="已安装", error="")
        return {"ok": True, "path": str(existing), "message": f"已检测到 cloudflared: {existing}"}
    if force_update and not resume:
        TUNNEL_MANAGER.stop_all()

    with _INSTALL_LOCK:
        if _INSTALL_STATE["active"]:
            return {"ok": True, "in_progress": True, "message": "正在下载中..."}
        _INSTALL_PAUSE.clear()
        _INSTALL_CANCEL.clear()
        if resume and _INSTALL_STATE.get("paused"):
            _INSTALL_STATE.update(active=True, paused=False, status="正在恢复下载...", error="")
        else:
            resume = False
            _INSTALL_STATE.update(active=True, paused=False, downloaded=0, total=0, percent=0, status="正在连接下载源...", error="")

    threading.Thread(target=_download_worker, args=(force_update, resume), daemon=True, name="cloudflared-dl").start()
    return {"ok": True, "started": True, "message": "已继续下载" if resume else "已开始下载 cloudflared"}


def pause_cloudflared_download() -> dict[str, Any]:
    with _INSTALL_LOCK:
        if not _INSTALL_STATE["active"]:
            return {"ok": False, "error": "当前没有进行中的下载"}
    _INSTALL_PAUSE.set()
    return {"ok": True, "message": "正在暂停下载..."}


def cancel_cloudflared_download() -> dict[str, Any]:
    _INSTALL_CANCEL.set()
    _INSTALL_PAUSE.clear()
    info = get_cloudflared_download_info()
    tmp = info["target"].with_suffix(".downloading")
    with _INSTALL_LOCK:
        was_active = bool(_INSTALL_STATE["active"])
        if not was_active:
            tmp.unlink(missing_ok=True)
            _INSTALL_STATE.update(active=False, paused=False, downloaded=0, total=0, percent=0, status="", error="")
    return {"ok": True, "message": "已取消下载"}


def import_cloudflared_bytes(filename: str, data: bytes) -> dict[str, Any]:
    """Import a manually downloaded cloudflared binary or .tgz archive into project bin/."""
    if not data or len(data) < 100_000:
        return {"ok": False, "error": "文件过小，不像有效的 cloudflared 可执行文件或压缩包。"}

    name_l = (filename or "").lower()
    is_tgz = name_l.endswith(".tgz") or name_l.endswith(".tar.gz") or data[:2] == b"\x1f\x8b"
    if not is_tgz:
        valid_magic = (
            data[:2] == b"MZ"  # Windows PE
            or data[:4] == b"\x7fELF"  # Linux ELF
            or data[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe")  # macOS Mach-O
        )
        if not valid_magic:
            return {"ok": False, "error": "文件格式不受支持，请选择官方下载的 cloudflared 可执行文件或 .tgz 压缩包。"}

    cancel_cloudflared_download()
    TUNNEL_MANAGER.stop_all()
    info = get_cloudflared_download_info()
    target: Path = info["target"]
    BIN_DIR.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(".importing")
    try:
        tmp.write_bytes(data)
        if is_tgz:
            with tarfile.open(tmp, "r:gz") as tf:
                member = next((m for m in tf.getmembers() if m.isfile() and Path(m.name).name in ("cloudflared", "cloudflared.exe")), None)
                if member is None:
                    raise RuntimeError("压缩包中未找到 cloudflared 可执行文件")
                src_f = tf.extractfile(member)
                if src_f is None:
                    raise RuntimeError("无法解压 cloudflared")
                with target.open("wb") as out_f:
                    shutil.copyfileobj(src_f, out_f)
            tmp.unlink(missing_ok=True)
        else:
            tmp.replace(target)
        if os.name != "nt":
            os.chmod(target, 0o755)
        _VER_CACHE["path"] = ""
        _VER_CACHE["version"] = ""
        ver = get_cloudflared_version(target)
        _set_install_state(active=False, paused=False, percent=100, status="导入完成", error="")
        return {"ok": True, "path": str(target), "version": ver, "message": f"已导入 cloudflared{(' v' + ver) if ver else ''}"}
    except Exception as exc:
        tmp.unlink(missing_ok=True)
        return {"ok": False, "error": f"导入失败: {exc}"}


def install_cloudflared(force_update: bool = False) -> dict[str, Any]:
    return start_cloudflared_download(force_update=force_update, resume=False)


def load_tunnel_state() -> dict[str, Any]:
    ensure_storage_layout()
    if not TUNNEL_STATE_PATH.is_file():
        return {}
    try:
        data = json.loads(TUNNEL_STATE_PATH.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


class _TunnelProc:
    def __init__(self, profile_id: str, mode: str, proc: subprocess.Popen[bytes]) -> None:
        self.profile_id = profile_id
        self.mode = mode
        self.proc = proc
        self.live_url: str = ""
        self.connected: bool = False
        self.error: str = ""
        self.stopped: bool = False
        self.last_lines: list[str] = []
        self.started_at: float = time.time()


class TunnelManager:
    """Manages per-profile cloudflared child processes (silent, zero black console windows)."""

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._procs: dict[str, _TunnelProc] = {}

    def _persist_state(self) -> None:
        ensure_storage_layout()
        with self._lock:
            payload: dict[str, Any] = {}
            for pid, tp in self._procs.items():
                if tp.proc.poll() is None:
                    payload[pid] = {
                        "mode": tp.mode,
                        "live_url": tp.live_url,
                        "connected": tp.connected,
                        "pid": tp.proc.pid,
                    }
        try:
            TUNNEL_STATE_PATH.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        except Exception:
            pass

    def get_statuses(self) -> dict[str, Any]:
        binary = find_cloudflared()
        disk_state = load_tunnel_state()
        with self._lock:
            tunnels: dict[str, Any] = {}
            for pid, tp in list(self._procs.items()):
                running = tp.proc.poll() is None
                tunnels[pid] = {
                    "running": running,
                    "mode": tp.mode,
                    "live_url": tp.live_url,
                    "connected": tp.connected and running,
                    "error": tp.error,
                    "pid": tp.proc.pid if running else None,
                }
            # Merge disk state when queried from the MCP server subprocess (/dashboard)
            for pid, info in disk_state.items():
                if pid not in tunnels:
                    tunnels[pid] = {
                        "running": True,
                        "mode": info.get("mode", ""),
                        "live_url": info.get("live_url", ""),
                        "connected": bool(info.get("connected", False)),
                        "error": "",
                        "pid": info.get("pid"),
                    }
            exe = "cloudflared.exe" if os.name == "nt" else "cloudflared"
            local_managed = bool(binary and binary.resolve() == (BIN_DIR / exe).resolve())
            dl_info = get_cloudflared_download_info()
            return {
                "installed": binary is not None,
                "binary": str(binary) if binary else None,
                "version": get_cloudflared_version(binary),
                "local_managed": local_managed,
                "download_url": dl_info["download_url"],
                "releases_url": dl_info["releases_url"],
                "asset": dl_info["asset"],
                "install": get_install_status(),
                "tunnels": tunnels,
            }

    def start_tunnel(self, profile: dict[str, Any], local_port: int) -> dict[str, Any]:
        pid = str(profile.get("id") or "default")
        mode = str(profile.get("tunnel_mode") or "none").lower()
        if mode not in ("token", "quick"):
            return {"ok": False, "error": "该入口未启用 Cloudflared 隧道模式。"}

        binary = find_cloudflared()
        if not binary:
            return {"ok": False, "error": "未检测到 cloudflared，请先点击「一键下载 cloudflared」。"}

        self.stop_tunnel(pid)

        if mode == "token":
            token = str(profile.get("tunnel_token") or "").strip()
            if not token:
                return {"ok": False, "error": "Token 固定隧道模式必须填写 Cloudflare Tunnel Token。"}
            # Auto-extract token if user pasted full `cloudflared service install <token>` command
            parts = token.split()
            if len(parts) > 1:
                token = parts[-1].strip()
            cmd = [str(binary), "tunnel", "--no-autoupdate", "run", "--token", token]
        else:
            cmd = [str(binary), "tunnel", "--no-autoupdate", "--url", f"http://127.0.0.1:{int(local_port)}"]

        env = os.environ.copy()
        if not (env.get("HTTPS_PROXY") or env.get("https_proxy") or env.get("HTTP_PROXY") or env.get("http_proxy")):
            try:
                sys_proxies = urllib.request.getproxies()
                https_p = sys_proxies.get("https") or sys_proxies.get("http")
                http_p = sys_proxies.get("http") or sys_proxies.get("https")
                if https_p:
                    env["HTTPS_PROXY"] = https_p
                    env["https_proxy"] = https_p
                if http_p:
                    env["HTTP_PROXY"] = http_p
                    env["http_proxy"] = http_p
                if https_p or http_p:
                    existing_no = env.get("NO_PROXY") or env.get("no_proxy") or ""
                    no_parts = [x.strip() for x in existing_no.split(",") if x.strip()]
                    for local_h in ("127.0.0.1", "localhost", "::1"):
                        if local_h not in no_parts:
                            no_parts.append(local_h)
                    no_val = ",".join(no_parts)
                    env["NO_PROXY"] = no_val
                    env["no_proxy"] = no_val
            except Exception:
                pass

        kw: dict[str, Any] = {
            "stdin": subprocess.DEVNULL,
            "stdout": subprocess.PIPE,
            "stderr": subprocess.STDOUT,
            "env": env,
        }
        if os.name == "nt":
            kw["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW
            si = subprocess.STARTUPINFO()
            si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            si.wShowWindow = 0
            kw["startupinfo"] = si
        else:
            kw["start_new_session"] = True

        try:
            proc = subprocess.Popen(cmd, **kw)
        except Exception as exc:
            return {"ok": False, "error": f"启动 cloudflared 失败: {exc}"}

        tp = _TunnelProc(pid, mode, proc)
        with self._lock:
            self._procs[pid] = tp
        self._persist_state()

        def _reader() -> None:
            assert proc.stdout is not None
            try:
                for raw in iter(proc.stdout.readline, b""):
                    line = raw.decode("utf-8", errors="replace").strip()
                    if not line:
                        continue
                    tp.last_lines.append(line)
                    if len(tp.last_lines) > 12:
                        tp.last_lines.pop(0)
                    changed = False
                    if mode == "quick":
                        m = _QUICK_URL_RE.search(line)
                        if m and not tp.live_url:
                            tp.live_url = m.group(0).rstrip("/")
                            tp.connected = True
                            changed = True
                    if "Registered tunnel connection" in line or "Connection registered" in line:
                        if not tp.connected:
                            tp.connected = True
                            changed = True
                    low = line.lower()
                    if ("err " in low or "error" in low or "not valid" in low or "failed" in low) and (
                        "failed" in low or "unauthorized" in low or "invalid" in low or "not valid" in low or "unable" in low or "cannot" in low
                    ):
                        tp.error = line[-240:]
                    if changed:
                        self._persist_state()
            finally:
                rc = proc.wait()
                if not tp.stopped and rc != 0 and not tp.error:
                    hint = ""
                    for ln in reversed(tp.last_lines):
                        if any(k in ln.lower() for k in ("err", "fail", "invalid", "not valid", "unable", "denied", "timeout", "refused", "usage")):
                            hint = ln[-220:]
                            break
                    if not hint and tp.last_lines:
                        hint = tp.last_lines[-1][-220:]
                    tp.error = f"{hint} (code={rc})" if hint else f"cloudflared 已退出 (code={rc})"
                tp.connected = False
                self._persist_state()

        threading.Thread(target=_reader, daemon=True).start()
        return {"ok": True, "pid": proc.pid, "mode": mode}

    def stop_tunnel(self, profile_id: str) -> dict[str, Any]:
        with self._lock:
            tp = self._procs.pop(profile_id, None)
        if tp:
            tp.stopped = True
        if tp and tp.proc.poll() is None:
            if os.name == "nt":
                subprocess.run(
                    ["taskkill", "/F", "/T", "/PID", str(tp.proc.pid)],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    creationflags=subprocess.CREATE_NO_WINDOW,
                    check=False,
                )
            else:
                try:
                    tp.proc.terminate()
                    tp.proc.wait(timeout=3)
                except Exception:
                    tp.proc.kill()
        self._persist_state()
        return {"ok": True}

    def start_auto_tunnels(self, profiles: list[dict[str, Any]], local_port: int) -> None:
        for p in profiles:
            if p.get("enabled", True) and p.get("tunnel_mode") in ("token", "quick") and p.get("tunnel_auto_start", True):
                self.start_tunnel(p, local_port)

    def stop_all(self) -> None:
        with self._lock:
            pids = list(self._procs.keys())
        for pid in pids:
            self.stop_tunnel(pid)


TUNNEL_MANAGER = TunnelManager()
