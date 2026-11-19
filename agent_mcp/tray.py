"""Unified Claude-inspired app icon generator + System Tray (pystray / Win32 fallback)."""

from __future__ import annotations

import base64
import os
import sys
import threading
import time
from pathlib import Path
from typing import Callable

APP_ICON_SVG = (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">'
    '<rect x="2" y="2" width="60" height="60" rx="16" fill="#FAF9F5" stroke="#E3E0D6" stroke-width="2.5"/>'
    '<path d="M32 10L37.4 26.6L54 32L37.4 37.4L32 54L26.6 37.4L10 32L26.6 26.6L32 10Z" fill="#D97757"/>'
    "</svg>"
)
APP_ICON_DATA_URI = "data:image/svg+xml;base64," + base64.b64encode(APP_ICON_SVG.encode("utf-8")).decode("ascii")


def ensure_app_icon(ico_path: Path, force: bool = False) -> Path | None:
    """Generate a crisp multi-resolution Claude-style warm-parchment + terracotta 4-point star .ico."""
    if ico_path.is_file() and not force:
        return ico_path
    try:
        from PIL import Image, ImageDraw

        # Render at 512x512 (2x supersampled) for razor-sharp anti-aliased edges at every ICO size
        s = 512
        img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)

        # Warm parchment rounded square with subtle hairline border
        pad = 24
        radius = 124
        draw.rounded_rectangle(
            (pad, pad, s - pad, s - pad),
            radius=radius,
            fill=(250, 249, 245, 255),
            outline=(227, 224, 214, 255),
            width=14,
        )

        # Terracotta 4-point star (#D97757)
        cx = cy = s / 2
        outer = 176
        inner = 48
        pts = [
            (cx, cy - outer),
            (cx + inner, cy - inner),
            (cx + outer, cy),
            (cx + inner, cy + inner),
            (cx, cy + outer),
            (cx - inner, cy + inner),
            (cx - outer, cy),
            (cx - inner, cy - inner),
        ]
        draw.polygon(pts, fill=(217, 119, 87, 255))

        ico_path.parent.mkdir(parents=True, exist_ok=True)
        img.save(
            ico_path,
            format="ICO",
            sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
        )
        return ico_path
    except Exception:
        return ico_path if ico_path.is_file() else None


# Backward-compatible alias
def _create_tray_ico(ico_path: Path) -> Path | None:
    return ensure_app_icon(ico_path)


