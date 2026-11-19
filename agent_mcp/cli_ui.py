"""Lightweight Rich-based terminal UI components for Agent MCP CLI."""

from __future__ import annotations

import shutil
import socket
import sys
from typing import Any

from . import VERSION
from .config import ServerConfig, sanitize_prefix

ACCENT = "#D97757"  # Claude-inspired warm terracotta
SUCCESS = "#22C55E"
WARNING = "#F59E0B"
DANGER = "#EF4444"
MUTED = "#9CA3AF"

try:
    from rich import box
    from rich.console import Console
    from rich.panel import Panel
    from rich.table import Table
    from rich.text import Text

    HAS_RICH = True
except Exception:  # pragma: no cover - fallback when rich is unavailable
    HAS_RICH = False


def get_console(*, no_color: bool = False, stderr: bool = False) -> Any:
    if not HAS_RICH:
        return None
    return Console(no_color=no_color, stderr=stderr, highlight=False)


def _badge(label: str, color: str) -> str:
    return f"[bold {color}]{label}[/]"


def print_banner(title: str, subtitle: str = "", *, no_color: bool = False) -> None:
    console = get_console(no_color=no_color)
    if console is None:
        print(f"=== {title} ===")
        if subtitle:
            print(subtitle)
        return
    body = Text()
    body.append(title, style=f"bold {ACCENT}")
    if subtitle:
        body.append(f"\n{subtitle}", style=MUTED)
    console.print(Panel(body, box=box.ROUNDED, border_style=ACCENT, padding=(0, 2)))


def print_startup_card(
    config: ServerConfig,
    *,
    sub_enabled: int = 0,
    sub_total: int = 0,
    no_color: bool = False,
) -> None:
    """Render a compact Claude-style Rich startup card for `agent-mcp run`."""
    if config.transport == "stdio":
        # Never write decorative output to stdout in stdio MCP mode.
        return
    console = get_console(no_color=no_color)
    if console is None:
        return

    scheme = "http"
    display_host = "127.0.0.1" if config.host in ("0.0.0.0", "::", "") else config.host
    local_base = f"{scheme}://{display_host}:{config.port}"

    grid = Table.grid(padding=(0, 2))
    grid.add_column(style=f"bold {MUTED}", justify="right", no_wrap=True)
    grid.add_column(overflow="fold")

    grid.add_row("Server", f"[bold white]{config.server_name}[/]  [dim]v{VERSION} · {socket.gethostname()}[/]")
    if config.transport == "dual":
        grid.add_row("Endpoints", f"[cyan]{local_base}/mcp[/]  [dim]|[/]  [cyan]{local_base}/sse[/]")
    elif config.transport == "http":
        grid.add_row("Endpoint", f"[cyan]{local_base}/mcp[/]")
    else:
        grid.add_row("Endpoint", f"[cyan]{local_base}/sse[/]")
    grid.add_row("Dashboard", f"[cyan]{local_base}/dashboard[/]")

    if config.oauth_base_url:
        grid.add_row("Public URL", f"[underline cyan]{config.oauth_base_url}[/]")

    auth_color = SUCCESS if config.auth_mode != "none" else WARNING
    auth_label = _badge(config.auth_mode.upper(), auth_color)
    if config.auth_mode == "bearer":
        auth_label += "  [dim](API key configured)[/]" if config.api_key else f"  [{DANGER}](missing key)[/]"
    grid.add_row("Auth", auth_label)

    perm_bits = [
        _badge("READ-ONLY", WARNING) if config.read_only else _badge("READ-WRITE", ACCENT),
        _badge("UNRESTRICTED", WARNING) if config.unrestricted else _badge(f"{len(config.roots)} ROOTS", SUCCESS),
        _badge("SECRETS-OPEN", DANGER) if config.allow_secrets else _badge("SECRETS-GUARDED", SUCCESS),
    ]
    grid.add_row("Policy", "  ".join(perm_bits))

    rg_badge = _badge("rg", SUCCESS) if shutil.which("rg") else _badge("py-fallback", MUTED)
    sub_text = f"{sub_enabled}/{sub_total} enabled" if sub_total else "0 configured"
    prof_count = len(config.profiles) if config.profiles else 1
    grid.add_row(
        "Runtime",
        f"Profiles: [bold]{prof_count}[/]  [dim]|[/]  Sub-MCP: [bold]{sub_text}[/]  [dim]|[/]  Search: {rg_badge}",
    )

    panel = Panel(
        grid,
        title=f"[bold {ACCENT}]● Agent MCP[/] [dim]({config.transport.upper()})[/]",
        subtitle="[dim]Ctrl+C to stop · agent-mcp config / profile / sub / tunnel[/]",
        box=box.ROUNDED,
        border_style=ACCENT,
        padding=(1, 2),
    )
    console.print(panel)


