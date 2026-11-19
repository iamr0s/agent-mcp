#!/usr/bin/env python3
"""Double-click silent GUI launcher for Windows (no console window)."""

import sys
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))


def _report_fatal(exc: BaseException) -> None:
    logs_dir = ROOT / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)
    log_path = logs_dir / "gui_crash.log"
    tb = traceback.format_exc()
    try:
        log_path.write_text(tb, encoding="utf-8")
    except Exception:
        pass
    try:
        import ctypes

        ctypes.windll.user32.MessageBoxW(
            0,
            f"Agent MCP 启动失败:\n{exc}\n\n详细日志已保存至: {log_path}",
            "Agent MCP 启动错误",
            0x10 | 0x40000,
        )
    except Exception:
        pass


if __name__ == "__main__":
    try:
        # Ensure sys.stdout / sys.stderr are never None under pythonw.exe
        if sys.stdout is None:
            sys.stdout = open("nul", "w", encoding="utf-8")
        if sys.stderr is None:
            sys.stderr = open("nul", "w", encoding="utf-8")
        from agent_mcp.cli import main

        if len(sys.argv) == 1:
            sys.argv.append("gui")
        main()
    except SystemExit:
        raise
    except Exception as exc:
        _report_fatal(exc)