def start_system_tray(
    title: str,
    ico_dir: Path,
    on_open: Callable[[], None],
    on_start: Callable[[], None],
    on_stop: Callable[[], None],
    on_quit: Callable[[], None],
) -> bool:
    """Start a background system tray icon using the unified app_icon.ico."""
    ico_path = ensure_app_icon(ico_dir / "app_icon.ico")

    # 1. Try cross-platform pystray first (Win / macOS / Linux)
    try:
        import pystray
        from PIL import Image

        img = Image.open(ico_path) if ico_path else Image.new("RGB", (32, 32), (217, 119, 87))
        menu = pystray.Menu(
            pystray.MenuItem("打开控制台", lambda _i, _m: on_open(), default=True),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("启动 MCP 服务", lambda _i, _m: on_start()),
            pystray.MenuItem("停止 MCP 服务", lambda _i, _m: on_stop()),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("完全退出应用", lambda icon, _m: (icon.stop(), on_quit())),
        )
        icon = pystray.Icon("agent-mcp", img, title, menu)
        threading.Thread(target=icon.run, daemon=True).start()
        return True
    except Exception:
        pass

    # 2. Native Windows tray fallback using pywin32
    if os.name == "nt":
        ready_ev = threading.Event()
        ok_flag = {"ok": False}

        def _run_win32_tray() -> None:
            try:
                import win32api
                import win32con
                import win32gui

                WM_TRAY = win32con.WM_USER + 20
                ID_OPEN, ID_START, ID_STOP, ID_QUIT = 1001, 1002, 1003, 1004
                cls_name = f"AgentMcpTray_{os.getpid()}_{int(time.time() * 1000)}"

                def _wnd_proc(hwnd: int, msg: int, wparam: int, lparam: int) -> int:
                    if msg == WM_TRAY:
                        if lparam in (win32con.WM_LBUTTONDBLCLK, win32con.WM_LBUTTONUP):
                            on_open()
                        elif lparam == win32con.WM_RBUTTONUP:
                            menu = win32gui.CreatePopupMenu()
                            win32gui.AppendMenu(menu, win32con.MF_STRING, ID_OPEN, "打开控制台")
                            win32gui.AppendMenu(menu, win32con.MF_SEPARATOR, 0, "")
                            win32gui.AppendMenu(menu, win32con.MF_STRING, ID_START, "启动 MCP 服务")
                            win32gui.AppendMenu(menu, win32con.MF_STRING, ID_STOP, "停止 MCP 服务")
                            win32gui.AppendMenu(menu, win32con.MF_SEPARATOR, 0, "")
                            win32gui.AppendMenu(menu, win32con.MF_STRING, ID_QUIT, "完全退出应用")
                            pos = win32gui.GetCursorPos()
                            win32gui.SetForegroundWindow(hwnd)
                            win32gui.TrackPopupMenu(
                                menu,
                                win32con.TPM_LEFTALIGN | win32con.TPM_BOTTOMALIGN,
                                pos[0],
                                pos[1],
                                0,
                                hwnd,
                                None,
                            )
                            win32gui.PostMessage(hwnd, win32con.WM_NULL, 0, 0)
                    elif msg == win32con.WM_COMMAND:
                        cid = win32api.LOWORD(wparam)
                        if cid == ID_OPEN:
                            on_open()
                        elif cid == ID_START:
                            on_start()
                        elif cid == ID_STOP:
                            on_stop()
                        elif cid == ID_QUIT:
                            try:
                                win32gui.Shell_NotifyIcon(win32gui.NIM_DELETE, (hwnd, 0))
                            except Exception:
                                pass
                            win32gui.DestroyWindow(hwnd)
                            on_quit()
                    elif msg == win32con.WM_DESTROY:
                        try:
                            win32gui.Shell_NotifyIcon(win32gui.NIM_DELETE, (hwnd, 0))
                        except Exception:
                            pass
                        win32gui.PostQuitMessage(0)
                    return win32gui.DefWindowProc(hwnd, msg, wparam, lparam)

                wc = win32gui.WNDCLASS()
                wc.hInstance = win32api.GetModuleHandle(None)
                wc.lpszClassName = cls_name
                wc.lpfnWndProc = _wnd_proc
                class_atom = win32gui.RegisterClass(wc)
                hwnd = win32gui.CreateWindow(
                    class_atom, title, 0, 0, 0, 0, 0, 0, 0, wc.hInstance, None
                )
                hicon = (
                    win32gui.LoadImage(
                        0,
                        str(ico_path),
                        win32con.IMAGE_ICON,
                        0,
                        0,
                        win32con.LR_LOADFROMFILE | win32con.LR_DEFAULTSIZE,
                    )
                    if ico_path and ico_path.is_file()
                    else win32gui.LoadIcon(0, win32con.IDI_APPLICATION)
                )
                flags = win32gui.NIF_ICON | win32gui.NIF_MESSAGE | win32gui.NIF_TIP
                win32gui.Shell_NotifyIcon(win32gui.NIM_ADD, (hwnd, 0, flags, WM_TRAY, hicon, title[:127]))
                ok_flag["ok"] = True
                ready_ev.set()
                win32gui.PumpMessages()
            except Exception as exc:
                print(f"[Tray] 初始化系统托盘失败: {exc}", file=sys.stderr)
                ready_ev.set()

        threading.Thread(target=_run_win32_tray, daemon=True).start()
        ready_ev.wait(timeout=2.0)
        return ok_flag["ok"]

    return False