def print_config_panel(config: ServerConfig, *, no_color: bool = False) -> None:
    console = get_console(no_color=no_color)
    if console is None:
        print(f"Server: {config.server_name} ({config.transport} {config.host}:{config.port})")
        return

    tbl = Table(box=box.SIMPLE_HEAVY, show_header=False, pad_edge=False)
    tbl.add_column("Key", style=f"bold {MUTED}", width=22)
    tbl.add_column("Value", overflow="fold")

    tbl.add_row("Server Name", f"[bold]{config.server_name}[/]  [dim](v{VERSION})[/]")
    tbl.add_row("Tool Prefix", sanitize_prefix(config.tool_prefix) or "[dim](none)[/]")
    tbl.add_row("Config File", f"[dim]{config.config_file}[/]")
    tbl.add_row("Transport", f"[bold cyan]{config.transport}[/]  ({config.host}:{config.port})")
    tbl.add_row("Auth Mode", _badge(config.auth_mode, SUCCESS if config.auth_mode != "none" else WARNING))
    tbl.add_row("API Key", _badge("configured", SUCCESS) if config.api_key else "[dim]not set[/]")
    tbl.add_row("OAuth Base URL", config.oauth_base_url or "[dim]-[/]")
    tbl.add_row("Access Scope", "unrestricted" if config.unrestricted else ", ".join(str(r) for r in config.roots))
    tbl.add_row("Read-Only", _badge("YES", WARNING) if config.read_only else "no")
    tbl.add_row("Allow Secrets", _badge("YES", DANGER) if config.allow_secrets else _badge("NO (protected)", SUCCESS))
    tbl.add_row("Timeout / Log", f"{config.default_timeout}s  |  {config.log_level} ({config.log_file or 'stdout'})")

    console.print(
        Panel(
            tbl,
            title=f"[bold {ACCENT}]Agent MCP Effective Configuration[/]",
            subtitle="[dim]Pass --json for machine-readable output[/]",
            box=box.ROUNDED,
            border_style=ACCENT,
            padding=(0, 2),
        )
    )
    if config.profiles:
        print_profiles_table(config.profiles, no_color=no_color)


def print_profiles_table(profiles: list[dict[str, Any]], *, no_color: bool = False) -> None:
    console = get_console(no_color=no_color)
    if console is None:
        for p in profiles:
            print(f"- {p.get('id')}: {p.get('name')} enabled={p.get('enabled', True)}")
        return

    table = Table(
        title=f"[bold {ACCENT}]Profiles ({len(profiles)})[/]",
        box=box.ROUNDED,
        border_style=MUTED,
        header_style=f"bold {ACCENT}",
    )
    table.add_column("ID", style="cyan", no_wrap=True)
    table.add_column("Name", style="bold")
    table.add_column("Status", no_wrap=True)
    table.add_column("Policy", no_wrap=True)
    table.add_column("Roots")
    table.add_column("Tunnel", no_wrap=True)

    for p in profiles:
        enabled = bool(p.get("enabled", True))
        status = _badge("ENABLED", SUCCESS) if enabled else _badge("DISABLED", MUTED)
        ro = "RO" if p.get("read_only") else "RW"
        sec = "+SEC" if p.get("allow_secrets") else ""
        roots = p.get("roots") or []
        roots_str = "unrestricted" if not roots else f"{len(roots)} dir(s)"
        tmode = str(p.get("tunnel_mode") or "off")
        table.add_row(
            str(p.get("id") or "-"),
            str(p.get("name") or "-"),
            status,
            f"{ro}{sec}",
            roots_str,
            tmode,
        )
    console.print(table)


