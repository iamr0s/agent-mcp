"""Claude / Anthropic editorial-style Local Web Console with System Tray & App Window."""

from __future__ import annotations

import asyncio
import json
import os
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import threading
import urllib.parse
import urllib.request
import webbrowser
from collections import deque
from pathlib import Path
from typing import Any

from . import VERSION
from .auth import hash_password
from .config import (
    APP_ICON_PATH,
    DATA_DIR,
    PROJECT_ROOT,
    WINDOW_STATE_PATH,
    clean_storage,
    ensure_profiles_in_config,
    get_storage_stats,
    load_saved_config,
    normalize_profile,
    sanitize_prefix,
    save_config_file,
)
from .file_tools import decode_bytes_smart
from .logging_utils import JSON_EVENT_PREFIX
from .sub_mcp import SUB_MCP_MANAGER
from .tray import APP_ICON_DATA_URI, ensure_app_icon, start_system_tray
from .tunnel import (
    TUNNEL_MANAGER,
    cancel_cloudflared_download,
    import_cloudflared_bytes,
    pause_cloudflared_download,
    start_cloudflared_download,
    uninstall_cloudflared,
)


def _find_port_owner(port: int) -> int | None:
    """Return PID listening on `port` (excluding current process), or None."""
    # Fast 50ms TCP probe: skip slow `netstat` subprocess completely when port is free!
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.05):
            pass
    except OSError:
        return None
    my_pid = os.getpid()
    if os.name == "nt":
        try:
            out = subprocess.check_output(
                ["netstat", "-ano", "-p", "TCP"],
                stderr=subprocess.DEVNULL,
                creationflags=subprocess.CREATE_NO_WINDOW,
            ).decode("utf-8", errors="ignore")
            for line in out.splitlines():
                parts = line.split()
                if len(parts) >= 5 and parts[3].upper() == "LISTENING":
                    local_addr = parts[1]
                    if local_addr.endswith(f":{port}"):
                        pid = int(parts[4])
                        if pid > 0 and pid != my_pid:
                            return pid
        except Exception:
            pass
    else:
        for cmd in (["lsof", "-t", f"-iTCP:{port}", "-sTCP:LISTEN"], ["fuser", f"{port}/tcp"]):
            try:
                out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode("utf-8", errors="ignore").strip()
                for tok in out.split():
                    if tok.isdigit() and int(tok) != my_pid:
                        return int(tok)
            except Exception:
                continue
    return None


