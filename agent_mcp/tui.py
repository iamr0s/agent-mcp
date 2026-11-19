"""Claude / Anthropic editorial-style Fullscreen Terminal UI (TUI) for Agent MCP.

Strict 1:1 visual, structural, and functional counterpart to `web_gui.py`:
  - Shares `GuiController` directly (structured `MCP_JSON_EVENTS=1` events, 1-call-1-card merging,
    port-conflict detection & takeover prompt, auto-start, and auto-tunnel lifecycle).
  - Supports Claude Warm Paper (Light) and Claude Slate (Dark) themes live.
  - Exact 3-page collapsible sidebar layout (`活动与调用流`, `子 MCP`, `服务配置`) and all 5 setup cards,
    chips, segmented controls, expandable cards, and modals without extra or simplified fields.
"""

from __future__ import annotations

import json
import os
import secrets
import string
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any, Callable

from . import VERSION
from .auth import hash_password
from .config import (
    DATA_DIR,
    DEFAULT_CONFIG_PATH,
    LOGS_DIR,
    clean_storage,
    get_storage_stats,
    normalize_profile,
    sanitize_prefix,
    save_config_file,
)
from .sub_mcp import SUB_MCP_MANAGER
from .tunnel import (
    TUNNEL_MANAGER,
    cancel_cloudflared_download,
    import_cloudflared_bytes,
    pause_cloudflared_download,
    start_cloudflared_download,
    uninstall_cloudflared,
)
from .web_gui import GuiController

try:
    from rich.markup import escape as rich_escape
    from rich.text import Text
    from textual import on, work
    from textual.app import App, ComposeResult
    from textual.binding import Binding
    from textual.containers import Horizontal, Vertical, VerticalScroll
    from textual.screen import ModalScreen
    from textual.widgets import (
        Button,
        Checkbox,
        ContentSwitcher,
        Input,
        Label,
        ProgressBar,
        Select,
        Static,
        Switch,
        TextArea,
    )

    HAS_TEXTUAL = True
except Exception:  # pragma: no cover
    HAS_TEXTUAL = False


TOOL_LABELS: dict[str, tuple[str, str]] = {
    "read_file": ("📄", "读取文件"),
    "read_files": ("📚", "批量读取"),
    "stat_file": ("ℹ️", "查看属性"),
    "list_dir": ("📁", "浏览目录"),
    "glob_files": ("🗂️", "查找文件"),
    "search_text": ("🔍", "搜索内容"),
    "create_file": ("📝", "写入文件"),
    "edit_file": ("✏️", "编辑文件"),
    "apply_patch": ("🩹", "应用补丁"),
    "replace_text": ("🔁", "批量替换"),
    "file_op": ("📦", "文件操作"),
    "undo_edit": ("↩️", "撤销修改"),
    "run_command": ("⚡", "执行命令"),
    "start_process": ("🚀", "启动进程"),
    "manage_process": ("⚙️", "管理进程"),
    "list_roots": ("🧭", "检查环境"),
    "list_sub_mcps": ("🧩", "列出子 MCP"),
    "inspect_sub_mcp": ("🔎", "查看子 MCP 工具"),
    "call_sub_mcp": ("🔌", "调用子 MCP"),
}

TUI_STATE_PATH = DATA_DIR / "tui_state.json"


def _gen_rand(prefix: str, length: int) -> str:
    alphabet = string.ascii_letters + string.digits + "_-"
    return prefix + "".join(secrets.choice(alphabet) for _ in range(length))


def _fmt_bytes(num: int | float) -> str:
    b = float(num or 0)
    if b <= 0:
        return "0 B"
    if b < 1024:
        return f"{int(b)} B"
    if b < 1048576:
        return f"{b / 1024:.1f} KB"
    return f"{b / 1048576:.2f} MB"


def _tool_meta(raw_tool: str) -> tuple[str, str]:
    if not raw_tool:
        return ("•", "系统消息")
    for k, v in TOOL_LABELS.items():
        if raw_tool == k or raw_tool.endswith("_" + k):
            return v
    return ("🔧", raw_tool)


def _human_summary(ev: dict[str, Any]) -> str:
    a = ev.get("args") or {}
    t = str(ev.get("tool") or "")
    if isinstance(a, dict):
        if t.endswith("read_file") and a.get("path"):
            off = f" (第 {a['offset']} 行起)" if a.get("offset") else ""
            return f"{a['path']}{off}"
        if t.endswith("edit_file") and a.get("path"):
            cnt = f" · {len(a['edits'])} 处修改" if isinstance(a.get("edits"), list) else ""
            return f"{a['path']}{cnt}"
        if t.endswith("create_file") and a.get("path"):
            ov = " (覆盖)" if a.get("overwrite") else ""
            return f"{a['path']}{ov}"
        if t.endswith("list_dir"):
            return str(a.get("path") or ".")
        if t.endswith("search_text") and a.get("pattern"):
            return f"\"{a['pattern']}\" @ {a.get('path') or '.'}"
        if t.endswith("run_command") and a.get("command"):
            return str(a["command"]).splitlines()[0][:120]
        if t.endswith("file_op") and a.get("action"):
            dst = f" -> {a['dst']}" if a.get("dst") else ""
            return f"{a['action']}: {a.get('src') or ''}{dst}"
        if t.endswith("inspect_sub_mcp") and a.get("server_name"):
            sub_t = f" / {a['tool_name']}" if a.get("tool_name") else " (工具目录)"
            return f"{a['server_name']}{sub_t}"
        if t.endswith("call_sub_mcp") and a.get("server_name"):
            return f"{a['server_name']} / {a.get('tool_name') or ''}"
    return str(ev.get("summary") or ev.get("raw") or "")