def print_sub_mcps_table(entries: list[dict[str, Any]], *, no_color: bool = False) -> None:
    console = get_console(no_color=no_color)
    if console is None:
        for e in entries:
            print(f"- {e.get('name')} ({e.get('transport')}) enabled={e.get('enabled')}")
        return

    table = Table(
        title=f"[bold {ACCENT}]Nested Sub-MCP Servers ({len(entries)})[/]",
        box=box.ROUNDED,
        border_style=MUTED,
        header_style=f"bold {ACCENT}",
    )
    table.add_column("Name", style="bold cyan", no_wrap=True)
    table.add_column("Status", no_wrap=True)
    table.add_column("Transport", no_wrap=True)
    table.add_column("Target", overflow="fold")
    table.add_column("Tools", justify="right", no_wrap=True)

    if not entries:
        console.print(Panel("[dim]No Sub-MCP servers configured yet. Add one in GUI or config/mcp_sub_servers.json.[/]", box=box.ROUNDED, border_style=MUTED))
        return

    for e in entries:
        enabled = bool(e.get("enabled", True))
        status = _badge("ON", SUCCESS) if enabled else _badge("OFF", MUTED)
        transport = str(e.get("transport") or "stdio")
        target = str(e.get("url") or " ".join([str(e.get("command") or ""), *[str(a) for a in (e.get("args") or [])]]).strip() or "-")
        tools = e.get("tool_count")
        tools_str = str(tools) if tools is not None else "-"
        table.add_row(str(e.get("name") or "-"), status, transport, target, tools_str)
    console.print(table)


def print_tunnels_table(
    profiles: list[dict[str, Any]],
    statuses: dict[str, Any],
    *,
    no_color: bool = False,
) -> None:
    console = get_console(no_color=no_color)
    if console is None:
        print(statuses)
        return

    table = Table(
        title=f"[bold {ACCENT}]Cloudflare Tunnels[/]",
        box=box.ROUNDED,
        border_style=MUTED,
        header_style=f"bold {ACCENT}",
    )
    table.add_column("Profile ID", style="cyan", no_wrap=True)
    table.add_column("Name", style="bold")
    table.add_column("Mode", no_wrap=True)
    table.add_column("State", no_wrap=True)
    table.add_column("Public URL", overflow="fold")

    items = statuses.get("tunnels") if isinstance(statuses, dict) and isinstance(statuses.get("tunnels"), dict) else statuses
    for p in profiles:
        pid = str(p.get("id") or "")
        st = items.get(pid, {}) if isinstance(items, dict) else {}
        running = bool(st.get("running"))
        state = _badge("RUNNING", SUCCESS) if running else _badge("STOPPED", MUTED)
        url = str(st.get("public_url") or st.get("url") or p.get("tunnel_hostname") or "-")
        table.add_row(pid, str(p.get("name") or "-"), str(p.get("tunnel_mode") or "off"), state, url)
    console.print(table)


def print_message(text: str, *, kind: str = "info", no_color: bool = False) -> None:
    console = get_console(no_color=no_color)
    colors = {"info": ACCENT, "ok": SUCCESS, "warn": WARNING, "err": DANGER}
    prefix = {"info": "●", "ok": "✓", "warn": "!", "err": "✗"}.get(kind, "●")
    if console is None:
        stream = sys.stderr if kind == "err" else sys.stdout
        print(f"{prefix} {text}", file=stream)
        return
    c = colors.get(kind, ACCENT)
    console.print(f"[bold {c}]{prefix}[/] {text}")
