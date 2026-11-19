"""Structured, aligned, terminal-width-aware colored logging."""

from __future__ import annotations

import json
import logging
import os
import re
import shutil
import sys
import threading
import time
import unicodedata
from collections import deque
from pathlib import Path
from typing import Any, Callable

LOGGER = logging.getLogger("local-agent-mcp")
JSON_EVENT_PREFIX = "@@MCP_EVENT@@"
_EMIT_JSON_EVENTS = os.environ.get("MCP_JSON_EVENTS") == "1"

_EVENT_LOCK = threading.Lock()
_EVENT_HISTORY: deque[dict[str, Any]] = deque(maxlen=1500)
_EVENT_LISTENERS: set[Callable[[dict[str, Any]], None]] = set()


def get_event_history() -> list[dict[str, Any]]:
    with _EVENT_LOCK:
        return list(_EVENT_HISTORY)


def clear_event_history() -> None:
    with _EVENT_LOCK:
        _EVENT_HISTORY.clear()


def subscribe_events(cb: Callable[[dict[str, Any]], None]) -> None:
    with _EVENT_LOCK:
        _EVENT_LISTENERS.add(cb)


def unsubscribe_events(cb: Callable[[dict[str, Any]], None]) -> None:
    with _EVENT_LOCK:
        _EVENT_LISTENERS.discard(cb)


def emit_structured_event(event: dict[str, Any]) -> None:
    """Record a structured event in memory (for /dashboard SSE) and emit to stderr under desktop GUI."""
    payload = {
        "ts": time.strftime("%H:%M:%S"),
        "ts_full": time.strftime("%Y-%m-%d %H:%M:%S"),
        **event,
    }
    with _EVENT_LOCK:
        _EVENT_HISTORY.append(payload)
        listeners = list(_EVENT_LISTENERS)
    for cb in listeners:
        try:
            cb(payload)
        except Exception:
            pass
    if not _EMIT_JSON_EVENTS:
        return
    try:
        sys.stderr.write(f"{JSON_EVENT_PREFIX}{json.dumps(payload, ensure_ascii=False)}\n")
        sys.stderr.flush()
    except Exception:
        pass


def _enable_windows_ansi() -> bool:
    if os.name != "nt":
        return True
    try:
        import ctypes

        kernel32 = ctypes.windll.kernel32  # type: ignore[attr-defined]
        handle = kernel32.GetStdHandle(-12)  # STD_ERROR_HANDLE
        mode = ctypes.c_uint32()
        if kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
            kernel32.SetConsoleMode(handle, mode.value | 0x0004)
            return True
    except Exception:
        pass
    return bool(os.environ.get("WT_SESSION") or os.environ.get("TERM"))


def _char_width(ch: str) -> int:
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def _truncate_visible_ansi(text: str, max_cols: int) -> str:
    if max_cols <= 4:
        return text
    out: list[str] = []
    vis = 0
    i = 0
    n = len(text)
    limit = max_cols - 3
    truncated = False
    while i < n:
        if text[i] == "\033":
            end = text.find("m", i)
            if end != -1:
                out.append(text[i : end + 1])
                i = end + 1
                continue
        ch = text[i]
        w = _char_width(ch)
        if vis + w > limit:
            truncated = True
            break
        out.append(ch)
        vis += w
        i += 1
    if truncated:
        out.append("\033[0m...")
    return "".join(out)