def _parse_kv_lines(text: str, sep: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for raw in text.splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        idx = s.find(sep)
        if idx > 0:
            k, v = s[:idx].strip(), s[idx + 1 :].strip()
            if k:
                out[k] = v
    return out


def _copy_to_clipboard(app: App[Any], text: str) -> None:
    try:
        app.copy_to_clipboard(text)
    except Exception:
        pass
    if os.name == "nt":
        try:
            subprocess.run(["clip"], input=text.encode("utf-16le"), check=False, creationflags=subprocess.CREATE_NO_WINDOW)
        except Exception:
            pass


TUI_CSS = """
/* ---- Light Mode (Default: Claude Warm Paper) ---- */
Screen {
    background: #FAF9F5;
    color: #141413;
}

Screen.dark-mode {
    background: #1A1917;
    color: #F3F1EA;
}

#titlebar {
    height: 2;
    background: #F3F1EA;
    color: #141413;
    border-bottom: solid #E3E0D6;
    padding: 0 2;
    align-vertical: middle;
}
Screen.dark-mode #titlebar {
    background: #23221F;
    color: #F3F1EA;
    border-bottom: solid #35332E;
}
#tb-name {
    width: 1fr;
    text-style: bold;
}
#tb-mode {
    width: auto;
    background: #E8E6DC;
    color: #6E6C66;
    padding: 0 1;
}
Screen.dark-mode #tb-mode {
    background: #2E2D29;
    color: #9C988E;
}

#statusbar {
    height: 2;
    background: #F3F1EA;
    color: #6E6C66;
    border-top: solid #E3E0D6;
    padding: 0 2;
    align-vertical: middle;
}
Screen.dark-mode #statusbar {
    background: #23221F;
    color: #9C988E;
    border-top: solid #35332E;
}
#ft-left {
    width: 1fr;
}
#ft-right {
    width: auto;
}

#body-shell {
    height: 1fr;
    width: 1fr;
}

/* ---- Left Sidebar ---- */
#sidebar {
    width: 26;
    background: #F3F1EA;
    border-right: solid #E3E0D6;
    padding: 1 1;
}
Screen.dark-mode #sidebar {
    background: #23221F;
    border-right: solid #35332E;
}
#sidebar.collapsed {
    width: 9;
}

#sb-brand-row {
    height: 3;
    align-vertical: middle;
    margin-bottom: 1;
}
#btn-sb-collapse {
    min-width: 5;
    width: 5;
    height: 3;
    padding: 0;
    margin-right: 1;
}
#sb-pill {
    width: 1fr;
    background: #E8E6DC;
    color: #6E6C66;
    padding: 0 1;
    height: 3;
    content-align: center middle;
    border: round #E3E0D6;
}
Screen.dark-mode #sb-pill {
    background: #2E2D29;
    color: #9C988E;
    border: round #35332E;
}
#sb-pill.on {
    background: #EBF0E4;
    color: #3E5425;
    border: round #788C5D;
    text-style: bold;
}
Screen.dark-mode #sb-pill.on {
    background: #283022;
    color: #8FA672;
    border: round #8FA672;
}

#sb-nav {
    height: 1fr;
}
.nav-btn {
    width: 1fr;
    height: 3;
    margin-bottom: 1;
    background: transparent;
    color: #6E6C66;
    border: round transparent;
    content-align: left middle;
}
Screen.dark-mode .nav-btn {
    color: #9C988E;
}
.nav-btn:hover {
    background: #E8E6DC;
    color: #141413;
}
Screen.dark-mode .nav-btn:hover {
    background: #2E2D29;
    color: #F3F1EA;
}
.nav-btn.active {
    background: #FAF9F5;
    color: #141413;
    border: round #E3E0D6;
    text-style: bold;
}
Screen.dark-mode .nav-btn.active {
    background: #1A1917;
    color: #F3F1EA;
    border: round #35332E;
}

#sb-ctrl {
    height: auto;
    border-top: solid #E3E0D6;
    padding-top: 1;
}
Screen.dark-mode #sb-ctrl {
    border-top: solid #35332E;
}
.ctrl-btn {
    width: 1fr;
    height: 3;
    margin-bottom: 1;
}

/* ---- Main Content ---- */
#main-area {
    width: 1fr;
    height: 1fr;
    padding: 1 2;
}

.page-head {
    height: 3;
    align-vertical: middle;
    margin-bottom: 1;
}
.page-h1 {
    width: 1fr;
    text-style: bold;
    padding-top: 1;
}

/* ---- Buttons ---- */
Button {
    background: #FAF9F5;
    color: #141413;
    border: round #E3E0D6;
    min-width: 8;
    height: 3;
    margin-right: 1;
}
Screen.dark-mode Button {
    background: #23221F;
    color: #F3F1EA;
    border: round #35332E;
}
Button:hover {
    background: #E8E6DC;
}
Screen.dark-mode Button:hover {
    background: #2E2D29;
}
Button.clay {
    background: #D97757;
    color: #FAF9F5;
    border: round #C46142;
    text-style: bold;
}
Button.clay:hover {
    background: #C46142;
}
Button.ink {
    background: #141413;
    color: #FAF9F5;
    border: round #141413;
    text-style: bold;
}
Screen.dark-mode Button.ink {
    background: #F3F1EA;
    color: #1A1917;
    border: round #F3F1EA;
}
Button.danger {
    background: #B8443A;
    color: #FAF9F5;
    border: round #9E372E;
    text-style: bold;
}
Button.danger-outline {
    color: #B8443A;
}
Screen.dark-mode Button.danger-outline {
    color: #EF6B60;
}
Button.seg-btn {
    min-width: 7;
    margin-right: 0;
    background: #F3F1EA;
    color: #6E6C66;
    border: round #E3E0D6;
}
Screen.dark-mode Button.seg-btn {
    background: #23221F;
    color: #9C988E;
    border: round #35332E;
}
Button.seg-btn.active {
    background: #D97757;
    color: #FAF9F5;
    border: round #C46142;
    text-style: bold;
}
Button.chip {
    min-width: 6;
    height: 3;
    padding: 0 1;
    margin-right: 1;
    background: #F3F1EA;
    color: #6E6C66;
    border: round #E3E0D6;
}
Screen.dark-mode Button.chip {
    background: #23221F;
    color: #9C988E;
    border: round #35332E;
}
Button.chip.active {
    background: #141413;
    color: #FAF9F5;
    border: round #141413;
    text-style: bold;
}
Screen.dark-mode Button.chip.active {
    background: #E08263;
    color: #1A1917;
    border: round #E08263;
}

/* ---- Activity Page ---- */
.stats-row {
    height: 4;
    margin-bottom: 1;
}
.stat-box {
    width: 1fr;
    height: 4;
    background: #F3F1EA;
    border: round #E3E0D6;
    padding: 0 2;
    margin-right: 1;
}
Screen.dark-mode .stat-box {
    background: #23221F;
    border: round #35332E;
}
.stat-k {
    color: #6E6C66;
}
Screen.dark-mode .stat-k {
    color: #9C988E;
}
.stat-v {
    text-style: bold;
}

.toolbar {
    height: 3;
    align-vertical: middle;
    margin-bottom: 1;
}
.seg-wrap {
    width: auto;
    height: 3;
    margin-right: 1;
}
#f-q {
    width: 1fr;
    margin-right: 1;
}
#f-dep {
    width: auto;
    background: transparent;
    border: none;
}

.chip-bar {
    height: auto;
    margin-bottom: 1;
}

#feed-scroll {
    height: 1fr;
    border: round #E3E0D6;
    background: #F3F1EA;
    padding: 1 1;
}
Screen.dark-mode #feed-scroll {
    border: round #35332E;
    background: #23221F;
}

.ev-card {
    background: #FAF9F5;
    border: round #E3E0D6;
    padding: 0 1;
    margin-bottom: 1;
    height: auto;
}
Screen.dark-mode .ev-card {
    background: #1A1917;
    border: round #35332E;
}
.ev-card.err {
    border: round #D9827B;
}
.ev-head {
    height: 3;
    align-vertical: middle;
}
.ev-title {
    width: 1fr;
    padding-top: 1;
}
.ev-det {
    border-top: solid #E3E0D6;
    padding: 1 1;
    height: auto;
}
Screen.dark-mode .ev-det {
    border-top: solid #35332E;
}
.det-box {
    background: #141413;
    color: #F3F1EA;
    padding: 1 1;
    margin-top: 0;
    margin-bottom: 1;
    height: auto;
}

/* ---- Cards & Sub-MCP / Profile Items ---- */
.card {
    background: #F3F1EA;
    border: round #E3E0D6;
    padding: 1 2;
    margin-bottom: 1;
    height: auto;
}
Screen.dark-mode .card {
    background: #23221F;
    border: round #35332E;
}
.card-h2 {
    text-style: bold;
    margin-bottom: 1;
    width: 1fr;
}
.card-foot {
    height: 3;
    align-vertical: middle;
    border-top: solid #E3E0D6;
    padding-top: 0;
    margin-top: 1;
}
Screen.dark-mode .card-foot {
    border-top: solid #35332E;
}
.dirty-hint {
    width: 1fr;
    color: #6E6C66;
    padding-top: 1;
}
Screen.dark-mode .dirty-hint {
    color: #9C988E;
}
.dirty-hint.dirty {
    color: #D97757;
    text-style: bold;
}

.sub-banner {
    background: #F3F1EA;
    border: round #E3E0D6;
    padding: 0 2;
    margin-bottom: 1;
    height: 3;
    content-align: left middle;
}
Screen.dark-mode .sub-banner {
    background: #23221F;
    border: round #35332E;
}

.item-card {
    background: #FAF9F5;
    border: round #E3E0D6;
    padding: 1 2;
    margin-bottom: 1;
    height: auto;
}
Screen.dark-mode .item-card {
    background: #1A1917;
    border: round #35332E;
}
.item-card.disabled {
    opacity: 0.65;
}
.item-top {
    height: 3;
    align-vertical: middle;
}
.item-id {
    width: 1fr;
    padding-top: 1;
}
.item-ep {
    color: #6E6C66;
    margin-top: 0;
    margin-bottom: 0;
}
Screen.dark-mode .item-ep {
    color: #9C988E;
}
.tools-box {
    border-top: solid #E3E0D6;
    margin-top: 1;
    padding-top: 1;
    height: auto;
}
Screen.dark-mode .tools-box {
    border-top: solid #35332E;
}

/* ---- Storage 4-Tile Grid ---- */
.st-grid {
    height: 5;
    margin-bottom: 1;
}
.st-tile {
    width: 1fr;
    height: 5;
    background: #FAF9F5;
    border: round #E3E0D6;
    padding: 0 2;
    margin-right: 1;
}
Screen.dark-mode .st-tile {
    background: #1A1917;
    border: round #35332E;
}

/* ---- Form Controls ---- */
.form-row {
    height: auto;
    align-vertical: middle;
    margin-bottom: 1;
}
.form-lbl {
    width: 22;
    color: #6E6C66;
    padding-top: 1;
}
Screen.dark-mode .form-lbl {
    color: #9C988E;
}
Input {
    background: #FAF9F5;
    color: #141413;
    border: round #E3E0D6;
    width: 1fr;
}
Screen.dark-mode Input {
    background: #1A1917;
    color: #F3F1EA;
    border: round #35332E;
}
Input:focus {
    border: round #D97757;
}
TextArea {
    background: #FAF9F5;
    color: #141413;
    border: round #E3E0D6;
    height: 5;
    width: 1fr;
}
Screen.dark-mode TextArea {
    background: #1A1917;
    color: #F3F1EA;
    border: round #35332E;
}
Select {
    width: 24;
    margin-right: 1;
}
Checkbox {
    background: transparent;
    border: none;
    margin-right: 2;
}
Switch {
    margin-right: 1;
}
.muted {
    color: #6E6C66;
}
Screen.dark-mode .muted {
    color: #9C988E;
}
.hidden {
    display: none;
}

/* ---- Modals ---- */
ModalScreen {
    align: center middle;
    background: rgba(20, 20, 19, 0.55);
}
.modal-card {
    width: 72;
    height: auto;
    max-height: 92%;
    background: #FAF9F5;
    border: round #D97757;
    padding: 1 2;
}
Screen.dark-mode .modal-card {
    background: #23221F;
    color: #F3F1EA;
}
.modal-wide {
    width: 88;
    height: auto;
    max-height: 92%;
    background: #FAF9F5;
    border: round #D97757;
    padding: 1 2;
}
Screen.dark-mode .modal-wide {
    background: #23221F;
    color: #F3F1EA;
}
.modal-hdr {
    height: 3;
    align-vertical: middle;
    margin-bottom: 1;
}
.modal-title {
    width: 1fr;
    text-style: bold;
    color: #D97757;
    padding-top: 1;
}
.modal-actions {
    height: 3;
    align-vertical: middle;
    border-top: solid #E3E0D6;
    margin-top: 1;
}
Screen.dark-mode .modal-actions {
    border-top: solid #35332E;
}
"""


if HAS_TEXTUAL:

    # =========================================================================
    # Modals matching web_gui.py
    # =========================================================================
    class ConfirmModal(ModalScreen[bool]):
        """Matches `#modal-backdrop` confirmation dialog in web_gui.py."""

        BINDINGS = [Binding("escape", "cancel", "取消")]

        def __init__(self, title: str, message: str, ok_text: str = "确定", danger: bool = False) -> None:
            super().__init__()
            self._title = title
            self._message = message
            self._ok_text = ok_text
            self._danger = danger

        def compose(self) -> ComposeResult:
            if self.app.screen.has_class("dark-mode"):
                self.add_class("dark-mode")
            with Vertical(classes="modal-card"):
                yield Static(f"✦ {rich_escape(self._title)}", classes="modal-title")
                yield Static(rich_escape(self._message), classes="muted")
                with Horizontal(classes="modal-actions"):
                    yield Button("取消", id="cm-cancel")
                    yield Button(self._ok_text, id="cm-ok", classes=("danger" if self._danger else "clay"))

        def action_cancel(self) -> None:
            self.dismiss(False)

        def on_button_pressed(self, event: Button.Pressed) -> None:
            self.dismiss(event.button.id == "cm-ok")

    class ImportFileModal(ModalScreen[str | None]):
        """File path selector for importing a local `cloudflared` archive/binary."""

        BINDINGS = [Binding("escape", "cancel", "取消")]

        def compose(self) -> ComposeResult:
            if self.app.screen.has_class("dark-mode"):
                self.add_class("dark-mode")
            with Vertical(classes="modal-card"):
                yield Static("✦ 选择本地 cloudflared 文件导入", classes="modal-title")
                yield Static("输入下载好的 cloudflared 可执行文件或 .tgz 压缩包路径：", classes="muted")
                yield Input(placeholder="例如 D:\\Downloads\\cloudflared-windows-amd64.exe", id="imp-path")
                with Horizontal(classes="modal-actions"):
                    yield Button("取消", id="imp-cancel")
                    yield Button("导入", id="imp-ok", classes="clay")

        def action_cancel(self) -> None:
            self.dismiss(None)

        def on_button_pressed(self, event: Button.Pressed) -> None:
            if event.button.id == "imp-cancel":
                self.dismiss(None)
            elif event.button.id == "imp-ok":
                val = self.query_one("#imp-path", Input).value.strip().strip('"')
                self.dismiss(val or None)

    class ConnectModal(ModalScreen[None]):
        """Matches `#connect-modal-backdrop` (`连接与检测`) in web_gui.py."""

        BINDINGS = [Binding("escape", "close", "关闭")]

        def __init__(self, profile: dict[str, Any], cfg: dict[str, Any], tunnel_state: dict[str, Any]) -> None:
            super().__init__()
            self._p = profile
            self._cfg = cfg
            self._ts = tunnel_state
            self._show_sec = False

            live_quick = str(tunnel_state.get("live_url") or "") if profile.get("tunnel_mode") == "quick" else ""
            local_host = cfg.get("host") if (cfg.get("host") and cfg.get("host") != "0.0.0.0") else "127.0.0.1"
            self._base = (live_quick or profile.get("base_url") or f"http://{local_host}:{cfg.get('port') or 8778}").rstrip("/")
            self._active_url = live_quick or str(profile.get("base_url") or "")
            tr = str(profile.get("transport") or "dual")
            self._tr = tr
            self._http_url = f"{self._base}/mcp" if tr in ("http", "dual") else "未启用"
            self._sse_url = f"{self._base}/sse" if tr in ("sse", "dual") else "未启用"
            self._dash_url = f"{self._base}/dashboard"

        def compose(self) -> ComposeResult:
            p = self._p
            if self.app.screen.has_class("dark-mode"):
                self.add_class("dark-mode")
            with VerticalScroll(classes="modal-wide"):
                with Horizontal(classes="modal-hdr"):
                    yield Static(f"✦ 连接与检测 · {rich_escape(str(p.get('name') or ''))}", classes="modal-title")
                    yield Button("关闭", id="conn-close")

                with Vertical(classes="card"):
                    yield Static(f"[bold]{rich_escape(self._base)}[/]  [bold #D97757][{rich_escape(self._tr)}][/]")
                    with Horizontal(classes="form-row"):
                        yield Label("HTTP 端点", classes="form-lbl")
                        yield Input(value=self._http_url, disabled=True, id="cm-http")
                        yield Button("复制", id="cp-http")
                    with Horizontal(classes="form-row"):
                        yield Label("SSE 端点", classes="form-lbl")
                        yield Input(value=self._sse_url, disabled=True, id="cm-sse")
                        yield Button("复制", id="cp-sse")
                    with Horizontal(classes="form-row"):
                        yield Label("Dashboard", classes="form-lbl")
                        yield Input(value=self._dash_url, disabled=True, id="cm-dash")
                        yield Button("复制", id="cp-dash")

                auth_mode = str(p.get("auth_mode") or "oauth-local")
                if auth_mode == "oauth-local":
                    with Vertical(classes="card"):
                        yield Static("[bold]OAuth 2.1 凭据[/]")
                        with Horizontal(classes="form-row"):
                            yield Label("Client ID", classes="form-lbl")
                            yield Input(value=str(p.get("oauth_client_id") or "-"), disabled=True, id="cm-cid")
                            yield Button("复制", id="cp-cid")
                        with Horizontal(classes="form-row"):
                            yield Label("Client Secret", classes="form-lbl")
                            yield Input(value=str(p.get("oauth_client_secret") or "-"), password=True, disabled=True, id="cm-sec")
                            yield Button("👁", id="eye-sec")
                            yield Button("复制", id="cp-sec")
                elif auth_mode == "bearer":
                    with Vertical(classes="card"):
                        yield Static("[bold]Bearer Token[/]")
                        with Horizontal(classes="form-row"):
                            yield Label("API Key", classes="form-lbl")
                            yield Input(value=str(p.get("api_key") or "-"), password=True, disabled=True, id="cm-sec")
                            yield Button("👁", id="eye-sec")
                            yield Button("复制", id="cp-sec")

                with Horizontal(classes="modal-actions"):
                    yield Static("", id="health-msg", classes="dirty-hint")
                    yield Button("⚡ 测试 /health 连通性", id="btn-test-health", classes="ink")

        def action_close(self) -> None:
            self.dismiss(None)

        @work(thread=True)
        def _probe_health(self) -> None:
            self.app.call_from_thread(self.query_one("#health-msg", Static).update, "检测中...")
            port = int(self._cfg.get("port") or 8000)
            hurl = f"{self._active_url.rstrip('/')}/health" if self._active_url else f"http://127.0.0.1:{port}/health"
            try:
                req = urllib.request.Request(hurl, headers={"User-Agent": "AgentMCP-TUI/1.2", "Accept": "application/json,*/*"})
                if "://127.0.0.1" in hurl or "://localhost" in hurl:
                    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                    resp_ctx = opener.open(req, timeout=5)
                else:
                    resp_ctx = urllib.request.urlopen(req, timeout=5)
                with resp_ctx as resp:
                    _ = resp.read()
                self.app.call_from_thread(self.query_one("#health-msg", Static).update, f"[#3E5425]✓ 连通正常 ({rich_escape(hurl)})[/]")
            except Exception as exc:
                self.app.call_from_thread(self.query_one("#health-msg", Static).update, f"[#B8443A]✗ 失败: {rich_escape(str(exc))}[/]")

        def on_button_pressed(self, event: Button.Pressed) -> None:
            bid = event.button.id or ""
            if bid == "conn-close":
                self.dismiss(None)
            elif bid == "eye-sec":
                inp = self.query_one("#cm-sec", Input)
                inp.password = not inp.password
            elif bid.startswith("cp-"):
                target_map = {
                    "cp-http": self._http_url,
                    "cp-sse": self._sse_url,
                    "cp-dash": self._dash_url,
                    "cp-cid": str(self._p.get("oauth_client_id") or ""),
                    "cp-sec": str(self._p.get("oauth_client_secret") if self._p.get("auth_mode") == "oauth-local" else (self._p.get("api_key") or "")),
                }
                val = target_map.get(bid, "")
                if val:
                    _copy_to_clipboard(self.app, val)
                    self.notify("已复制到剪贴板")
            elif bid == "btn-test-health":
                self._probe_health()

    class ProfileModal(ModalScreen[dict[str, Any] | None]):
        """Exact replica of `#prof-modal-backdrop` (`添加 / 编辑传输与鉴权入口`) in web_gui.py."""

        BINDINGS = [Binding("escape", "cancel", "取消")]

        def __init__(self, profile: dict[str, Any] | None, next_index: int) -> None:
            super().__init__()
            p = dict(profile) if profile else None
            self._prev = p
            self._default_name = p["name"] if p else f"入口 #{next_index}"
            self._tr = str(p.get("transport") or "dual") if p else "dual"
            self._tun = str(p.get("tunnel_mode") or "none") if p else "none"
            raw_auth = str(p.get("auth_mode") or "oauth-local") if p else "oauth-local"
            self._auth = raw_auth if raw_auth in ("oauth-local", "bearer", "none") else "oauth-local"

        def compose(self) -> ComposeResult:
            p = self._prev
            if self.app.screen.has_class("dark-mode"):
                self.add_class("dark-mode")
            title = f"✦ 编辑入口 · {rich_escape(str(p['name']))}" if p else "✦ 添加传输与鉴权入口"
            with VerticalScroll(classes="modal-wide"):
                yield Static(title, classes="modal-title")

                with Horizontal(classes="form-row"):
                    yield Label("入口名称", classes="form-lbl")
                    yield Input(value=self._default_name, id="pf-name", placeholder="如 Gemini 主力、只读审计、本机脚本")

                with Horizontal(classes="form-row"):
                    yield Label("传输协议", classes="form-lbl")
                    yield Button("dual 双模", id="pf-tr-dual", classes="seg-btn")
                    yield Button("HTTP", id="pf-tr-http", classes="seg-btn")
                    yield Button("SSE", id="pf-tr-sse", classes="seg-btn")

                with Horizontal(classes="form-row"):
                    yield Label("接入与隧道", classes="form-lbl")
                    yield Button("手动 / 直连", id="pf-tun-none", classes="seg-btn")
                    yield Button("Token 固定隧道", id="pf-tun-token", classes="seg-btn")
                    yield Button("Quick 临时隧道", id="pf-tun-quick", classes="seg-btn")

                with Horizontal(classes="form-row", id="pf-tun-token-box"):
                    yield Label("Tunnel Token", classes="form-lbl")
                    yield Input(value=str(p.get("tunnel_token") or "") if p else "", password=True, id="pf-token-inp", placeholder="从 Cloudflare Zero Trust 复制的 eyJ... Token")
                    yield Button("👁", id="eye-pf-token")

                with Horizontal(classes="form-row", id="pf-base-row"):
                    yield Label("公开根地址", classes="form-lbl")
                    yield Input(value=str(p.get("base_url") or "") if p else "", id="pf-base", placeholder="https://xxx.example.com（留空使用本机地址）")

                yield Static(
                    "无需手动填写地址——启动隧道后会自动生成 https://xxx.trycloudflare.com，并自动热注入 OAuth 2.1 与「连接与检测」弹窗。",
                    id="pf-quick-hint",
                    classes="sub-banner",
                )

                yield Checkbox(
                    "跟随 MCP 服务自动启停该隧道",
                    value=(p.get("tunnel_auto_start", True) is not False) if p else True,
                    id="pf-tun-auto",
                )

                with Horizontal(classes="form-row"):
                    yield Label("鉴权方式", classes="form-lbl")
                    yield Button("OAuth 2.1", id="pf-auth-oauth-local", classes="seg-btn")
                    yield Button("Bearer Key", id="pf-auth-bearer", classes="seg-btn")
                    yield Button("无鉴权", id="pf-auth-none", classes="seg-btn")

                with Vertical(id="pf-oauth-box"):
                    with Horizontal(classes="form-row"):
                        yield Label("Client ID", classes="form-lbl")
                        yield Input(value=str(p.get("oauth_client_id") or "") if p else _gen_rand("mcp-client-", 10), id="pf-cid")
                        yield Button("随机", id="pf-gen-cid")
                    with Horizontal(classes="form-row"):
                        yield Label("Client Secret", classes="form-lbl")
                        yield Input(value=str(p.get("oauth_client_secret") or "") if p else _gen_rand("mcp-sec-", 24), password=True, id="pf-csec")
                        yield Button("👁", id="eye-pf-csec")
                        yield Button("随机", id="pf-gen-csec")
                    with Horizontal(classes="form-row"):
                        yield Label("回调地址", classes="form-lbl")
                        yield TextArea("\n".join(p.get("oauth_redirect_uris") or []) if p else "", id="pf-ruris")

                with Vertical(id="pf-bearer-box"):
                    with Horizontal(classes="form-row"):
                        yield Label("API Key", classes="form-lbl")
                        yield Input(value=str(p.get("api_key") or "") if p else _gen_rand("sk-mcp-", 28), password=True, id="pf-apikey")
                        yield Button("👁", id="eye-pf-apikey")
                        yield Button("随机", id="pf-gen-apikey")

                yield Checkbox(
                    "继承全局默认权限（取消勾选可为该入口单独指定权限）",
                    value=(p.get("inherit_permissions", True) is not False) if p else True,
                    id="pf-inherit",
                )

                with Vertical(id="pf-perm-box"):
                    with Horizontal(classes="form-row"):
                        yield Checkbox("仅只读模式（禁止写文件与执行命令）", value=bool(p.get("read_only")) if p else False, id="pf-ro")
                        yield Checkbox("允许读取敏感文件", value=bool(p.get("allow_secrets")) if p else False, id="pf-sec")
                    with Horizontal(classes="form-row"):
                        yield Label("目录白名单", classes="form-lbl")
                        yield TextArea("\n".join(str(r) for r in (p.get("roots") or [])) if p else "", id="pf-roots")

                with Horizontal(classes="modal-actions"):
                    yield Button("取消", id="pf-cancel")
                    yield Button("确定", id="pf-submit", classes="clay")

        def on_mount(self) -> None:
            self._sync_visibility()

        def _sync_visibility(self) -> None:
            for v in ("dual", "http", "sse"):
                self.query_one(f"#pf-tr-{v}", Button).set_class(self._tr == v, "active")
            for v in ("none", "token", "quick"):
                self.query_one(f"#pf-tun-{v}", Button).set_class(self._tun == v, "active")
            for v in ("oauth-local", "bearer", "none"):
                self.query_one(f"#pf-auth-{v}", Button).set_class(self._auth == v, "active")

            self.query_one("#pf-tun-token-box").set_class(self._tun != "token", "hidden")
            self.query_one("#pf-base-row").set_class(self._tun == "quick", "hidden")
            self.query_one("#pf-quick-hint").set_class(self._tun != "quick", "hidden")
            self.query_one("#pf-tun-auto").set_class(self._tun == "none", "hidden")

            self.query_one("#pf-oauth-box").set_class(self._auth != "oauth-local", "hidden")
            self.query_one("#pf-bearer-box").set_class(self._auth != "bearer", "hidden")

            inherit = self.query_one("#pf-inherit", Checkbox).value
            self.query_one("#pf-perm-box").set_class(inherit, "hidden")

        @on(Checkbox.Changed, "#pf-inherit")
        def _on_inherit_toggle(self) -> None:
            self._sync_visibility()

        def action_cancel(self) -> None:
            self.dismiss(None)

        def on_button_pressed(self, event: Button.Pressed) -> None:
            bid = event.button.id or ""
            if bid == "pf-cancel":
                self.dismiss(None)
            elif bid in ("pf-tr-dual", "pf-tr-http", "pf-tr-sse"):
                self._tr = bid.replace("pf-tr-", "")
                self._sync_visibility()
            elif bid in ("pf-tun-none", "pf-tun-token", "pf-tun-quick"):
                self._tun = bid.replace("pf-tun-", "")
                self._sync_visibility()
            elif bid in ("pf-auth-oauth-local", "pf-auth-bearer", "pf-auth-none"):
                self._auth = bid.replace("pf-auth-", "")
                self._sync_visibility()
            elif bid == "eye-pf-token":
                inp = self.query_one("#pf-token-inp", Input)
                inp.password = not inp.password
            elif bid == "eye-pf-csec":
                inp = self.query_one("#pf-csec", Input)
                inp.password = not inp.password
            elif bid == "eye-pf-apikey":
                inp = self.query_one("#pf-apikey", Input)
                inp.password = not inp.password
            elif bid == "pf-gen-cid":
                self.query_one("#pf-cid", Input).value = _gen_rand("mcp-client-", 10)
            elif bid == "pf-gen-csec":
                self.query_one("#pf-csec", Input).value = _gen_rand("mcp-sec-", 24)
            elif bid == "pf-gen-apikey":
                self.query_one("#pf-apikey", Input).value = _gen_rand("sk-mcp-", 28)
            elif bid == "pf-submit":
                split_list = lambda s: [x.strip() for x in s.replace(",", "\n").splitlines() if x.strip()]
                prev = self._prev
                item = {
                    "id": prev["id"] if prev else _gen_rand("prof-", 8),
                    "name": self.query_one("#pf-name", Input).value.strip() or self._default_name,
                    "enabled": prev.get("enabled", True) if prev else True,
                    "transport": self._tr,
                    "base_url": "" if self._tun == "quick" else self.query_one("#pf-base", Input).value.strip().rstrip("/"),
                    "auth_mode": self._auth,
                    "tunnel_mode": self._tun,
                    "tunnel_token": self.query_one("#pf-token-inp", Input).value.strip() or None,
                    "tunnel_auto_start": bool(self.query_one("#pf-tun-auto", Checkbox).value),
                    "oauth_client_id": self.query_one("#pf-cid", Input).value.strip() or None,
                    "oauth_client_secret": self.query_one("#pf-csec", Input).value.strip() or None,
                    "oauth_redirect_uris": split_list(self.query_one("#pf-ruris", TextArea).text),
                    "api_key": self.query_one("#pf-apikey", Input).value.strip() or None,
                    "inherit_permissions": bool(self.query_one("#pf-inherit", Checkbox).value),
                    "read_only": bool(self.query_one("#pf-ro", Checkbox).value),
                    "allow_secrets": bool(self.query_one("#pf-sec", Checkbox).value),
                    "roots": split_list(self.query_one("#pf-roots", TextArea).text),
                }
                self.dismiss(normalize_profile(item))

    class SubMcpModal(ModalScreen[dict[str, Any] | None]):
        """Exact replica of `#sub-modal-backdrop` (`表单配置` + `粘贴 JSON` + `✨ 自动获取`) in web_gui.py."""

        BINDINGS = [Binding("escape", "cancel", "取消")]

        def __init__(self, entry: dict[str, Any] | None = None, initial_mode: str = "form") -> None:
            super().__init__()
            self._item = dict(entry) if entry else None
            self._edit_name = str(entry["name"]) if entry else None
            self._mode = "form" if entry else initial_mode
            self._proto = str(entry.get("transport") or "stdio") if entry else "stdio"

        def compose(self) -> ComposeResult:
            it = self._item
            if self.app.screen.has_class("dark-mode"):
                self.add_class("dark-mode")
            title = f"✦ 编辑子 MCP · {rich_escape(self._edit_name)}" if self._edit_name else "✦ 添加子 MCP"
            with VerticalScroll(classes="modal-wide"):
                with Horizontal(classes="modal-hdr"):
                    yield Static(title, classes="modal-title")
                    with Horizontal(id="sub-mode-seg", classes="seg-wrap"):
                        yield Button("表单配置", id="sm-mode-form", classes="seg-btn")
                        yield Button("粘贴 JSON", id="sm-mode-json", classes="seg-btn")

                # Form Pane
                with Vertical(id="sub-pane-form"):
                    with Horizontal(classes="form-row"):
                        yield Label("传输协议", classes="form-lbl")
                        yield Button("stdio 本地进程", id="sm-proto-stdio", classes="seg-btn")
                        yield Button("Streamable HTTP", id="sm-proto-http", classes="seg-btn")
                        yield Button("SSE", id="sm-proto-sse", classes="seg-btn")

                    with Vertical(id="sm-stdio-fields"):
                        with Horizontal(classes="form-row"):
                            yield Label("启动命令", classes="form-lbl")
                            yield Input(value=str(it.get("command") or "") if it else "", id="sm-cmd", placeholder="如 npx、uvx、python")
                        with Horizontal(classes="form-row"):
                            yield Label("命令参数", classes="form-lbl")
                            yield TextArea("\n".join(str(a) for a in (it.get("args") or [])) if it else "", id="sm-args")
                        with Horizontal(classes="form-row"):
                            yield Label("工作目录", classes="form-lbl")
                            yield Input(value=str(it.get("cwd") or "") if it else "", id="sm-cwd", placeholder="留空使用默认目录（选填）")
                        with Horizontal(classes="form-row"):
                            yield Label("环境变量", classes="form-lbl")
                            env_txt = "\n".join(f"{k}={v}" for k, v in (it.get("env") or {}).items()) if it else ""
                            yield TextArea(env_txt, id="sm-env")

                    with Vertical(id="sm-net-fields"):
                        with Horizontal(classes="form-row"):
                            yield Label("服务地址 URL", classes="form-lbl")
                            yield Input(value=str(it.get("url") or "") if it else "", id="sm-url", placeholder="https://example.com/mcp")
                        with Horizontal(classes="form-row"):
                            yield Label("请求头 Headers", classes="form-lbl")
                            hdr_txt = "\n".join(f"{k}: {v}" for k, v in (it.get("headers") or {}).items()) if it else ""
                            yield TextArea(hdr_txt, id="sm-headers")

                    with Horizontal(classes="form-row"):
                        yield Label("子 MCP 名称", classes="form-lbl")
                        yield Input(value=str(it.get("name") or "") if it else "", id="sm-name", placeholder="可留空，点右侧自动获取")
                        yield Button("✨ 自动获取", id="btn-sm-probe")

                    with Horizontal(classes="form-row"):
                        yield Label("功能简介", classes="form-lbl")
                        yield Input(value=str(it.get("description") or "") if it else "", id="sm-desc", placeholder="自动识别或手动填写（选填）")

                    with Horizontal(classes="form-row"):
                        yield Label("超时（秒）", classes="form-lbl")
                        yield Input(value=str(it.get("timeout") or 30) if it else "30", id="sm-timeout")

                # JSON Pane
                with Vertical(id="sub-pane-json"):
                    yield Static("支持直接粘贴 Claude Desktop / Cursor / Antigravity 的 mcpServers JSON 配置", id="sm-json-hint", classes="muted")
                    yield TextArea("", id="sm-json")

                with Horizontal(classes="modal-actions"):
                    yield Button("取消", id="sm-cancel")
                    yield Button("保存", id="sm-save", classes="clay")

        def on_mount(self) -> None:
            if self._edit_name:
                self.query_one("#sub-mode-seg").add_class("hidden")
            self._sync_ui()

        def _sync_ui(self) -> None:
            self.query_one("#sm-mode-form", Button).set_class(self._mode == "form", "active")
            self.query_one("#sm-mode-json", Button).set_class(self._mode == "json", "active")
            self.query_one("#sub-pane-form").set_class(self._mode != "form", "hidden")
            self.query_one("#sub-pane-json").set_class(self._mode != "json", "hidden")
            self.query_one("#sm-save", Button).label = "导入配置" if self._mode == "json" else "保存"

            for p in ("stdio", "http", "sse"):
                self.query_one(f"#sm-proto-{p}", Button).set_class(self._proto == p, "active")
            self.query_one("#sm-stdio-fields").set_class(self._proto != "stdio", "hidden")
            self.query_one("#sm-net-fields").set_class(self._proto == "stdio", "hidden")

        @on(TextArea.Changed, "#sm-json")
        def _on_json_changed(self, event: TextArea.Changed) -> None:
            raw = event.text_area.text.strip()
            hint = self.query_one("#sm-json-hint", Static)
            if not raw:
                hint.update("支持直接粘贴 Claude Desktop / Cursor / Antigravity 的 mcpServers JSON 配置")
                return
            try:
                obj = json.loads(raw)
                root = obj["mcpServers"] if (isinstance(obj, dict) and isinstance(obj.get("mcpServers"), dict)) else obj
                cnt = len(root) if isinstance(root, list) else (1 if (isinstance(root, dict) and ("command" in root or "url" in root)) else len(root or {}))
                hint.update(f"[#3E5425]✓ JSON 格式有效，检测到 {cnt} 个子 MCP 配置[/]")
            except Exception as exc:
                hint.update(f"[#B8443A]JSON 语法错误：{rich_escape(str(exc))}[/]")

        def _collect_draft(self) -> dict[str, Any]:
            t_raw = self.query_one("#sm-timeout", Input).value.strip()
            return {
                "old_name": self._edit_name,
                "name": self.query_one("#sm-name", Input).value.strip(),
                "description": self.query_one("#sm-desc", Input).value.strip(),
                "transport": self._proto,
                "command": self.query_one("#sm-cmd", Input).value.strip(),
                "args": [x.strip() for x in self.query_one("#sm-args", TextArea).text.splitlines() if x.strip()],
                "cwd": self.query_one("#sm-cwd", Input).value.strip(),
                "env": _parse_kv_lines(self.query_one("#sm-env", TextArea).text, "="),
                "url": self.query_one("#sm-url", Input).value.strip(),
                "headers": _parse_kv_lines(self.query_one("#sm-headers", TextArea).text, ":"),
                "timeout": int(t_raw) if t_raw.isdigit() else 30,
            }

        @work(thread=True)
        def _probe_worker(self, draft: dict[str, Any]) -> None:
            btn = self.query_one("#btn-sm-probe", Button)
            self.app.call_from_thread(setattr, btn, "disabled", True)
            self.app.call_from_thread(setattr, btn, "label", "↻ 探测中")
            try:
                d = SUB_MCP_MANAGER.probe_draft(draft)
                if not d.get("ok"):
                    self.app.call_from_thread(self.notify, f"探测失败：{d.get('error') or '无法连接'}", severity="error")
                    return
                if d.get("name"):
                    self.app.call_from_thread(setattr, self.query_one("#sm-name", Input), "value", str(d["name"]))
                if d.get("description"):
                    self.app.call_from_thread(setattr, self.query_one("#sm-desc", Input), "value", str(d["description"]))
                self.app.call_from_thread(
                    self.notify,
                    f"✓ 已识别 {d.get('raw_name') or d.get('name') or 'MCP'} · {d.get('tool_count', 0)} 个工具 ({d.get('ms', 0)} ms)",
                )
            finally:
                self.app.call_from_thread(setattr, btn, "disabled", False)
                self.app.call_from_thread(setattr, btn, "label", "✨ 自动获取")

        def action_cancel(self) -> None:
            self.dismiss(None)

        def on_button_pressed(self, event: Button.Pressed) -> None:
            bid = event.button.id or ""
            if bid == "sm-cancel":
                self.dismiss(None)
            elif bid == "sm-mode-form":
                self._mode = "form"
                self._sync_ui()
            elif bid == "sm-mode-json":
                self._mode = "json"
                self._sync_ui()
            elif bid in ("sm-proto-stdio", "sm-proto-http", "sm-proto-sse"):
                self._proto = bid.replace("sm-proto-", "")
                self._sync_ui()
            elif bid == "btn-sm-probe":
                self._probe_worker(self._collect_draft())
            elif bid == "sm-save":
                if self._mode == "json":
                    raw = self.query_one("#sm-json", TextArea).text.strip()
                    if not raw:
                        self.notify("请先粘贴 JSON 配置", severity="warning")
                        return
                    self.dismiss({"mode": "json", "raw": raw})
                else:
                    draft = self._collect_draft()
                    if not draft["name"]:
                        self.notify("请填写子 MCP 名称（或点击右侧 ✨ 自动获取）", severity="warning")
                        return
                    self.dismiss({"mode": "form", "draft": draft})

    # =========================================================================
    # Reusable Card Widgets matching web_gui.py
    # =========================================================================
    class EventCardWidget(Vertical):
        """Expandable event card matching `.ev-card` in web_gui.py."""

        def __init__(self, ev: dict[str, Any], expanded: bool, on_toggle: Callable[[int], None]) -> None:
            classes = "ev-card err" if ev.get("kind") == "err" else "ev-card"
            super().__init__(classes=classes)
            self._ev = ev
            self._expanded = expanded
            self._on_toggle = on_toggle

        def compose(self) -> ComposeResult:
            ev = self._ev
            icon, tool_lbl = _tool_meta(str(ev.get("tool") or ""))
            running = ev.get("status") == "running"
            badge_txt = "● 执行中" if running else str(ev.get("badge") or "完成")
            badge_color = "#D97757" if running else ("#B8443A" if ev.get("kind") == "err" else ("#2563EB" if ev.get("kind") == "oauth" else "#3E5425"))
            summary = _human_summary(ev)
            src = f" 🌐 {rich_escape(str(ev['source']))}" if ev.get("source") else ""
            ms = f" [#6E6C66]{ev['ms']:.1f} ms[/]" if isinstance(ev.get("ms"), (int, float)) else ""
            ts = f" [#6E6C66]{rich_escape(str(ev.get('ts') or ''))}[/]"
            arrow = "▾" if self._expanded else "▸"

            with Horizontal(classes="ev-head"):
                yield Static(
                    f"[bold {badge_color}][{rich_escape(badge_txt)}][/] {icon} [bold]{rich_escape(tool_lbl)}[/]  "
                    f"{rich_escape(summary[:90])}{src}{ms}{ts}",
                    classes="ev-title",
                )
                yield Button(f"{arrow} 详情", id="ev-toggle")

            if self._expanded:
                with Vertical(classes="ev-det"):
                    args = ev.get("args")
                    if isinstance(args, dict) and args:
                        with Horizontal(classes="form-row"):
                            yield Static("[bold]输入参数[/]", classes="card-h2")
                            yield Button("复制参数", id="ev-cp-args")
                        args_txt = json.dumps(args, ensure_ascii=False, indent=2)
                        yield Static(rich_escape(args_txt[:2000]), classes="det-box")
                    res = str(ev.get("result") or "")
                    if res:
                        with Horizontal(classes="form-row"):
                            yield Static("[bold]执行结果[/]", classes="card-h2")
                            yield Button("复制结果", id="ev-cp-res")
                        yield Static(self._render_diff_or_text(res[:3000]), classes="det-box")
                    if not (isinstance(args, dict) and args) and not res:
                        raw_txt = str(ev.get("summary") or ev.get("raw") or "")
                        with Horizontal(classes="form-row"):
                            yield Static("[bold]详情[/]", classes="card-h2")
                            yield Button("复制", id="ev-cp-raw")
                        yield Static(rich_escape(raw_txt[:2000]), classes="det-box")

        @staticmethod
        def _render_diff_or_text(text: str) -> Text:
            t = Text()
            is_diff = "\n@@ " in text or "\n--- a/" in text
            if not is_diff:
                t.append(text)
                return t
            for line in text.splitlines(keepends=True):
                if line.startswith("+") and not line.startswith("+++"):
                    t.append(line, style="green")
                elif line.startswith("-") and not line.startswith("---"):
                    t.append(line, style="red")
                elif line.startswith("@@"):
                    t.append(line, style="cyan")
                else:
                    t.append(line)
            return t

        def on_button_pressed(self, event: Button.Pressed) -> None:
            event.stop()
            bid = event.button.id or ""
            if bid == "ev-toggle":
                self._on_toggle(int(self._ev["id"]))
            elif bid == "ev-cp-args":
                _copy_to_clipboard(self.app, json.dumps(self._ev.get("args") or {}, ensure_ascii=False, indent=2))
                self.notify("已复制参数")
            elif bid == "ev-cp-res":
                _copy_to_clipboard(self.app, str(self._ev.get("result") or ""))
                self.notify("已复制结果")
            elif bid == "ev-cp-raw":
                _copy_to_clipboard(self.app, str(self._ev.get("summary") or self._ev.get("raw") or ""))
                self.notify("已复制内容")

    # =========================================================================
    # Main TUI Application
    # =========================================================================
    class AgentMcpTuiApp(App[None]):
        """1:1 Claude Console TUI powered by GuiController."""

        TITLE = "Agent MCP Console"
        CSS = TUI_CSS

        BINDINGS = [
            Binding("f1", "nav('logs')", "活动与调用流", priority=True),
            Binding("f2", "nav('submcp')", "子 MCP", priority=True),
            Binding("f3", "nav('setup')", "服务配置", priority=True),
            Binding("ctrl+b", "toggle_sidebar", "收起/展开侧栏", priority=True),
        ]

        def __init__(self, config_path: Path = DEFAULT_CONFIG_PATH) -> None:
            super().__init__()
            self.config_path = config_path.resolve()
            self.ctrl = GuiController(self.config_path)

            self._raw_cursor = 0
            self._ev_seq = 0
            self._all_events: list[dict[str, Any]] = []
            self._expanded_ids: set[int] = set()
            self._active_cat = "ALL"
            self._active_sort = "newest"
            self._active_tool = "ALL"
            self._active_source = "ALL"
            self._feed_signature = ""

            self._sub_mcps: list[dict[str, Any]] = []
            self._sub_testing: set[str] = set()
            self._sub_open_tools: set[str] = set()
            self._sub_signature = ""

            self._profiles: list[dict[str, Any]] = []
            self._tunnel_info: dict[str, Any] = {"installed": True, "tunnels": {}}
            self._prof_signature = ""
            self._cf_signature = ""

            self._dirty_basic = False
            self._dirty_perm = False
            self._loading_form = False
            self._theme_mode = self._load_saved_theme()
            self._sb_collapsed = False

        @staticmethod
        def _load_saved_theme() -> str:
            try:
                if TUI_STATE_PATH.is_file():
                    d = json.loads(TUI_STATE_PATH.read_text(encoding="utf-8"))
                    if d.get("theme") in ("auto", "light", "dark"):
                        return str(d["theme"])
            except Exception:
                pass
            return "auto"

        def _save_theme_pref(self, mode: str) -> None:
            try:
                TUI_STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
                TUI_STATE_PATH.write_text(json.dumps({"theme": mode}), encoding="utf-8")
            except Exception:
                pass

        def compose(self) -> ComposeResult:
            # Top Titlebar
            with Horizontal(id="titlebar"):
                yield Static("✦ Agent MCP · Console", id="tb-name")
                yield Static("TUI · HTTP", id="tb-mode")

            # Middle Shell: Collapsible Sidebar + 3 Main Pages
            with Horizontal(id="body-shell"):
                with Vertical(id="sidebar"):
                    with Horizontal(id="sb-brand-row"):
                        yield Button("◀", id="btn-sb-collapse")
                        yield Static("● 已停止", id="sb-pill")
                    with Vertical(id="sb-nav"):
                        yield Button("≡ 活动与调用流", id="nav-logs", classes="nav-btn active")
                        yield Button("⊞ 子 MCP", id="nav-submcp", classes="nav-btn")
                        yield Button("⚙ 服务配置", id="nav-setup", classes="nav-btn")
                    with Vertical(id="sb-ctrl"):
                        yield Button("▶ 启动服务", id="btn-toggle", classes="clay ctrl-btn")
                        yield Button("↻ 重启服务", id="btn-restart", classes="ctrl-btn")
                        yield Button("⏻ 完全退出", id="btn-quit", classes="ctrl-btn")

                with ContentSwitcher(initial="tab-logs", id="main-area"):
                    # ---- Page 1: 活动与调用流 ----
                    with Vertical(id="tab-logs"):
                        with Horizontal(classes="page-head"):
                            yield Static("活动与调用流", classes="page-h1")
                            yield Button("清空", id="btn-logs-clear")
                            yield Button("导出 .log", id="btn-logs-export")
                        with Horizontal(classes="stats-row"):
                            with Vertical(classes="stat-box"):
                                yield Static("总事件数", classes="stat-k")
                                yield Static("0", id="st-total", classes="stat-v")
                            with Vertical(classes="stat-box"):
                                yield Static("工具调用", classes="stat-k")
                                yield Static("0", id="st-tools", classes="stat-v")
                            with Vertical(classes="stat-box"):
                                yield Static("错误 / 警告", classes="stat-k")
                                yield Static("0", id="st-err", classes="stat-v")
                            with Vertical(classes="stat-box"):
                                yield Static("平均耗时", classes="stat-k")
                                yield Static("-", id="st-avg", classes="stat-v")
                        with Horizontal(classes="toolbar"):
                            with Horizontal(classes="seg-wrap"):
                                yield Button("全部", id="cat-ALL", classes="seg-btn active")
                                yield Button("工具", id="cat-TOOL", classes="seg-btn")
                                yield Button("鉴权", id="cat-OAUTH", classes="seg-btn")
                                yield Button("异常", id="cat-ERR", classes="seg-btn")
                            with Horizontal(classes="seg-wrap"):
                                yield Button("最新", id="sort-newest", classes="seg-btn active")
                                yield Button("最早", id="sort-oldest", classes="seg-btn")
                                yield Button("最慢", id="sort-slowest", classes="seg-btn")
                            yield Input(id="f-q", placeholder="搜索参数、路径或关键词...")
                            yield Checkbox("框架日志", value=False, id="f-dep")
                        yield Horizontal(id="source-chips", classes="chip-bar hidden")
                        yield Horizontal(id="tool-chips", classes="chip-bar hidden")
                        yield VerticalScroll(id="feed-scroll")

                    # ---- Page 2: 子 MCP 网关 ----
                    with Vertical(id="tab-submcp"):
                        with Horizontal(classes="page-head"):
                            yield Static("子 MCP 网关", classes="page-h1")
                            yield Button("粘贴 JSON 导入", id="btn-sub-json")
                            yield Button("+ 添加子 MCP", id="btn-sub-add", classes="clay")
                        yield Static(
                            "嵌套代理仅暴露 3 个元工具，避免工具爆炸与命名冲突： "
                            "[bold #D97757]list_sub_mcps[/] · [bold #D97757]inspect_sub_mcp[/] · [bold #D97757]call_sub_mcp[/]  "
                            "｜ 修改即时生效，无需重启主服务",
                            classes="sub-banner",
                        )
                        yield VerticalScroll(id="submcp-list")

                    # ---- Page 3: 服务配置 (Exact 5 Cards) ----
                    with VerticalScroll(id="tab-setup"):
                        with Horizontal(classes="page-head"):
                            yield Static("服务配置", classes="page-h1")

                        # Card 1: 基础服务与全局密码
                        with Vertical(classes="card", id="card-basic"):
                            yield Static("基础服务与全局密码", classes="card-h2")
                            with Horizontal(classes="form-row"):
                                yield Label("MCP 服务名称", classes="form-lbl")
                                yield Input(id="c-name")
                            with Horizontal(classes="form-row"):
                                yield Label("工具名前缀 (可选)", classes="form-lbl")
                                yield Input(id="c-prefix", placeholder="留空不加前缀，如 omen_pc")
                                yield Button("用服务名", id="btn-use-name")
                            with Horizontal(classes="form-row"):
                                yield Label("监听 Host / Port", classes="form-lbl")
                                yield Input(id="c-host", placeholder="0.0.0.0")
                                yield Input(id="c-port", placeholder="8778")
                            with Horizontal(classes="form-row"):
                                yield Label("全局管理 / 授权密码", classes="form-lbl")
                                yield Input(id="c-lpwd", password=True, placeholder="用于 OAuth 本地授权与 /dashboard 登录")
                                yield Button("👁", id="eye-c-lpwd")
                                yield Button("随机生成", id="btn-gen-lpwd")
                            with Horizontal(classes="form-row"):
                                yield Label("界面主题", classes="form-lbl")
                                yield Button("跟随系统", id="theme-auto", classes="seg-btn")
                                yield Button("浅色", id="theme-light", classes="seg-btn")
                                yield Button("深色", id="theme-dark", classes="seg-btn")
                            yield Checkbox("应用启动时自动开启 MCP 服务", value=False, id="c-autostart")
                            with Horizontal(classes="card-foot"):
                                yield Static("修改监听端口或服务名后建议重启生效", id="dirty-basic", classes="dirty-hint")
                                yield Button("保存基础配置", id="btn-save-basic")
                                yield Button("保存并重启", id="btn-save-basic-restart", classes="ink")

                        # Card 2: 传输、鉴权与权限入口
                        with Vertical(classes="card", id="card-profiles"):
                            with Horizontal(classes="form-row"):
                                yield Static("传输、鉴权与权限入口", classes="card-h2")
                                yield Button("+ 添加入口", id="btn-prof-add", classes="clay")
                            yield Static(
                                "同端口支持多入口共存：不同公网域名、独立 OAuth Client / Bearer Token、Cloudflared 隧道以及独立权限策略。增删改与启停均[bold]即时保存并实时热加载生效[/]。",
                                classes="muted",
                            )
                            yield Vertical(id="profiles-list")

                        # Card 3: Cloudflared 隧道组件
                        with Vertical(classes="card", id="card-cf"):
                            with Horizontal(classes="form-row"):
                                yield Static("Cloudflared 隧道组件", classes="card-h2")
                                yield Static("检测中...", id="cf-badge")
                            yield Vertical(id="cf-body")

                        # Card 4: 全局默认权限与日志 (ONLY the exact fields in web_gui.py!)
                        with Vertical(classes="card", id="card-perm"):
                            yield Static("全局默认权限与日志", classes="card-h2")
                            with Horizontal(classes="form-row"):
                                yield Checkbox("默认只读模式 (--read-only)", value=False, id="c-ro")
                                yield Checkbox("默认允许读取敏感文件", value=False, id="c-sec")
                            with Horizontal(classes="form-row"):
                                yield Label("默认目录白名单 (留空=全盘)", classes="form-lbl")
                                yield TextArea("", id="c-roots")
                            with Horizontal(classes="form-row"):
                                yield Label("日志等级 / 保存文件", classes="form-lbl")
                                yield Select(
                                    [("DEBUG", "DEBUG"), ("INFO", "INFO"), ("WARNING", "WARNING"), ("ERROR", "ERROR")],
                                    value="INFO",
                                    id="c-loglvl",
                                    allow_blank=False,
                                )
                                yield Input(id="c-logfile", placeholder="留空仅输出到控制台，或填 logs/mcp.log")
                            with Horizontal(classes="card-foot"):
                                yield Static("保存后全局默认权限即时热加载生效", id="dirty-perm", classes="dirty-hint")
                                yield Button("保存权限与日志", id="btn-save-perm")

                        # Card 5: 存储与维护
                        with Vertical(classes="card", id="card-storage"):
                            with Horizontal(classes="form-row"):
                                yield Static("存储与维护", classes="card-h2")
                                yield Button("↻ 刷新占用", id="btn-st-refresh")
                            with Horizontal(classes="st-grid"):
                                with Vertical(classes="st-tile"):
                                    yield Static("配置目录 config/", classes="stat-k")
                                    yield Static("0 B", id="st-cfg-v", classes="stat-v")
                                    yield Static("0 个文件", id="st-cfg-s", classes="muted")
                                with Vertical(classes="st-tile"):
                                    yield Static("状态数据 data/", classes="stat-k")
                                    yield Static("0 B", id="st-data-v", classes="stat-v")
                                    yield Static("0 个文件", id="st-data-s", classes="muted")
                                with Vertical(classes="st-tile"):
                                    yield Static("缓存与字节码", classes="stat-k")
                                    yield Static("0 B", id="st-cache-v", classes="stat-v")
                                    yield Static("0 个文件", id="st-cache-s", classes="muted")
                                with Vertical(classes="st-tile"):
                                    yield Static("日志文件 logs/", classes="stat-k")
                                    yield Static("0 B", id="st-logs-v", classes="stat-v")
                                    yield Static("0 个文件", id="st-logs-s", classes="muted")
                            with Horizontal(classes="form-row"):
                                yield Button("清理缓存", id="btn-clean-cache")
                                yield Button("清理日志", id="btn-clean-logs")
                                yield Button("重置窗口位置", id="btn-clean-window")
                                yield Button("清空 OAuth 会话", id="btn-clean-oauth", classes="danger-outline")

            # Bottom Statusbar
            with Horizontal(id="statusbar"):
                yield Static("Agent MCP  |  http://127.0.0.1:8000/mcp  |  终端控制台已就绪（F1-F3 切页 · Ctrl+B 折叠侧栏）", id="ft-left")
                yield Static(f"v{VERSION}", id="ft-right")

        def on_mount(self) -> None:
            self._apply_theme(self._theme_mode, notify_user=False)
            self._sync_all_from_controller(sync_forms=True)
            self._load_sub_mcps()
            self._load_storage_stats()
            self._render_feed(force=True)

            cfg = self.ctrl.get_config()
            if cfg.get("auto_start") and not self.ctrl.is_running():
                res = self.ctrl.start(force_kill_conflict=False)
                if res.get("conflict"):
                    self.ctrl._emit_text_line(
                        f"[GUI] 检测到端口 {res.get('port')} 已有运行中的服务进程 (PID {res.get('pid')})；如需由当前 TUI 接管，请点击左侧「启动服务」。"
                    )

            self.set_interval(0.5, self._tick)

        def on_unmount(self) -> None:
            self.ctrl.stop()

        # ---- Theme & Sidebar ----
        def _apply_theme(self, mode: str, *, notify_user: bool = True) -> None:
            self._theme_mode = mode
            self._save_theme_pref(mode)
            is_dark = mode == "dark"
            if mode == "auto" and os.name == "nt":
                try:
                    import winreg

                    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize") as k:
                        val, _ = winreg.QueryValueEx(k, "AppsUseLightTheme")
                        is_dark = int(val) == 0
                except Exception:
                    is_dark = False
            self.screen.set_class(is_dark, "dark-mode")
            for m in ("auto", "light", "dark"):
                self.query_one(f"#theme-{m}", Button).set_class(mode == m, "active")
            if notify_user:
                lbl = "已切换：跟随系统主题" if mode == "auto" else ("已切换：深色模式" if mode == "dark" else "已切换：浅色模式")
                self.notify(lbl)

        def action_toggle_sidebar(self) -> None:
            self._sb_collapsed = not self._sb_collapsed
            sb = self.query_one("#sidebar")
            sb.set_class(self._sb_collapsed, "collapsed")
            self.query_one("#btn-sb-collapse", Button).label = "▶" if self._sb_collapsed else "◀"
            self.query_one("#sb-pill").set_class(self._sb_collapsed, "hidden")
            if self._sb_collapsed:
                self.query_one("#nav-logs", Button).label = "≡"
                self.query_one("#nav-submcp", Button).label = "⊞"
                self.query_one("#nav-setup", Button).label = "⚙"
                self.query_one("#btn-toggle", Button).label = "■" if self.ctrl.is_running() else "▶"
                self.query_one("#btn-restart", Button).label = "↻"
                self.query_one("#btn-quit", Button).label = "⏻"
            else:
                self._update_sidebar_labels()

        def _update_sidebar_labels(self) -> None:
            running = self.ctrl.is_running()
            pill = self.query_one("#sb-pill", Static)
            pill.set_class(running, "on")
            pill.update("● 运行中" if running else "● 已停止")

            btn_tog = self.query_one("#btn-toggle", Button)
            btn_tog.set_class(not running, "clay")
            btn_tog.set_class(running, "danger")
            if self._sb_collapsed:
                btn_tog.label = "■" if running else "▶"
                return
            self.query_one("#nav-logs", Button).label = "≡ 活动与调用流"
            en_cnt = sum(1 for s in self._sub_mcps if s.get("enabled", True))
            sub_lbl = f"⊞ 子 MCP ({en_cnt})" if self._sub_mcps else "⊞ 子 MCP"
            self.query_one("#nav-submcp", Button).label = sub_lbl
            self.query_one("#nav-setup", Button).label = "⚙ 服务配置"
            btn_tog.label = "■ 停止服务" if running else "▶ 启动服务"
            self.query_one("#btn-restart", Button).label = "↻ 重启服务"
            self.query_one("#btn-quit", Button).label = "⏻ 完全退出"

        def action_nav(self, tab: str) -> None:
            self.query_one("#main-area", ContentSwitcher).current = f"tab-{tab}"
            for t in ("logs", "submcp", "setup"):
                self.query_one(f"#nav-{t}", Button).set_class(t == tab, "active")
            if tab == "submcp":
                self._load_sub_mcps()
            elif tab == "setup":
                self._sync_all_from_controller(sync_forms=False)
                self._load_storage_stats()

        # ---- Periodic Poll & Event Ingestion ----
        def _tick(self) -> None:
            raw_list = list(self.ctrl.logs)
            if len(raw_list) < self._raw_cursor:
                self._raw_cursor = 0
            new_items = raw_list[self._raw_cursor :]
            self._raw_cursor = len(raw_list)
            if new_items:
                for item in new_items:
                    self._upsert_event(item)
                self._update_stats_and_chips()
                self._render_feed()

            self._sync_all_from_controller(sync_forms=False)

        def _upsert_event(self, raw_ev: dict[str, Any]) -> None:
            cid = str(raw_ev.get("call_id") or "")
            norm = {
                "id": 0,
                "call_id": cid,
                "status": raw_ev.get("status") or ("running" if raw_ev.get("kind") == "call" else "done"),
                "ts": raw_ev.get("ts") or "",
                "level": raw_ev.get("level") or "INFO",
                "kind": raw_ev.get("kind") or "info",
                "badge": raw_ev.get("badge") or "系统",
                "tool": raw_ev.get("tool") or "",
                "source": raw_ev.get("source") or "",
                "source_host": raw_ev.get("source_host") or "",
                "ms": raw_ev.get("ms") if isinstance(raw_ev.get("ms"), (int, float)) else None,
                "args": raw_ev.get("args") or None,
                "result": raw_ev.get("result") or "",
                "summary": raw_ev.get("summary") or raw_ev.get("raw") or "",
                "raw": raw_ev.get("raw") or json.dumps(raw_ev, ensure_ascii=False),
                "isDep": bool(raw_ev.get("isDep")),
            }
            if cid:
                for idx, ex in enumerate(self._all_events):
                    if ex["call_id"] == cid:
                        merged = {**ex, **norm, "id": ex["id"], "args": norm["args"] or ex["args"]}
                        self._all_events[idx] = merged
                        return
            self._ev_seq += 1
            norm["id"] = self._ev_seq
            self._all_events.append(norm)
            if len(self._all_events) > 1000:
                self._all_events = self._all_events[-800:]

        def _matches_filter(self, ev: dict[str, Any]) -> bool:
            show_dep = self.query_one("#f-dep", Checkbox).value
            if not show_dep and ev["isDep"]:
                return False
            if self._active_cat == "TOOL" and not (ev["kind"] in ("call", "ok") or (ev["kind"] == "err" and ev["tool"])):
                return False
            if self._active_cat == "OAUTH" and ev["kind"] != "oauth":
                return False
            if self._active_cat == "ERR" and not (ev["kind"] == "err" or ev["level"] in ("WARNING", "ERROR")):
                return False
            if self._active_tool != "ALL" and ev["tool"] != self._active_tool:
                return False
            if self._active_source != "ALL" and ev["source"] != self._active_source:
                return False
            q = self.query_one("#f-q", Input).value.strip().lower()
            if q and q not in f"{ev['tool']} {ev['source']} {ev['summary']} {ev['raw']}".lower():
                return False
            return True

        def _update_stats_and_chips(self) -> None:
            tools, errs, ms_sum, ms_cnt = 0, 0, 0.0, 0
            tool_counts: dict[str, int] = {}
            source_counts: dict[str, int] = {}
            for e in self._all_events:
                if e["tool"]:
                    tools += 1
                    tool_counts[e["tool"]] = tool_counts.get(e["tool"], 0) + 1
                if e["source"]:
                    source_counts[e["source"]] = source_counts.get(e["source"], 0) + 1
                if e["kind"] == "err" or e["level"] in ("WARNING", "ERROR"):
                    errs += 1
                if e["ms"] is not None:
                    ms_sum += float(e["ms"])
                    ms_cnt += 1

            self.query_one("#st-total", Static).update(str(len(self._all_events)))
            self.query_one("#st-tools", Static).update(str(tools))
            self.query_one("#st-err", Static).update(str(errs))
            self.query_one("#st-avg", Static).update(f"{ms_sum / ms_cnt:.0f}ms" if ms_cnt else "-")

            # Source chips
            src_bar = self.query_one("#source-chips", Horizontal)
            s_names = sorted(source_counts.keys())
            if self._active_source != "ALL" and self._active_source not in s_names:
                self._active_source = "ALL"
            src_bar.remove_children()
            if not s_names:
                src_bar.add_class("hidden")
            else:
                src_bar.remove_class("hidden")
                src_bar.mount(Button("🌐 全部来源", name="src:ALL", classes=("chip active" if self._active_source == "ALL" else "chip")))
                for n in s_names:
                    cls = "chip active" if self._active_source == n else "chip"
                    src_bar.mount(Button(f"🌐 {n} {source_counts[n]}", name=f"src:{n}", classes=cls))

            # Tool chips
            tool_bar = self.query_one("#tool-chips", Horizontal)
            t_names = sorted(tool_counts.keys())
            if self._active_tool != "ALL" and self._active_tool not in t_names:
                self._active_tool = "ALL"
            tool_bar.remove_children()
            if not t_names:
                tool_bar.add_class("hidden")
            else:
                tool_bar.remove_class("hidden")
                tool_bar.mount(Button("全部工具", name="tool:ALL", classes=("chip active" if self._active_tool == "ALL" else "chip")))
                for n in t_names:
                    ic, lbl = _tool_meta(n)
                    cls = "chip active" if self._active_tool == n else "chip"
                    tool_bar.mount(Button(f"{ic} {lbl} {tool_counts[n]}", name=f"tool:{n}", classes=cls))

        def _toggle_event_expand(self, ev_id: int) -> None:
            if ev_id in self._expanded_ids:
                self._expanded_ids.remove(ev_id)
            else:
                self._expanded_ids.add(ev_id)
            self._render_feed(force=True)

        def _render_feed(self, *, force: bool = False) -> None:
            filtered = [e for e in self._all_events if self._matches_filter(e)]
            if self._active_sort == "newest":
                filtered = list(reversed(filtered))
            elif self._active_sort == "slowest":
                filtered = sorted(filtered, key=lambda x: x["ms"] if x["ms"] is not None else -1.0, reverse=True)
            visible = filtered[:80]
            sig = json.dumps([(e["id"], e["status"], e["ms"], e["id"] in self._expanded_ids) for e in visible])
            if not force and sig == self._feed_signature:
                return
            self._feed_signature = sig

            box = self.query_one("#feed-scroll", VerticalScroll)
            box.remove_children()
            if not visible:
                box.mount(Static("暂无匹配的活动记录。点击左侧「启动服务」即可实时查看每一次 Agent 工具调用。", classes="muted"))
                return
            for ev in visible:
                box.mount(EventCardWidget(ev, ev["id"] in self._expanded_ids, self._toggle_event_expand))

        # ---- Controller & Setup Sync ----
        def _sync_all_from_controller(self, *, sync_forms: bool) -> None:
            cfg = self.ctrl.get_config()
            self._tunnel_info = TUNNEL_MANAGER.get_statuses()
            self._profiles = list(cfg.get("profiles") or [])

            srv_name = str(cfg.get("server_name") or "Agent MCP")
            tr = str(cfg.get("transport") or "dual")
            self.query_one("#tb-name", Static).update(f"✦ {rich_escape(srv_name)} · Console")
            self.query_one("#tb-mode", Static).update(f"TUI · {tr.upper()}")

            p0 = next((x for x in self._profiles if x.get("enabled")), self._profiles[0] if self._profiles else {})
            p_tr = str(p0.get("transport") or tr)
            primary = str(p0.get("base_url") or cfg.get("oauth_base_url") or f"http://{cfg.get('host') or '127.0.0.1'}:{cfg.get('port') or 8778}")
            ep_disp = f"{primary}/mcp · /sse" if p_tr == "dual" else (f"{primary}/sse" if p_tr == "sse" else f"{primary}/mcp")
            self.query_one("#ft-left", Static).update(
                f"{rich_escape(srv_name)}  ·  {rich_escape(ep_disp)}  ·  F1-F3 切页 / Ctrl+B 收起侧栏"
            )

            self._update_sidebar_labels()
            self._render_profiles_card(cfg)
            self._render_cloudflared_card()

            if sync_forms:
                self._loading_form = True
                try:
                    self.query_one("#c-name", Input).value = str(cfg.get("server_name") or "")
                    self.query_one("#c-prefix", Input).value = str(cfg.get("tool_prefix") or "")
                    self.query_one("#c-host", Input).value = str(cfg.get("host") or "0.0.0.0")
                    self.query_one("#c-port", Input).value = str(cfg.get("port") or 8778)
                    self.query_one("#c-lpwd", Input).value = str(cfg.get("oauth_local_password") or "")
                    self.query_one("#c-autostart", Checkbox).value = bool(cfg.get("auto_start"))

                    self.query_one("#c-ro", Checkbox).value = bool(cfg.get("read_only"))
                    self.query_one("#c-sec", Checkbox).value = bool(cfg.get("allow_secrets"))
                    self.query_one("#c-roots", TextArea).text = "\n".join(str(r) for r in (cfg.get("roots") or []))
                    lvl = str(cfg.get("log_level") or "INFO").upper()
                    self.query_one("#c-loglvl", Select).value = lvl if lvl in ("DEBUG", "INFO", "WARNING", "ERROR") else "INFO"
                    self.query_one("#c-logfile", Input).value = str(cfg.get("log_file") or "")
                    self._mark_dirty("basic", False)
                    self._mark_dirty("perm", False)
                finally:
                    self._loading_form = False

        def _mark_dirty(self, card: str, dirty: bool) -> None:
            if self._loading_form:
                return
            if card == "basic":
                self._dirty_basic = dirty
                h = self.query_one("#dirty-basic", Static)
                h.update("● 有未保存的基础配置修改" if dirty else "修改监听端口或服务名后建议重启生效")
                h.set_class(dirty, "dirty")
                self.query_one("#btn-save-basic", Button).set_class(dirty, "clay")
            elif card == "perm":
                self._dirty_perm = dirty
                h = self.query_one("#dirty-perm", Static)
                h.update("● 有未保存的权限与日志修改" if dirty else "保存后全局默认权限即时热加载生效")
                h.set_class(dirty, "dirty")
                self.query_one("#btn-save-perm", Button).set_class(dirty, "clay")

        # ---- Render Profile Cards (Card 2) ----
        def _render_profiles_card(self, cfg: dict[str, Any], *, force: bool = False) -> None:
            t_map = (self._tunnel_info or {}).get("tunnels") or {}
            running = self.ctrl.is_running()
            sig = json.dumps({"p": self._profiles, "t": t_map, "r": running}, ensure_ascii=False, sort_keys=True)
            if not force and sig == self._prof_signature:
                return
            self._prof_signature = sig

            box = self.query_one("#profiles-list", Vertical)
            box.remove_children()
            if not self._profiles:
                box.mount(Static("暂无接入入口，点击上方「+ 添加入口」创建一个。", classes="muted"))
                return

            auth_lbl = {"oauth-local": "OAuth 2.1", "bearer": "Bearer Key", "none": "无鉴权", "github": "GitHub", "google": "Google", "oauth-custom": "OIDC"}
            local_host = cfg.get("host") if (cfg.get("host") and cfg.get("host") != "0.0.0.0") else "127.0.0.1"
            local_fb = f"http://{local_host}:{cfg.get('port') or 8778}"

            for idx, p in enumerate(self._profiles):
                pid = str(p.get("id") or "")
                ts = t_map.get(pid) or {}
                has_tun = p.get("tunnel_mode") in ("token", "quick")
                tun_ready = (not has_tun) or (bool(ts.get("live_url")) if p.get("tunnel_mode") == "quick" else bool(ts.get("running")))
                live_quick = str(ts.get("live_url") or "") if p.get("tunnel_mode") == "quick" else ""
                if has_tun:
                    if p.get("tunnel_mode") == "quick":
                        base = live_quick or "隧道未启动（点击「☁️ 启隧道」后自动生成公网地址）"
                    else:
                        base = (p.get("base_url") or "Token 隧道已运行（请在编辑中填绑定域名）") if ts.get("running") else (f"{p['base_url']}（隧道未启动）" if p.get("base_url") else "隧道未启动（未开放该入口）")
                else:
                    base = str(p.get("base_url") or local_fb)

                tun_pill = ""
                if has_tun:
                    if ts.get("running"):
                        t_txt = ("Quick 在线" if live_quick else "Quick 分配中...") if p.get("tunnel_mode") == "quick" else ("Token 在线" if ts.get("connected") else "Token 连接中...")
                        tun_pill = f"  [#3E5425][☁️ {t_txt}][/]"
                    else:
                        tun_pill = "  [#6E6C66][☁️ 未启动 · 未开放][/]"

                if p.get("inherit_permissions", True):
                    perm_txt = "[继承全局权限]"
                else:
                    bits = ["🔒 只读" if p.get("read_only") else "✏️ 读写执行"]
                    if p.get("allow_secrets"):
                        bits.append("⚠️ 含敏感文件")
                    roots = p.get("roots") or []
                    bits.append(f"📁 限定 {len(roots)} 个目录" if roots else "🌐 全盘")
                    perm_txt = "  ".join(f"[{b}]" for b in bits)

                is_live = running and bool(p.get("enabled", True)) and tun_ready
                dot = "[#3E5425]●[/]" if is_live else ("[#B8443A]●[/]" if (has_tun and ts.get("error")) else "[#9C9A92]●[/]")

                card = Vertical(classes=("item-card" if p.get("enabled", True) else "item-card disabled"))
                box.mount(card)
                top = Horizontal(classes="item-top")
                card.mount(top)
                top.mount(
                    Static(
                        f"{dot} [bold]{rich_escape(str(p.get('name') or ''))}[/]  "
                        f"[bold #D97757][{rich_escape(str(p.get('transport') or 'dual'))}][/]  "
                        f"[{rich_escape(auth_lbl.get(str(p.get('auth_mode')), str(p.get('auth_mode'))))}]"
                        f"{tun_pill}",
                        classes="item-id",
                    )
                )
                top.mount(Button("已启用" if p.get("enabled", True) else "已停用", name=f"pf-tog:{idx}", classes=("clay" if p.get("enabled", True) else "")))
                if has_tun:
                    if ts.get("running"):
                        top.mount(Button("■ 停隧道", name=f"pf-tstop:{pid}"))
                    else:
                        top.mount(Button("☁️ 启隧道", name=f"pf-tstart:{pid}"))
                conn_btn = Button("🔗 连接与检测", name=f"pf-conn:{idx}")
                conn_btn.disabled = not tun_ready
                top.mount(conn_btn)
                top.mount(Button("编辑", name=f"pf-edit:{idx}"))
                if len(self._profiles) > 1:
                    top.mount(Button("删除", name=f"pf-del:{idx}", classes="danger-outline"))

                card.mount(Static(rich_escape(base), classes="item-ep"))
                if ts.get("error"):
                    card.mount(Static(f"[#B8443A]Cloudflared: {rich_escape(str(ts['error']))}[/]"))
                card.mount(Static(f"[#6E6C66]{rich_escape(perm_txt)}[/]"))

        # ---- Render Cloudflared Card (Card 3) ----
        def _render_cloudflared_card(self, *, force: bool = False) -> None:
            ti = self._tunnel_info or {}
            sig = json.dumps(ti, ensure_ascii=False, sort_keys=True)
            if not force and sig == self._cf_signature:
                return
            self._cf_signature = sig

            inst = ti.get("install") or {}
            t_map = ti.get("tunnels") or {}
            active_cnt = sum(1 for v in t_map.values() if isinstance(v, dict) and v.get("running"))
            dl_url = str(ti.get("download_url") or "https://github.com/cloudflare/cloudflared/releases/latest")
            asset = str(ti.get("asset") or "cloudflared")

            badge = self.query_one("#cf-badge", Static)
            body = self.query_one("#cf-body", Vertical)
            body.remove_children()

            if inst.get("active") or inst.get("paused"):
                pct = int(inst.get("percent") or 0)
                paused = bool(inst.get("paused"))
                badge.update(f"已暂停 {pct}%" if paused else f"[#D97757]下载中 {pct}%[/]")
                st_txt = str(inst.get("status") or ("已暂停下载" if paused else "正在下载 cloudflared..."))
                body.mount(Static(f"{'⏸' if paused else '↻'} {rich_escape(st_txt)}  [bold]{pct}%[/]"))
                pb = ProgressBar(total=100, show_eta=False)
                pb.progress = pct
                body.mount(pb)
                row = Horizontal(classes="form-row")
                body.mount(row)
                if paused:
                    row.mount(Button("▶ 继续下载", name="cf:resume", classes="clay"))
                else:
                    row.mount(Button("⏸ 暂停", name="cf:pause"))
                row.mount(Button("✕ 取消", name="cf:cancel", classes="danger-outline"))
                row.mount(Button("📂 选择文件导入", name="cf:import"))
            elif ti.get("installed"):
                ver = ti.get("version")
                badge.update(f"[#3E5425]✓ 已安装 v{rich_escape(str(ver))}[/]" if ver else "[#3E5425]✓ 已安装[/]")
                body.mount(Static(rich_escape(str(ti.get("binary") or "cloudflared")), classes="item-ep"))
                body.mount(Static(f"当前有 {active_cnt} 条隧道运行中" if active_cnt else "已就绪，可在上方任意入口开启 Token 或 Quick 隧道", classes="muted"))
                row = Horizontal(classes="form-row")
                body.mount(row)
                row.mount(Button("↻ 更新到最新版", name="cf:update"))
                row.mount(Button("📂 导入替换", name="cf:import"))
                if ti.get("local_managed"):
                    row.mount(Button("移除本地副本", name="cf:uninstall", classes="danger-outline"))
                if inst.get("error"):
                    body.mount(Static(f"[#B8443A]{rich_escape(str(inst['error']))}[/]"))
            else:
                badge.update("未安装")
                body.mount(Static("未检测到 cloudflared。可一键在线下载到项目 bin/ 目录，或从官方地址手动下载后选择文件导入。", classes="muted"))
                if inst.get("error"):
                    body.mount(Static(f"[#B8443A]{rich_escape(str(inst['error']))}[/]"))
                row = Horizontal(classes="form-row")
                body.mount(row)
                row.mount(Button("⬇️ 下载安装 cloudflared", name="cf:install", classes="clay"))
                row.mount(Button("📂 选择文件导入", name="cf:import"))

            foot = Horizontal(classes="form-row")
            body.mount(foot)
            foot.mount(Static(f"官方直链：[#D97757]{rich_escape(asset)}[/]", classes="dirty-hint"))
            foot.mount(Button("复制直链", name=f"cf-copy:{dl_url}"))

        # ---- Render Sub-MCP Cards (Page 2) ----
        def _load_sub_mcps(self) -> None:
            try:
                self._sub_mcps = SUB_MCP_MANAGER.list_with_status()
            except Exception:
                self._sub_mcps = []
            self._update_sidebar_labels()
            self._render_sub_mcps(force=True)

        def _render_sub_mcps(self, *, force: bool = False) -> None:
            sig = json.dumps({"s": self._sub_mcps, "t": sorted(self._sub_testing), "o": sorted(self._sub_open_tools)}, ensure_ascii=False)
            if not force and sig == self._sub_signature:
                return
            self._sub_signature = sig

            box = self.query_one("#submcp-list", VerticalScroll)
            box.remove_children()
            if not self._sub_mcps:
                empty = Vertical(classes="card")
                box.mount(empty)
                empty.mount(Static("还没有配置子 MCP", classes="card-h2"))
                empty.mount(Static("把第三方 MCP（如 GitHub、Fetch、数据库、浏览器等）挂在这里，主服务只会暴露 3 个极简元工具按需发现与调用，完全不撑爆上下文。", classes="muted"))
                row = Horizontal(classes="form-row")
                empty.mount(row)
                row.mount(Button("粘贴 mcpServers JSON", name="sub:empty-json"))
                row.mount(Button("+ 添加第一个子 MCP", name="sub:empty-form", classes="clay"))
                return

            for s in self._sub_mcps:
                name = str(s.get("name") or "")
                testing = name in self._sub_testing
                tools = s.get("tools") or []
                has_tools = isinstance(s.get("tool_count"), int)
                tools_open = name in self._sub_open_tools
                ep = " ".join([str(s.get("command") or ""), *[str(a) for a in (s.get("args") or [])]]).strip() if s.get("transport") == "stdio" else str(s.get("url") or "")

                if testing:
                    st_txt = "正在连接探测..."
                    dot = "[#D97757]●[/]"
                elif s.get("status") == "ok":
                    ms_part = f" · {s['last_ms']} ms" if s.get("last_ms") is not None else ""
                    st_txt = f"已发现 {s.get('tool_count')} 个工具{ms_part}"
                    dot = "[#3E5425]●[/]"
                elif s.get("status") == "error":
                    st_txt = "上次探测失败"
                    dot = "[#B8443A]●[/]"
                else:
                    st_txt = "未探测（大模型调用时自动按需连接）"
                    dot = "[#9C9A92]●[/]"

                card = Vertical(classes=("item-card" if s.get("enabled", True) else "item-card disabled"))
                box.mount(card)
                top = Horizontal(classes="item-top")
                card.mount(top)
                top.mount(
                    Static(
                        f"{dot} [bold]{rich_escape(name)}[/]  [bold #D97757][{rich_escape(str(s.get('transport') or 'stdio'))}][/]",
                        classes="item-id",
                    )
                )
                top.mount(Button("已启用" if s.get("enabled", True) else "已停用", name=f"sub-tog:{name}", classes=("clay" if s.get("enabled", True) else "")))
                t_btn = Button("↻ 探测中" if testing else "⚡ 测试连接", name=f"sub-test:{name}")
                t_btn.disabled = testing
                top.mount(t_btn)
                top.mount(Button("编辑", name=f"sub-edit:{name}"))
                top.mount(Button("删除", name=f"sub-del:{name}", classes="danger-outline"))

                if s.get("description"):
                    card.mount(Static(rich_escape(str(s["description"]))))
                card.mount(Static(rich_escape(ep), classes="item-ep"))
                if s.get("last_error"):
                    card.mount(Static(f"[#B8443A]{rich_escape(str(s['last_error']))}[/]"))

                foot = Horizontal(classes="form-row")
                card.mount(foot)
                foot.mount(Static(st_txt, classes="dirty-hint"))
                if has_tools and tools:
                    foot.mount(Button("收起工具列表" if tools_open else f"展开 {len(tools)} 个工具", name=f"sub-tools:{name}", classes=("chip active" if tools_open else "chip")))

                if tools_open and tools:
                    tbox = Vertical(classes="tools-box")
                    card.mount(tbox)
                    for t in tools:
                        tname = str(t.get("name") or "") if isinstance(t, dict) else str(t)
                        tdesc = str(t.get("description") or "无描述").splitlines()[0] if isinstance(t, dict) else ""
                        tbox.mount(Static(f"[bold]{rich_escape(tname)}[/]  [#6E6C66]{rich_escape(tdesc[:100])}[/]"))

        # ---- Storage Stats (Card 5) ----
        def _load_storage_stats(self) -> None:
            st = get_storage_stats()
            for key, prefix in (("config", "st-cfg"), ("data", "st-data"), ("cache", "st-cache"), ("logs", "st-logs")):
                info = st.get(key) or {}
                self.query_one(f"#{prefix}-v", Static).update(_fmt_bytes(info.get("bytes", 0)))
                self.query_one(f"#{prefix}-s", Static).update(f"{info.get('files', 0)} 个文件")

        # ---- Config Persistence (matching `api_config` in web_gui.py) ----
        def _persist_config_patch(self, patch: dict[str, Any]) -> None:
            cur = self.ctrl.get_config()
            body = dict(patch)
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
            save_config_file(self.config_path, cur)
            self._sync_all_from_controller(sync_forms=False)

        # ---- Server Start / Stop / Conflict Handling ----
        def _start_with_conflict_check(self) -> None:
            res = self.ctrl.start(force_kill_conflict=False)
            if res.get("conflict"):
                msg = f"{res.get('message')}\n\n是否结束旧实例并立即启动当前服务？"

                def _after(ok: bool) -> None:
                    if ok:
                        self.ctrl.start(force_kill_conflict=True)
                        self.notify("已结束旧实例并重新启动")
                    self._sync_all_from_controller(sync_forms=False)

                self.push_screen(ConfirmModal("端口已被占用", msg, "结束旧实例并启动", danger=True), _after)
            else:
                self._sync_all_from_controller(sync_forms=False)

        @work(thread=True)
        def _test_sub_worker(self, name: str) -> None:
            try:
                d = SUB_MCP_MANAGER.discover_tools(name, refresh=True)
                if d.get("ok"):
                    self._sub_open_tools.add(name)
                    self.call_from_thread(self.notify, f"{name} 连通成功，发现 {len(d.get('tools') or [])} 个工具")
                else:
                    self.call_from_thread(self.notify, f"{name} 连接失败：{d.get('error') or ''}", severity="error")
            finally:
                self._sub_testing.discard(name)
                self.call_from_thread(self._load_sub_mcps)

        # ---- Dirty Tracking Events ----
        @on(Input.Changed)
        def _on_any_input(self, event: Input.Changed) -> None:
            iid = event.input.id or ""
            if iid == "f-q":
                self._render_feed()
            elif iid in ("c-name", "c-prefix", "c-host", "c-port", "c-lpwd"):
                self._mark_dirty("basic", True)
            elif iid == "c-logfile":
                self._mark_dirty("perm", True)

        @on(TextArea.Changed, "#c-roots")
        def _on_roots_changed(self) -> None:
            self._mark_dirty("perm", True)

        @on(Select.Changed, "#c-loglvl")
        def _on_loglvl_changed(self) -> None:
            self._mark_dirty("perm", True)

        @on(Checkbox.Changed)
        def _on_any_chk(self, event: Checkbox.Changed) -> None:
            cid = event.checkbox.id or ""
            if cid == "f-dep":
                self._render_feed()
            elif cid == "c-autostart":
                self._mark_dirty("basic", True)
            elif cid in ("c-ro", "c-sec"):
                self._mark_dirty("perm", True)

        # ---- Unified Button Handler ----
        def on_button_pressed(self, event: Button.Pressed) -> None:
            bid = event.button.id or ""
            bname = event.button.name or ""

            # Dynamic chip / card actions (via `button.name`)
            if bname.startswith("src:"):
                self._active_source = bname[4:]
                self._update_stats_and_chips()
                self._render_feed()
                return
            if bname.startswith("tool:"):
                self._active_tool = bname[5:]
                self._update_stats_and_chips()
                self._render_feed()
                return
            if bname.startswith("pf-tog:"):
                idx = int(bname.split(":", 1)[1])
                if 0 <= idx < len(self._profiles):
                    self._profiles[idx]["enabled"] = not bool(self._profiles[idx].get("enabled", True))
                    en = self._profiles[idx]["enabled"]
                    self._persist_config_patch({"profiles": self._profiles})
                    self.notify("✓ 已启用入口并即时生效" if en else "已停用入口并即时生效")
                return
            if bname.startswith("pf-tstart:"):
                pid = bname.split(":", 1)[1]
                cfg = self.ctrl.get_config()
                prof = next((p for p in self._profiles if p.get("id") == pid), None)
                if prof:
                    d = TUNNEL_MANAGER.start_tunnel(prof, int(cfg.get("port") or 8000))
                    self.notify("☁️ 隧道已启动，正在建立连接..." if d.get("ok") else str(d.get("error") or "启动隧道失败"))
                    self._sync_all_from_controller(sync_forms=False)
                return
            if bname.startswith("pf-tstop:"):
                pid = bname.split(":", 1)[1]
                TUNNEL_MANAGER.stop_tunnel(pid)
                self.notify("已停止隧道")
                self._sync_all_from_controller(sync_forms=False)
                return
            if bname.startswith("pf-conn:"):
                idx = int(bname.split(":", 1)[1])
                if 0 <= idx < len(self._profiles):
                    p = self._profiles[idx]
                    ts = ((self._tunnel_info or {}).get("tunnels") or {}).get(p["id"]) or {}
                    self.push_screen(ConnectModal(p, self.ctrl.get_config(), ts))
                return
            if bname.startswith("pf-edit:"):
                idx = int(bname.split(":", 1)[1])
                if 0 <= idx < len(self._profiles):

                    def _saved_edit(item: dict[str, Any] | None) -> None:
                        if item:
                            self._profiles[idx] = item
                            self._persist_config_patch({"profiles": self._profiles})
                            self.notify("✓ 入口已保存并即时热加载生效")

                    self.push_screen(ProfileModal(self._profiles[idx], len(self._profiles) + 1), _saved_edit)
                return
            if bname.startswith("pf-del:"):
                idx = int(bname.split(":", 1)[1])
                if 0 <= idx < len(self._profiles):
                    pname = str(self._profiles[idx].get("name") or "")

                    def _do_del(ok: bool) -> None:
                        if ok:
                            self._profiles.pop(idx)
                            self._persist_config_patch({"profiles": self._profiles})
                            self.notify("✓ 已删除入口并即时生效")

                    self.push_screen(ConfirmModal("删除入口", f"确定删除入口「{pname}」吗？", "确认删除", danger=True), _do_del)
                return

            if bname.startswith("cf:"):
                act = bname[3:]
                if act == "install":
                    d = start_cloudflared_download(force_update=False, resume=False)
                    self.notify(str(d.get("message") or d.get("error") or "已开始下载"))
                elif act == "resume":
                    d = start_cloudflared_download(force_update=False, resume=True)
                    self.notify(str(d.get("message") or d.get("error") or "继续下载"))
                elif act == "pause":
                    d = pause_cloudflared_download()
                    self.notify(str(d.get("message") or d.get("error") or "已暂停下载"))
                elif act == "cancel":
                    d = cancel_cloudflared_download()
                    self.notify(str(d.get("message") or d.get("error") or "已取消下载"))
                elif act == "update":
                    self.push_screen(
                        ConfirmModal("更新 cloudflared", "更新期间会先停止正在运行的隧道，下载完成后可重新启动。确定继续？", "开始更新", danger=False),
                        lambda ok: (start_cloudflared_download(force_update=True, resume=False), self.notify("已开始更新")) if ok else None,
                    )
                elif act == "uninstall":

                    def _do_uninst(ok: bool) -> None:
                        if ok:
                            d = uninstall_cloudflared()
                            self.notify("✓ " + str(d.get("message")) if d.get("ok") else str(d.get("error") or "移除失败"))
                            self._sync_all_from_controller(sync_forms=False)

                    self.push_screen(ConfirmModal("移除本地 cloudflared", "将停止所有运行中的隧道并删除项目 bin/ 目录内的 cloudflared 文件，确定继续？", "确认移除", danger=True), _do_uninst)
                elif act == "import":

                    def _do_imp(fpath: str | None) -> None:
                        if not fpath:
                            return
                        p = Path(fpath).expanduser()
                        if not p.is_file():
                            self.notify(f"文件不存在：{p}", severity="error")
                            return
                        d = import_cloudflared_bytes(p.name, p.read_bytes())
                        self.notify("✓ " + str(d.get("message")) if d.get("ok") else str(d.get("error") or "导入失败"))
                        self._sync_all_from_controller(sync_forms=False)

                    self.push_screen(ImportFileModal(), _do_imp)
                self._sync_all_from_controller(sync_forms=False)
                return

            if bname.startswith("cf-copy:"):
                _copy_to_clipboard(self, bname.split(":", 1)[1])
                self.notify("已复制官方下载地址")
                return

            if bname in ("sub:empty-json", "sub:empty-form"):
                self._open_sub_modal(None, "json" if bname.endswith("json") else "form")
                return
            if bname.startswith("sub-tog:"):
                sname = bname.split(":", 1)[1]
                cur_item = next((x for x in self._sub_mcps if x.get("name") == sname), None)
                if cur_item:
                    nxt = not bool(cur_item.get("enabled", True))
                    SUB_MCP_MANAGER.toggle_entry(sname, nxt)
                    self.notify(f"已启用 {sname}" if nxt else f"已停用 {sname}")
                    self._load_sub_mcps()
                return
            if bname.startswith("sub-test:"):
                sname = bname.split(":", 1)[1]
                self._sub_testing.add(sname)
                self._render_sub_mcps(force=True)
                self._test_sub_worker(sname)
                return
            if bname.startswith("sub-edit:"):
                sname = bname.split(":", 1)[1]
                cur_item = next((x for x in self._sub_mcps if x.get("name") == sname), None)
                if cur_item:
                    self._open_sub_modal(cur_item, "form")
                return
            if bname.startswith("sub-del:"):
                sname = bname.split(":", 1)[1]

                def _del_sub(ok: bool) -> None:
                    if ok:
                        SUB_MCP_MANAGER.delete_entry(sname)
                        self._sub_open_tools.discard(sname)
                        self.notify(f"已删除 {sname}")
                        self._load_sub_mcps()

                self.push_screen(
                    ConfirmModal("删除子 MCP", f"确定移除子 MCP「{sname}」吗？\n移除后大模型将不再能通过元工具调用它。", "确认删除", danger=True),
                    _del_sub,
                )
                return
            if bname.startswith("sub-tools:"):
                sname = bname.split(":", 1)[1]
                if sname in self._sub_open_tools:
                    self._sub_open_tools.remove(sname)
                else:
                    self._sub_open_tools.add(sname)
                self._render_sub_mcps(force=True)
                return

            # Static ID buttons
            if bid == "btn-sb-collapse":
                self.action_toggle_sidebar()
            elif bid in ("nav-logs", "nav-submcp", "nav-setup"):
                self.action_nav(bid.replace("nav-", ""))
            elif bid == "btn-toggle":
                if self.ctrl.is_running():
                    self.ctrl.stop()
                    self._sync_all_from_controller(sync_forms=False)
                else:
                    self._start_with_conflict_check()
            elif bid == "btn-restart":
                self.ctrl.stop()
                self._start_with_conflict_check()
            elif bid == "btn-quit":
                self.push_screen(
                    ConfirmModal("退出 Agent MCP", "确定要停止 MCP 服务并完全退出控制台吗？", "完全退出", danger=True),
                    lambda ok: self.exit() if ok else None,
                )

            # Activity page buttons
            elif bid == "btn-logs-clear":
                self.ctrl.logs.clear()
                self._raw_cursor = 0
                self._all_events.clear()
                self._expanded_ids.clear()
                self._update_stats_and_chips()
                self._render_feed(force=True)
            elif bid == "btn-logs-export":
                LOGS_DIR.mkdir(parents=True, exist_ok=True)
                out = LOGS_DIR / "mcp_events.json"
                out.write_text(json.dumps(self._all_events, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
                self.notify(f"已导出至 logs/{out.name}")
            elif bid.startswith("cat-"):
                self._active_cat = bid[4:]
                for c in ("ALL", "TOOL", "OAUTH", "ERR"):
                    self.query_one(f"#cat-{c}", Button).set_class(c == self._active_cat, "active")
                self._render_feed()
            elif bid.startswith("sort-"):
                self._active_sort = bid[5:]
                for s in ("newest", "oldest", "slowest"):
                    self.query_one(f"#sort-{s}", Button).set_class(s == self._active_sort, "active")
                self._render_feed()

            # Sub-MCP top buttons
            elif bid == "btn-sub-add":
                self._open_sub_modal(None, "form")
            elif bid == "btn-sub-json":
                self._open_sub_modal(None, "json")

            # Card 1: Basic
            elif bid == "btn-use-name":
                raw_n = self.query_one("#c-name", Input).value.strip()
                self.query_one("#c-prefix", Input).value = sanitize_prefix(raw_n).rstrip("_")
                self._mark_dirty("basic", True)
            elif bid == "eye-c-lpwd":
                inp = self.query_one("#c-lpwd", Input)
                inp.password = not inp.password
            elif bid == "btn-gen-lpwd":
                self.query_one("#c-lpwd", Input).value = _gen_rand("", 14)
                self._mark_dirty("basic", True)
            elif bid in ("theme-auto", "theme-light", "theme-dark"):
                self._apply_theme(bid.replace("theme-", ""))
            elif bid in ("btn-save-basic", "btn-save-basic-restart"):
                port_s = self.query_one("#c-port", Input).value.strip()
                payload: dict[str, Any] = {
                    "server_name": self.query_one("#c-name", Input).value.strip(),
                    "tool_prefix": self.query_one("#c-prefix", Input).value.strip(),
                    "host": self.query_one("#c-host", Input).value.strip(),
                    "port": int(port_s) if port_s.isdigit() else 8778,
                    "auto_start": bool(self.query_one("#c-autostart", Checkbox).value),
                }
                lpwd = self.query_one("#c-lpwd", Input).value.strip()
                if lpwd:
                    payload["oauth_local_password"] = lpwd
                self._persist_config_patch(payload)
                self._mark_dirty("basic", False)
                self.notify("✓ 基础服务配置已保存")
                if bid == "btn-save-basic-restart":
                    self.ctrl.stop()
                    self._start_with_conflict_check()

            # Card 2: Add Profile
            elif bid == "btn-prof-add":

                def _added(item: dict[str, Any] | None) -> None:
                    if item:
                        self._profiles.append(item)
                        self._persist_config_patch({"profiles": self._profiles})
                        self.notify("✓ 入口已保存并即时热加载生效")

                self.push_screen(ProfileModal(None, len(self._profiles) + 1), _added)

            # Card 4: Permissions & Logging
            elif bid == "btn-save-perm":
                roots_txt = self.query_one("#c-roots", TextArea).text
                roots_list = [x.strip() for x in roots_txt.replace(",", "\n").splitlines() if x.strip()]
                payload = {
                    "read_only": bool(self.query_one("#c-ro", Checkbox).value),
                    "allow_secrets": bool(self.query_one("#c-sec", Checkbox).value),
                    "roots": roots_list,
                    "log_level": str(self.query_one("#c-loglvl", Select).value or "INFO"),
                    "log_file": self.query_one("#c-logfile", Input).value.strip() or None,
                }
                self._persist_config_patch(payload)
                self._mark_dirty("perm", False)
                self.notify("✓ 全局默认权限与日志已保存")

            # Card 5: Storage
            elif bid == "btn-st-refresh":
                self._load_storage_stats()
                self.notify("已刷新占用")
            elif bid in ("btn-clean-cache", "btn-clean-logs", "btn-clean-window", "btn-clean-oauth"):
                meta = {
                    "btn-clean-cache": ("cache", "清理缓存", "将清理临时缓存与 __pycache__，不会影响配置和已授权的 OAuth 会话。", False),
                    "btn-clean-logs": ("logs", "清理日志", "将清空当前活动流以及 logs/ 下的日志文件。", False),
                    "btn-clean-window": ("window", "重置窗口位置", "将清除窗口记忆尺寸，下次启动恢复默认居中。", False),
                    "btn-clean-oauth": ("oauth", "清空 OAuth 会话", "注意：清空后已绑定的客户端（如 Gemini）需要重新授权！确定继续？", True),
                }[bid]
                target, title, msg, danger = meta

                def _do_clean(ok: bool) -> None:
                    if not ok:
                        return
                    if target == "logs":
                        self.ctrl.logs.clear()
                        self._raw_cursor = 0
                        self._all_events.clear()
                        self._update_stats_and_chips()
                        self._render_feed(force=True)
                    d = clean_storage(target)
                    self.notify(str(d.get("message") or ("已完成" if d.get("ok") else d.get("error"))))
                    self._load_storage_stats()

                self.push_screen(ConfirmModal(title, msg, "确认执行", danger=danger), _do_clean)

        def _open_sub_modal(self, entry: dict[str, Any] | None, mode: str) -> None:
            def _done(res: dict[str, Any] | None) -> None:
                if not res:
                    return
                try:
                    if res["mode"] == "json":
                        imported = SUB_MCP_MANAGER.import_json(res["raw"])
                        self.notify(f"已导入 {len(imported)} 个子 MCP")
                    else:
                        draft = res["draft"]
                        old_n = draft.pop("old_name", None)
                        saved = SUB_MCP_MANAGER.upsert_entry(draft, old_name=old_n)
                        self.notify(f"已保存子 MCP · {saved['name']}")
                    self._load_sub_mcps()
                except Exception as exc:
                    self.notify(str(exc), severity="error")

            self.push_screen(SubMcpModal(entry, initial_mode=mode), _done)


def run_tui(config_path: Path = DEFAULT_CONFIG_PATH) -> None:
    if not HAS_TEXTUAL:
        print(
            "未安装 textual，安装后即可使用全屏 TUI：\n"
            '  pip install -e ".[tui]"   # 或: pip install textual',
            file=sys.stderr,
        )
        sys.exit(1)
    app = AgentMcpTuiApp(config_path=config_path)
    app.run()