def _kill_pid_tree(pid: int) -> bool:
    try:
        if os.name == "nt":
            subprocess.run(
                ["taskkill", "/F", "/T", "/PID", str(pid)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                creationflags=subprocess.CREATE_NO_WINDOW,
                check=False,
            )
        else:
            os.kill(pid, signal.SIGTERM)
        return True
    except Exception:
        return False


def _ask_styled_yes_no(title: str, message: str, confirm_text: str = "结束旧实例并启动", cancel_text: str = "取消") -> bool:
    """Claude-styled frameless confirmation dialog using pywebview (with native fallback)."""
    try:
        import html as _html
        import webview

        choice = {"yes": False}
        win_box: dict[str, Any] = {"w": None}

        class DialogApi:
            def choose(self, yes: bool) -> None:
                choice["yes"] = bool(yes)
                if win_box["w"]:
                    win_box["w"].destroy()

        t_esc = _html.escape(title)
        m_esc = _html.escape(message).replace("\n", "<br/>")
        c_esc = _html.escape(confirm_text)
        x_esc = _html.escape(cancel_text)
        dpi_scale = 1.0
        if os.name == "nt":
            try:
                import ctypes

                dpi = ctypes.windll.user32.GetDpiForSystem()
                if dpi and dpi >= 96:
                    dpi_scale = dpi / 96.0
            except Exception:
                pass
        dlg_w = int(round(460 * dpi_scale))
        dlg_h = int(round(240 * dpi_scale))
        dlg_html = f"""<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>
        :root{{--paper:#FAF9F5;--paper-2:#F3F1EA;--paper-3:#E8E6DC;--ink:#141413;--muted:#57554F;--hairline:#E3E0D6;--clay:#D97757;--clay-h:#C46142}}
        @media (prefers-color-scheme: dark){{:root{{--paper:#1A1917;--paper-2:#23221F;--paper-3:#2E2D29;--ink:#F3F1EA;--muted:#9C988E;--hairline:#35332E;--clay:#E08263;--clay-h:#EC9477}}}}
        *{{box-sizing:border-box}}
        html,body{{margin:0;width:100%;height:100%;background:var(--paper);color:var(--ink);font-family:"Plus Jakarta Sans","Microsoft YaHei UI",system-ui,sans-serif;overflow:hidden}}
        .wrap{{width:100%;height:100%;border:1px solid var(--hairline);display:flex;flex-direction:column;justify-content:space-between;padding:22px 24px 20px;gap:14px}}
        .hdr{{display:flex;align-items:center;gap:10px}}
        .title{{font-family:"Newsreader","Georgia",serif;font-size:19px;font-weight:500}}
        .msg{{font-size:13.5px;line-height:1.65;color:var(--muted);margin:10px 0 0;word-break:break-word;overflow-y:auto}}
        .btns{{display:flex;justify-content:flex-end;gap:10px;flex-shrink:0}}
        button{{padding:8px 16px;border-radius:10px;font:inherit;font-size:13px;font-weight:600;cursor:pointer;outline:none;-webkit-tap-highlight-color:transparent;touch-action:manipulation;white-space:nowrap;transition:transform .11s cubic-bezier(.22,1,.36,1),background .14s,box-shadow .14s,filter .12s}}
        button:active{{transform:scale(.955);filter:brightness(.93)}}
        .cancel{{background:var(--paper-2);border:1px solid var(--hairline);color:var(--ink)}}
        .cancel:hover{{background:var(--paper-3)}}
        .ok{{background:var(--clay);border:1px solid var(--clay);color:#FAF9F5;box-shadow:0 2px 8px rgba(217,119,87,.28)}}
        .ok:hover{{background:var(--clay-h)}}
        </style></head><body><div class="wrap">
        <div style="min-height:0;display:flex;flex-direction:column"><div class="hdr"><svg width="18" height="18" viewBox="0 0 24 24" fill="none"><path d="M12 2L14.2 9.2L21.5 11.5L14.2 13.8L12 21L9.8 13.8L2.5 11.5L9.8 9.2L12 2Z" fill="#D97757"/></svg><div class="title">{t_esc}</div></div>
        <div class="msg">{m_esc}</div></div>
        <div class="btns"><button class="cancel" onclick="window.pywebview.api.choose(false)">{x_esc}</button><button class="ok" onclick="window.pywebview.api.choose(true)">{c_esc}</button></div>
        </div></body></html>"""
        win_box["w"] = webview.create_window(
            title=title,
            html=dlg_html,
            width=dlg_w,
            height=dlg_h,
            frameless=True,
            resizable=False,
            on_top=True,
            js_api=DialogApi(),
            background_color="#FAF9F5",
        )
        webview.start()
        return choice["yes"]
    except Exception:
        if os.name == "nt":
            try:
                import ctypes

                return ctypes.windll.user32.MessageBoxW(0, message, title, 0x04 | 0x20 | 0x40000) == 6
            except Exception:
                pass
        return False


class GuiController:
    def __init__(self, config_path: Path) -> None:
        self.config_path = config_path
        self.proc: subprocess.Popen[bytes] | None = None
        self.lock = threading.Lock()
        self.logs: deque[dict[str, Any]] = deque(maxlen=4000)
        self.subscribers: set[asyncio.Queue[dict[str, Any]]] = set()
        self.loop: asyncio.AbstractEventLoop | None = None
        self.uvicorn_server: Any = None

    def get_config(self) -> dict[str, Any]:
        d = load_saved_config(self.config_path)
        d.setdefault("server_name", f"mcp-{socket.gethostname()}")
        d.setdefault("tool_prefix", "")
        d.setdefault("transport", "http")
        d.setdefault("host", "127.0.0.1")
        d.setdefault("port", 8000)
        d.setdefault("auth_mode", "bearer")
        d.setdefault("read_only", False)
        d.setdefault("allow_secrets", False)
        d.setdefault("roots", [])
        d.setdefault("log_level", "INFO")
        d.setdefault("log_file", None)
        d.setdefault("auto_start", False)
        d["profiles"] = ensure_profiles_in_config(d)
        return d

    def is_running(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def _emit_event(self, ev: dict[str, Any]) -> None:
        self.logs.append(ev)
        if self.loop and self.subscribers:
            for q in list(self.subscribers):
                self.loop.call_soon_threadsafe(q.put_nowait, ev)

    def _emit_text_line(self, line: str) -> None:
        if line.startswith(JSON_EVENT_PREFIX):
            try:
                ev = json.loads(line[len(JSON_EVENT_PREFIX) :])
                ev.setdefault("isDep", False)
                self._emit_event(ev)
                return
            except Exception:
                pass
        # Skip plain text duplicate of tool call/ok/err/crash since structured JSON event was emitted
        if any(tag in line for tag in ("[TOOL CALL]", "[TOOL OK]", "[TOOL ERR]", "[TOOL CRASH]")):
            return
        import time as _t

        # Strip ANSI escapes & filter noisy blank lines / FastMCP ASCII banner art
        clean = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", line).strip()
        if not clean or any(ch in clean for ch in ("╭", "╰", "│", "─", "▀", "▄", "█")):
            return
        if clean.startswith(("FastMCP", "Server:", "Transport:", "Docs:", "Hosting:", "MCP")):
            return

        is_dep = "[dep:" in clean
        m = re.match(r"^(\d{4}-\d{2}-\d{2}\s+(\d{2}:\d{2}:\d{2}))\s+\[([A-Z]+)\s*\]\s+\[([^\]]+)\]\s+(.*)$", clean)
        ts = m.group(2) if m else _t.strftime("%H:%M:%S")
        lvl = m.group(3) if m else ("WARNING" if "[WARNING]" in clean else ("ERROR" if "[ERROR" in clean else "INFO"))
        body = m.group(5) if m else clean

        kind = "dep" if is_dep else "info"
        badge = "DEP" if is_dep else "SYSTEM"
        if not is_dep:
            mo = re.match(r"^\[(OAUTH [A-Z ]+|AUTH 401|PROC EXIT)\]\s*(.*)$", body)
            if mo:
                kind = "oauth"
                badge = mo.group(1).strip()
                body = mo.group(2)
            elif body.startswith("[GUI]"):
                badge = "GUI"
                body = body[5:].strip()
            elif lvl in ("WARNING", "ERROR", "CRITICAL"):
                kind = "err"
                badge = lvl

        ev = {
            "ts": ts,
            "kind": kind,
            "badge": badge,
            "level": lvl,
            "tool": "",
            "ms": None,
            "summary": body,
            "raw": clean,
            "isDep": is_dep,
        }
        self._emit_event(ev)

    def start(self, force_kill_conflict: bool = False) -> dict[str, Any]:
        with self.lock:
            if self.is_running():
                return {"ok": True, "pid": self.proc.pid if self.proc else None, "already_running": True}

            cfg = self.get_config()
            if cfg.get("transport") in ("http", "sse", "dual"):
                port = int(cfg.get("port", 8000))
                owner_pid = _find_port_owner(port)
                if owner_pid is not None:
                    if not force_kill_conflict:
                        return {
                            "ok": False,
                            "conflict": True,
                            "port": port,
                            "pid": owner_pid,
                            "message": f"端口 {port} 正被另一个进程 (PID {owner_pid}) 占用。",
                        }
                    _kill_pid_tree(owner_pid)
                    import time as _t

                    _t.sleep(0.35)
                    self._emit_text_line(f"[GUI] 已结束占用端口 {port} 的旧进程 (PID {owner_pid})")

            cmd = [sys.executable, "-m", "agent_mcp", "run", "--config", str(self.config_path), "--no-color"]
            env = os.environ.copy()
            env["PYTHONUNBUFFERED"] = "1"
            env["PYTHONIOENCODING"] = "utf-8"
            env["MCP_JSON_EVENTS"] = "1"
            kw: dict[str, Any] = {
                "stdout": subprocess.PIPE,
                "stderr": subprocess.STDOUT,
                "env": env,
                "cwd": str(PROJECT_ROOT),
            }
            if os.name == "nt":
                kw["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW
            else:
                kw["start_new_session"] = True

            self.proc = subprocess.Popen(cmd, **kw)
            proc_ref = self.proc
            self._emit_text_line(f"[GUI] 已启动服务进程 (pid={proc_ref.pid})")

            def _reader() -> None:
                assert proc_ref.stdout is not None
                for raw in iter(proc_ref.stdout.readline, b""):
                    self._emit_text_line(decode_bytes_smart(raw).rstrip("\r\n"))
                rc = proc_ref.wait()
                self._emit_text_line(f"[GUI] 服务进程已退出 (exit_code={rc})")

            threading.Thread(target=_reader, daemon=True).start()
            TUNNEL_MANAGER.start_auto_tunnels(cfg.get("profiles") or [], int(cfg.get("port", 8000)))
            return {"ok": True, "pid": proc_ref.pid}

    def stop(self) -> dict[str, Any]:
        TUNNEL_MANAGER.stop_all()
        with self.lock:
            if self.proc and self.proc.poll() is None:
                if os.name == "nt":
                    subprocess.run(
                        ["taskkill", "/F", "/T", "/PID", str(self.proc.pid)],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        creationflags=subprocess.CREATE_NO_WINDOW,
                        check=False,
                    )
                else:
                    try:
                        os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)
                    except Exception:
                        self.proc.kill()
            self.proc = None
        return {"ok": True}

    def shutdown_app(self) -> None:
        self.stop()
        if self.uvicorn_server is not None:
            self.uvicorn_server.should_exit = True


HTML_PAGE = r"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover" />
<link rel="icon" type="image/svg+xml" href="__FAVICON__" />
<title>Agent MCP Console</title>
<style>
:root{
  /* Anthropic / Claude official warm paper & slate tokens (Light) */
  --paper:#FAF9F5;
  --paper-2:#F3F1EA;
  --paper-3:#E8E6DC;
  --ink:#141413;
  --ink-soft:#30302E;
  --muted:#6E6C66;
  --hairline:#E3E0D6;
  --clay:#D97757;
  --clay-h:#C46142;
  --sage:#788C5D;
  --sage-bg:#EBF0E4;
  --term:#141413;
  --term-fg:#F3F1EA;
  --r-btn:10px;
  --r-card:14px;
  --font-serif:"Newsreader","Georgia","Noto Serif SC","Songti SC",serif;
  --font-sans:"Plus Jakarta Sans","PingFang SC","Microsoft YaHei UI",system-ui,-apple-system,sans-serif;
  --font-mono:"JetBrains Mono","Cascadia Mono","Consolas",ui-monospace,monospace;
}
/* Claude Dark Mode (follows OS or manual toggle) */
:root[data-theme="dark"]{
  --paper:#1A1917;
  --paper-2:#23221F;
  --paper-3:#2E2D29;
  --ink:#F3F1EA;
  --ink-soft:#D6D3CB;
  --muted:#9C988E;
  --hairline:#35332E;
  --clay:#E08263;
  --clay-h:#EC9477;
  --sage:#8FA672;
  --sage-bg:rgba(143,166,114,.18);
  --term:#121210;
  --term-fg:#EBE8E0;
}
@media (prefers-color-scheme: dark){
  :root:not([data-theme="light"]){
    --paper:#1A1917;
    --paper-2:#23221F;
    --paper-3:#2E2D29;
    --ink:#F3F1EA;
    --ink-soft:#D6D3CB;
    --muted:#9C988E;
    --hairline:#35332E;
    --clay:#E08263;
    --clay-h:#EC9477;
    --sage:#8FA672;
    --sage-bg:rgba(143,166,114,.18);
    --term:#121210;
    --term-fg:#EBE8E0;
  }
}
/* Smooth View-Transition circular theme ripple + fallback */
::view-transition-old(root),::view-transition-new(root){animation:none;mix-blend-mode:normal}
::view-transition-new(root){z-index:9999}
.theme-fade,.theme-fade *{transition:background-color .26s cubic-bezier(.22,1,.36,1),color .26s ease,border-color .26s ease,box-shadow .26s ease !important}

/* Frameless window 6px edge & corner resize handles (desktop only) */
.rz{position:fixed;z-index:250;background:transparent}
.rz.n{top:0;left:6px;right:6px;height:6px;cursor:ns-resize}
.rz.s{bottom:0;left:6px;right:6px;height:6px;cursor:ns-resize}
.rz.w{left:0;top:6px;bottom:6px;width:6px;cursor:ew-resize}
.rz.e{right:0;top:6px;bottom:6px;width:6px;cursor:ew-resize}
.rz.nw{top:0;left:0;width:10px;height:10px;cursor:nwse-resize}
.rz.ne{top:0;right:0;width:10px;height:10px;cursor:nesw-resize}
.rz.sw{bottom:0;left:0;width:10px;height:10px;cursor:nesw-resize}
.rz.se{bottom:0;right:0;width:10px;height:10px;cursor:nwse-resize}

/* Password input with inline eye toggle */
.pwd-wrap{position:relative;display:flex;align-items:center;width:100%}
.pwd-wrap.full{grid-column:2 / 4}
.pwd-wrap .input{width:100%;padding-right:36px}
.pwd-eye{position:absolute;right:6px;width:26px;height:26px;border:0;border-radius:6px;background:transparent;color:var(--muted);display:inline-flex;align-items:center;justify-content:center;cursor:pointer;outline:none;-webkit-tap-highlight-color:transparent;touch-action:manipulation;transition:background .12s,color .12s,transform .1s cubic-bezier(.22,1,.36,1)}
.pwd-eye:hover{background:var(--paper-3);color:var(--ink)}
.pwd-eye:active{transform:scale(.86);background:var(--paper-3)}
.pwd-eye svg{width:15px;height:15px}
*{box-sizing:border-box}
html,body{height:100%;width:100%;max-width:100%;margin:0;background:var(--paper);color:var(--ink);font-family:var(--font-sans);font-size:14px;-webkit-font-smoothing:antialiased;overflow:hidden}
.shell{display:grid;grid-template-columns:236px minmax(0,1fr);grid-template-rows:40px minmax(0,1fr) 34px;height:100vh;height:100dvh;width:100%;overflow:hidden;border:1px solid var(--hairline);transition:grid-template-columns .24s cubic-bezier(.22,1,.36,1)}
.shell.collapsed{grid-template-columns:64px minmax(0,1fr)}
/* Custom Frameless Titlebar (Claude warm-paper unified bar) */
.titlebar{grid-column:1 / 3;grid-row:1;background:var(--paper-2);border-bottom:1px solid var(--hairline);display:flex;align-items:center;justify-content:space-between;padding:0 0 0 10px;user-select:none;touch-action:none}
.tb-left{display:flex;align-items:center;gap:8px;flex:1;height:100%;min-width:0;touch-action:none}
.tb-toggle{width:30px;height:30px;border:0;border-radius:8px;background:transparent;color:var(--muted);display:inline-flex;align-items:center;justify-content:center;cursor:pointer;outline:none;-webkit-tap-highlight-color:transparent;transition:background .15s,color .15s,transform .12s;flex-shrink:0}
.tb-toggle:hover{background:var(--paper-3);color:var(--ink)}
.tb-toggle:active{transform:scale(.92)}
.tb-toggle svg{width:16px;height:16px}
.tb-title{font-family:var(--font-serif);font-size:14.5px;font-weight:500;color:var(--ink);letter-spacing:.01em;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tb-tag{font-size:11px;color:var(--muted);background:var(--paper-3);padding:1px 7px;border-radius:999px;flex-shrink:0}
.tb-controls{display:flex;align-items:stretch;height:100%}
.tb-btn{width:44px;height:100%;border:0;background:transparent;color:var(--ink-soft);display:inline-flex;align-items:center;justify-content:center;cursor:pointer;outline:none;-webkit-tap-highlight-color:transparent;transition:background .14s,color .14s,transform .1s}
.tb-btn:hover{background:var(--paper-3);color:var(--ink)}
.tb-btn:active{transform:scale(.92)}
.tb-btn.close:hover{background:#C94A4A;color:#FAF9F5}
.tb-btn svg{width:13px;height:13px;pointer-events:none}
.sidebar{grid-row:2;background:var(--paper-2);border-right:1px solid var(--hairline);display:flex;flex-direction:column;padding:16px 12px 14px;gap:16px;overflow:hidden;transition:padding .24s cubic-bezier(.22,1,.36,1)}
.shell.collapsed .sidebar{padding:16px 10px 14px}
.brand{padding:0 2px;display:flex;align-items:center;justify-content:flex-start;gap:10px;height:34px;flex-shrink:0;overflow:hidden;transition:padding .24s cubic-bezier(.22,1,.36,1),gap .24s cubic-bezier(.22,1,.36,1)}
.shell.collapsed .brand{padding:0 5px;gap:0}
.sb-collapse-btn{width:34px;height:34px;border:1px solid transparent;border-radius:9px;background:transparent;color:var(--muted);display:inline-flex;align-items:center;justify-content:center;cursor:pointer;outline:none;flex-shrink:0;-webkit-tap-highlight-color:transparent;touch-action:manipulation;transition:background .15s,color .15s,border-color .15s,transform .11s cubic-bezier(.22,1,.36,1)}
.sb-collapse-btn:hover{background:var(--paper-3);color:var(--ink)}
.sb-collapse-btn:active{transform:scale(.9)}
.brand-row{display:flex;align-items:center;gap:9px;min-width:0;padding-left:4px;transition:gap .24s cubic-bezier(.22,1,.36,1),padding .24s cubic-bezier(.22,1,.36,1)}
.shell.collapsed .brand-row{gap:0;padding-left:11px}
.spark{width:20px;height:20px;flex-shrink:0}
.brand-title{font-family:var(--font-serif);font-size:17.5px;font-weight:500;letter-spacing:-0.01em;color:var(--ink);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:170px;opacity:1;transform:translateX(0);transition:max-width .24s cubic-bezier(.22,1,.36,1),opacity .18s ease,transform .22s cubic-bezier(.22,1,.36,1)}
.nav-txt,.ctrl-txt,#sb-pill-txt{display:inline-block;white-space:nowrap;overflow:hidden;max-width:160px;opacity:1;transform:translateX(0);transition:max-width .24s cubic-bezier(.22,1,.36,1),opacity .18s ease,transform .22s cubic-bezier(.22,1,.36,1)}
.shell.collapsed .brand-title,.shell.collapsed .nav-txt,.shell.collapsed .ctrl-txt,.shell.collapsed #sb-pill-txt{max-width:0;opacity:0;transform:translateX(-6px);pointer-events:none}
.pill{display:inline-flex;align-items:center;gap:7px;font-size:12px;font-weight:600;padding:4px 10px;border-radius:999px;width:fit-content;max-width:140px;opacity:1;overflow:hidden;white-space:nowrap;background:var(--paper-3);color:var(--muted);transition:max-width .24s cubic-bezier(.22,1,.36,1),opacity .18s ease,padding .24s cubic-bezier(.22,1,.36,1),gap .24s cubic-bezier(.22,1,.36,1)}
.shell.collapsed .pill{max-width:0;opacity:0;padding:0;gap:0;pointer-events:none}
.pill .dot{width:7px;height:7px;border-radius:50%;background:#9C9A92;flex-shrink:0}
.pill.on{background:var(--sage-bg);color:#3E5425}
.pill.on .dot{background:var(--sage)}

.nav{display:flex;flex-direction:column;gap:4px;flex:1;width:100%}
.nav button{position:relative;display:flex;align-items:center;gap:10px;width:100%;height:38px;padding:0 12px;border:1px solid transparent;border-radius:10px;background:transparent;color:var(--muted);font:inherit;font-size:13.5px;font-weight:500;cursor:pointer;text-align:left;outline:none;-webkit-tap-highlight-color:transparent;touch-action:manipulation;overflow:hidden;transition:background .18s cubic-bezier(.22,1,.36,1),color .18s,transform .12s cubic-bezier(.22,1,.36,1),box-shadow .18s,padding .24s cubic-bezier(.22,1,.36,1),gap .24s cubic-bezier(.22,1,.36,1)}
.shell.collapsed .nav button{padding:0 13px;gap:0;overflow:visible}
.nav button svg{width:16px;height:16px;flex-shrink:0}
.nav button:focus-visible{box-shadow:0 0 0 2px rgba(217,119,87,.28)}
.nav button:hover{background:var(--paper-3);color:var(--ink)}
.nav button:active{transform:scale(.94)}
.nav button.active{background:var(--paper);border-color:var(--hairline);color:var(--ink);font-weight:600;box-shadow:0 2px 8px rgba(20,20,19,.05)}

.ctrl{display:flex;flex-direction:column;gap:8px;padding-top:14px;border-top:1px solid var(--hairline);width:100%}
.ctrl .btn{width:100%;height:38px;padding:0 12px;overflow:hidden;transition:transform .11s cubic-bezier(.22,1,.36,1),box-shadow .14s ease,background .14s,border-color .14s,filter .12s,padding .24s cubic-bezier(.22,1,.36,1),gap .24s cubic-bezier(.22,1,.36,1)}
.shell.collapsed .ctrl .btn{padding:0;gap:0}
#sb-collapse-ico{width:15px;height:15px;flex-shrink:0;transition:transform .24s cubic-bezier(.22,1,.36,1)}
.shell.collapsed #sb-collapse-ico{transform:rotate(180deg)}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:6px;padding:9px 15px;border-radius:var(--r-btn);border:1px solid var(--hairline);background:var(--paper);color:var(--ink);font:inherit;font-size:13.5px;font-weight:600;cursor:pointer;outline:none;-webkit-tap-highlight-color:transparent;touch-action:manipulation;box-shadow:0 1px 2px rgba(20,20,19,.04);transition:transform .11s cubic-bezier(.22,1,.36,1),box-shadow .14s ease,background .14s,border-color .14s,filter .12s;user-select:none}
.btn:focus-visible{box-shadow:0 0 0 3px rgba(217,119,87,.24)}
.btn:hover{background:var(--paper-3);box-shadow:0 3px 10px rgba(20,20,19,.08);transform:translateY(-1px)}
.btn:active{transform:translateY(1px) scale(.955) !important;box-shadow:0 0 1px rgba(20,20,19,.06);filter:brightness(.94)}
.btn:disabled{opacity:.58;cursor:not-allowed;transform:none !important;filter:none}
/* Anthropic inverse dark primary button + subtle clay accent only for start */
.btn.ink{background:var(--ink);border-color:var(--ink);color:var(--paper);box-shadow:0 2px 6px rgba(20,20,19,.16)}
.btn.ink:hover{background:#2A2A28;box-shadow:0 4px 12px rgba(20,20,19,.22)}
.btn.ink:active{filter:brightness(.88)}
.btn.clay{background:var(--clay);border-color:var(--clay);color:#FAF9F5;box-shadow:0 2px 8px rgba(217,119,87,.28)}
.btn.clay:hover{background:var(--clay-h);box-shadow:0 4px 14px rgba(217,119,87,.36)}
.btn.clay:active{background:var(--clay-h);filter:brightness(.92)}
.btn.danger{background:#B8443A;border-color:#B8443A;color:#FAF9F5;box-shadow:0 2px 8px rgba(184,68,58,.24)}
.btn.danger:hover{background:#9E372E;box-shadow:0 4px 14px rgba(184,68,58,.32)}
.btn.danger:active{background:#8E2F27}
.btn.sm{padding:6px 12px;font-size:12.5px}

.main{grid-row:2;display:flex;flex-direction:column;overflow:hidden;min-height:0;padding:22px 28px 16px;gap:16px}
@keyframes pageFade{from{opacity:0;transform:translateY(5px)}to{opacity:1;transform:none}}
.page{display:none;flex-direction:column;flex:1;min-height:0;height:100%;gap:16px;overflow:hidden}
.page.active{display:flex;animation:pageFade .2s cubic-bezier(.22,1,.36,1)}
.page-head{display:flex;align-items:baseline;justify-content:space-between;flex-shrink:0;gap:12px}
.page-head h1{margin:0;font-family:var(--font-serif);font-size:26px;font-weight:500;letter-spacing:-0.015em;color:var(--ink)}
.page-head .sub{font-size:13px;color:var(--muted);margin-left:10px;font-family:var(--font-sans)}

.toolbar{display:flex;align-items:center;gap:10px;flex-wrap:wrap;background:var(--paper-2);border:1px solid var(--hairline);border-radius:var(--r-card);padding:8px 12px;flex-shrink:0}
.seg-group{display:inline-flex;align-items:center;background:var(--paper);border:1px solid var(--hairline);border-radius:9px;padding:2px;gap:2px;flex-shrink:0}
.seg-btn{height:28px;padding:0 10px;border:0;border-radius:7px;background:transparent;color:var(--muted);font:inherit;font-size:12.5px;font-weight:500;cursor:pointer;outline:none;-webkit-tap-highlight-color:transparent;transition:background .15s,color .15s,transform .1s;white-space:nowrap}
.seg-btn:hover{color:var(--ink)}
.seg-btn:active{transform:scale(.95)}
.seg-btn.active{background:var(--ink);color:var(--paper);font-weight:600}
.search-box{position:relative;flex:1;min-width:160px;display:flex;align-items:center}
.search-box svg{position:absolute;left:10px;width:14px;height:14px;color:var(--muted);pointer-events:none}
.search-box .input{width:100%;padding-left:30px}
.input{height:34px;background:var(--paper);border:1px solid var(--hairline);border-radius:9px;padding:0 11px;color:var(--ink);font:inherit;font-size:13.5px;outline:none;touch-action:pan-x pan-y;user-select:text;-webkit-user-select:text;transition:border-color .16s,box-shadow .16s}
.input:focus{border-color:var(--clay);box-shadow:0 0 0 3px rgba(217,119,87,.14)}

/* Custom animated Select dropdown (replaces stiff native <select>) */
select.native-select{display:none}
.c-sel{position:relative;display:block;width:100%;min-width:0}
.c-sel.full{width:100%;grid-column:2 / 4}
.c-sel-trigger{width:100%;height:34px;display:flex;align-items:center;justify-content:space-between;gap:8px;background:var(--paper);border:1px solid var(--hairline);border-radius:9px;padding:0 10px;color:var(--ink);font:inherit;font-size:13px;cursor:pointer;outline:none;-webkit-tap-highlight-color:transparent;transition:border-color .15s,box-shadow .15s,transform .12s;user-select:none}
.c-sel-trigger span{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.c-sel-trigger:hover{border-color:#CFCBC0;background:var(--paper-2)}
.c-sel-trigger:active{transform:scale(.985)}
.c-sel.open .c-sel-trigger{border-color:var(--clay);box-shadow:0 0 0 3px rgba(217,119,87,.14)}
.c-sel-arrow{width:14px;height:14px;color:var(--muted);transition:transform .2s cubic-bezier(.22,1,.36,1);flex-shrink:0}
.c-sel.open .c-sel-arrow{transform:rotate(180deg)}
.c-sel-menu{position:absolute;top:calc(100% + 6px);left:0;min-width:100%;background:var(--paper);border:1px solid var(--hairline);border-radius:11px;padding:5px;box-shadow:0 10px 28px rgba(20,20,19,.12),0 2px 6px rgba(20,20,19,.05);z-index:99;opacity:0;transform:translateY(-6px) scale(.98);pointer-events:none;transition:opacity .16s cubic-bezier(.22,1,.36,1),transform .18s cubic-bezier(.22,1,.36,1);max-height:240px;overflow-y:auto}
.c-sel.open .c-sel-menu{opacity:1;transform:translateY(0) scale(1);pointer-events:auto}
.c-sel-opt{padding:7px 10px;border-radius:7px;font-size:13.5px;color:var(--ink-soft);cursor:pointer;-webkit-tap-highlight-color:transparent;touch-action:manipulation;transition:background .12s,color .12s,transform .1s}
.c-sel-opt:hover{background:var(--paper-2);color:var(--ink)}
.c-sel-opt:active{transform:scale(.97);background:var(--paper-3)}
.c-sel-opt.selected{background:#F8E5DD;color:#9A4123;font-weight:600}

/* Structured Activity Feed (Cards + Filter + Sort + Animations) */
.stats-row{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;flex-shrink:0}
.stat-box{background:var(--paper-2);border:1px solid var(--hairline);border-radius:12px;padding:12px 15px;display:flex;flex-direction:column;gap:2px;transition:transform .16s,box-shadow .16s}
.stat-box:hover{transform:translateY(-1px);box-shadow:0 4px 12px rgba(20,20,19,.05)}
.stat-box .k{font-size:11.5px;color:var(--muted)}
.stat-box .v{font-family:var(--font-serif);font-size:22px;font-weight:500;color:var(--ink)}
.feed{flex:1;min-height:0;overflow-y:auto;-webkit-overflow-scrolling:touch;overscroll-behavior-y:contain;display:flex;flex-direction:column;gap:8px;padding:2px 4px 4px 0}
@keyframes slideIn{from{opacity:0;transform:translateY(8px) scale(.99)}to{opacity:1;transform:none}}
.ev-card{background:var(--paper-2);border:1px solid var(--hairline);border-radius:12px;padding:11px 14px;display:flex;flex-direction:column;gap:0;outline:none;-webkit-tap-highlight-color:transparent;transition:border-color .16s,background .16s,box-shadow .18s,transform .12s cubic-bezier(.22,1,.36,1);animation:slideIn .2s cubic-bezier(.22,1,.36,1);will-change:transform}
.ev-card:hover{border-color:#CFCBC0;background:var(--paper-3);box-shadow:0 4px 14px rgba(20,20,19,.06);transform:translateY(-1px)}
.ev-card:active{transform:scale(.992);box-shadow:0 1px 4px rgba(20,20,19,.04)}
.ev-card.err{border-left:3px solid #B8443A}
.ev-card.ok{border-left:3px solid var(--sage)}
.ev-card.call{border-left:3px solid var(--clay)}
.ev-card.oauth{border-left:3px solid #7C6EA6}
.ev-card.dep{opacity:.62;padding:7px 12px}
.tool-chips{display:flex;align-items:center;gap:6px;flex-wrap:wrap;flex-shrink:0}
.chip{display:inline-flex;align-items:center;gap:5px;padding:4px 10px;border-radius:999px;border:1px solid var(--hairline);background:var(--paper-2);color:var(--muted);font-family:var(--font-mono);font-size:12px;cursor:pointer;outline:none;-webkit-tap-highlight-color:transparent;transition:background .14s,color .14s,border-color .14s,transform .1s}
.chip:hover{background:var(--paper-3);color:var(--ink)}
.chip:active{transform:scale(.95)}
.chip.active{background:var(--ink);border-color:var(--ink);color:var(--paper)}
.chip .cnt{opacity:.7;font-size:11px}

@keyframes pulseDot{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.35;transform:scale(.75)}}
.pulse-dot{display:inline-block;width:6px;height:6px;border-radius:50%;background:#A84B2C;margin-right:4px;animation:pulseDot 1.1s infinite ease-in-out}
.ev-top{display:grid;grid-template-columns:82px 132px 1fr 140px;align-items:center;gap:10px;cursor:pointer}
.ev-badge{font-size:11px;font-weight:700;padding:3px 8px;text-align:center;border-radius:999px;letter-spacing:.02em;display:inline-flex;align-items:center;justify-content:center}
.ev-badge.call{background:#F8E5DD;color:#A84B2C}
.ev-badge.ok{background:var(--sage-bg);color:#3E5425}
.ev-badge.err{background:#F8DFDD;color:#9E372E}
.ev-badge.oauth{background:#ECE8F6;color:#554488}
.ev-badge.info{background:var(--paper-3);color:var(--ink-soft)}
.ev-tool{font-family:var(--font-sans);font-size:13px;font-weight:600;color:var(--ink);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ev-summary{font-family:var(--font-mono);font-size:12px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ev-meta{display:flex;align-items:center;justify-content:flex-end;gap:6px;font-size:11.5px;color:var(--muted);font-family:var(--font-mono);flex-wrap:wrap}
.ev-src{font-family:var(--font-sans);font-size:11px;padding:1px 7px;border-radius:999px;background:rgba(217,119,87,.12);color:var(--clay);border:1px solid rgba(217,119,87,.22);white-space:nowrap}
.storage-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px}
.st-tile{background:var(--paper);border:1px solid var(--hairline);border-radius:10px;padding:10px 12px;display:flex;flex-direction:column;gap:3px}
.st-tile .k{font-size:11.5px;color:var(--muted)}
.st-tile .v{font-family:var(--font-mono);font-size:15px;font-weight:600;color:var(--ink)}
.st-tile .s{font-size:11px;color:var(--muted)}
.dl-wrap{display:flex;flex-direction:column;gap:6px;width:100%}
.dl-bar{width:100%;height:6px;border-radius:999px;background:var(--paper-3);overflow:hidden}
.dl-fill{height:100%;border-radius:999px;background:var(--clay);transition:width .25s cubic-bezier(.22,1,.36,1)}
.ev-ms{background:var(--paper);border:1px solid var(--hairline);padding:1px 7px;border-radius:999px;color:var(--ink-soft)}
.diff-add{display:block;background:rgba(120,140,93,.22);color:#C3E88D;padding:0 4px;border-radius:3px}
.diff-del{display:block;background:rgba(201,74,74,.24);color:#FF9E9E;padding:0 4px;border-radius:3px}
.diff-hunk{display:block;color:#89DDFF;font-weight:600;margin-top:4px}
.ev-detail-wrap{display:grid;grid-template-rows:0fr;transition:grid-template-rows .22s cubic-bezier(.22,1,.36,1),margin-top .22s}
.ev-card.open .ev-detail-wrap{grid-template-rows:1fr;margin-top:10px}
.ev-detail-inner{overflow:hidden}
.ev-detail{background:var(--paper);border:1px solid var(--hairline);border-radius:10px;padding:12px 14px;display:flex;flex-direction:column;gap:10px}
.det-sec{display:flex;flex-direction:column;gap:6px}
.det-hdr{display:flex;align-items:center;justify-content:space-between;font-size:11.5px;font-weight:700;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}
.det-kv{display:grid;grid-template-columns:130px 1fr;gap:6px 12px;font-size:12.5px;align-items:start}
.det-k{font-family:var(--font-mono);color:var(--muted);word-break:break-all}
.det-v{font-family:var(--font-mono);color:var(--ink);background:var(--paper-2);border:1px solid var(--hairline);border-radius:6px;padding:4px 8px;white-space:pre-wrap;word-break:break-all;max-height:160px;overflow:auto}
.det-out{background:var(--term);color:var(--term-fg);border-radius:8px;padding:10px 12px;font-family:var(--font-mono);font-size:12px;line-height:1.55;white-space:pre-wrap;word-break:break-word;max-height:260px;overflow:auto}
.det-copy{background:transparent;border:1px solid var(--hairline);color:var(--muted);border-radius:6px;padding:2px 8px;font-size:11px;cursor:pointer;outline:none;-webkit-tap-highlight-color:transparent;touch-action:manipulation;transition:background .12s,color .12s,transform .1s}
.det-copy:hover{background:var(--paper-3);color:var(--ink)}
.det-copy:active{transform:scale(.92);background:var(--paper-3)}
.empty-feed{text-align:center;color:var(--muted);padding:48px 20px;font-size:13.5px}

.feed::-webkit-scrollbar,.scroll-area::-webkit-scrollbar,.det-out::-webkit-scrollbar,.det-v::-webkit-scrollbar{width:6px;height:6px}
.feed::-webkit-scrollbar-track,.scroll-area::-webkit-scrollbar-track{background:transparent}
.feed::-webkit-scrollbar-thumb,.scroll-area::-webkit-scrollbar-thumb,.det-out::-webkit-scrollbar-thumb,.det-v::-webkit-scrollbar-thumb{background:rgba(110,108,102,.32);border-radius:999px}
.feed::-webkit-scrollbar-thumb:hover,.scroll-area::-webkit-scrollbar-thumb:hover{background:rgba(110,108,102,.52)}
.scroll-area{flex:1;min-height:0;overflow-y:auto;-webkit-overflow-scrolling:touch;overscroll-behavior-y:contain;display:flex;flex-direction:column;gap:16px;padding-right:4px}
.card{background:var(--paper-2);border:1px solid var(--hairline);border-radius:var(--r-card);padding:20px 22px;display:flex;flex-direction:column;gap:14px}
.card h2{margin:0;font-family:var(--font-serif);font-size:17px;font-weight:500;color:var(--ink)}
.card-foot{display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;padding-top:12px;border-top:1px solid var(--hairline)}
.card-dirty-hint{font-size:12px;color:var(--muted);transition:color .16s}
.card-dirty-hint.dirty{color:var(--clay);font-weight:500}
.setup-svc-only{display:none}
.grid{display:grid;grid-template-columns:188px 1fr auto;gap:10px 14px;align-items:center}
.grid label{color:var(--muted);font-size:13px}
.grid .full{grid-column:2 / 4}
.row-inline{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
.chk{display:inline-flex;align-items:center;gap:7px;cursor:pointer;color:var(--ink-soft);font-size:13.5px}

/* Bottom status bar */
.statusbar{grid-column:1 / 3;grid-row:3;background:var(--paper-2);border-top:1px solid var(--hairline);display:flex;align-items:center;justify-content:space-between;padding:0 18px;font-size:12px;color:var(--muted)}
.statusbar .sb-group{display:flex;align-items:center;gap:16px}
.statusbar button{background:transparent;border:0;color:var(--muted);font:inherit;cursor:pointer;padding:2px 6px;border-radius:6px;outline:none;-webkit-tap-highlight-color:transparent;touch-action:manipulation;transition:background .12s,color .12s,transform .1s}
.statusbar button:hover{background:var(--paper-3);color:var(--ink)}
.statusbar button:active{transform:scale(.93);background:var(--paper-3)}

.toast{position:fixed;bottom:44px;right:24px;background:var(--ink);color:var(--paper);padding:10px 16px;border-radius:10px;font-size:13px;opacity:0;pointer-events:none;transition:opacity .2s,transform .2s;transform:translateY(6px);z-index:200}
.toast.show{opacity:1;transform:translateY(0)}

/* Claude-styled in-app confirmation modal (replaces native browser confirm) */
.modal-backdrop{position:fixed;inset:0;background:rgba(20,20,19,.36);backdrop-filter:blur(3px);display:flex;align-items:center;justify-content:center;opacity:0;pointer-events:none;transition:opacity .18s ease;z-index:300}
.modal-backdrop.open{opacity:1;pointer-events:auto}
.modal-card{width:min(420px,calc(100vw - 32px));background:var(--paper);border:1px solid var(--hairline);border-radius:16px;padding:22px 24px 18px;box-shadow:0 18px 48px rgba(20,20,19,.18);transform:translateY(10px) scale(.97);transition:transform .2s cubic-bezier(.22,1,.36,1)}
.modal-backdrop.open .modal-card{transform:translateY(0) scale(1)}
.modal-hdr{display:flex;align-items:center;gap:10px;margin-bottom:10px}
.modal-title{font-family:var(--font-serif);font-size:19px;font-weight:500;color:var(--ink)}
.modal-msg{font-size:13.5px;line-height:1.65;color:var(--muted);margin-bottom:18px;white-space:pre-line}
.modal-actions{display:flex;justify-content:flex-end;gap:10px}

/* Custom warm-clay checkboxes (replaces native OS blue checkbox) */
input[type="checkbox"]{appearance:none;-webkit-appearance:none;width:16px;height:16px;border:1.5px solid #C8C4B8;border-radius:5px;background:var(--paper);cursor:pointer;display:inline-grid;place-content:center;transition:background .15s,border-color .15s,transform .1s;flex-shrink:0;margin:0}
input[type="checkbox"]:hover{border-color:var(--clay)}
input[type="checkbox"]:active{transform:scale(.9)}
input[type="checkbox"]:checked{background:var(--clay);border-color:var(--clay)}
input[type="checkbox"]:checked::after{content:"";width:8px;height:5px;border-left:2px solid #FAF9F5;border-bottom:2px solid #FAF9F5;transform:rotate(-45deg) translate(0.5px,-0.5px)}

/* Sub-MCP Gateway Page & Animated Controls */
.nav-badge{margin-left:auto;flex-shrink:0;min-width:20px;height:18px;padding:0 6px;border-radius:999px;display:inline-flex;align-items:center;justify-content:center;font-family:var(--font-mono);font-size:11px;font-weight:700;line-height:1;background:rgba(217,119,87,.16);color:var(--clay);border:1px solid rgba(217,119,87,.3);transition:background .15s,color .15s,transform .2s}
.nav button.active .nav-badge{background:var(--clay);color:#FAF9F5;border-color:var(--clay)}
.shell.collapsed .nav-badge{position:absolute;top:2px;right:2px;margin:0;min-width:16px;height:15px;padding:0 4px;font-size:9.5px}
@keyframes fadeSlideUp{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:translateY(0)}}
@keyframes spinAnim{to{transform:rotate(360deg)}}
.spin{display:inline-block;animation:spinAnim .85s linear infinite}

.sub-banner{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;background:var(--paper-2);border:1px solid var(--hairline);border-radius:12px;padding:11px 16px;font-size:12.5px;color:var(--muted)}
.sub-banner-pills{display:flex;align-items:center;gap:6px;flex-wrap:wrap}
.meta-pill{font-family:var(--font-mono);font-size:11.5px;padding:2px 8px;border-radius:6px;background:var(--paper);border:1px solid var(--hairline);color:var(--ink-soft)}
.sub-list{display:flex;flex-direction:column;gap:12px}
.sub-card{background:var(--paper-2);border:1px solid var(--hairline);border-radius:var(--r-card);padding:16px 20px;display:flex;flex-direction:column;gap:10px;transition:transform .18s cubic-bezier(.22,1,.36,1),box-shadow .18s ease,border-color .18s ease,opacity .2s ease;animation:fadeSlideUp .26s cubic-bezier(.22,1,.36,1) both}
.sub-card:hover{border-color:rgba(217,119,87,.42);box-shadow:0 6px 20px rgba(20,20,19,.05);transform:translateY(-1px)}
.sub-card.disabled{opacity:.64}
.sub-top{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap}
.sub-id{display:flex;align-items:center;gap:10px;min-width:0}
.sub-dot{width:9px;height:9px;border-radius:50%;flex-shrink:0;background:var(--muted);opacity:.45;transition:background .2s,box-shadow .2s}
.sub-dot.ok{background:var(--sage);opacity:1;box-shadow:0 0 0 3px var(--sage-bg)}
.sub-dot.error{background:var(--danger);opacity:1;box-shadow:0 0 0 3px rgba(201,74,74,.18)}
.sub-dot.testing{background:var(--clay);opacity:1;animation:pulseDot 1s infinite ease-in-out}
.sub-name{font-family:var(--font-serif);font-size:17px;font-weight:500;color:var(--ink);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.proto-pill{font-family:var(--font-mono);font-size:11px;font-weight:600;padding:2px 8px;border-radius:999px;text-transform:uppercase;letter-spacing:.03em;border:1px solid var(--hairline)}
.proto-pill.stdio{background:rgba(217,119,87,.12);color:var(--clay);border-color:rgba(217,119,87,.25)}
.proto-pill.http{background:var(--sage-bg);color:var(--sage);border-color:rgba(120,140,93,.28)}
.proto-pill.sse{background:rgba(124,110,166,.14);color:#7C6EA6;border-color:rgba(124,110,166,.28)}
.sub-actions{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.sub-desc{font-size:13px;color:var(--muted);line-height:1.5}
.sub-ep{font-family:var(--font-mono);font-size:12px;color:var(--ink-soft);background:var(--paper);border:1px solid var(--hairline);border-radius:8px;padding:6px 10px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sub-foot{display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;font-size:12px;color:var(--muted)}
.sub-err{color:var(--danger);font-family:var(--font-mono);font-size:11.5px;background:rgba(201,74,74,.08);border:1px solid rgba(201,74,74,.2);border-radius:8px;padding:6px 10px;word-break:break-word}

/* Warm-clay sliding toggle switch with tactile thumb stretch */
.switch{position:relative;display:inline-flex;align-items:center;width:38px;height:22px;cursor:pointer;flex-shrink:0;-webkit-tap-highlight-color:transparent;touch-action:manipulation}
.switch input{opacity:0;width:0;height:0;position:absolute}
.slider{position:absolute;inset:0;background:var(--paper-3);border:1px solid var(--hairline);border-radius:999px;transition:background .2s ease,border-color .2s ease}
.slider::before{content:"";position:absolute;width:16px;height:16px;left:2px;top:2px;border-radius:999px;background:var(--paper);box-shadow:0 1px 3px rgba(20,20,19,.22);transition:transform .22s cubic-bezier(.34,1.56,.64,1),width .14s ease}
.switch:active .slider::before{width:20px}
.switch input:checked + .slider{background:var(--clay);border-color:var(--clay)}
.switch input:checked + .slider::before{transform:translateX(16px);background:#FAF9F5}
.switch:active input:checked + .slider::before{transform:translateX(12px)}

/* Accordion tools drawer inside Sub-MCP card */
.sub-tools-wrap{display:grid;grid-template-rows:0fr;transition:grid-template-rows .24s cubic-bezier(.22,1,.36,1)}
.sub-card.tools-open .sub-tools-wrap{grid-template-rows:1fr}
.sub-tools-inner{overflow:hidden}
.sub-tools-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:8px;padding-top:10px;border-top:1px solid var(--hairline);margin-top:4px}
.sub-tool-item{background:var(--paper);border:1px solid var(--hairline);border-radius:9px;padding:8px 10px;display:flex;flex-direction:column;gap:3px}
.sub-tool-name{font-family:var(--font-mono);font-size:12px;font-weight:600;color:var(--ink)}
.sub-tool-desc{font-size:11.5px;color:var(--muted);line-height:1.4;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}

.sub-empty{background:var(--paper-2);border:1px dashed var(--hairline);border-radius:var(--r-card);padding:44px 24px;text-align:center;display:flex;flex-direction:column;align-items:center;gap:10px;animation:fadeSlideUp .25s ease}
.sub-empty-ico{width:46px;height:46px;border-radius:14px;background:rgba(217,119,87,.12);color:var(--clay);display:grid;place-items:center;margin-bottom:4px}
.sub-empty h3{margin:0;font-family:var(--font-serif);font-size:18px;font-weight:500;color:var(--ink)}
.sub-empty p{margin:0;max-width:440px;font-size:13px;line-height:1.6;color:var(--muted)}

/* Sub-MCP Edit / Import Modal */
.sub-modal-card{width:min(560px,calc(100vw - 32px));max-height:calc(100vh - 48px);display:flex;flex-direction:column;background:var(--paper);border:1px solid var(--hairline);border-radius:18px;padding:22px 24px 18px;box-shadow:0 22px 56px rgba(20,20,19,.22);transform:translateY(12px) scale(.97);transition:transform .22s cubic-bezier(.22,1,.36,1)}
.modal-backdrop.open .sub-modal-card{transform:translateY(0) scale(1)}
.sub-modal-body{overflow-y:auto;-webkit-overflow-scrolling:touch;overscroll-behavior-y:contain;padding-right:4px;display:flex;flex-direction:column;gap:12px;margin:12px 0 16px}
.sub-modal-body::-webkit-scrollbar{width:6px}
.sub-modal-body::-webkit-scrollbar-thumb{background:rgba(110,108,102,.32);border-radius:999px}
.sub-form-row{display:grid;grid-template-columns:116px 1fr;gap:10px 12px;align-items:center}
.sub-form-row label{font-size:13px;color:var(--muted)}
.textarea{width:100%;box-sizing:border-box;background:var(--paper-2);border:1px solid var(--hairline);border-radius:10px;padding:9px 12px;font-family:var(--font-mono);font-size:12.5px;line-height:1.5;color:var(--ink);outline:none;resize:vertical;touch-action:pan-x pan-y;user-select:text;-webkit-user-select:text;transition:border-color .15s,box-shadow .15s}
.textarea:focus{border-color:var(--clay);box-shadow:0 0 0 3px rgba(217,119,87,.14)}
.grid .textarea{background:var(--paper);font-size:13px;padding:8px 11px}
.conn-domain-card{background:var(--paper-2);border:1px solid var(--hairline);border-radius:12px;padding:12px 14px;display:flex;flex-direction:column;gap:8px}
.conn-domain-hdr{display:flex;align-items:center;justify-content:space-between;gap:8px;font-size:12.5px;font-weight:600;color:var(--ink)}
.conn-row{display:grid;grid-template-columns:86px minmax(0,1fr) auto;gap:8px;align-items:center}
.conn-row label{font-size:12px;color:var(--muted)}
.conn-row .input{height:32px;font-family:var(--font-mono);font-size:12px}
.json-hint{font-size:12px;color:var(--muted);display:flex;align-items:center;justify-content:space-between;gap:8px}
.json-hint.ok{color:var(--sage)}
.json-hint.err{color:var(--danger)}
.dash-only{display:none}
body.dashboard-mode .desktop-only{display:none !important}
body.dashboard-mode .dash-only{display:inline-flex}

/* Smooth responsive & portrait / narrow-window adaptation */
.main,.sidebar,.card,.toolbar,.stats-row,.ev-top{transition:padding .2s ease,gap .2s ease}
@media (max-width: 900px) and (min-width: 641px){
  .shell:not(.collapsed){grid-template-columns:64px minmax(0,1fr)}
  .shell:not(.collapsed) .sidebar{padding:16px 8px 14px;align-items:center}
  .shell:not(.collapsed) .brand-title,.shell:not(.collapsed) .nav-txt,.shell:not(.collapsed) .ctrl-txt,.shell:not(.collapsed) #sb-pill-txt{display:none}
  .shell:not(.collapsed) .pill{padding:6px;border-radius:50%}
  .shell:not(.collapsed) .nav button{justify-content:center;padding:0;width:44px;margin:0 auto}
  .shell:not(.collapsed) .ctrl .btn{padding:0;width:44px;height:38px;margin:0 auto}
  .main{padding:16px 18px 14px;gap:12px}
  .toolbar{grid-template-columns:1fr 1fr;gap:8px}
  .toolbar .input{grid-column:1 / 3}
  .stats-row{grid-template-columns:repeat(2,1fr)}
  .ev-top{grid-template-columns:66px 1fr auto;gap:8px}
  .ev-summary{grid-column:1 / 4;padding-left:2px}
  .grid{grid-template-columns:minmax(0,1fr) auto}
  .grid label{grid-column:1 / 3;margin-top:4px}
  .grid .full,.c-sel.full,.pwd-wrap.full{grid-column:1 / 3}
}
@media (max-width: 640px){
  .shell,.shell:not(.collapsed),.shell.collapsed{grid-template-columns:minmax(0,1fr);grid-template-rows:48px minmax(0,1fr) auto;width:100%;max-width:100vw;border:0}
  .titlebar{grid-column:1;grid-row:1;padding:0 8px 0 14px;min-width:0}
  #btn-sb-toggle,#tb-mode{display:none}
  .tb-title{font-size:15.5px}
  .main{grid-column:1;grid-row:2;padding:0;gap:0;min-width:0;min-height:0;width:100%;overflow:hidden}
  .page{gap:10px;min-width:0;min-height:0;width:100%;padding:12px 12px 20px;overflow-y:auto;overflow-x:hidden;-webkit-overflow-scrolling:touch;overscroll-behavior-y:contain;touch-action:pan-y}
  .scroll-area,.feed{overflow:visible;flex:none;padding-right:0;min-width:0;max-width:100%}
  .card,.sub-card,.ev-card{min-width:0;max-width:100%}
  .page-head{flex-wrap:wrap;gap:8px;align-items:center}
  .page-head h1{font-size:20px}
  .stats-row{grid-template-columns:repeat(4,minmax(0,1fr));gap:6px}
  .stat-box{padding:8px 4px;align-items:center;text-align:center;border-radius:10px;min-width:0}
  .stat-box .k{font-size:10.5px;white-space:nowrap}
  .stat-box .v{font-size:17px}
  .toolbar{padding:8px;gap:7px;max-width:100%}
  .seg-group{max-width:100%;overflow-x:auto}
  .seg-btn{height:28px;padding:0 8px;font-size:12px}
  .search-box{flex:1 1 100%;min-width:0}
  .tool-chips{flex-wrap:nowrap;overflow-x:auto;padding-bottom:2px;-webkit-overflow-scrolling:touch;scrollbar-width:none}
  .tool-chips::-webkit-scrollbar{display:none}
  .chip{flex-shrink:0}
  .ev-card{padding:10px 11px}
  .ev-top{grid-template-columns:auto minmax(0,1fr) auto;gap:6px 8px}
  .ev-badge{font-size:10.5px;padding:2px 7px}
  .ev-tool{font-size:12.5px}
  .ev-meta{font-size:11px;gap:5px}
  .ev-summary{grid-column:1 / 4;font-size:11.5px;padding-left:0}
  .det-kv{grid-template-columns:1fr;gap:4px}
  .card{padding:14px;gap:12px;border-radius:12px}
  .card h2{font-size:15.5px}
  .grid{grid-template-columns:minmax(0,1fr) auto;gap:8px;width:100%}
  .grid label{grid-column:1 / 3;margin-top:2px;font-size:12.5px}
  .grid .full,.c-sel.full,.pwd-wrap.full{grid-column:1 / 3}
  .row-inline{gap:8px;min-width:0;max-width:100%}
  .input,.c-sel-trigger{height:38px;font-size:14px;min-width:0;width:100%;max-width:100%}
  #c-host,#c-port{flex:1 1 110px;width:auto !important}
  .btn{white-space:nowrap;flex-shrink:0}
  .sub-banner{padding:9px 12px;font-size:12px}
  .sub-card{padding:13px 14px;border-radius:12px}
  .sub-top{gap:8px}
  .sub-name{font-size:15.5px}
  .sub-actions{width:100%;justify-content:flex-start}
  .sub-tools-grid{grid-template-columns:1fr}
  .sub-modal-card{width:calc(100vw - 20px);max-height:calc(100dvh - 28px);padding:16px 16px 14px;border-radius:16px}
  .sub-form-row{grid-template-columns:1fr;gap:5px}
  .sub-form-row label{margin-top:0 !important;font-size:12.5px}
  .statusbar{display:none}
  /* Native mobile bottom tab bar */
  .sidebar{
    grid-column:1;grid-row:3;flex-direction:row;align-items:stretch;justify-content:stretch;
    padding:6px 6px max(8px, env(safe-area-inset-bottom));
    border-right:0;border-top:1px solid var(--hairline);background:var(--paper-2);gap:0;width:100%;
  }
  .brand,.ctrl{display:none}
  .setup-svc-only{display:flex}
  .nav{flex-direction:row;justify-content:space-around;gap:4px;width:100%}
  .nav button{
    position:relative;flex:1;width:auto !important;height:46px;padding:4px 2px !important;
    flex-direction:column;justify-content:center;align-items:center;gap:3px;border-radius:10px;border:0;
    background:transparent !important;box-shadow:none !important;
  }
  .nav button svg{width:19px;height:19px}
  .nav button.active{color:var(--clay)}
  .nav-txt{display:block !important;font-size:11px;line-height:1.1;white-space:nowrap}
  .nav-badge{position:absolute;top:2px;right:calc(50% - 22px);padding:0 5px;font-size:10px;line-height:15px}
  .toast{bottom:74px;right:14px;left:14px;text-align:center}
}
</style>
</head>
<body>
<div class="rz n desktop-only" data-edge="n"></div>
<div class="rz s desktop-only" data-edge="s"></div>
<div class="rz w desktop-only" data-edge="w"></div>
<div class="rz e desktop-only" data-edge="e"></div>
<div class="rz nw desktop-only" data-edge="nw"></div>
<div class="rz ne desktop-only" data-edge="ne"></div>
<div class="rz sw desktop-only" data-edge="sw"></div>
<div class="rz se desktop-only" data-edge="se"></div>
<div class="shell" id="app-shell">
  <header class="titlebar">
    <div class="tb-left" id="drag-bar" style="padding-left:6px" ondblclick="winAction('toggle_maximize')">
      <svg style="width:16px;height:16px;flex-shrink:0" viewBox="0 0 24 24" fill="none">
        <path d="M12 2L14.2 9.2L21.5 11.5L14.2 13.8L12 21L9.8 13.8L2.5 11.5L9.8 9.2L12 2Z" fill="#D97757"/>
      </svg>
      <span class="tb-title" id="tb-name">Agent MCP Console</span>
      <span class="tb-tag" id="tb-mode">Desktop</span>
    </div>
    <div class="tb-controls" id="tb-controls">
      <button class="btn sm dash-only" style="margin:0 8px 0 4px;height:26px;padding:0 10px;font-size:12px" onclick="logoutDashboard()">退出登录</button>
      <button class="tb-btn desktop-only" title="最小化" onclick="winAction('minimize')">
        <svg viewBox="0 0 12 12" fill="none"><path d="M2 6h8" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>
      </button>
      <button class="tb-btn desktop-only" id="btn-max" title="最大化 / 还原" onclick="winAction('toggle_maximize')">
        <svg viewBox="0 0 12 12" fill="none"><rect x="2" y="2" width="8" height="8" rx="1.4" stroke="currentColor" stroke-width="1.25"/></svg>
      </button>
      <button class="tb-btn close desktop-only" title="隐藏到托盘（后台继续运行）" onclick="winAction('close')">
        <svg viewBox="0 0 12 12" fill="none"><path d="M2.5 2.5l7 7M9.5 2.5l-7 7" stroke="currentColor" stroke-width="1.35" stroke-linecap="round"/></svg>
      </button>
    </div>
  </header>
  <aside class="sidebar">
    <div class="brand">
      <button class="sb-collapse-btn" id="btn-sb-toggle" onclick="toggleSidebar()" title="收起 / 展开侧边栏">
        <svg id="sb-collapse-ico" viewBox="0 0 20 20" fill="none"><path d="M12.5 5L7.5 10l5 5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>
      </button>
      <div id="sb-pill" class="pill"><span class="dot"></span><span id="sb-pill-txt">已停止</span></div>
    </div>

    <nav class="nav">
      <button class="active" data-tab="logs" title="活动与调用流">
        <svg viewBox="0 0 20 20" fill="none"><path d="M3 5h14M3 10h10M3 15h14" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>
        <span class="nav-txt">活动与调用流</span>
      </button>
      <button data-tab="submcp" title="子 MCP 网关">
        <svg viewBox="0 0 20 20" fill="none"><rect x="3" y="3" width="6" height="6" rx="1.6" stroke="currentColor" stroke-width="1.5"/><rect x="11" y="3" width="6" height="6" rx="1.6" stroke="currentColor" stroke-width="1.5"/><rect x="3" y="11" width="6" height="6" rx="1.6" stroke="currentColor" stroke-width="1.5"/><path d="M14 11.5v5M11.5 14h5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>
        <span class="nav-txt">子 MCP</span>
        <span class="nav-badge" id="nav-sub-cnt" style="display:none">0</span>
      </button>
      <button data-tab="setup" title="服务配置">
        <svg viewBox="0 0 20 20" fill="none"><circle cx="10" cy="10" r="3" stroke="currentColor" stroke-width="1.5"/><path d="M10 2.5v2M10 15.5v2M2.5 10h2M15.5 10h2M4.7 4.7l1.4 1.4M13.9 13.9l1.4 1.4M15.3 4.7l-1.4 1.4M6.1 13.9l-1.4 1.4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>
        <span class="nav-txt">服务配置</span>
      </button>
    </nav>

    <div class="ctrl desktop-only">
      <button id="btn-toggle" class="btn clay" onclick="toggleRun()" title="启动 / 停止服务">▶ <span class="ctrl-txt">启动服务</span></button>
      <button class="btn" onclick="restartRun()" title="重启服务">↻ <span class="ctrl-txt">重启服务</span></button>
      <button class="btn sm" onclick="quitApp()" title="完全退出应用" style="color:var(--muted)">⏻ <span class="ctrl-txt">完全退出</span></button>
    </div>
  </aside>

  <main class="main">
    <section id="tab-logs" class="page active">
      <div class="page-head">
        <div><h1>活动与调用流</h1></div>
        <div class="row-inline">
          <button class="btn sm" onclick="clearLogs()">清空</button>
          <button class="btn sm" onclick="exportLogs()">导出 .log</button>
        </div>
      </div>
      <div class="stats-row">
        <div class="stat-box"><span class="k">总事件数</span><span class="v" id="st-total">0</span></div>
        <div class="stat-box"><span class="k">工具调用</span><span class="v" id="st-tools">0</span></div>
        <div class="stat-box"><span class="k">错误 / 警告</span><span class="v" id="st-err">0</span></div>
        <div class="stat-box"><span class="k">平均耗时</span><span class="v" id="st-avg">-</span></div>
      </div>
      <div class="toolbar">
        <div class="seg-group" id="seg-cat">
          <button class="seg-btn active" data-val="ALL" onclick="setCatFilter('ALL')">全部</button>
          <button class="seg-btn" data-val="TOOL" onclick="setCatFilter('TOOL')">工具</button>
          <button class="seg-btn" data-val="OAUTH" onclick="setCatFilter('OAUTH')">鉴权</button>
          <button class="seg-btn" data-val="ERR" onclick="setCatFilter('ERR')">异常</button>
        </div>
        <div class="seg-group" id="seg-sort">
          <button class="seg-btn active" data-val="newest" onclick="setSortMode('newest')">最新</button>
          <button class="seg-btn" data-val="oldest" onclick="setSortMode('oldest')">最早</button>
          <button class="seg-btn" data-val="slowest" onclick="setSortMode('slowest')">最慢</button>
        </div>
        <div class="search-box">
          <svg viewBox="0 0 20 20" fill="none"><circle cx="9" cy="9" r="5.5" stroke="currentColor" stroke-width="1.6"/><path d="M13.5 13.5L17 17" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>
          <input id="f-q" class="input" placeholder="搜索参数、路径或关键词..." oninput="renderAllLogs()" />
        </div>
        <label class="chk" style="white-space:nowrap"><input id="f-dep" type="checkbox" onchange="renderAllLogs()" /> 框架日志</label>
      </div>
      <div id="source-chips" class="tool-chips"></div>
      <div id="tool-chips" class="tool-chips"></div>
      <div id="feed" class="feed"></div>
    </section>

    <section id="tab-submcp" class="page">
      <div class="page-head">
        <div><h1>子 MCP 网关</h1></div>
        <div class="row-inline">
          <button class="btn sm" onclick="openSubModal(null, 'json')">粘贴 JSON 导入</button>
          <button class="btn clay sm" onclick="openSubModal(null, 'form')">+ 添加子 MCP</button>
        </div>
      </div>
      <div class="sub-banner">
        <div class="sub-banner-pills">
          <span>嵌套代理仅暴露 3 个元工具，避免工具爆炸与命名冲突：</span>
          <span class="meta-pill">list_sub_mcps</span>
          <span class="meta-pill">inspect_sub_mcp</span>
          <span class="meta-pill">call_sub_mcp</span>
        </div>
        <span>修改即时生效，无需重启主服务</span>
      </div>
      <div class="scroll-area">
        <div id="submcp-list" class="sub-list"></div>
      </div>
    </section>

    <section id="tab-setup" class="page">
      <div class="page-head">
        <h1>服务配置</h1>
      </div>
      <div class="scroll-area">
        <div id="setup-svc-card" class="card setup-svc-only desktop-only" style="gap:10px">
          <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap">
            <h2>服务运行控制</h2>
            <div id="setup-svc-pill" class="pill"><span class="dot"></span><span id="setup-svc-pill-txt">已停止</span></div>
          </div>
          <div class="row-inline">
            <button id="setup-btn-toggle" type="button" class="btn clay sm" style="flex:1" onclick="toggleRun()">▶ 启动服务</button>
            <button type="button" class="btn sm" style="flex:1" onclick="restartRun()">↻ 重启服务</button>
          </div>
        </div>

        <div class="card" id="card-basic">
          <h2>基础服务与全局密码</h2>
          <div class="grid">
            <label>MCP 服务名称</label>
            <input id="c-name" class="input full" />
            <label>工具名前缀 (可选)</label>
            <input id="c-prefix" class="input" placeholder="留空不加前缀，如 omen_pc" />
            <button type="button" class="btn sm" onclick="useNameAsPrefix()">用服务名</button>
            <label>监听 Host / Port</label>
            <div class="row-inline full">
              <input id="c-host" class="input" style="width:160px" placeholder="0.0.0.0" />
              <input id="c-port" class="input" style="width:96px" type="number" placeholder="8778" />
            </div>
            <label>全局管理 / 授权密码</label>
            <div class="pwd-wrap"><input id="c-lpwd" class="input" type="password" placeholder="用于 OAuth 本地授权与 /dashboard 登录" /><button type="button" class="pwd-eye" title="显示 / 隐藏" onclick="togglePwdById('c-lpwd',this)"></button></div>
            <button type="button" class="btn sm" onclick="document.getElementById('c-lpwd').value=genRand('',14);markCardDirty('basic',true)">随机生成</button>
            <label>界面主题</label>
            <div class="seg-group full" id="seg-theme" style="width:fit-content">
              <button type="button" class="seg-btn" data-theme-val="auto" onclick="selectTheme('auto', event)">跟随系统</button>
              <button type="button" class="seg-btn" data-theme-val="light" onclick="selectTheme('light', event)">浅色</button>
              <button type="button" class="seg-btn" data-theme-val="dark" onclick="selectTheme('dark', event)">深色</button>
            </div>
          </div>
          <div class="row-inline" style="margin-top:2px">
            <label class="chk"><input id="c-autostart" type="checkbox" /> 应用启动时自动开启 MCP 服务</label>
          </div>
          <div class="card-foot">
            <span id="dirty-basic" class="card-dirty-hint">修改监听端口或服务名后建议重启生效</span>
            <div class="row-inline">
              <button type="button" class="btn sm" id="btn-save-basic" onclick="saveBasicCard(false)">保存基础配置</button>
              <button type="button" class="btn ink sm desktop-only" onclick="saveBasicCard(true)">保存并重启</button>
            </div>
          </div>
        </div>

        <div class="card" id="card-profiles">
          <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap">
            <h2>传输、鉴权与权限入口</h2>
            <button type="button" class="btn clay sm" onclick="openProfileModal(null)">+ 添加入口</button>
          </div>
          <div style="font-size:12.5px;color:var(--muted);line-height:1.5">
            同端口支持多入口共存：不同公网域名、独立 OAuth Client / Bearer Token、Cloudflared 隧道以及独立权限策略。增删改与启停均<strong>即时保存并实时热加载生效</strong>。
          </div>
          <div id="profiles-list" class="sub-list"></div>
        </div>

        <div class="card">
          <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap">
            <h2>Cloudflared 隧道组件</h2>
            <span id="cf-card-badge" class="meta-pill">检测中...</span>
          </div>
          <input id="cf-file-input" type="file" style="display:none" onchange="importCloudflaredFile(this)" />
          <div id="cf-card-body" style="display:flex;flex-direction:column;gap:10px"></div>
        </div>

        <div class="card" id="card-perm">
          <h2>全局默认权限与日志</h2>
          <div class="row-inline">
            <label class="chk"><input id="c-ro" type="checkbox" /> 默认只读模式 (--read-only)</label>
            <label class="chk"><input id="c-sec" type="checkbox" /> 默认允许读取敏感文件</label>
          </div>
          <div class="grid">
            <label>默认目录白名单 (留空=全盘)</label>
            <textarea id="c-roots" class="textarea full" rows="2" placeholder="每行一个或英文逗号分隔，留空允许全盘"></textarea>
            <label>日志等级 / 保存文件</label>
            <div class="row-inline full">
              <select id="c-loglvl">
                <option value="DEBUG">DEBUG</option>
                <option value="INFO">INFO</option>
                <option value="WARNING">WARNING</option>
                <option value="ERROR">ERROR</option>
              </select>
              <input id="c-logfile" class="input" style="flex:1" placeholder="留空仅输出到控制台，或填 logs/mcp.log" />
            </div>
          </div>
          <div class="card-foot">
            <span id="dirty-perm" class="card-dirty-hint">保存后全局默认权限即时热加载生效</span>
            <button type="button" class="btn sm" id="btn-save-perm" onclick="savePermCard()">保存权限与日志</button>
          </div>
        </div>

        <div class="card">
          <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap">
            <h2>存储与维护</h2>
            <button type="button" class="btn sm" onclick="loadStorageStats()">↻ 刷新占用</button>
          </div>
          <div id="storage-grid" class="storage-grid"></div>
          <div class="row-inline">
            <button type="button" class="btn sm" onclick="cleanStorageTarget('cache','清理缓存','将清理临时缓存与 __pycache__，不会影响配置和已授权的 OAuth 会话。')">清理缓存</button>
            <button type="button" class="btn sm" onclick="cleanStorageTarget('logs','清理日志','将清空当前活动流以及 logs/ 下的日志文件。')">清理日志</button>
            <button type="button" class="btn sm desktop-only" onclick="cleanStorageTarget('window','重置窗口位置','将清除窗口记忆尺寸，下次启动恢复默认居中。')">重置窗口位置</button>
            <button type="button" class="btn sm" style="color:var(--danger)" onclick="cleanStorageTarget('oauth','清空 OAuth 会话','注意：清空后已绑定的客户端（如 Gemini）需要重新授权！确定继续？',true)">清空 OAuth 会话</button>
          </div>
        </div>
      </div>
    </section>
  </main>

  <footer class="statusbar">
    <div class="sb-group">
      <span id="ft-name">Agent MCP</span>
      <span id="ft-ep">http://127.0.0.1:8000/mcp</span>
      <span id="ft-tray">托盘驻留已就绪（关闭窗口可在后台继续运行）</span>
    </div>
    <div class="sb-group">
      <span id="ft-ver">v1.2.0</span>
      <button class="desktop-only" onclick="window.close()">隐藏窗口</button>
      <button class="desktop-only" onclick="quitApp()">退出应用</button>
      <button class="dash-only" onclick="logoutDashboard()">退出登录</button>
    </div>
  </footer>
</div>
<div id="toast" class="toast"></div>
<div id="modal-backdrop" class="modal-backdrop" onclick="if(event.target===this)resolveModal(false)">
  <div class="modal-card">
    <div class="modal-hdr">
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none"><path d="M12 2L14.2 9.2L21.5 11.5L14.2 13.8L12 21L9.8 13.8L2.5 11.5L9.8 9.2L12 2Z" fill="#D97757"/></svg>
      <div class="modal-title" id="modal-title">确认操作</div>
    </div>
    <div class="modal-msg" id="modal-msg"></div>
    <div class="modal-actions">
      <button class="btn sm" id="modal-cancel" onclick="resolveModal(false)">取消</button>
      <button class="btn clay sm" id="modal-ok" onclick="resolveModal(true)">确定</button>
    </div>
  </div>
</div>

<div id="sub-modal-backdrop" class="modal-backdrop" onclick="if(event.target===this)closeSubModal()">
  <div class="sub-modal-card">
    <div class="modal-hdr" style="justify-content:space-between;margin-bottom:4px">
      <div style="display:flex;align-items:center;gap:10px">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none"><path d="M12 2L14.2 9.2L21.5 11.5L14.2 13.8L12 21L9.8 13.8L2.5 11.5L9.8 9.2L12 2Z" fill="#D97757"/></svg>
        <div class="modal-title" id="sub-modal-title">添加子 MCP</div>
      </div>
      <div class="seg-group" id="sub-mode-seg">
        <button type="button" class="seg-btn active" data-mode="form" onclick="setSubModalMode('form')">表单配置</button>
        <button type="button" class="seg-btn" data-mode="json" onclick="setSubModalMode('json')">粘贴 JSON</button>
      </div>
    </div>
    <div class="sub-modal-body">
      <div id="sub-pane-form" style="display:flex;flex-direction:column;gap:11px">
        <div class="sub-form-row">
          <label>传输协议</label>
          <div class="seg-group" id="sm-proto-seg" style="width:fit-content">
            <button type="button" class="seg-btn active" data-proto="stdio" onclick="setSubProto('stdio')">stdio 本地进程</button>
            <button type="button" class="seg-btn" data-proto="http" onclick="setSubProto('http')">Streamable HTTP</button>
            <button type="button" class="seg-btn" data-proto="sse" onclick="setSubProto('sse')">SSE</button>
          </div>
        </div>
        <div id="sm-stdio-fields" style="display:flex;flex-direction:column;gap:11px">
          <div class="sub-form-row">
            <label>启动命令</label>
            <input id="sm-cmd" class="input" placeholder="如 npx、uvx、python" />
          </div>
          <div class="sub-form-row" style="align-items:start">
            <label style="margin-top:8px">命令参数</label>
            <textarea id="sm-args" class="textarea" rows="3" placeholder="每行一个参数，例如：&#10;-y&#10;@modelcontextprotocol/server-github"></textarea>
          </div>
          <div class="sub-form-row">
            <label>工作目录</label>
            <input id="sm-cwd" class="input" placeholder="留空使用默认目录（选填）" />
          </div>
          <div class="sub-form-row" style="align-items:start">
            <label style="margin-top:8px">环境变量</label>
            <textarea id="sm-env" class="textarea" rows="3" placeholder="每行一个 KEY=VALUE（选填）&#10;GITHUB_PERSONAL_ACCESS_TOKEN=ghp_xxx"></textarea>
          </div>
        </div>
        <div id="sm-net-fields" style="display:none;flex-direction:column;gap:11px">
          <div class="sub-form-row">
            <label>服务地址 URL</label>
            <input id="sm-url" class="input" placeholder="https://example.com/mcp" />
          </div>
          <div class="sub-form-row" style="align-items:start">
            <label style="margin-top:8px">请求头 Headers</label>
            <textarea id="sm-headers" class="textarea" rows="3" placeholder="每行一个 Key: Value（选填）&#10;Authorization: Bearer sk-xxx"></textarea>
          </div>
        </div>
        <div class="sub-form-row">
          <label>子 MCP 名称</label>
          <div class="row-inline" style="flex-wrap:nowrap">
            <input id="sm-name" class="input" style="flex:1;min-width:0" placeholder="可留空，点右侧自动获取" />
            <button type="button" class="btn sm" id="btn-sm-probe" onclick="probeSubDraft()">✨ 自动获取</button>
          </div>
        </div>
        <div class="sub-form-row">
          <label>功能简介</label>
          <input id="sm-desc" class="input" placeholder="自动识别或手动填写（选填）" />
        </div>
        <div class="sub-form-row">
          <label>超时（秒）</label>
          <input id="sm-timeout" class="input" type="number" min="3" max="300" value="30" style="width:110px" />
        </div>
      </div>

      <div id="sub-pane-json" style="display:none;flex-direction:column;gap:10px">
        <div class="json-hint" id="sm-json-hint">支持直接粘贴 Claude Desktop / Cursor / Antigravity 的 mcpServers JSON 配置</div>
        <textarea id="sm-json" class="textarea" rows="12" oninput="previewSubJson()" placeholder='{&#10;  "mcpServers": {&#10;    "github": {&#10;      "command": "npx",&#10;      "args": ["-y", "@modelcontextprotocol/server-github"],&#10;      "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": "..." }&#10;    }&#10;  }&#10;}'></textarea>
      </div>
    </div>
    <div class="modal-actions">
      <button type="button" class="btn sm" onclick="closeSubModal()">取消</button>
      <button type="button" class="btn clay sm" id="sub-modal-save" onclick="submitSubModal()">保存</button>
    </div>
  </div>
</div>

<div id="connect-modal-backdrop" class="modal-backdrop" onclick="if(event.target===this)closeConnectModal()">
  <div class="sub-modal-card">
    <div class="modal-hdr" style="justify-content:space-between;margin-bottom:4px">
      <div style="display:flex;align-items:center;gap:10px">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none"><path d="M12 2L14.2 9.2L21.5 11.5L14.2 13.8L12 21L9.8 13.8L2.5 11.5L9.8 9.2L12 2Z" fill="#D97757"/></svg>
        <div class="modal-title" id="conn-modal-title">连接信息与健康检查</div>
      </div>
      <button type="button" class="btn sm" onclick="closeConnectModal()">关闭</button>
    </div>
    <div class="sub-modal-body" id="connect-modal-body"></div>
    <div class="modal-actions" style="justify-content:space-between;align-items:center;flex-wrap:wrap">
      <span id="health-msg" style="color:var(--muted);font-size:12.5px;word-break:break-all"></span>
      <button type="button" class="btn ink sm" onclick="testHealth()">⚡ 测试 /health 连通性</button>
    </div>
  </div>
</div>

<div id="prof-modal-backdrop" class="modal-backdrop" onclick="if(event.target===this)closeProfileModal()">
  <div class="sub-modal-card">
    <div class="modal-hdr" style="justify-content:space-between;margin-bottom:4px">
      <div style="display:flex;align-items:center;gap:10px">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none"><path d="M12 2L14.2 9.2L21.5 11.5L14.2 13.8L12 21L9.8 13.8L2.5 11.5L9.8 9.2L12 2Z" fill="#D97757"/></svg>
        <div class="modal-title" id="prof-modal-title">添加传输与鉴权入口</div>
      </div>
    </div>
    <div class="sub-modal-body">
      <div class="sub-form-row"><label>入口名称</label><input id="pf-name" class="input" placeholder="如 Gemini 主力、只读审计、本机脚本" /></div>
      <div class="sub-form-row"><label>传输协议</label>
        <div class="seg-group" id="pf-tr-seg" style="width:fit-content">
          <button type="button" class="seg-btn active" data-val="dual" onclick="setPfTr('dual')">dual 双模</button>
          <button type="button" class="seg-btn" data-val="http" onclick="setPfTr('http')">HTTP</button>
          <button type="button" class="seg-btn" data-val="sse" onclick="setPfTr('sse')">SSE</button>
        </div>
      </div>
      <div class="sub-form-row"><label>接入与隧道</label>
        <div class="seg-group" id="pf-tun-seg" style="width:fit-content">
          <button type="button" class="seg-btn active" data-val="none" onclick="setPfTun('none')">手动 / 直连</button>
          <button type="button" class="seg-btn" data-val="token" onclick="setPfTun('token')">Token 固定隧道</button>
          <button type="button" class="seg-btn" data-val="quick" onclick="setPfTun('quick')">Quick 临时隧道</button>
        </div>
      </div>
      <div id="pf-tun-token-box" style="display:none;flex-direction:column;gap:8px">
        <div class="sub-form-row"><label>Tunnel Token</label><div class="pwd-wrap"><input id="pf-tun-token" class="input" type="password" placeholder="从 Cloudflare Zero Trust 复制的 eyJ... Token" /><button type="button" class="pwd-eye" onclick="togglePwdById('pf-tun-token',this)"></button></div></div>
      </div>
      <div id="pf-base-row" class="sub-form-row"><label>公开根地址</label><input id="pf-base" class="input" placeholder="https://xxx.example.com（留空使用本机地址）" /></div>
      <div id="pf-tun-quick-hint" style="display:none;font-size:12px;color:var(--muted);line-height:1.5;background:var(--paper-2);border:1px solid var(--hairline);border-radius:9px;padding:8px 11px">
        无需手动填写地址——启动隧道后会自动生成 <code>https://xxx.trycloudflare.com</code>，并自动热注入 OAuth 2.1 与「连接与检测」弹窗。
      </div>
      <div id="pf-tun-auto-box" style="display:none">
        <label class="chk"><input id="pf-tun-auto" type="checkbox" checked /> 跟随 MCP 服务自动启停该隧道</label>
      </div>
      <div class="sub-form-row"><label>鉴权方式</label>
        <div class="seg-group" id="pf-auth-seg" style="width:fit-content">
          <button type="button" class="seg-btn active" data-val="oauth-local" onclick="setPfAuth('oauth-local')">OAuth 2.1</button>
          <button type="button" class="seg-btn" data-val="bearer" onclick="setPfAuth('bearer')">Bearer Key</button>
          <button type="button" class="seg-btn" data-val="none" onclick="setPfAuth('none')">无鉴权</button>
        </div>
      </div>
      <div id="pf-oauth-box" style="display:flex;flex-direction:column;gap:10px">
        <div class="sub-form-row"><label>Client ID</label><div class="row-inline" style="flex-wrap:nowrap"><input id="pf-cid" class="input" style="flex:1;min-width:0" /><button type="button" class="btn sm" onclick="document.getElementById('pf-cid').value=genRand('mcp-client-',10)">随机</button></div></div>
        <div class="sub-form-row"><label>Client Secret</label><div class="row-inline" style="flex-wrap:nowrap"><div class="pwd-wrap" style="flex:1"><input id="pf-csec" class="input" type="password" /><button type="button" class="pwd-eye" onclick="togglePwdById('pf-csec',this)"></button></div><button type="button" class="btn sm" onclick="document.getElementById('pf-csec').value=genRand('mcp-sec-',24)">随机</button></div></div>
        <div class="sub-form-row" style="align-items:start"><label style="margin-top:8px">回调地址</label><textarea id="pf-ruris" class="textarea" rows="2" placeholder="每行一个 Redirect URI（选填）"></textarea></div>
      </div>
      <div id="pf-bearer-box" style="display:none;flex-direction:column;gap:10px">
        <div class="sub-form-row"><label>API Key</label><div class="row-inline" style="flex-wrap:nowrap"><div class="pwd-wrap" style="flex:1"><input id="pf-apikey" class="input" type="password" /><button type="button" class="pwd-eye" onclick="togglePwdById('pf-apikey',this)"></button></div><button type="button" class="btn sm" onclick="document.getElementById('pf-apikey').value=genRand('sk-mcp-',28)">随机</button></div></div>
      </div>
      <div style="border-top:1px solid var(--hairline);padding-top:10px;display:flex;flex-direction:column;gap:10px">
        <label class="chk"><input id="pf-inherit" type="checkbox" checked onchange="togglePfPerm()" /> 继承全局默认权限（取消勾选可为该入口单独指定权限）</label>
        <div id="pf-perm-box" style="display:none;flex-direction:column;gap:10px">
          <div class="row-inline">
            <label class="chk"><input id="pf-ro" type="checkbox" /> 仅只读模式（禁止写文件与执行命令）</label>
            <label class="chk"><input id="pf-sec" type="checkbox" /> 允许读取敏感文件</label>
          </div>
          <div class="sub-form-row" style="align-items:start"><label style="margin-top:8px">目录白名单</label><textarea id="pf-roots" class="textarea" rows="2" placeholder="每行一个允许访问的目录，留空允许全盘"></textarea></div>
        </div>
      </div>
    </div>
    <div class="modal-actions">
      <button type="button" class="btn sm" onclick="closeProfileModal()">取消</button>
      <button type="button" class="btn clay sm" onclick="submitProfileModal()">确定</button>
    </div>
  </div>
</div>

<script>
const IS_DASHBOARD = location.pathname.startsWith('/dashboard');
const API_BASE = IS_DASHBOARD ? '/dashboard/api' : '/api';
if(IS_DASHBOARD) document.body.classList.add('dashboard-mode');
async function apiFetch(path, opts){
  const res = await fetch(API_BASE + path, opts);
  if(IS_DASHBOARD && res.status === 401){
    location.href = '/dashboard';
    throw new Error('Unauthorized');
  }
  return res;
}
async function logoutDashboard(){
  try{ await fetch('/dashboard/api/logout', {method:'POST'}); }catch(_){}
  location.href = '/dashboard';
}
let allEvents = [], rawLogs = [], cfg = {}, isRunning = false, evSeq = 0;
document.querySelectorAll('.nav button').forEach(btn=>{
  btn.onclick = () => {
    document.querySelectorAll('.nav button').forEach(b=>b.classList.remove('active'));
    document.querySelectorAll('.page').forEach(p=>p.classList.remove('active'));
    btn.classList.add('active');
    document.getElementById('tab-' + btn.dataset.tab).classList.add('active');
    if(btn.dataset.tab === 'submcp') loadSubMcps();
    if(btn.dataset.tab === 'setup') loadStatus(false);
  };
});
function toggleSidebar(){
  const sh = document.getElementById('app-shell');
  sh.classList.toggle('collapsed');
  const txt = document.querySelector('#btn-sb-toggle .ctrl-txt');
  if(txt) txt.textContent = sh.classList.contains('collapsed') ? '展开侧栏' : '收起侧栏';
}
// Native-cursor 8-direction edge & corner resize for frameless window (mouse + touch, zero jitter)
(function initWindowResize(){
  let resizing = false, inFlight = false, needStep = false, activeEl = null;
  function pumpResize(){
    if(!resizing || inFlight) return;
    if(!(window.pywebview && window.pywebview.api && window.pywebview.api.resize_step)) return;
    needStep = false;
    inFlight = true;
    window.pywebview.api.resize_step().finally(()=>{
      inFlight = false;
      if(resizing && needStep) pumpResize();
    });
  }
  document.querySelectorAll('.rz').forEach(el => {
    el.addEventListener('pointerdown', async e => {
      if(e.button !== 0 && e.pointerType === 'mouse') return;
      e.preventDefault();
      activeEl = el;
      try{ el.setPointerCapture(e.pointerId); }catch(_){}
      if(window.pywebview && window.pywebview.api && window.pywebview.api.resize_begin){
        const res = await window.pywebview.api.resize_begin(el.dataset.edge);
        if(res && res.ok) resizing = true;
      }
    });
    el.addEventListener('pointermove', () => {
      if(!resizing) return;
      needStep = true;
      pumpResize();
    });
    const endResize = e => {
      if(!resizing) return;
      resizing = false;
      needStep = false;
      try{ if(activeEl) activeEl.releasePointerCapture(e.pointerId); }catch(_){}
      activeEl = null;
      if(window.pywebview && window.pywebview.api && window.pywebview.api.resize_end){
        window.pywebview.api.resize_end();
      }
    };
    el.addEventListener('pointerup', endResize);
    el.addEventListener('pointercancel', endResize);
  });
})();

// Unified Mouse + Touch + Pen dragging for frameless titlebar (4px threshold preserves dblclick, native OS cursor = zero jitter)
(function initTitlebarDrag(){
  const bar = document.getElementById('drag-bar');
  if(!bar) return;
  const isWin = /win/i.test(navigator.platform || navigator.userAgent || '');
  if(!isWin){
    // On macOS / Linux, pywebview natively handles drag regions smoothly without Windows WebView2 jitter
    bar.classList.add('pywebview-drag-region');
    return;
  }
  let armed = false, dragging = false, inFlight = false, needStep = false;
  let downX = 0, downY = 0, pointerId = null;

  function pumpStep(){
    if(!dragging || inFlight) return;
    if(!(window.pywebview && window.pywebview.api && window.pywebview.api.touch_drag_step)) return;
    needStep = false;
    inFlight = true;
    window.pywebview.api.touch_drag_step().finally(()=>{
      inFlight = false;
      if(dragging && needStep) pumpStep();
    });
  }

  bar.addEventListener('pointerdown', e => {
    if(e.button !== 0 && e.pointerType === 'mouse') return;
    armed = true;
    dragging = false;
    downX = e.clientX;
    downY = e.clientY;
    pointerId = e.pointerId;
  });
  bar.addEventListener('pointermove', async e => {
    if(!armed && !dragging) return;
    if(!dragging){
      if(Math.hypot(e.clientX - downX, e.clientY - downY) < 4) return;
      armed = false;
      try{ bar.setPointerCapture(pointerId); }catch(_){}
      if(window.pywebview && window.pywebview.api && window.pywebview.api.touch_drag_begin){
        const res = await window.pywebview.api.touch_drag_begin();
        if(res && res.ok){
          dragging = true;
          needStep = true;
          pumpStep();
        }
      }
      return;
    }
    needStep = true;
    pumpStep();
  });
  const endDrag = e => {
    armed = false;
    if(!dragging) return;
    dragging = false;
    needStep = false;
    try{ bar.releasePointerCapture(e.pointerId); }catch(_){}
    if(window.pywebview && window.pywebview.api && window.pywebview.api.touch_drag_end){
      window.pywebview.api.touch_drag_end();
    }
  };
  bar.addEventListener('pointerup', endDrag);
  bar.addEventListener('pointercancel', endDrag);
})();
function toast(msg){const el=document.getElementById('toast');el.textContent=msg;el.classList.add('show');setTimeout(()=>el.classList.remove('show'),2200)}
async function winAction(act){
  if(window.pywebview && window.pywebview.api && window.pywebview.api[act]){
    const res = await window.pywebview.api[act]();
    if(act==='toggle_maximize' && res && typeof res.maximized==='boolean'){
      const btn = document.getElementById('btn-max');
      btn.innerHTML = res.maximized
        ? '<svg viewBox="0 0 12 12" fill="none"><rect x="2" y="3.5" width="6.5" height="6.5" rx="1.1" stroke="currentColor" stroke-width="1.2"/><path d="M4 3.5V2.3c0-.4.3-.8.8-.8h4.9c.4 0 .8.3.8.8v4.9c0 .4-.3.8-.8.8H8.5" stroke="currentColor" stroke-width="1.2"/></svg>'
        : '<svg viewBox="0 0 12 12" fill="none"><rect x="2" y="2" width="8" height="8" rx="1.4" stroke="currentColor" stroke-width="1.25"/></svg>';
    }
    return;
  }
  if(act==='close') window.close();
}
function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
function genRand(p,n){const c='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-';let r='';for(let i=0;i<n;i++)r+=c[Math.floor(Math.random()*c.length)];return p+r}

const TOOL_LABELS = {
  read_file: {icon:'📄', label:'读取文件'},
  read_files: {icon:'📚', label:'批量读取'},
  stat_file: {icon:'ℹ️', label:'查看属性'},
  list_dir: {icon:'📁', label:'浏览目录'},
  glob_files: {icon:'🗂️', label:'查找文件'},
  search_text: {icon:'🔍', label:'搜索内容'},
  create_file: {icon:'📝', label:'写入文件'},
  edit_file: {icon:'✏️', label:'编辑文件'},
  apply_patch: {icon:'🩹', label:'应用补丁'},
  replace_text: {icon:'🔁', label:'批量替换'},
  file_op: {icon:'📦', label:'文件操作'},
  undo_edit: {icon:'↩️', label:'撤销修改'},
  run_command: {icon:'⚡', label:'执行命令'},
  start_process: {icon:'🚀', label:'启动进程'},
  manage_process: {icon:'⚙️', label:'管理进程'},
  list_roots: {icon:'🧭', label:'检查环境'},
  list_sub_mcps: {icon:'🧩', label:'列出子 MCP'},
  inspect_sub_mcp: {icon:'🔎', label:'查看子 MCP 工具'},
  call_sub_mcp: {icon:'🔌', label:'调用子 MCP'},
};

function toolMeta(rawTool){
  if(!rawTool) return {icon:'•', label:'系统消息', key:''};
  for(const [k, v] of Object.entries(TOOL_LABELS)){
    if(rawTool === k || rawTool.endsWith('_' + k)) return {...v, key: rawTool};
  }
  return {icon:'🔧', label: rawTool, key: rawTool};
}

function humanSummary(ev){
  const a = ev.args || {};
  const t = ev.tool || '';
  if(t.endsWith('read_file') && a.path) return `${a.path}${a.offset ? ` (第 ${a.offset} 行起)` : ''}`;
  if(t.endsWith('edit_file') && a.path) return `${a.path}${Array.isArray(a.edits) ? ` · ${a.edits.length} 处修改` : ''}`;
  if(t.endsWith('create_file') && a.path) return `${a.path}${a.overwrite ? ' (覆盖)' : ''}`;
  if(t.endsWith('list_dir')) return `${a.path || '.'}`;
  if(t.endsWith('search_text') && a.pattern) return `"${a.pattern}" @ ${a.path || '.'}`;
  if(t.endsWith('run_command') && a.command) return a.command;
  if(t.endsWith('file_op') && a.action) return `${a.action}: ${a.src || ''}${a.dst ? ' -> ' + a.dst : ''}`;
  if(t.endsWith('inspect_sub_mcp') && a.server_name) return `${a.server_name}${a.tool_name ? ' / ' + a.tool_name : ' (工具目录)'}`;
  if(t.endsWith('call_sub_mcp') && a.server_name) return `${a.server_name} / ${a.tool_name || ''}`;
  return ev.summary || ev.raw || '';
}

function formatDiffOrOutput(text){
  if(text.includes('\n@@ ') || text.includes('\n--- a/')){
    return text.split('\n').map(line=>{
      if(line.startsWith('+') && !line.startsWith('+++')) return `<span class="diff-add">${esc(line)}</span>`;
      if(line.startsWith('-') && !line.startsWith('---')) return `<span class="diff-del">${esc(line)}</span>`;
      if(line.startsWith('@@')) return `<span class="diff-hunk">${esc(line)}</span>`;
      return esc(line);
    }).join('\n');
  }
  return esc(text);
}

function normalizeEvent(ev){
  return {
    id: ++evSeq,
    call_id: ev.call_id || '',
    status: ev.status || (ev.kind === 'call' ? 'running' : 'done'),
    ts: ev.ts || '',
    level: ev.level || 'INFO',
    kind: ev.kind || 'info',
    badge: ev.badge || '系统',
    tool: ev.tool || '',
    source: ev.source || '',
    source_host: ev.source_host || '',
    ms: typeof ev.ms === 'number' ? ev.ms : null,
    args: ev.args || null,
    result: ev.result || '',
    summary: ev.summary || ev.raw || '',
    raw: ev.raw || JSON.stringify(ev, null, 2),
    isDep: !!ev.isDep,
  };
}

function upsertEvent(rawEv){
  const ev = normalizeEvent(rawEv);
  if(ev.call_id){
    const idx = allEvents.findIndex(x => x.call_id === ev.call_id);
    if(idx !== -1){
      // Merge completion into the existing running card (1 call = 1 card!)
      allEvents[idx] = {...allEvents[idx], ...ev, id: allEvents[idx].id, args: ev.args || allEvents[idx].args};
      return {ev: allEvents[idx], merged: true};
    }
  }
  allEvents.push(ev);
  if(allEvents.length > 4000) allEvents.shift();
  return {ev, merged: false};
}

function updateStats(){
  let tools=0, errs=0, msSum=0, msCnt=0;
  const toolCounts = {}, sourceCounts = {};
  for(const e of allEvents){
    if(e.tool){ tools++; toolCounts[e.tool] = (toolCounts[e.tool] || 0) + 1; }
    if(e.source){ sourceCounts[e.source] = (sourceCounts[e.source] || 0) + 1; }
    if(e.kind==='err'||e.level==='WARNING'||e.level==='ERROR') errs++;
    if(e.ms!==null){ msSum+=e.ms; msCnt++; }
  }
  document.getElementById('st-total').textContent = allEvents.length;
  document.getElementById('st-tools').textContent = tools;
  document.getElementById('st-err').textContent = errs;
  document.getElementById('st-avg').textContent = msCnt ? (msSum/msCnt).toFixed(0)+'ms' : '-';
  refreshSourceFilterUI(sourceCounts);
  refreshToolFilterUI(toolCounts);
}

let activeCat = 'ALL', activeSort = 'newest', activeTool = 'ALL', activeSource = 'ALL';

function selectSourceFilter(sname){
  activeSource = sname;
  renderAllLogs();
}

function refreshSourceFilterUI(sourceCounts){
  const names = Object.keys(sourceCounts).sort();
  if(activeSource !== 'ALL' && !names.includes(activeSource)) activeSource = 'ALL';
  const box = document.getElementById('source-chips');
  if(!box) return;
  if(!names.length){ box.innerHTML = ''; return; }
  box.innerHTML = `<button class="chip ${activeSource==='ALL'?'active':''}" onclick="selectSourceFilter('ALL')">🌐 全部来源</button>` +
    names.map(n=>`<button class="chip ${activeSource===n?'active':''}" onclick="selectSourceFilter('${esc(n)}')">🌐 ${esc(n)} <span class="cnt">${sourceCounts[n]||''}</span></button>`).join('');
}

function setCatFilter(val){
  activeCat = val;
  document.querySelectorAll('#seg-cat .seg-btn').forEach(b=>b.classList.toggle('active', b.dataset.val===val));
  renderAllLogs();
}

function setSortMode(val){
  activeSort = val;
  document.querySelectorAll('#seg-sort .seg-btn').forEach(b=>b.classList.toggle('active', b.dataset.val===val));
  renderAllLogs();
}

function selectToolFilter(tname){
  activeTool = tname;
  renderAllLogs();
}

function refreshToolFilterUI(toolCounts){
  const names = Object.keys(toolCounts).sort();
  if(activeTool !== 'ALL' && !names.includes(activeTool)) activeTool = 'ALL';
  const box = document.getElementById('tool-chips');
  if(!names.length){ box.innerHTML = ''; return; }
  box.innerHTML = `<button class="chip ${activeTool==='ALL'?'active':''}" onclick="selectToolFilter('ALL')">全部工具</button>` +
    names.map(n=>{
      const m = toolMeta(n);
      return `<button class="chip ${activeTool===n?'active':''}" onclick="selectToolFilter('${esc(n)}')">${m.icon} ${esc(m.label)} <span class="cnt">${toolCounts[n]||''}</span></button>`;
    }).join('');
}

function matchesFilter(ev){
  if(!document.getElementById('f-dep').checked && ev.isDep) return false;
  if(activeCat==='TOOL' && !(ev.kind==='call'||ev.kind==='ok'||(ev.kind==='err'&&ev.tool))) return false;
  if(activeCat==='OAUTH' && ev.kind!=='oauth') return false;
  if(activeCat==='ERR' && !(ev.kind==='err'||ev.level==='WARNING'||ev.level==='ERROR')) return false;
  if(activeTool && activeTool!=='ALL' && ev.tool !== activeTool) return false;
  if(activeSource && activeSource!=='ALL' && ev.source !== activeSource) return false;
  const q = document.getElementById('f-q').value.trim().toLowerCase();
  if(q && !(ev.tool + ' ' + ev.source + ' ' + ev.summary + ' ' + ev.raw).toLowerCase().includes(q)) return false;
  return true;
}

function copyTextDirect(evObj, btn){
  evObj.stopPropagation();
  const txt = btn.dataset.copy || '';
  navigator.clipboard.writeText(txt);
  toast('已复制内容');
}

function cardHtml(ev){
  const tm = toolMeta(ev.tool);
  const msHtml = ev.ms !== null ? `<span class="ev-ms">${ev.ms.toFixed(1)} ms</span>` : '';
  const srcHtml = ev.source ? `<span class="ev-src" title="${esc(ev.source_host || ev.source)}">🌐 ${esc(ev.source)}</span>` : '';
  const pulse = ev.status === 'running' ? '<span class="pulse-dot"></span>' : '';
  const badgeText = ev.status === 'running' ? '执行中' : (ev.badge || '完成');
  const toolHtml = `<span class="ev-tool" title="${esc(ev.tool || '系统')}">${tm.icon} ${esc(tm.label)}</span>`;
  const sumText = humanSummary(ev);
  let sections = '';
  if(ev.args && Object.keys(ev.args).length){
    const rows = Object.entries(ev.args).map(([k,v])=>{
      const valStr = typeof v === 'string' ? v : JSON.stringify(v, null, 2);
      return `<div class="det-k">${esc(k)}</div><div class="det-v">${esc(valStr)}</div>`;
    }).join('');
    sections += `<div class="det-sec">
      <div class="det-hdr"><span>输入参数</span><button class="det-copy" data-copy="${esc(JSON.stringify(ev.args,null,2))}" onclick="copyTextDirect(event,this)">复制参数</button></div>
      <div class="det-kv">${rows}</div>
    </div>`;
  }
  if(ev.result){
    sections += `<div class="det-sec">
      <div class="det-hdr"><span>执行结果</span><button class="det-copy" data-copy="${esc(ev.result)}" onclick="copyTextDirect(event,this)">复制结果</button></div>
      <div class="det-out">${formatDiffOrOutput(ev.result)}</div>
    </div>`;
  }
  if(!sections){
    sections = `<div class="det-sec">
      <div class="det-hdr"><span>详情</span><button class="det-copy" data-copy="${esc(ev.summary || ev.raw)}" onclick="copyTextDirect(event,this)">复制</button></div>
      <div class="det-out">${esc(ev.summary || ev.raw)}</div>
    </div>`;
  }
  return `<div class="ev-card ${ev.kind}" data-cid="${esc(ev.call_id)}" onclick="this.classList.toggle('open')">
    <div class="ev-top">
      <span class="ev-badge ${ev.kind}">${pulse}${esc(badgeText)}</span>
      ${toolHtml}
      <span class="ev-summary">${esc(sumText)}</span>
      <div class="ev-meta">${srcHtml}${msHtml}<span>${esc(ev.ts || '')}</span></div>
    </div>
    <div class="ev-detail-wrap" onclick="event.stopPropagation()"><div class="ev-detail-inner"><div class="ev-detail">${sections}</div></div></div>
  </div>`;
}

function renderAllLogs(){
  updateStats();
  const feed = document.getElementById('feed');
  let list = allEvents.filter(matchesFilter);
  if(activeSort==='newest') list = [...list].reverse();
  else if(activeSort==='slowest') list = [...list].sort((a,b)=>(b.ms??-1)-(a.ms??-1));
  if(!list.length){ feed.innerHTML='<div class="empty-feed">暂无匹配的活动记录。点击左侧「启动服务」即可实时查看每一次 Agent 工具调用。</div>'; return; }
  feed.innerHTML = list.slice(0, 300).map(cardHtml).join('');
}

function appendEvent(rawEv){
  const {ev, merged} = upsertEvent(rawEv);
  updateStats();
  if(merged){ renderAllLogs(); return; }
  if(!matchesFilter(ev)) return;
  if(activeSort==='slowest'){ renderAllLogs(); return; }
  const feed = document.getElementById('feed');
  if(feed.querySelector('.empty-feed')) feed.innerHTML = '';
  if(activeSort==='newest'){
    feed.insertAdjacentHTML('afterbegin', cardHtml(ev));
    if(feed.children.length > 300) feed.lastElementChild.remove();
  } else {
    feed.insertAdjacentHTML('beforeend', cardHtml(ev));
    if(feed.children.length > 300) feed.firstElementChild.remove();
    feed.scrollTop = feed.scrollHeight;
  }
}

const EYE_OPEN_SVG = '<svg viewBox="0 0 20 20" fill="none"><path d="M2 10s3-5.5 8-5.5S18 10 18 10s-3 5.5-8 5.5S2 10 2 10z" stroke="currentColor" stroke-width="1.5"/><circle cx="10" cy="10" r="2.3" stroke="currentColor" stroke-width="1.5"/></svg>';
const EYE_OFF_SVG = '<svg viewBox="0 0 20 20" fill="none"><path d="M3 3l14 14M8.4 8.5A2.3 2.3 0 0011.5 11.6M5.4 5.9C3.3 7.3 2 10 2 10s3 5.5 8 5.5c1.6 0 3-.5 4.2-1.3M9 4.6c.3 0 .7-.1 1-.1 5 0 8 5.5 8 5.5s-1 1.8-2.7 3.3" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>';

function togglePwdById(id, btn){
  const el = document.getElementById(id);
  if(!el) return;
  const show = el.type === 'password';
  el.type = show ? 'text' : 'password';
  if(btn) btn.innerHTML = show ? EYE_OFF_SVG : EYE_OPEN_SVG;
}

function initEyeIcons(){
  document.querySelectorAll('.pwd-eye').forEach(btn=>{
    if(!btn.innerHTML.trim()) btn.innerHTML = EYE_OPEN_SVG;
  });
}

// Theme: auto (follow OS) / light / dark
function applyTheme(mode){
  const root = document.documentElement;
  if(mode === 'light' || mode === 'dark') root.setAttribute('data-theme', mode);
  else root.removeAttribute('data-theme');
  localStorage.setItem('mcp_theme', mode);
  document.querySelectorAll('#seg-theme .seg-btn').forEach(b => b.classList.toggle('active', b.dataset.themeVal === mode));
}
function selectTheme(next, ev){
  const cur = localStorage.getItem('mcp_theme') || 'auto';
  if(cur === next) return;
  const label = next === 'auto' ? '已切换：跟随系统主题' : (next === 'dark' ? '已切换：深色模式' : '已切换：浅色模式');
  if(document.startViewTransition && ev && typeof ev.clientX === 'number'){
    const x = ev.clientX, y = ev.clientY;
    const endR = Math.hypot(Math.max(x, innerWidth - x), Math.max(y, innerHeight - y));
    const vt = document.startViewTransition(() => applyTheme(next));
    vt.ready.then(() => {
      document.documentElement.animate(
        {clipPath: [`circle(0px at ${x}px ${y}px)`, `circle(${endR}px at ${x}px ${y}px)`]},
        {duration: 300, easing: 'cubic-bezier(.22,1,.36,1)', pseudoElement: '::view-transition-new(root)'}
      );
    }).catch(()=>{});
  } else {
    document.documentElement.classList.add('theme-fade');
    applyTheme(next);
    setTimeout(()=>document.documentElement.classList.remove('theme-fade'), 300);
  }
  toast(label);
}
applyTheme(localStorage.getItem('mcp_theme') || 'auto');

let profiles = [], tunnelInfo = {installed: true, tunnels: {}}, _pfEditIdx = null, _pfTr = 'dual', _pfAuth = 'oauth-local', _pfTun = 'none', _activeConnectUrl = '';
let _lastProfilesTunKey = '', _lastCfCardKey = '';

function copyRawText(txt, okMsg='已复制到剪贴板'){
  if(!txt) return;
  if(navigator.clipboard && navigator.clipboard.writeText){
    navigator.clipboard.writeText(txt).then(()=>toast(okMsg)).catch(()=>{});
  }else{
    const ta=document.createElement('textarea'); ta.value=txt; document.body.appendChild(ta); ta.select();
    try{ document.execCommand('copy'); toast(okMsg); }catch(_){}
    ta.remove();
  }
}

function renderCloudflaredCard(){
  const badge = document.getElementById('cf-card-badge');
  const body = document.getElementById('cf-card-body');
  if(!badge || !body) return;
  const ti = tunnelInfo || {};
  const inst = ti.install || {};
  const tMap = ti.tunnels || {};
  const activeCnt = Object.values(tMap).filter(x => x && x.running).length;
  const dlUrl = ti.download_url || 'https://github.com/cloudflare/cloudflared/releases/latest';
  const relUrl = ti.releases_url || 'https://github.com/cloudflare/cloudflared/releases/latest';
  const asset = ti.asset || 'cloudflared';

  const officialRow = `<div style="display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap;font-size:12px;color:var(--muted);padding-top:4px;border-top:1px dashed var(--hairline)">
    <div style="display:flex;align-items:center;gap:6px;min-width:0;flex:1">
      <span style="flex-shrink:0">官方直链：</span>
      <a href="${esc(dlUrl)}" target="_blank" rel="noopener" style="color:var(--clay);text-decoration:none;font-family:var(--font-mono);white-space:nowrap;overflow:hidden;text-overflow:ellipsis" title="${esc(dlUrl)}">${esc(asset)}</a>
      <a href="${esc(relUrl)}" target="_blank" rel="noopener" style="color:var(--muted);text-decoration:underline;flex-shrink:0">Releases</a>
    </div>
    <button type="button" class="btn sm" style="padding:3px 9px;font-size:11.5px" onclick="copyRawText('${esc(dlUrl)}','已复制官方下载地址')">复制直链</button>
  </div>`;

  if(inst.active || inst.paused){
    const pct = Number(inst.percent || 0);
    const mode = inst.paused ? 'paused' : 'active';
    badge.className = inst.paused ? 'meta-pill' : 'proto-pill stdio';
    badge.textContent = inst.paused ? `已暂停 ${pct}%` : `下载中 ${pct}%`;
    const liveEl = document.getElementById('cf-dl-live');
    if(liveEl && liveEl.dataset.mode === mode){
      const stEl = document.getElementById('cf-dl-status');
      const pctEl = document.getElementById('cf-dl-pct');
      const fillEl = document.getElementById('cf-dl-fill');
      if(stEl) stEl.textContent = inst.status || (inst.paused ? '已暂停下载' : '正在下载 cloudflared...');
      if(pctEl) pctEl.textContent = pct + '%';
      if(fillEl) fillEl.style.width = pct + '%';
      return;
    }
    body.innerHTML = `<div id="cf-dl-live" data-mode="${mode}" class="dl-wrap" style="gap:9px">
      <div style="display:flex;justify-content:space-between;align-items:center;gap:8px;font-size:12.5px;color:var(--muted)">
        <span>${inst.paused ? '⏸ ' : '<span class="spin">↻</span> '}<span id="cf-dl-status">${esc(inst.status || (inst.paused ? '已暂停下载' : '正在下载 cloudflared...'))}</span></span>
        <span id="cf-dl-pct" style="font-family:var(--font-mono);font-weight:600;color:${inst.paused ? 'var(--muted)' : 'var(--clay)'}">${pct}%</span>
      </div>
      <div class="dl-bar"><div id="cf-dl-fill" class="dl-fill" style="width:${pct}%;${inst.paused ? 'opacity:.55' : ''}"></div></div>
      <div class="row-inline">
        ${inst.paused
          ? `<button type="button" class="btn clay sm" onclick="installCloudflared(false, true)">▶ 继续下载</button>`
          : `<button type="button" class="btn sm" onclick="pauseCloudflared()">⏸ 暂停</button>`}
        <button type="button" class="btn sm" style="color:var(--danger)" onclick="cancelCloudflared()">✕ 取消</button>
        <button type="button" class="btn sm" onclick="triggerImportCloudflared()">📂 选择文件导入</button>
      </div>
    </div>${officialRow}`;
    return;
  }

  if(ti.installed){
    badge.className = 'proto-pill http';
    badge.textContent = ti.version ? `✓ 已安装 v${ti.version}` : '✓ 已安装';
    body.innerHTML = `<div class="sub-ep" title="${esc(ti.binary || '')}">${esc(ti.binary || 'cloudflared')}</div>
      <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;font-size:12.5px;color:var(--muted)">
        <span>${activeCnt ? `当前有 ${activeCnt} 条隧道运行中` : '已就绪，可在上方任意入口开启 Token 或 Quick 隧道'}</span>
        <div class="row-inline">
          <button type="button" class="btn sm" onclick="installCloudflared(true, false)">↻ 更新到最新版</button>
          <button type="button" class="btn sm" onclick="triggerImportCloudflared()">📂 导入替换</button>
          ${ti.local_managed ? `<button type="button" class="btn sm" style="color:var(--danger)" onclick="uninstallCloudflared()">移除本地副本</button>` : ''}
        </div>
      </div>
      ${inst.error ? `<div class="sub-err">${esc(inst.error)}</div>` : ''}
      ${officialRow}`;
  } else {
    badge.className = 'meta-pill';
    badge.textContent = '未安装';
    body.innerHTML = `<div style="font-size:12.5px;color:var(--muted);line-height:1.55">
        未检测到 <code>cloudflared</code>。可一键在线下载到项目 <code>bin/</code> 目录，或从官方地址手动下载后选择文件导入。
      </div>
      ${inst.error ? `<div class="sub-err">${esc(inst.error)}</div>` : ''}
      <div class="row-inline">
        <button type="button" class="btn clay sm" onclick="installCloudflared(false, false)">⬇️ 下载安装 cloudflared</button>
        <button type="button" class="btn sm" onclick="triggerImportCloudflared()">📂 选择文件导入</button>
      </div>
      ${officialRow}`;
  }
}

function renderProfiles(){
  const box = document.getElementById('profiles-list');
  if(!box) return;
  if(!profiles.length){
    box.innerHTML = `<div class="sub-empty" style="padding:24px"><p>暂无接入入口，点击上方「+ 添加入口」创建一个。</p></div>`;
    return;
  }
  const authLabel = { 'oauth-local':'OAuth 2.1', bearer:'Bearer Key', none:'无鉴权', github:'GitHub', google:'Google', 'oauth-custom':'OIDC' };
  const tMap = (tunnelInfo && tunnelInfo.tunnels) || {};
  const localHost = (cfg.host && cfg.host !== '0.0.0.0') ? cfg.host : '127.0.0.1';
  const localFallback = `http://${localHost}:${cfg.port||8778}`;
  box.innerHTML = profiles.map((p, idx) => {
    const tState = tMap[p.id] || {};
    const hasTun = p.tunnel_mode === 'token' || p.tunnel_mode === 'quick';
    const tunReady = !hasTun || (p.tunnel_mode === 'quick' ? !!tState.live_url : !!tState.running);
    const liveQuick = (p.tunnel_mode === 'quick' && tState.live_url) ? tState.live_url : '';
    const base = hasTun
      ? (p.tunnel_mode === 'quick'
        ? (liveQuick || '隧道未启动（点击「☁️ 启隧道」后自动生成公网地址）')
        : (tState.running ? (p.base_url || 'Token 隧道已运行（请在编辑中填绑定域名）') : (p.base_url ? `${p.base_url}（隧道未启动）` : '隧道未启动（未开放该入口）')))
      : (p.base_url || localFallback);
    const permTags = p.inherit_permissions
      ? `<span class="meta-pill">继承全局权限</span>`
      : `<span class="meta-pill">${p.read_only ? '🔒 只读' : '✏️ 读写执行'}</span>`
        + (p.allow_secrets ? `<span class="meta-pill">⚠️ 含敏感文件</span>` : '')
        + (p.roots && p.roots.length ? `<span class="meta-pill">📁 限定 ${p.roots.length} 个目录</span>` : `<span class="meta-pill">🌐 全盘</span>`);
    const tunPill = hasTun
      ? (tState.running
        ? `<span class="proto-pill http">☁️ ${p.tunnel_mode==='quick'?(liveQuick?'Quick 在线':'Quick 分配中...'):(tState.connected?'Token 在线':'Token 连接中...')}</span>`
        : `<span class="meta-pill">☁️ ${p.tunnel_mode==='quick'?'未启动 · 未开放':'未启动 · 未开放'}</span>`)
      : '';
    const tunBtn = hasTun
      ? (tState.running
        ? `<button type="button" class="btn sm" onclick="stopTunnel('${esc(p.id)}')">■ 停隧道</button>`
        : `<button type="button" class="btn sm" onclick="startTunnel('${esc(p.id)}')">☁️ 启隧道</button>`)
      : '';
    const tunConnecting = hasTun && !!tState.running && !tunReady;
    const tunFailed = hasTun && !tState.running && !!tState.error;
    const isLive = !!isRunning && !!p.enabled && tunReady;
    const dotCls = !p.enabled ? 'idle' : (tunFailed ? 'error' : (tunConnecting ? 'testing' : (isLive ? 'ok' : 'idle')));
    const dotTitle = !p.enabled ? '已停用' : (tunFailed ? '隧道启动失败' : (tunConnecting ? '隧道连接中...' : (isLive ? '可用 · 运行中' : (!isRunning ? 'MCP 服务未启动' : '隧道未启动 · 未开放'))));
    return `<div class="sub-card ${p.enabled?'':'disabled'}" style="padding:13px 16px">
      <div class="sub-top">
        <div class="sub-id">
          <span class="sub-dot ${dotCls}" title="${dotTitle}"></span>
          <span class="sub-name" style="font-size:15.5px">${esc(p.name)}</span>
          <span class="proto-pill ${p.transport==='sse'?'sse':'http'}">${esc(p.transport)}</span>
          <span class="proto-pill stdio">${esc(authLabel[p.auth_mode] || p.auth_mode)}</span>
          ${tunPill}
        </div>
        <div class="sub-actions">
          <label class="switch" title="${p.enabled?'已启用':'已停用'}">
            <input type="checkbox" ${p.enabled?'checked':''} onchange="toggleProfileEnabled(${idx}, this.checked)" />
            <span class="slider"></span>
          </label>
          ${tunBtn}
          <button type="button" class="btn sm" onclick="openProfileConnect(${idx})" ${tunReady?'':'disabled title="请先启动隧道后再获取连接地址"'}>🔗 连接与检测</button>
          <button type="button" class="btn sm" onclick="openProfileModal(${idx})">编辑</button>
          ${profiles.length > 1 ? `<button type="button" class="btn sm" style="color:var(--danger)" onclick="deleteProfile(${idx})">删除</button>` : ''}
        </div>
      </div>
      <div class="sub-ep" style="${tunReady?'':'color:var(--muted);font-style:italic'}" title="${esc(base)}">${esc(base)}</div>
      ${tState.error ? `<div class="sub-err">Cloudflared: ${esc(tState.error)}</div>` : ''}
      <div class="sub-banner-pills">${permTags}</div>
    </div>`;
  }).join('');
}

async function startTunnel(pid){
  const d = await (await apiFetch(`/tunnels/${encodeURIComponent(pid)}/start`, {method:'POST'})).json();
  if(!d.ok){ toast(d.error || '启动隧道失败'); return; }
  toast('☁️ 隧道已启动，正在建立连接...');
  let tries = 0;
  const poll = setInterval(async ()=>{
    tries++;
    await loadStatus(false);
    const ts = ((tunnelInfo && tunnelInfo.tunnels) || {})[pid] || {};
    if(ts.live_url || ts.connected || ts.error || !ts.running || tries >= 25){
      clearInterval(poll);
    }
  }, 1000);
}
async function stopTunnel(pid){
  await apiFetch(`/tunnels/${encodeURIComponent(pid)}/stop`, {method:'POST'});
  toast('已停止隧道');
  await loadStatus(false);
}
let _cfPollTimer = null;
function syncCfPoller(){
  const active = !!(tunnelInfo && tunnelInfo.install && tunnelInfo.install.active);
  if(active && !_cfPollTimer){
    _cfPollTimer = setInterval(()=>loadStatus(false), 450);
  }else if(!active && _cfPollTimer){
    clearInterval(_cfPollTimer);
    _cfPollTimer = null;
  }
}
async function installCloudflared(forceUpdate=false, resume=false){
  if(forceUpdate && !resume){
    const ok = await showModal('更新 cloudflared', '更新期间会先停止正在运行的隧道，下载完成后可重新启动。确定继续？', '开始更新', false);
    if(!ok) return;
  }
  const d = await (await apiFetch('/tunnels/install', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({force: forceUpdate, resume})})).json();
  if(!d.ok){ toast(d.error || '启动下载失败'); return; }
  toast(d.message || '已开始下载');
  await loadStatus(false);
}
async function pauseCloudflared(){
  const d = await (await apiFetch('/tunnels/pause', {method:'POST'})).json();
  toast(d.ok ? (d.message || '已暂停下载') : (d.error || '暂停失败'));
  setTimeout(()=>loadStatus(false), 250);
}
async function cancelCloudflared(){
  const d = await (await apiFetch('/tunnels/cancel', {method:'POST'})).json();
  toast(d.ok ? (d.message || '已取消下载') : (d.error || '取消失败'));
  setTimeout(()=>loadStatus(false), 250);
}
function triggerImportCloudflared(){
  const inp = document.getElementById('cf-file-input');
  if(!inp) return;
  inp.value = '';
  inp.click();
}
async function importCloudflaredFile(inp){
  const file = inp && inp.files && inp.files[0];
  if(!file) return;
  toast(`正在导入 ${file.name}...`);
  try{
    const buf = await file.arrayBuffer();
    const res = await apiFetch('/tunnels/import', {
      method: 'POST',
      headers: {'Content-Type': 'application/octet-stream', 'X-Filename': encodeURIComponent(file.name)},
      body: buf,
    });
    const d = await res.json();
    toast(d.ok ? ('✓ ' + d.message) : (d.error || '导入失败'));
  }catch(e){
    toast('导入失败: ' + e.message);
  }finally{
    inp.value = '';
    await loadStatus(false);
  }
}
async function uninstallCloudflared(){
  const ok = await showModal('移除本地 cloudflared', '将停止所有运行中的隧道并删除项目 bin/ 目录内的 cloudflared 文件，确定继续？', '确认移除', true);
  if(!ok) return;
  const d = await (await apiFetch('/tunnels/uninstall', {method:'POST'})).json();
  toast(d.ok ? ('✓ ' + d.message) : (d.error || '移除失败'));
  await loadStatus(false);
}

function setPfTr(v){
  _pfTr = v;
  document.querySelectorAll('#pf-tr-seg .seg-btn').forEach(b=>b.classList.toggle('active', b.dataset.val===v));
}
function setPfAuth(v){
  _pfAuth = v;
  document.querySelectorAll('#pf-auth-seg .seg-btn').forEach(b=>b.classList.toggle('active', b.dataset.val===v));
  document.getElementById('pf-oauth-box').style.display = v==='oauth-local' ? 'flex' : 'none';
  document.getElementById('pf-bearer-box').style.display = v==='bearer' ? 'flex' : 'none';
}
function setPfTun(v){
  _pfTun = v;
  document.querySelectorAll('#pf-tun-seg .seg-btn').forEach(b=>b.classList.toggle('active', b.dataset.val===v));
  document.getElementById('pf-tun-token-box').style.display = v==='token' ? 'flex' : 'none';
  document.getElementById('pf-base-row').style.display = v==='quick' ? 'none' : 'grid';
  document.getElementById('pf-tun-quick-hint').style.display = v==='quick' ? 'block' : 'none';
  document.getElementById('pf-tun-auto-box').style.display = v==='none' ? 'none' : 'block';
}
function togglePfPerm(){
  document.getElementById('pf-perm-box').style.display = document.getElementById('pf-inherit').checked ? 'none' : 'flex';
}
function openProfileModal(idx){
  _pfEditIdx = idx;
  const p = idx !== null ? profiles[idx] : null;
  document.getElementById('prof-modal-title').textContent = p ? `编辑入口 · ${p.name}` : '添加传输与鉴权入口';
  document.getElementById('pf-name').value = p ? p.name : `入口 #${profiles.length + 1}`;
  setPfTr(p ? p.transport : 'dual');
  document.getElementById('pf-base').value = p ? (p.base_url||'') : '';
  setPfAuth(p ? (['oauth-local','bearer','none'].includes(p.auth_mode)?p.auth_mode:'oauth-local') : 'oauth-local');
  setPfTun(p ? (p.tunnel_mode || 'none') : 'none');
  document.getElementById('pf-tun-token').value = p ? (p.tunnel_token||'') : '';
  document.getElementById('pf-tun-auto').checked = p ? (p.tunnel_auto_start !== false) : true;
  document.getElementById('pf-cid').value = p ? (p.oauth_client_id||'') : genRand('mcp-client-',10);
  document.getElementById('pf-csec').value = p ? (p.oauth_client_secret||'') : genRand('mcp-sec-',24);
  document.getElementById('pf-ruris').value = p ? (p.oauth_redirect_uris||[]).join('\n') : '';
  document.getElementById('pf-apikey').value = p ? (p.api_key||'') : genRand('sk-mcp-',28);
  document.getElementById('pf-inherit').checked = p ? (p.inherit_permissions !== false) : true;
  document.getElementById('pf-ro').checked = p ? !!p.read_only : false;
  document.getElementById('pf-sec').checked = p ? !!p.allow_secrets : false;
  document.getElementById('pf-roots').value = p ? (p.roots||[]).join('\n') : '';
  togglePfPerm();
  initEyeIcons();
  document.getElementById('prof-modal-backdrop').classList.add('open');
}
function closeProfileModal(){ document.getElementById('prof-modal-backdrop').classList.remove('open'); }
async function saveProfilesImmediate(okMsg){
  await apiFetch('/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({profiles})});
  await loadStatus('profiles');
  if(okMsg) toast(okMsg);
}
async function submitProfileModal(){
  const splitList = s => s.split(/[\r\n,]+/).map(x=>x.trim()).filter(Boolean);
  const prev = _pfEditIdx !== null ? profiles[_pfEditIdx] : null;
  const item = {
    id: prev ? prev.id : genRand('prof-', 8),
    name: document.getElementById('pf-name').value.trim() || `入口 #${profiles.length + 1}`,
    enabled: prev ? prev.enabled : true,
    transport: _pfTr,
    base_url: _pfTun === 'quick' ? '' : document.getElementById('pf-base').value.trim().replace(/\/+$/,''),
    auth_mode: _pfAuth,
    tunnel_mode: _pfTun,
    tunnel_token: document.getElementById('pf-tun-token').value.trim() || null,
    tunnel_auto_start: document.getElementById('pf-tun-auto').checked,
    oauth_client_id: document.getElementById('pf-cid').value.trim() || null,
    oauth_client_secret: document.getElementById('pf-csec').value.trim() || null,
    oauth_redirect_uris: splitList(document.getElementById('pf-ruris').value),
    api_key: document.getElementById('pf-apikey').value.trim() || null,
    inherit_permissions: document.getElementById('pf-inherit').checked,
    read_only: document.getElementById('pf-ro').checked,
    allow_secrets: document.getElementById('pf-sec').checked,
    roots: splitList(document.getElementById('pf-roots').value),
  };
  if(_pfEditIdx !== null) profiles[_pfEditIdx] = item;
  else profiles.push(item);
  closeProfileModal();
  renderProfiles();
  await saveProfilesImmediate('✓ 入口已保存并即时热加载生效');
}
async function toggleProfileEnabled(idx, checked){
  profiles[idx].enabled = checked;
  renderProfiles();
  await saveProfilesImmediate(checked ? '✓ 已启用入口并即时生效' : '已停用入口并即时生效');
}
async function deleteProfile(idx){
  const ok = await showModal('删除入口', `确定删除入口「${profiles[idx].name}」吗？`, '确认删除', true);
  if(!ok) return;
  profiles.splice(idx, 1);
  renderProfiles();
  await saveProfilesImmediate('✓ 已删除入口并即时生效');
}

function openProfileConnect(idx){
  const p = profiles[idx];
  if(!p) return;
  const tState = ((tunnelInfo && tunnelInfo.tunnels) || {})[p.id] || {};
  const hasTun = p.tunnel_mode === 'token' || p.tunnel_mode === 'quick';
  if(hasTun && (p.tunnel_mode === 'quick' ? !tState.live_url : !tState.running)){
    toast('该入口的 Cloudflared 隧道尚未启动，请先点击「☁️ 启隧道」');
    return;
  }
  const liveQuick = (p.tunnel_mode === 'quick' && tState.live_url) ? tState.live_url : '';
  const localHost = (cfg.host && cfg.host !== '0.0.0.0') ? cfg.host : '127.0.0.1';
  const base = (liveQuick || p.base_url || `http://${localHost}:${cfg.port||8778}`).replace(/\/+$/,'');
  _activeConnectUrl = liveQuick || p.base_url || '';
  const tr = p.transport || 'dual';
  const httpUrl = (tr==='http'||tr==='dual') ? base + '/mcp' : '未启用';
  const sseUrl = (tr==='sse'||tr==='dual') ? base + '/sse' : '未启用';
  const dashUrl = base + '/dashboard';
  document.getElementById('conn-modal-title').textContent = `连接与检测 · ${p.name}`;
  let html = `<div class="conn-domain-card">
    <div class="conn-domain-hdr"><span>${esc(base)}</span><span class="proto-pill http">${esc(tr)}</span></div>
    <div class="conn-row"><label>HTTP 端点</label><input id="cm-http" class="input" value="${esc(httpUrl)}" readonly /><button class="btn sm" onclick="copyField('cm-http')">复制</button></div>
    <div class="conn-row"><label>SSE 端点</label><input id="cm-sse" class="input" value="${esc(sseUrl)}" readonly /><button class="btn sm" onclick="copyField('cm-sse')">复制</button></div>
    <div class="conn-row"><label>Dashboard</label><input id="cm-dash" class="input" value="${esc(dashUrl)}" readonly /><button class="btn sm" onclick="copyField('cm-dash')">复制</button></div>
  </div>`;
  if(p.auth_mode === 'oauth-local'){
    html += `<div class="conn-domain-card">
      <div class="conn-domain-hdr"><span>OAuth 2.1 凭据</span></div>
      <div class="conn-row"><label>Client ID</label><input id="cm-cid" class="input" value="${esc(p.oauth_client_id||'-')}" readonly /><button class="btn sm" onclick="copyField('cm-cid')">复制</button></div>
      <div class="conn-row"><label>Client Secret</label><div class="pwd-wrap"><input id="cm-sec" class="input" type="password" value="${esc(p.oauth_client_secret||'-')}" readonly /><button type="button" class="pwd-eye" onclick="togglePwdById('cm-sec',this)"></button></div><button class="btn sm" onclick="copyField('cm-sec')">复制</button></div>
    </div>`;
  } else if(p.auth_mode === 'bearer'){
    html += `<div class="conn-domain-card">
      <div class="conn-domain-hdr"><span>Bearer Token</span></div>
      <div class="conn-row"><label>API Key</label><div class="pwd-wrap"><input id="cm-sec" class="input" type="password" value="${esc(p.api_key||'-')}" readonly /><button type="button" class="pwd-eye" onclick="togglePwdById('cm-sec',this)"></button></div><button class="btn sm" onclick="copyField('cm-sec')">复制</button></div>
    </div>`;
  }
  document.getElementById('connect-modal-body').innerHTML = html;
  document.getElementById('health-msg').textContent = '';
  initEyeIcons();
  document.getElementById('connect-modal-backdrop').classList.add('open');
}
function closeConnectModal(){ document.getElementById('connect-modal-backdrop').classList.remove('open'); }
function useNameAsPrefix(){document.getElementById('c-prefix').value=document.getElementById('c-name').value.trim().replace(/[^a-zA-Z0-9_]+/g,'_').replace(/^_+|_+$/g,'');markCardDirty('basic',true)}
function refreshConnectTab(){
  const p0 = (profiles.find(x=>x.enabled) || profiles[0]);
  const tr = (p0 && p0.transport) || cfg.transport || 'dual';
  const primary = (p0 && p0.base_url) || cfg.oauth_base_url || `http://${cfg.host||'127.0.0.1'}:${cfg.port||8778}`;
  const httpUrl = (tr==='http'||tr==='dual') ? primary+'/mcp' : '未启用';
  const sseUrl = (tr==='sse'||tr==='dual') ? primary+'/sse' : '未启用';
  document.getElementById('ft-name').textContent=cfg.server_name||'Agent MCP';
  document.getElementById('ft-ep').textContent=tr==='dual' ? `${primary}/mcp · /sse` : (tr==='sse' ? sseUrl : httpUrl);
}
function fmtBytes(b){
  if(!b) return '0 B';
  if(b < 1024) return b + ' B';
  if(b < 1048576) return (b/1024).toFixed(1) + ' KB';
  return (b/1048576).toFixed(2) + ' MB';
}
async function loadStorageStats(){
  try{
    const d = await (await apiFetch('/storage')).json();
    if(!d.ok || !d.stats) return;
    const st = d.stats;
    const box = document.getElementById('storage-grid');
    if(!box) return;
    box.innerHTML = [
      {k:'配置目录 config/', v:fmtBytes(st.config.bytes), s:`${st.config.files} 个文件`},
      {k:'状态数据 data/', v:fmtBytes(st.data.bytes), s:`${st.data.files} 个文件`},
      {k:'缓存与字节码', v:fmtBytes(st.cache.bytes), s:`${st.cache.files} 个文件`},
      {k:'日志文件 logs/', v:fmtBytes(st.logs.bytes), s:`${st.logs.files} 个文件`},
    ].map(x=>`<div class="st-tile"><span class="k">${x.k}</span><span class="v">${x.v}</span><span class="s">${x.s}</span></div>`).join('');
  }catch(_){}
}
async function cleanStorageTarget(target, title, msg, danger=false){
  const ok = await showModal(title, msg, '确认执行', danger);
  if(!ok) return;
  const d = await (await apiFetch('/storage/clean', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({target})})).json();
  toast(d.message || (d.ok ? '已完成' : d.error));
  if(target === 'logs'){ allEvents = []; renderAllLogs(); }
  await loadStorageStats();
}
function updateRunUi(running){
  const changed = (isRunning !== !!running);
  isRunning=!!running;
  const pill=document.getElementById('sb-pill'), txt=document.getElementById('sb-pill-txt'), btn=document.getElementById('btn-toggle');
  if(running){pill.className='pill on';txt.textContent='运行中';btn.className='btn danger';btn.innerHTML='■ <span class="ctrl-txt">停止服务</span>'}
  else{pill.className='pill';txt.textContent='已停止';btn.className='btn clay';btn.innerHTML='▶ <span class="ctrl-txt">启动服务</span>'}
  const sPill=document.getElementById('setup-svc-pill'), sTxt=document.getElementById('setup-svc-pill-txt'), sBtn=document.getElementById('setup-btn-toggle');
  if(sPill && sTxt && sBtn){
    if(running){sPill.className='pill on';sTxt.textContent='运行中';sBtn.className='btn danger sm';sBtn.textContent='■ 停止服务'}
    else{sPill.className='pill';sTxt.textContent='已停止';sBtn.className='btn clay sm';sBtn.textContent='▶ 启动服务'}
  }
  if(changed && _setupLoaded) renderProfiles();
}
function enhanceSelects(){
  document.querySelectorAll('select').forEach(sel=>{
    if(sel.dataset.enhanced){ syncCustomSelect(sel); return; }
    sel.dataset.enhanced = '1';
    sel.classList.add('native-select');
    const wrap = document.createElement('div');
    wrap.className = 'c-sel' + (sel.classList.contains('full') ? ' full' : '');
    const trig = document.createElement('button');
    trig.type = 'button'; trig.className = 'c-sel-trigger';
    const lbl = document.createElement('span');
    const arrow = document.createElementNS('http://www.w3.org/2000/svg','svg');
    arrow.setAttribute('class','c-sel-arrow'); arrow.setAttribute('viewBox','0 0 20 20'); arrow.setAttribute('fill','none');
    arrow.innerHTML = '<path d="M5 7.5L10 12.5L15 7.5" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>';
    trig.append(lbl, arrow);
    const menu = document.createElement('div');
    menu.className = 'c-sel-menu';
    Array.from(sel.options).forEach(opt=>{
      const item = document.createElement('div');
      item.className = 'c-sel-opt'; item.textContent = opt.textContent; item.dataset.val = opt.value;
      item.onclick = e => {
        e.stopPropagation();
        sel.value = opt.value;
        wrap.classList.remove('open');
        syncCustomSelect(sel);
        sel.dispatchEvent(new Event('change'));
      };
      menu.appendChild(item);
    });
    trig.onclick = e => {
      e.stopPropagation();
      const wasOpen = wrap.classList.contains('open');
      document.querySelectorAll('.c-sel.open').forEach(x=>x.classList.remove('open'));
      if(!wasOpen) wrap.classList.add('open');
    };
    wrap.append(trig, menu);
    sel.parentNode.insertBefore(wrap, sel.nextSibling);
    sel._cWrap = wrap; sel._cLbl = lbl; sel._cMenu = menu;
    syncCustomSelect(sel);
  });
}
function syncCustomSelect(sel){
  if(!sel._cWrap) return;
  const opt = sel.options[sel.selectedIndex];
  sel._cLbl.textContent = opt ? opt.textContent : '';
  sel._cMenu.querySelectorAll('.c-sel-opt').forEach(el=>el.classList.toggle('selected', el.dataset.val === sel.value));
}
document.addEventListener('click', ()=>document.querySelectorAll('.c-sel.open').forEach(x=>x.classList.remove('open')));

let _setupLoaded = false, _dirtyBasic = false, _dirtyPerm = false, _lastConfigRev = null, _lastSubRev = null;
function markCardDirty(card, dirty = true){
  if(card === 'basic'){
    _dirtyBasic = dirty;
    const h = document.getElementById('dirty-basic'), b = document.getElementById('btn-save-basic');
    if(h){ h.textContent = dirty ? '● 有未保存的基础配置修改' : '修改监听端口或服务名后建议重启生效'; h.classList.toggle('dirty', dirty); }
    if(b){ b.classList.toggle('clay', dirty); }
  }else if(card === 'perm'){
    _dirtyPerm = dirty;
    const h = document.getElementById('dirty-perm'), b = document.getElementById('btn-save-perm');
    if(h){ h.textContent = dirty ? '● 有未保存的权限与日志修改' : '保存后全局默认权限即时热加载生效'; h.classList.toggle('dirty', dirty); }
    if(b){ b.classList.toggle('clay', dirty); }
  }
}
document.getElementById('card-basic').addEventListener('input', () => markCardDirty('basic', true));
document.getElementById('card-basic').addEventListener('change', () => markCardDirty('basic', true));
document.getElementById('card-perm').addEventListener('input', () => markCardDirty('perm', true));
document.getElementById('card-perm').addEventListener('change', () => markCardDirty('perm', true));
async function loadStatus(syncForm = false){
  const res=await apiFetch('/status'), data=await res.json();
  cfg=data.config||{};
  if(data.tunnels){
    tunnelInfo = data.tunnels;
    const cfKey = JSON.stringify(tunnelInfo);
    const profTunKey = JSON.stringify({installed: !!tunnelInfo.installed, tunnels: tunnelInfo.tunnels || {}});
    if(cfKey !== _lastCfCardKey){
      _lastCfCardKey = cfKey;
      renderCloudflaredCard();
    }
    if(profTunKey !== _lastProfilesTunKey){
      _lastProfilesTunKey = profTunKey;
      if(_setupLoaded) renderProfiles();
    }
    syncCfPoller();
  }
  const cfgChanged = _lastConfigRev !== null && data.config_rev !== undefined && data.config_rev !== _lastConfigRev;
  const subChanged = _lastSubRev !== null && data.sub_rev !== undefined && data.sub_rev !== _lastSubRev;
  if(data.config_rev !== undefined) _lastConfigRev = data.config_rev;
  if(data.sub_rev !== undefined) _lastSubRev = data.sub_rev;

  document.title=(cfg.server_name||'Agent MCP')+(IS_DASHBOARD?' · Dashboard':' · Console');
  const sbNameEl = document.getElementById('sb-name');
  if(sbNameEl) sbNameEl.textContent=cfg.server_name||'Agent MCP';
  document.getElementById('tb-name').textContent=(cfg.server_name||'Agent MCP')+(IS_DASHBOARD?' · Dashboard':' · Console');
  document.getElementById('tb-mode').textContent=(IS_DASHBOARD?'Dashboard':(window.pywebview?'Frameless':'Web'))+' · '+(cfg.transport||'http').toUpperCase();
  document.getElementById('ft-ver').textContent='v'+(data.version||'1.2.0');
  document.getElementById('ft-tray').textContent=IS_DASHBOARD?'同端口加密管理页（密码保护中）':(data.tray_enabled?'系统托盘已就绪（点击托盘图标可重新唤出窗口）':'托盘未启用（请在右下角或命令行按 Ctrl+C 退出）');
  const syncAll = syncForm === true || !_setupLoaded;
  if(syncAll || syncForm === 'profiles' || cfgChanged){
    profiles = Array.isArray(cfg.profiles) ? JSON.parse(JSON.stringify(cfg.profiles)) : [];
    renderProfiles();
  }
  if(syncAll || syncForm === 'basic' || (cfgChanged && !_dirtyBasic)){
    document.getElementById('c-name').value=cfg.server_name||'';
    document.getElementById('c-prefix').value=cfg.tool_prefix||'';
    document.getElementById('c-host').value=cfg.host||'0.0.0.0';
    document.getElementById('c-port').value=cfg.port||8778;
    document.getElementById('c-lpwd').value=cfg.oauth_local_password||'';
    document.getElementById('c-autostart').checked=!!cfg.auto_start;
    markCardDirty('basic', false);
  }
  if(syncAll || syncForm === 'perm' || (cfgChanged && !_dirtyPerm)){
    document.getElementById('c-ro').checked=!!cfg.read_only;
    document.getElementById('c-sec').checked=!!cfg.allow_secrets;
    document.getElementById('c-roots').value=(cfg.roots||[]).join('\n');
    document.getElementById('c-loglvl').value=cfg.log_level||'INFO';
    document.getElementById('c-logfile').value=cfg.log_file||'';
    enhanceSelects();
    markCardDirty('perm', false);
  }
  if(syncAll){
    _setupLoaded = true;
    initEyeIcons();
    loadStorageStats();
  }
  if(subChanged){
    loadSubMcps();
  }
  refreshConnectTab(); updateRunUi(data.running);
}
async function saveBasicCard(restartAfter){
  const payload={
    server_name:document.getElementById('c-name').value.trim(),
    tool_prefix:document.getElementById('c-prefix').value.trim(),
    host:document.getElementById('c-host').value.trim(),
    port:parseInt(document.getElementById('c-port').value||'8778',10),
    auto_start:document.getElementById('c-autostart').checked,
  };
  const lpwd = document.getElementById('c-lpwd').value.trim();
  if(lpwd) payload.oauth_local_password = lpwd;
  await apiFetch('/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});
  markCardDirty('basic', false);
  await loadStatus('basic');
  toast(IS_DASHBOARD ? '✓ 基础服务配置已保存（端口等变动需在桌面端重启生效）' : '✓ 基础服务配置已保存');
  if(restartAfter && !IS_DASHBOARD) await restartRun();
}
async function savePermCard(){
  const splitList = s => s.split(/[\r\n,]+/).map(x=>x.trim()).filter(Boolean);
  const payload={
    read_only:document.getElementById('c-ro').checked,
    allow_secrets:document.getElementById('c-sec').checked,
    roots:splitList(document.getElementById('c-roots').value),
    log_level:document.getElementById('c-loglvl').value,
    log_file:document.getElementById('c-logfile').value.trim()||null,
  };
  await apiFetch('/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});
  markCardDirty('perm', false);
  await loadStatus('perm');
  toast('✓ 全局默认权限与日志已保存');
}
let _modalResolver = null;
function showModal(title, msg, okText='确定', danger=false){
  return new Promise(resolve => {
    _modalResolver = resolve;
    document.getElementById('modal-title').textContent = title;
    document.getElementById('modal-msg').textContent = msg;
    const okBtn = document.getElementById('modal-ok');
    okBtn.textContent = okText;
    okBtn.className = 'btn sm ' + (danger ? 'danger' : 'clay');
    document.getElementById('modal-backdrop').classList.add('open');
  });
}
function resolveModal(val){
  document.getElementById('modal-backdrop').classList.remove('open');
  if(_modalResolver){ const r = _modalResolver; _modalResolver = null; r(val); }
}
async function startWithConflictCheck(){
  const res = await fetch('/api/start', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({force:false})});
  const d = await res.json();
  if(d.conflict){
    const ok = await showModal('端口已被占用', `${d.message}\n\n是否结束旧实例并立即启动当前服务？`, '结束旧实例并启动', true);
    if(ok){
      await fetch('/api/start', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({force:true})});
      toast('已结束旧实例并重新启动');
    }
  }
  await loadStatus();
}
async function toggleRun(){
  if(isRunning){ await fetch('/api/stop',{method:'POST'}); await loadStatus(); }
  else { await startWithConflictCheck(); }
}
async function restartRun(){
  await fetch('/api/stop',{method:'POST'});
  await startWithConflictCheck();
}
async function quitApp(){
  const ok = await showModal('退出 Agent MCP', '确定要停止 MCP 服务并完全退出后台应用吗？', '完全退出', true);
  if(!ok) return;
  if(window.pywebview && window.pywebview.api && window.pywebview.api.quit_app){
    try{ await window.pywebview.api.quit_app(); }catch(_){}
    return;
  }
  try{await fetch('/api/quit',{method:'POST'})}catch(e){}
  window.close();
}
async function clearLogs(){await apiFetch('/logs/clear',{method:'POST'});allEvents=[];renderAllLogs()}
function exportLogs(){const b=new Blob([JSON.stringify(allEvents,null,2)+'\n'],{type:'application/json'});const a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='mcp_events.json';a.click()}
function copyField(id){navigator.clipboard.writeText(document.getElementById(id).value);toast('已复制到剪贴板')}
function toggleSecret(){const el=document.getElementById('v-sec');el.type=el.type==='password'?'text':'password'}
async function testHealth(){
  const el=document.getElementById('health-msg'); el.textContent='检测中...';
  const qs = _activeConnectUrl ? ('?url=' + encodeURIComponent(_activeConnectUrl)) : '';
  const d=await (await apiFetch('/health-check' + qs)).json();
  el.textContent=d.ok?`✓ 连通正常 (${d.url || '/health'})`:`✗ 失败: ${d.error}`;
}

// ===== Sub-MCP Gateway UI =====
let subMcps = [], subEditOldName = null, subModalMode = 'form', subProto = 'stdio';
const subTesting = new Set(), subOpenTools = new Set();

async function loadSubMcps(){
  try{
    const d = await (await apiFetch('/sub-mcps')).json();
    subMcps = d.servers || [];
    renderSubMcps();
  }catch(_){}
}

function renderSubMcps(){
  const badge = document.getElementById('nav-sub-cnt');
  if(badge){
    const enCnt = subMcps.filter(x=>x.enabled).length;
    badge.textContent = enCnt;
    badge.style.display = subMcps.length ? 'inline-flex' : 'none';
  }
  const box = document.getElementById('submcp-list');
  if(!box) return;
  if(!subMcps.length){
    box.innerHTML = `<div class="sub-empty">
      <div class="sub-empty-ico"><svg width="24" height="24" viewBox="0 0 20 20" fill="none"><rect x="3" y="3" width="6" height="6" rx="1.6" stroke="currentColor" stroke-width="1.5"/><rect x="11" y="3" width="6" height="6" rx="1.6" stroke="currentColor" stroke-width="1.5"/><rect x="3" y="11" width="6" height="6" rx="1.6" stroke="currentColor" stroke-width="1.5"/><path d="M14 11.5v5M11.5 14h5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg></div>
      <h3>还没有配置子 MCP</h3>
      <p>把第三方 MCP（如 GitHub、Fetch、数据库、浏览器等）挂在这里，主服务只会暴露 3 个极简元工具按需发现与调用，完全不撑爆上下文。</p>
      <div class="row-inline" style="margin-top:6px">
        <button class="btn sm" onclick="openSubModal(null, 'json')">粘贴 mcpServers JSON</button>
        <button class="btn clay sm" onclick="openSubModal(null, 'form')">+ 添加第一个子 MCP</button>
      </div>
    </div>`;
    return;
  }
  box.innerHTML = subMcps.map((s, idx) => {
    const isTesting = subTesting.has(s.name);
    const dotCls = isTesting ? 'testing' : (s.status || 'idle');
    const ep = s.transport === 'stdio'
      ? [s.command, ...(s.args||[])].join(' ')
      : (s.url || '');
    const tools = s.tools || [];
    const hasTools = typeof s.tool_count === 'number';
    const toolsOpen = subOpenTools.has(s.name);
    const statusTxt = isTesting
      ? '正在连接探测...'
      : (s.status === 'ok'
        ? `已发现 ${s.tool_count} 个工具${s.last_ms != null ? ` · ${s.last_ms} ms` : ''}`
        : (s.status === 'error' ? '上次探测失败' : '未探测（大模型调用时自动按需连接）'));
    const toolsGrid = tools.length
      ? `<div class="sub-tools-grid">${tools.map(t=>`<div class="sub-tool-item"><div class="sub-tool-name">${esc(t.name)}</div><div class="sub-tool-desc">${esc(t.description || '无描述')}</div></div>`).join('')}</div>`
      : '';
    return `<div class="sub-card ${s.enabled?'':'disabled'} ${toolsOpen?'tools-open':''}" style="animation-delay:${Math.min(idx*35,200)}ms">
      <div class="sub-top">
        <div class="sub-id">
          <span class="sub-dot ${dotCls}"></span>
          <span class="sub-name">${esc(s.name)}</span>
          <span class="proto-pill ${esc(s.transport)}">${esc(s.transport)}</span>
        </div>
        <div class="sub-actions">
          <label class="switch" title="${s.enabled?'已启用（点击停用）':'已停用（点击启用）'}">
            <input type="checkbox" ${s.enabled?'checked':''} onchange="toggleSubMcp('${esc(s.name)}', this.checked)" />
            <span class="slider"></span>
          </label>
          <button class="btn sm" onclick="testSubMcp('${esc(s.name)}')" ${isTesting?'disabled':''}>${isTesting?'<span class="spin">↻</span> 探测中':'⚡ 测试连接'}</button>
          <button class="btn sm" onclick="openSubModal('${esc(s.name)}', 'form')">编辑</button>
          <button class="btn sm" style="color:var(--danger)" onclick="deleteSubMcp('${esc(s.name)}')">删除</button>
        </div>
      </div>
      ${s.description ? `<div class="sub-desc">${esc(s.description)}</div>` : ''}
      <div class="sub-ep" title="${esc(ep)}">${esc(ep)}</div>
      ${s.last_error ? `<div class="sub-err">${esc(s.last_error)}</div>` : ''}
      <div class="sub-foot">
        <span>${statusTxt}</span>
        ${hasTools && tools.length ? `<button class="chip ${toolsOpen?'active':''}" onclick="toggleSubTools('${esc(s.name)}')">${toolsOpen?'收起工具列表':'展开 ' + tools.length + ' 个工具'}</button>` : ''}
      </div>
      <div class="sub-tools-wrap"><div class="sub-tools-inner">${toolsGrid}</div></div>
    </div>`;
  }).join('');
}

function toggleSubTools(name){
  if(subOpenTools.has(name)) subOpenTools.delete(name);
  else subOpenTools.add(name);
  renderSubMcps();
}

function setSubModalMode(mode){
  subModalMode = mode;
  document.querySelectorAll('#sub-mode-seg .seg-btn').forEach(b=>b.classList.toggle('active', b.dataset.mode===mode));
  document.getElementById('sub-pane-form').style.display = mode==='form' ? 'flex' : 'none';
  document.getElementById('sub-pane-json').style.display = mode==='json' ? 'flex' : 'none';
  document.getElementById('sub-modal-save').textContent = mode==='json' ? '导入配置' : '保存';
}

function setSubProto(proto){
  subProto = proto;
  document.querySelectorAll('#sm-proto-seg .seg-btn').forEach(b=>b.classList.toggle('active', b.dataset.proto===proto));
  document.getElementById('sm-stdio-fields').style.display = proto==='stdio' ? 'flex' : 'none';
  document.getElementById('sm-net-fields').style.display = proto==='stdio' ? 'none' : 'flex';
}

function openSubModal(editName, mode='form'){
  subEditOldName = editName || null;
  document.getElementById('sub-modal-title').textContent = editName ? `编辑子 MCP · ${editName}` : '添加子 MCP';
  document.getElementById('sub-mode-seg').style.display = editName ? 'none' : 'inline-flex';
  setSubModalMode(editName ? 'form' : mode);
  const item = editName ? subMcps.find(x=>x.name===editName) : null;
  document.getElementById('sm-name').value = item ? item.name : '';
  document.getElementById('sm-desc').value = item ? (item.description||'') : '';
  setSubProto(item ? item.transport : 'stdio');
  document.getElementById('sm-cmd').value = item ? (item.command||'') : '';
  document.getElementById('sm-args').value = item ? (item.args||[]).join('\n') : '';
  document.getElementById('sm-cwd').value = item ? (item.cwd||'') : '';
  document.getElementById('sm-env').value = item ? Object.entries(item.env||{}).map(([k,v])=>`${k}=${v}`).join('\n') : '';
  document.getElementById('sm-url').value = item ? (item.url||'') : '';
  document.getElementById('sm-headers').value = item ? Object.entries(item.headers||{}).map(([k,v])=>`${k}: ${v}`).join('\n') : '';
  document.getElementById('sm-timeout').value = item ? (item.timeout||30) : 30;
  document.getElementById('sm-json').value = '';
  const hint = document.getElementById('sm-json-hint');
  hint.className = 'json-hint';
  hint.textContent = '支持直接粘贴 Claude Desktop / Cursor / Antigravity 的 mcpServers JSON 配置';
  document.getElementById('sub-modal-backdrop').classList.add('open');
}

function closeSubModal(){
  document.getElementById('sub-modal-backdrop').classList.remove('open');
}

function previewSubJson(){
  const raw = document.getElementById('sm-json').value.trim();
  const hint = document.getElementById('sm-json-hint');
  if(!raw){ hint.className='json-hint'; hint.textContent='支持直接粘贴 Claude Desktop / Cursor / Antigravity 的 mcpServers JSON 配置'; return; }
  try{
    const obj = JSON.parse(raw);
    const root = (obj && typeof obj==='object' && obj.mcpServers && typeof obj.mcpServers==='object') ? obj.mcpServers : obj;
    const cnt = Array.isArray(root) ? root.length : (root.command || root.url ? 1 : Object.keys(root||{}).length);
    hint.className = 'json-hint ok';
    hint.textContent = `✓ JSON 格式有效，检测到 ${cnt} 个子 MCP 配置`;
  }catch(e){
    hint.className = 'json-hint err';
    hint.textContent = `JSON 语法错误：${e.message}`;
  }
}

function parseKvLines(text, sep){
  const out = {};
  for(const line of text.split(/\r?\n/)){
    const s = line.trim();
    if(!s || s.startsWith('#')) continue;
    const idx = s.indexOf(sep);
    if(idx > 0){
      const k = s.slice(0, idx).trim(), v = s.slice(idx+1).trim();
      if(k) out[k] = v;
    }
  }
  return out;
}

async function probeSubDraft(){
  const btn = document.getElementById('btn-sm-probe');
  if(!btn) return;
  const payload = {
    transport: subProto,
    command: document.getElementById('sm-cmd').value.trim(),
    args: document.getElementById('sm-args').value.split(/\r?\n/).map(x=>x.trim()).filter(Boolean),
    cwd: document.getElementById('sm-cwd').value.trim(),
    env: parseKvLines(document.getElementById('sm-env').value, '='),
    url: document.getElementById('sm-url').value.trim(),
    headers: parseKvLines(document.getElementById('sm-headers').value, ':'),
    timeout: Number(document.getElementById('sm-timeout').value) || 30,
  };
  btn.disabled = true;
  btn.innerHTML = '<span class="spin">↻</span> 探测中';
  try{
    const d = await (await apiFetch('/sub-mcps/probe', {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body:JSON.stringify(payload),
    })).json();
    if(!d.ok){
      toast('探测失败：' + (d.error || '无法连接'));
      return;
    }
    if(d.name) document.getElementById('sm-name').value = d.name;
    if(d.description) document.getElementById('sm-desc').value = d.description;
    toast(`✓ 已识别 ${d.raw_name || d.name || 'MCP'} · ${d.tool_count} 个工具 (${d.ms} ms)`);
  }catch(_){
    toast('探测请求失败');
  }finally{
    btn.disabled = false;
    btn.innerHTML = '✨ 自动获取';
  }
}

async function submitSubModal(){
  if(subModalMode === 'json'){
    const raw = document.getElementById('sm-json').value.trim();
    if(!raw){ toast('请先粘贴 JSON 配置'); return; }
    const res = await apiFetch('/sub-mcps/import', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({raw})});
    const d = await res.json();
    if(!d.ok){ toast(d.error || '导入失败'); return; }
    closeSubModal();
    toast(`已导入 ${d.count} 个子 MCP`);
    await loadSubMcps();
    return;
  }
  const payload = {
    old_name: subEditOldName,
    name: document.getElementById('sm-name').value.trim(),
    description: document.getElementById('sm-desc').value.trim(),
    transport: subProto,
    command: document.getElementById('sm-cmd').value.trim(),
    args: document.getElementById('sm-args').value.split(/\r?\n/).map(x=>x.trim()).filter(Boolean),
    cwd: document.getElementById('sm-cwd').value.trim(),
    env: parseKvLines(document.getElementById('sm-env').value, '='),
    url: document.getElementById('sm-url').value.trim(),
    headers: parseKvLines(document.getElementById('sm-headers').value, ':'),
    timeout: Number(document.getElementById('sm-timeout').value) || 30,
  };
  const res = await apiFetch('/sub-mcps', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(payload)});
  const d = await res.json();
  if(!d.ok){ toast(d.error || '保存失败'); return; }
  closeSubModal();
  toast(`已保存子 MCP · ${d.entry.name}`);
  await loadSubMcps();
}

async function toggleSubMcp(name, enabled){
  await apiFetch(`/sub-mcps/${encodeURIComponent(name)}/toggle`, {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({enabled})});
  toast(enabled ? `已启用 ${name}` : `已停用 ${name}`);
  await loadSubMcps();
}

async function deleteSubMcp(name){
  const ok = await showModal('删除子 MCP', `确定移除子 MCP「${name}」吗？\n移除后大模型将不再能通过元工具调用它。`, '确认删除', true);
  if(!ok) return;
  await apiFetch(`/sub-mcps/${encodeURIComponent(name)}`, {method:'DELETE'});
  subOpenTools.delete(name);
  toast(`已删除 ${name}`);
  await loadSubMcps();
}

async function testSubMcp(name){
  subTesting.add(name);
  renderSubMcps();
  try{
    const d = await (await apiFetch(`/sub-mcps/${encodeURIComponent(name)}/test`, {method:'POST'})).json();
    if(d.ok){
      subOpenTools.add(name);
      toast(`${name} 连通成功，发现 ${(d.tools||[]).length} 个工具`);
    } else {
      toast(`${name} 连接失败`);
    }
  }finally{
    subTesting.delete(name);
    await loadSubMcps();
  }
}

(async()=>{
  await loadStatus(true);
  await loadSubMcps();
  const d=await (await apiFetch('/logs')).json();
  allEvents = [];
  for(const item of (d.logs || [])) upsertEvent(item);
  renderAllLogs();
  const es=new EventSource(API_BASE + '/logs/stream');
  es.onmessage=e=>{const ev=JSON.parse(e.data);appendEvent(ev);if((ev.summary||'').includes('已退出')||(ev.summary||'').includes('已启动'))loadStatus(false)};
  setInterval(()=>loadStatus(false),3000);
})();
</script>
</body>
</html>
"""


def _open_app_window(url: str) -> None:
    if os.name == "nt":
        for exe in (
            r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
            r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
            r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        ):
            if Path(exe).is_file():
                subprocess.Popen(
                    [exe, f"--app={url}", "--window-size=1120,760"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                return
    else:
        for bin_name in ("google-chrome", "chromium", "chromium-browser", "microsoft-edge"):
            found = shutil.which(bin_name)
            if found:
                subprocess.Popen(
                    [found, f"--app={url}", "--window-size=1120,760"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                return
    webbrowser.open(url)


def run_web_gui(config_path: Path, gui_port: int = 8779) -> None:
    import uvicorn
    from starlette.applications import Starlette
    from starlette.requests import Request
    from starlette.responses import HTMLResponse, JSONResponse, StreamingResponse
    from starlette.routing import Route

    ctrl = GuiController(config_path)
    url = f"http://127.0.0.1:{gui_port}"

    async def index(_req: Request) -> HTMLResponse:
        return HTMLResponse(HTML_PAGE.replace("__FAVICON__", APP_ICON_DATA_URI))

    tray_enabled = {"ok": False}
    quit_handler: dict[str, Any] = {"fn": ctrl.shutdown_app}

    def _file_rev(p: Path) -> int:
        try:
            return int(p.stat().st_mtime_ns) if p.is_file() else 0
        except OSError:
            return 0

    async def api_status(_req: Request) -> JSONResponse:
        return JSONResponse(
            {
                "running": ctrl.is_running(),
                "version": VERSION,
                "tray_enabled": tray_enabled["ok"],
                "config_rev": _file_rev(config_path),
                "sub_rev": _file_rev(SUB_MCP_MANAGER.config_path),
                "tunnels": TUNNEL_MANAGER.get_statuses(),
                "config": ctrl.get_config(),
            }
        )

    async def api_start(req: Request) -> JSONResponse:
        force = False
        try:
            body = await req.json()
            force = bool(body.get("force", False))
        except Exception:
            pass
        return JSONResponse(ctrl.start(force_kill_conflict=force))

    async def api_stop(_req: Request) -> JSONResponse:
        return JSONResponse(ctrl.stop())

    async def api_quit(_req: Request) -> JSONResponse:
        threading.Timer(0.15, lambda: quit_handler["fn"]()).start()
        return JSONResponse({"ok": True})

    async def api_config(req: Request) -> JSONResponse:
        body = await req.json()
        cur = ctrl.get_config()
        new_pwd = body.pop("oauth_local_password", None)
        if new_pwd:
            cur["oauth_local_password"] = str(new_pwd)
            cur["oauth_local_password_hash"] = hash_password(str(new_pwd))
        if "profiles" in body and isinstance(body["profiles"], list):
            profs = [normalize_profile(p, i) for i, p in enumerate(body.pop("profiles")) if isinstance(p, dict)]
            cur["profiles"] = profs
            enabled = [p for p in profs if p.get("enabled", True)] or profs
            if enabled:
                p0 = enabled[0]
                cur["transport"] = p0["transport"]
                cur["auth_mode"] = p0["auth_mode"]
                bases = [p["base_url"] for p in enabled if p.get("base_url")]
                if bases:
                    cur["oauth_base_url"] = bases[0]
                    cur["oauth_base_urls"] = bases
                if p0.get("oauth_client_id"):
                    cur["oauth_client_id"] = p0["oauth_client_id"]
                if p0.get("oauth_client_secret"):
                    cur["oauth_client_secret"] = p0["oauth_client_secret"]
                if p0.get("oauth_redirect_uris"):
                    cur["oauth_redirect_uris"] = p0["oauth_redirect_uris"]
                if p0.get("api_key"):
                    cur["api_key"] = p0["api_key"]
        for k, v in body.items():
            cur[k] = sanitize_prefix(str(v)).rstrip("_") if k == "tool_prefix" else v
        save_config_file(config_path, cur)
        return JSONResponse({"ok": True})

    async def api_logs(_req: Request) -> JSONResponse:
        return JSONResponse({"logs": list(ctrl.logs)})

    async def api_logs_clear(_req: Request) -> JSONResponse:
        ctrl.logs.clear()
        return JSONResponse({"ok": True})

    async def api_logs_stream(req: Request) -> StreamingResponse:
        ctrl.loop = asyncio.get_running_loop()
        q: asyncio.Queue[str] = asyncio.Queue()
        ctrl.subscribers.add(q)

        async def _gen():
            try:
                while True:
                    if await req.is_disconnected():
                        break
                    try:
                        line = await asyncio.wait_for(q.get(), timeout=15.0)
                        yield f"data: {json.dumps(line, ensure_ascii=False)}\n\n"
                    except asyncio.TimeoutError:
                        yield ": ping\n\n"
            finally:
                ctrl.subscribers.discard(q)

        return StreamingResponse(_gen(), media_type="text/event-stream")

    async def api_health_check(req: Request) -> JSONResponse:
        cfg = ctrl.get_config()
        target_url = req.query_params.get("url", "").strip()
        hurl = (target_url.rstrip("/") + "/health") if target_url else f"http://127.0.0.1:{cfg.get('port', 8000)}/health"
        try:
            def _probe() -> str:
                req_obj = urllib.request.Request(
                    hurl,
                    headers={
                        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36",
                        "Accept": "application/json,*/*",
                    },
                )
                with urllib.request.urlopen(req_obj, timeout=5) as resp:
                    return resp.read().decode("utf-8")

            body = await asyncio.to_thread(_probe)
            return JSONResponse({"ok": True, "url": hurl, "body": body})
        except Exception as exc:
            return JSONResponse({"ok": False, "url": hurl, "error": str(exc)})

    async def api_storage(_req: Request) -> JSONResponse:
        return JSONResponse({"ok": True, "stats": get_storage_stats()})

    async def api_storage_clean(req: Request) -> JSONResponse:
        body = await req.json()
        target = str(body.get("target", "")).strip()
        if target == "logs":
            ctrl.logs.clear()
        res = clean_storage(target)
        res["stats"] = get_storage_stats()
        return JSONResponse(res)

    async def api_tunnel_start(req: Request) -> JSONResponse:
        pid = req.path_params["pid"]
        c = ctrl.get_config()
        prof = next((p for p in (c.get("profiles") or []) if p.get("id") == pid), None)
        if not prof:
            return JSONResponse({"ok": False, "error": "未找到该入口配置"}, status_code=404)
        return JSONResponse(TUNNEL_MANAGER.start_tunnel(prof, int(c.get("port", 8000))))

    async def api_tunnel_stop(req: Request) -> JSONResponse:
        pid = req.path_params["pid"]
        return JSONResponse(TUNNEL_MANAGER.stop_tunnel(pid))

    async def api_tunnel_install(req: Request) -> JSONResponse:
        force, resume = False, False
        try:
            body = await req.json()
            force = bool(body.get("force", False))
            resume = bool(body.get("resume", False))
        except Exception:
            pass
        return JSONResponse(start_cloudflared_download(force_update=force, resume=resume))

    async def api_tunnel_pause(_req: Request) -> JSONResponse:
        return JSONResponse(pause_cloudflared_download())

    async def api_tunnel_cancel(_req: Request) -> JSONResponse:
        return JSONResponse(cancel_cloudflared_download())

    async def api_tunnel_import(req: Request) -> JSONResponse:
        raw_name = req.headers.get("X-Filename") or req.query_params.get("filename") or "cloudflared"
        filename = urllib.parse.unquote(raw_name)
        data = await req.body()
        res = await asyncio.to_thread(import_cloudflared_bytes, filename, data)
        return JSONResponse(res)

    async def api_tunnel_uninstall(_req: Request) -> JSONResponse:
        return JSONResponse(uninstall_cloudflared())

    async def api_sub_list(_req: Request) -> JSONResponse:
        return JSONResponse({"ok": True, "servers": SUB_MCP_MANAGER.list_with_status()})

    async def api_sub_upsert(req: Request) -> JSONResponse:
        try:
            body = await req.json()
            old_name = body.pop("old_name", None)
            entry = SUB_MCP_MANAGER.upsert_entry(body, old_name=old_name)
            return JSONResponse({"ok": True, "entry": entry})
        except Exception as exc:
            return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)

    async def api_sub_import(req: Request) -> JSONResponse:
        try:
            body = await req.json()
            imported = SUB_MCP_MANAGER.import_json(str(body.get("raw", "")))
            return JSONResponse({"ok": True, "count": len(imported), "entries": imported})
        except Exception as exc:
            return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)

    async def api_sub_toggle(req: Request) -> JSONResponse:
        name = req.path_params["name"]
        try:
            body = await req.json()
            entry = SUB_MCP_MANAGER.toggle_entry(name, bool(body.get("enabled", True)))
            return JSONResponse({"ok": True, "entry": entry})
        except Exception as exc:
            return JSONResponse({"ok": False, "error": str(exc)}, status_code=404)

    async def api_sub_delete(req: Request) -> JSONResponse:
        name = req.path_params["name"]
        ok = SUB_MCP_MANAGER.delete_entry(name)
        return JSONResponse({"ok": ok})

    async def api_sub_test(req: Request) -> JSONResponse:
        name = req.path_params["name"]
        res = await asyncio.to_thread(SUB_MCP_MANAGER.discover_tools, name, True)
        return JSONResponse(res)

    async def api_sub_probe(req: Request) -> JSONResponse:
        try:
            body = await req.json()
        except Exception:
            return JSONResponse({"ok": False, "error": "请求格式错误"}, status_code=400)
        res = await asyncio.to_thread(SUB_MCP_MANAGER.probe_draft, body)
        return JSONResponse(res)

    app = Starlette(
        routes=[
            Route("/", index),
            Route("/api/status", api_status),
            Route("/api/start", api_start, methods=["POST"]),
            Route("/api/stop", api_stop, methods=["POST"]),
            Route("/api/quit", api_quit, methods=["POST"]),
            Route("/api/config", api_config, methods=["POST"]),
            Route("/api/logs", api_logs),
            Route("/api/logs/clear", api_logs_clear, methods=["POST"]),
            Route("/api/logs/stream", api_logs_stream),
            Route("/api/health-check", api_health_check),
            Route("/api/storage", api_storage),
            Route("/api/storage/clean", api_storage_clean, methods=["POST"]),
            Route("/api/tunnels/install", api_tunnel_install, methods=["POST"]),
            Route("/api/tunnels/pause", api_tunnel_pause, methods=["POST"]),
            Route("/api/tunnels/cancel", api_tunnel_cancel, methods=["POST"]),
            Route("/api/tunnels/import", api_tunnel_import, methods=["POST"]),
            Route("/api/tunnels/uninstall", api_tunnel_uninstall, methods=["POST"]),
            Route("/api/tunnels/{pid}/start", api_tunnel_start, methods=["POST"]),
            Route("/api/tunnels/{pid}/stop", api_tunnel_stop, methods=["POST"]),
            Route("/api/sub-mcps", api_sub_list),
            Route("/api/sub-mcps", api_sub_upsert, methods=["POST"]),
            Route("/api/sub-mcps/import", api_sub_import, methods=["POST"]),
            Route("/api/sub-mcps/probe", api_sub_probe, methods=["POST"]),
            Route("/api/sub-mcps/{name}/toggle", api_sub_toggle, methods=["POST"]),
            Route("/api/sub-mcps/{name}", api_sub_delete, methods=["DELETE"]),
            Route("/api/sub-mcps/{name}/test", api_sub_test, methods=["POST"]),
        ]
    )

    # Check if another GUI instance is already listening on gui_port
    existing_gui_pid = _find_port_owner(gui_port)
    if existing_gui_pid is not None:
        should_kill = _ask_styled_yes_no(
            "Agent MCP 已在运行",
            f"检测到已有 Agent MCP 控制台实例正在运行（端口 {gui_port}，PID {existing_gui_pid}）。\n是否结束旧实例并启动当前窗口？",
        )
        if not should_kill:
            return
        _kill_pid_tree(existing_gui_pid)
        import time as _t

        _t.sleep(0.5)

    uv_config = uvicorn.Config(app, host="127.0.0.1", port=gui_port, log_level="warning")
    server = uvicorn.Server(uv_config)
    ctrl.uvicorn_server = server

    # Prefer pywebview frameless native window if installed; fallback to browser --app
    try:
        import webview

        server_thread = threading.Thread(target=server.run, daemon=True)
        server_thread.start()

        # Wait briefly for local HTTP server to bind
        import time as _time

        for _ in range(30):
            try:
                with socket.create_connection(("127.0.0.1", gui_port), timeout=0.15):
                    break
            except OSError:
                _time.sleep(0.1)

        win_state = {"maximized": False, "normal_rect": None}
        touch_drag_state: dict[str, Any] = {"hwnd": None, "ox": 0, "oy": 0}
        resize_state: dict[str, Any] = {"hwnd": None, "edge": "", "cx": 0, "cy": 0, "rect": (0, 0, 0, 0)}
        win_ref: dict[str, Any] = {"win": None}

        def _get_win32_hwnd() -> int | None:
            if os.name != "nt":
                return None
            # 1. Prefer exact native WinForms Form handle exposed by pywebview
            w = win_ref.get("win")
            if w is not None:
                try:
                    native = getattr(w, "native", None)
                    if native is not None and hasattr(native, "Handle"):
                        h = int(native.Handle.ToInt64())
                        if h:
                            return h
                except Exception:
                    pass
            # 2. Fallback: find visible top-level window belonging to this process
            try:
                import win32gui
                import win32process

                my_pid = os.getpid()
                found: list[int] = []

                def _cb(hwnd: int, _extra: Any) -> None:
                    if not win32gui.IsWindowVisible(hwnd):
                        return
                    _, pid = win32process.GetWindowThreadProcessId(hwnd)
                    if pid == my_pid:
                        l, t, r, b = win32gui.GetWindowRect(hwnd)
                        if (r - l) >= 200 and (b - t) >= 200:
                            found.append(hwnd)

                win32gui.EnumWindows(_cb, None)
                return found[0] if found else None
            except Exception:
                return None

        class WindowApi:
            def touch_drag_begin(self) -> dict[str, Any]:
                if os.name == "nt":
                    try:
                        import win32gui

                        hwnd = _get_win32_hwnd()
                        if hwnd:
                            if win_state["maximized"]:
                                rect = win_state.get("normal_rect")
                                win_state["maximized"] = False
                                if rect:
                                    l0, t0, r0, b0 = rect
                                    cx, cy = win32gui.GetCursorPos()
                                    w_norm = max(420, r0 - l0)
                                    h_norm = max(560, b0 - t0)
                                    nl = int(cx - w_norm // 2)
                                    nt = max(0, int(cy - 18))
                                    win32gui.MoveWindow(hwnd, nl, nt, w_norm, h_norm, True)
                            cx, cy = win32gui.GetCursorPos()
                            l, t, _, _ = win32gui.GetWindowRect(hwnd)
                            touch_drag_state["hwnd"] = hwnd
                            touch_drag_state["ox"] = int(cx - l)
                            touch_drag_state["oy"] = int(cy - t)
                            return {"ok": True}
                    except Exception:
                        pass
                return {"ok": False}

            def touch_drag_step(self) -> dict[str, Any]:
                if os.name == "nt":
                    hwnd = touch_drag_state.get("hwnd")
                    if hwnd:
                        try:
                            import win32con
                            import win32gui

                            cx, cy = win32gui.GetCursorPos()
                            nx = int(cx - touch_drag_state["ox"])
                            ny = int(cy - touch_drag_state["oy"])
                            win32gui.SetWindowPos(
                                hwnd,
                                0,
                                nx,
                                ny,
                                0,
                                0,
                                win32con.SWP_NOSIZE | win32con.SWP_NOZORDER | win32con.SWP_NOACTIVATE,
                            )
                            return {"ok": True}
                        except Exception:
                            pass
                return {"ok": False}

            def touch_drag_end(self) -> dict[str, Any]:
                touch_drag_state["hwnd"] = None
                _save_win_geom()
                return {"ok": True}

            def resize_begin(self, edge: str) -> dict[str, Any]:
                if os.name == "nt" and not win_state["maximized"]:
                    try:
                        import win32gui

                        hwnd = _get_win32_hwnd()
                        if hwnd:
                            cx, cy = win32gui.GetCursorPos()
                            rect = win32gui.GetWindowRect(hwnd)
                            resize_state["hwnd"] = hwnd
                            resize_state["edge"] = str(edge).lower()
                            resize_state["cx"] = int(cx)
                            resize_state["cy"] = int(cy)
                            resize_state["rect"] = rect
                            return {"ok": True}
                    except Exception:
                        pass
                return {"ok": False}

            def resize_step(self) -> dict[str, Any]:
                if os.name == "nt":
                    hwnd = resize_state.get("hwnd")
                    if hwnd:
                        try:
                            import win32con
                            import win32gui

                            cx, cy = win32gui.GetCursorPos()
                            dx = int(cx - resize_state["cx"])
                            dy = int(cy - resize_state["cy"])
                            l, t, r, b = resize_state["rect"]
                            edge = resize_state["edge"]
                            min_w, min_h = 420, 560
                            nl, nt, nr, nb = l, t, r, b
                            if "w" in edge:
                                nl = min(r - min_w, l + dx)
                            if "e" in edge:
                                nr = max(l + min_w, r + dx)
                            if "n" in edge:
                                nt = min(b - min_h, t + dy)
                            if "s" in edge:
                                nb = max(t + min_h, b + dy)
                            win32gui.SetWindowPos(
                                hwnd,
                                0,
                                int(nl),
                                int(nt),
                                int(nr - nl),
                                int(nb - nt),
                                win32con.SWP_NOZORDER | win32con.SWP_NOACTIVATE,
                            )
                            return {"ok": True}
                        except Exception:
                            pass
                return {"ok": False}

            def resize_end(self) -> dict[str, Any]:
                resize_state["hwnd"] = None
                _save_win_geom()
                return {"ok": True}

            def minimize(self) -> dict[str, Any]:
                if win_ref["win"]:
                    win_ref["win"].minimize()
                return {"ok": True}

            def toggle_maximize(self) -> dict[str, Any]:
                w = win_ref["win"]
                if not w:
                    return {"maximized": False}
                # On Windows, frameless maximize covers the taskbar; use Monitor WorkArea instead!
                if os.name == "nt":
                    try:
                        import win32api
                        import win32gui

                        hwnd = _get_win32_hwnd()
                        if hwnd:
                            if not win_state["maximized"]:
                                win_state["normal_rect"] = win32gui.GetWindowRect(hwnd)
                                mon = win32api.MonitorFromWindow(hwnd, 2)  # MONITOR_DEFAULTTONEAREST
                                left, top, right, bottom = win32api.GetMonitorInfo(mon)["Work"]
                                win32gui.MoveWindow(hwnd, left, top, right - left, bottom - top, True)
                                win_state["maximized"] = True
                            else:
                                rect = win_state.get("normal_rect")
                                if rect:
                                    l, t, r, b = rect
                                    win32gui.MoveWindow(hwnd, l, t, r - l, b - t, True)
                                else:
                                    w.restore()
                                win_state["maximized"] = False
                            return {"maximized": win_state["maximized"]}
                    except Exception:
                        pass
                if win_state["maximized"]:
                    w.restore()
                    win_state["maximized"] = False
                else:
                    w.maximize()
                    win_state["maximized"] = True
                return {"maximized": win_state["maximized"]}

            def close(self) -> dict[str, Any]:
                _save_win_geom()
                w = win_ref["win"]
                if w:
                    if tray_enabled["ok"]:
                        w.hide()
                    else:
                        w.destroy()
                return {"ok": True}

            def quit_app(self) -> dict[str, Any]:
                threading.Timer(0.05, _quit_all).start()
                return {"ok": True}

        def _show_window() -> None:
            w = win_ref["win"]
            if w:
                try:
                    w.show()
                    w.restore()
                except Exception:
                    pass

        def _quit_all() -> None:
            _save_win_geom()
            ctrl.shutdown_app()
            w = win_ref["win"]
            if w:
                try:
                    w.destroy()
                except Exception:
                    pass
            threading.Timer(0.5, lambda: os._exit(0)).start()

        quit_handler["fn"] = _quit_all

        cfg0 = ctrl.get_config()
        tray_title = f"{cfg0.get('server_name', 'Agent MCP')} Console"
        tray_enabled["ok"] = start_system_tray(
            title=tray_title,
            ico_dir=PROJECT_ROOT / "agent_mcp" / "assets",
            on_open=_show_window,
            on_start=lambda: ctrl.start(),
            on_stop=lambda: ctrl.stop(),
            on_quit=_quit_all,
        )

        print(f"Agent MCP Desktop Console (pywebview frameless) running at: {url} (System Tray: {'ON' if tray_enabled['ok'] else 'OFF'})")
        win_state_file = WINDOW_STATE_PATH

        def _load_win_geom() -> dict[str, Any]:
            if not win_state_file.is_file():
                return {}
            try:
                d = json.loads(win_state_file.read_text(encoding="utf-8"))
                return d if isinstance(d, dict) else {}
            except Exception:
                return {}

        def _save_win_geom() -> None:
            w = win_ref["win"]
            if not w:
                return
            try:
                rect: dict[str, Any] = {"maximized": bool(win_state["maximized"])}
                if os.name == "nt":
                    import win32gui

                    hwnd = _get_win32_hwnd()
                    if hwnd:
                        if win_state["maximized"] and win_state.get("normal_rect"):
                            l, t, r, b = win_state["normal_rect"]
                        else:
                            l, t, r, b = win32gui.GetWindowRect(hwnd)
                        if (r - l) >= 380 and (b - t) >= 400:
                            rect.update({"x": int(l), "y": int(t), "w": int(r - l), "h": int(b - t)})
                else:
                    rect.update({"x": int(w.x), "y": int(w.y), "w": int(w.width), "h": int(w.height)})
                if "w" in rect:
                    win_state_file.write_text(json.dumps(rect, indent=2), encoding="utf-8")
            except Exception:
                pass

        saved_geom = _load_win_geom()
        init_w = max(420, int(saved_geom.get("w") or 1140))
        init_h = max(560, int(saved_geom.get("h") or 760))
        init_x = saved_geom.get("x")
        init_y = saved_geom.get("y")

        def _apply_saved_geom_and_icon() -> None:
            """Apply terracotta taskbar icon + AppUserModelID + exact saved Win32 rect."""
            if os.name != "nt":
                return
            try:
                import ctypes
                import win32api
                import win32con
                import win32gui
                from .tray import _create_tray_ico

                try:
                    ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID("iamr0s.AgentMCP.Console.v2")
                except Exception:
                    pass

                ico_path = ensure_app_icon(APP_ICON_PATH)
                # Set native WinForms Form.Icon directly so Windows 11 taskbar always picks it up
                w = win_ref.get("win")
                if w is not None and ico_path and ico_path.is_file():
                    try:
                        import System.Drawing as _SD

                        native = getattr(w, "native", None)
                        if native is not None:
                            native.Icon = _SD.Icon(str(ico_path))
                    except Exception:
                        pass
                for _ in range(40):
                    hwnd = _get_win32_hwnd()
                    if hwnd:
                        if ico_path and ico_path.is_file():
                            h_big = win32gui.LoadImage(
                                0, str(ico_path), win32con.IMAGE_ICON, 48, 48, win32con.LR_LOADFROMFILE
                            )
                            h_small = win32gui.LoadImage(
                                0, str(ico_path), win32con.IMAGE_ICON, 16, 16, win32con.LR_LOADFROMFILE
                            )
                            if h_big:
                                win32api.SendMessage(hwnd, win32con.WM_SETICON, win32con.ICON_BIG, h_big)
                            if h_small:
                                win32api.SendMessage(hwnd, win32con.WM_SETICON, win32con.ICON_SMALL, h_small)
                        if init_x is not None and init_y is not None:
                            win32gui.MoveWindow(hwnd, int(init_x), int(init_y), init_w, init_h, True)
                        if saved_geom.get("maximized"):
                            win_state["normal_rect"] = (int(init_x or 100), int(init_y or 80), int(init_x or 100) + init_w, int(init_y or 80) + init_h)
                            mon = win32api.MonitorFromWindow(hwnd, 2)
                            left, top, right, bottom = win32api.GetMonitorInfo(mon)["Work"]
                            win32gui.MoveWindow(hwnd, left, top, right - left, bottom - top, True)
                            win_state["maximized"] = True
                        return
                    _time.sleep(0.1)
            except Exception:
                pass

        def _detect_initial_bg() -> str:
            if os.name == "nt":
                try:
                    import winreg

                    with winreg.OpenKey(
                        winreg.HKEY_CURRENT_USER,
                        r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                    ) as key:
                        val, _ = winreg.QueryValueEx(key, "AppsUseLightTheme")
                        if int(val) == 0:
                            return "#1A1917"
                except Exception:
                    pass
            elif sys.platform == "darwin":
                try:
                    out = subprocess.check_output(
                        ["defaults", "read", "-g", "AppleInterfaceStyle"],
                        stderr=subprocess.DEVNULL,
                    ).decode("utf-8", errors="ignore").strip()
                    if out.lower() == "dark":
                        return "#1A1917"
                except Exception:
                    pass
            return "#FAF9F5"

        create_kw: dict[str, Any] = {
            "title": tray_title,
            "url": url,
            "width": init_w,
            "height": init_h,
            "min_size": (420, 560),
            "frameless": True,
            "easy_drag": False,
            "hidden": True,
            "js_api": WindowApi(),
            "background_color": _detect_initial_bg(),
        }
        if init_x is not None and init_y is not None:
            create_kw["x"] = int(init_x)
            create_kw["y"] = int(init_y)

        # Must set AppUserModelID BEFORE creating any WinForms window so Windows taskbar uses our icon
        if os.name == "nt":
            try:
                import ctypes as _ct

                _ct.windll.shell32.SetCurrentProcessExplicitAppUserModelID("iamr0s.AgentMCP.Console.v2")
            except Exception:
                pass
        ico_file = ensure_app_icon(APP_ICON_PATH)

        if cfg0.get("auto_start"):
            threading.Timer(0.15, ctrl.start).start()

        win = webview.create_window(**create_kw)
        win_ref["win"] = win
        revealed = {"done": False}

        def _reveal_window() -> None:
            if revealed["done"]:
                return
            revealed["done"] = True
            _apply_saved_geom_and_icon()
            try:
                win.show()
            except Exception:
                pass
            # Re-apply icon once visible so Windows taskbar picks up ICON_BIG cleanly
            threading.Timer(0.15, _apply_saved_geom_and_icon).start()

        def _on_loaded() -> None:
            threading.Timer(0.06, _reveal_window).start()

        win.events.loaded += _on_loaded
        threading.Timer(2.5, _reveal_window).start()
        try:
            wv_cache = DATA_DIR / "webview2"
            wv_cache.mkdir(parents=True, exist_ok=True)
            start_kw: dict[str, Any] = {
                "private_mode": False,
                "storage_path": str(wv_cache),
            }
            if ico_file and ico_file.is_file():
                start_kw["icon"] = str(ico_file)
            webview.start(**start_kw)
        finally:
            _save_win_geom()
            ctrl.shutdown_app()
        return
    except ImportError:
        pass

    cfg0 = ctrl.get_config()
    tray_title = f"{cfg0.get('server_name', 'Agent MCP')} Console"
    tray_enabled["ok"] = start_system_tray(
        title=tray_title,
        ico_dir=PROJECT_ROOT / "agent_mcp" / "assets",
        on_open=lambda: _open_app_window(url),
        on_start=lambda: ctrl.start(),
        on_stop=lambda: ctrl.stop(),
        on_quit=lambda: ctrl.shutdown_app(),
    )

    print(f"Agent MCP Web Console running at: {url} (System Tray: {'ON' if tray_enabled['ok'] else 'OFF'})")
    threading.Timer(0.6, _open_app_window, args=(url,)).start()
    try:
        server.run()
    finally:
        ctrl.stop()