class _ColorFormatter(logging.Formatter):
    RESET = "\033[0m"
    DIM = "\033[90m"
    LEVEL_COLORS = {
        logging.DEBUG: "\033[36m",
        logging.INFO: "\033[32m",
        logging.WARNING: "\033[33m",
        logging.ERROR: "\033[91m",
        logging.CRITICAL: "\033[1;91m",
    }

    def __init__(self, use_color: bool, is_dep: bool = False, fit_terminal: bool = True) -> None:
        super().__init__(datefmt="%Y-%m-%d %H:%M:%S")
        self.use_color = use_color
        self.is_dep = is_dep
        self.fit_terminal = fit_terminal

    def format(self, record: logging.LogRecord) -> str:
        ts = self.formatTime(record, self.datefmt)
        msg = record.getMessage()
        if record.exc_info:
            msg = f"{msg}\n{self.formatException(record.exc_info)}"

        raw_tag = f"dep:{record.name}" if self.is_dep else record.name
        src_col = f"[{raw_tag:<18.18}]"
        lvl_col_txt = f"[{record.levelname:<7}]"

        if not self.use_color:
            return f"{ts} {lvl_col_txt} {src_col} {msg}"

        if self.is_dep:
            dep_line = f"{self.DIM}{ts} {lvl_col_txt} {src_col} {msg}{self.RESET}"
            if self.fit_terminal and "\n" not in dep_line:
                cols = shutil.get_terminal_size((120, 24)).columns
                dep_line = _truncate_visible_ansi(dep_line, max(60, cols - 1))
            return dep_line

        lvl_col = self.LEVEL_COLORS.get(record.levelno, "")
        highlighted = msg
        highlighted = re.sub(
            r"\[(TOOL CALL)\]\s+([a-zA-Z0-9_]+)",
            lambda m: f"\033[1;36m[{m.group(1):<10}]\033[0m \033[1;33m{m.group(2)}\033[0m",
            highlighted,
        )
        highlighted = re.sub(
            r"\[(TOOL OK)\]\s+([a-zA-Z0-9_]+)",
            lambda m: f"\033[1;32m[{m.group(1):<10}]\033[0m \033[1;33m{m.group(2)}\033[0m",
            highlighted,
        )
        highlighted = re.sub(
            r"\[(TOOL ERR|TOOL CRASH)\]\s+([a-zA-Z0-9_]+)",
            lambda m: f"\033[1;91m[{m.group(1):<10}]\033[0m \033[1;33m{m.group(2)}\033[0m",
            highlighted,
        )
        highlighted = re.sub(
            r"\[(OAUTH [A-Z ]+|AUTH 401|PROC EXIT)\]",
            lambda m: f"\033[1;35m[{m.group(1):<10}]\033[0m",
            highlighted,
        )
        line = (
            f"{self.DIM}{ts}{self.RESET} "
            f"{lvl_col}{lvl_col_txt}{self.RESET} "
            f"\033[34m{src_col}{self.RESET} "
            f"{highlighted}"
        )
        if self.fit_terminal and "\n" not in line:
            cols = shutil.get_terminal_size((120, 24)).columns
            line = _truncate_visible_ansi(line, max(60, cols - 1))
        return line


def setup_logging(
    level_name: str,
    log_file: str | None,
    server_name: str,
    no_color: bool = False,
) -> logging.Logger:
    global LOGGER
    level = getattr(logging, level_name.upper(), logging.INFO)
    use_color = (not no_color) and sys.stderr.isatty() and _enable_windows_ansi()

    logger = logging.getLogger(server_name)
    logger.setLevel(level)
    logger.handlers.clear()
    logger.propagate = False

    stderr_handler = logging.StreamHandler(sys.stderr)
    stderr_handler.setFormatter(_ColorFormatter(use_color=use_color, is_dep=False, fit_terminal=use_color))
    logger.addHandler(stderr_handler)

    dep_handler = logging.StreamHandler(sys.stderr)
    dep_handler.setFormatter(_ColorFormatter(use_color=use_color, is_dep=True, fit_terminal=use_color))
    dep_level = logging.DEBUG if level <= logging.DEBUG else logging.WARNING
    for dep_name in ("fastmcp", "mcp", "uvicorn", "uvicorn.error", "uvicorn.access", "httpx"):
        dep_log = logging.getLogger(dep_name)
        dep_log.handlers.clear()
        dep_log.addHandler(dep_handler)
        dep_log.propagate = False
        dep_log.setLevel(dep_level)

    if log_file:
        lf_path = Path(os.path.expanduser(log_file)).resolve()
        lf_path.parent.mkdir(parents=True, exist_ok=True)
        fh = logging.FileHandler(lf_path, encoding="utf-8")
        fh.setFormatter(_ColorFormatter(use_color=False, is_dep=False, fit_terminal=False))
        logger.addHandler(fh)

    LOGGER = logger
    return logger


def abbrev(val: Any, max_len: int = 120) -> str:
    if isinstance(val, str):
        s = val.replace("\r", "\\r").replace("\n", "\\n")
        if len(s) > max_len:
            return repr(s[:max_len] + "...") + f" (len={len(val)})"
        return repr(s)
    if isinstance(val, list):
        if len(val) > 5:
            preview = ", ".join(abbrev(x, 40) for x in val[:3])
            return f"[{preview}, ... ({len(val)} items)]"
        return "[" + ", ".join(abbrev(x, 60) for x in val) + "]"
    if isinstance(val, dict):
        items = list(val.items())
        parts = []
        for k, v in items[:5]:
            if any(sec in str(k).lower() for sec in ("password", "secret", "token", "key")):
                parts.append(f"{k}=***")
            else:
                parts.append(f"{k}={abbrev(v, 50)}")
        if len(items) > 5:
            parts.append(f"...(+{len(items) - 5})")
        return "{" + ", ".join(parts) + "}"
    s = repr(val)
    return (s[:max_len] + "...") if len(s) > max_len else s


def format_call_args(args: tuple[Any, ...], kwargs: dict[str, Any]) -> str:
    parts = [abbrev(a) for a in args]
    for k, v in kwargs.items():
        if any(sec in k.lower() for sec in ("password", "secret", "token", "api_key")):
            parts.append(f"{k}=***")
        else:
            parts.append(f"{k}={abbrev(v)}")
    joined = ", ".join(parts)
    if len(joined) > 320:
        return joined[:320] + "... (truncated)"
    return joined
