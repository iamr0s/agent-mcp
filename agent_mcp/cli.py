"""CLI argument parsing, interactive setup wizard, and entrypoint."""

from __future__ import annotations

import argparse
import getpass
import json
import os
import secrets
import shutil
import socket
import sys
from pathlib import Path
from typing import Any

from . import VERSION
from .auth import hash_password
from .cli_ui import (
    print_banner,
    print_config_panel,
    print_message,
    print_profiles_table,
    print_startup_card,
    print_sub_mcps_table,
    print_tunnels_table,
)
from .config import (
    DEFAULT_CONFIG_PATH,
    ServerConfig,
    ensure_profiles_in_config,
    load_saved_config,
    sanitize_prefix,
    save_config_file,
)
from .logging_utils import LOGGER, setup_logging
from .server import build_server, run_server
from .sub_mcp import SUB_MCP_MANAGER
from .tunnel import TUNNEL_MANAGER


def print_setup_help() -> None:
    print(
        """
=== 交互式配置指南 (python main.py setup) ===

运行 `python main.py setup`（或 `python main.py set`）可交互式保存认证与运行配置，
配置默认保存在项目根目录的 `mcp_config.json` 中，启动服务端时会自动加载。

支持的鉴权模式说明：
  1) none         无鉴权（仅建议用于 stdio 或本机回环测试）
  2) bearer       静态 Bearer / API Key 鉴权（本机/局域网最简单）
  3) oauth-local  本地自签发 OAuth 2.1（无需第三方平台，只需设一个本地密码）
  4) github       GitHub OAuth 2.1（回调地址: <base_url>/auth/callback）
  5) google       Google OAuth 2.1（回调地址: <base_url>/auth/callback）
  6) oauth-custom 自定义 OAuth2 / OIDC Proxy

常用命令：
  python main.py gui               # 启动 Claude 风格本地 Web 控制台
  python main.py setup             # 启动交互式配置向导（首次全量，后续可按项修改）
  python main.py help set          # 查看本配置说明
  python main.py config            # 查看当前生效配置（密钥会自动脱敏）
  python main.py run               # 按已保存配置启动服务
""".strip()
    )


def _prompt(label: str, default: str = "", secret: bool = False) -> str:
    suffix = f" [{'***' if (secret and default) else default}]" if default else ""
    prompt_str = f"{label}{suffix}: "
    if secret and sys.stdin.isatty():
        val = getpass.getpass(prompt_str).strip()
    else:
        val = input(prompt_str).strip()
    return val if val else default


def _setup_identity(data: dict[str, Any]) -> None:
    default_name = str(data.get("server_name") or f"mcp-{socket.gethostname()}")
    server_name = _prompt("自定义 MCP 服务名称 (用于区分多台电脑，如 home-pc / office-pc)", default_name)
    cur_pfx = str(data.get("tool_prefix") or "")
    pfx_input = _prompt(
        "工具名前缀 (多台设备防重名，输入 y 自动用服务名，n 不加前缀，或直接输入自定义前缀)",
        cur_pfx or "n",
    )
    if pfx_input.lower() in ("n", "no", "none"):
        tool_prefix = ""
    elif pfx_input.lower() in ("y", "yes"):
        tool_prefix = server_name
    else:
        tool_prefix = pfx_input
    data["server_name"] = server_name
    data["tool_prefix"] = sanitize_prefix(tool_prefix).rstrip("_")


def _setup_network(data: dict[str, Any]) -> None:
    transport = _prompt("默认传输模式 (dual=HTTP+SSE双模 / http / sse / stdio)", str(data.get("transport", "dual"))).lower()
    if transport == "streamable-http":
        transport = "http"
    if transport not in ("stdio", "http", "sse", "dual"):
        transport = "dual"
    data["transport"] = transport

    if transport in ("http", "sse", "dual"):
        data["host"] = _prompt("监听地址 Host (本机填 127.0.0.1，局域网/反代可填 0.0.0.0)", str(data.get("host", "127.0.0.1")))
        port_raw = _prompt("监听端口 Port", str(data.get("port", 8000)))
        if port_raw.isdigit():
            data["port"] = int(port_raw)


def _setup_auth(data: dict[str, Any]) -> None:
    host = str(data.get("host", "127.0.0.1"))
    port = int(data.get("port", 8000))
    transport = str(data.get("transport", "http"))

    print("\n选择鉴权方式:")
    print("  1) none         - 无鉴权")
    print("  2) bearer       - Bearer / API Key (推荐本机/内网使用)")
    print("  3) oauth-local  - 本地自签发 OAuth 2.1 (无需第三方账号，只需设一个密码)")
    print("  4) github       - GitHub OAuth 2.1")
    print("  5) google       - Google OAuth 2.1")
    print("  6) oauth-custom - 自定义 OAuth2 / OIDC Proxy")

    mode_map = {
        "1": "none",
        "2": "bearer",
        "3": "oauth-local",
        "4": "github",
        "5": "google",
        "6": "oauth-custom",
    }
    rev_map = {v: k for k, v in mode_map.items()}
    cur_mode = str(data.get("auth_mode", "bearer"))
    choice = _prompt("请选择编号 [1-6]", rev_map.get(cur_mode, "2"))
    auth_mode = mode_map.get(choice, choice if choice in rev_map else "bearer")
    data["auth_mode"] = auth_mode

    if auth_mode == "bearer":
        cur_key = str(data.get("api_key") or "")
        gen_hint = "留空自动生成随机 Token" if not cur_key else "回车保留当前 Token"
        print(f"\n[Bearer / API Key 设置] ({gen_hint})")
        key_val = _prompt("API Key / Bearer Token", cur_key, secret=True)
        if not key_val:
            key_val = "sk-mcp-" + secrets.token_urlsafe(24)
            print(f"已生成新 Token: {key_val}")
        data["api_key"] = key_val

    elif auth_mode == "oauth-local":
        default_base = str(data.get("oauth_base_url") or f"http://{host}:{port}")
        base_url = _prompt(
            "\nOAuth 公开访问根地址 base_url (如使用 cloudflared 请填 https://xxx.trycloudflare.com)",
            default_base,
        ).rstrip("/")
        data["oauth_base_url"] = base_url
        cur_hash = str(data.get("oauth_local_password_hash") or "")
        hint = "回车保留当前密码" if cur_hash else "留空自动生成随机密码"
        pwd = _prompt(f"设置本地 OAuth 授权密码 ({hint})", "", secret=True)
        if pwd:
            data["oauth_local_password_hash"] = hash_password(pwd)
        elif cur_hash:
            data["oauth_local_password_hash"] = cur_hash
        else:
            auto_pwd = secrets.token_urlsafe(12)
            data["oauth_local_password_hash"] = hash_password(auto_pwd)
            print(f"已生成本地授权密码: {auto_pwd}")

        use_static = _prompt(
            "是否配置固定 Client ID / Secret (客户端表单需要手动填 ID 和 Key 时选 y)? (Y/n)",
            "y",
        )
        if use_static.lower() in ("y", "yes", "1", ""):
            cur_cid = str(data.get("oauth_client_id") or "")
            cid = _prompt("OAuth Client ID (留空自动生成)", cur_cid)
            if not cid:
                cid = "mcp-client-" + secrets.token_hex(6)
            cur_sec = str(data.get("oauth_client_secret") or "")
            csec = _prompt("OAuth Client Secret / Key (留空自动生成)", cur_sec, secret=True)
            if not csec:
                csec = "mcp-sec-" + secrets.token_urlsafe(24)
            cur_uris = ",".join(data.get("oauth_redirect_uris") or [])
            uris_raw = _prompt(
                "客户端回调地址 Redirect URI (例如 https://oauth-redirect.googleusercontent.com/r/..., 多个逗号分隔)",
                cur_uris,
            )
            data["oauth_client_id"] = cid
            data["oauth_client_secret"] = csec
            data["oauth_redirect_uris"] = [u.strip() for u in uris_raw.split(",") if u.strip()]
            print("\n--- 请将以下信息填入客户端 ---")
            print(f"  MCP Server URL : {base_url}/mcp" if transport == "http" else f"  MCP SSE URL    : {base_url}/sse")
            print(f"  OAuth ID       : {cid}")
            print(f"  OAuth Key      : {csec}")
            print("--------------------------------")

    elif auth_mode in ("github", "google", "oauth-custom"):
        default_base = str(data.get("oauth_base_url") or f"http://{host}:{port}")
        base_url = _prompt("\nOAuth 公开访问根地址 base_url (反代部署填 https://域名)", default_base).rstrip("/")
        print(f"\n请先在对应平台创建 OAuth 应用，并将 Callback / Redirect URI 设为:\n  {base_url}/auth/callback")
        data["oauth_base_url"] = base_url
        data["oauth_client_id"] = _prompt("OAuth Client ID", str(data.get("oauth_client_id") or ""))
        data["oauth_client_secret"] = _prompt("OAuth Client Secret", str(data.get("oauth_client_secret") or ""), secret=True)
        if auth_mode == "oauth-custom":
            data["oauth_auth_url"] = _prompt("Authorization Endpoint URL", str(data.get("oauth_auth_url") or ""))
            data["oauth_token_url"] = _prompt("Token Endpoint URL", str(data.get("oauth_token_url") or ""))
            data["oauth_jwks_url"] = _prompt("JWKS URI", str(data.get("oauth_jwks_url") or ""))


def _setup_permissions(data: dict[str, Any]) -> None:
    cur_ro = bool(data.get("read_only", False))
    ro_ans = _prompt("是否默认开启只读模式 (--read-only)? (y/N)", "y" if cur_ro else "n")
    data["read_only"] = ro_ans.lower() in ("y", "yes", "true", "1")

    cur_roots = ",".join(data.get("roots") or [])
    roots_raw = _prompt("限制访问目录白名单 (留空=允许全盘，多个路径用逗号分隔，输入 none 清空限制)", cur_roots or "none")
    data["roots"] = [] if roots_raw.lower() in ("none", "") else [r.strip() for r in roots_raw.split(",") if r.strip()]

    cur_sec = bool(data.get("allow_secrets", False))
    sec_ans = _prompt("是否允许读取 .env / 私钥等敏感文件? (y/N)", "y" if cur_sec else "n")
    data["allow_secrets"] = sec_ans.lower() in ("y", "yes", "true", "1")


def _setup_logging(data: dict[str, Any]) -> None:
    cur_lvl = str(data.get("log_level", "INFO")).upper()
    lvl = _prompt("日志等级 (DEBUG / INFO / WARNING / ERROR)", cur_lvl).upper()
    data["log_level"] = lvl if lvl in ("DEBUG", "INFO", "WARNING", "ERROR") else "INFO"

    cur_lf = str(data.get("log_file") or "")
    lf = _prompt("日志保存文件路径 (例如 mcp.log，输入 none 表示仅输出到终端)", cur_lf or "none")
    data["log_file"] = None if lf.lower() in ("none", "") else lf


def _run_full_setup(data: dict[str, Any]) -> None:
    print("直接回车可保留括号内的默认值。\n")
    _setup_identity(data)
    _setup_network(data)
    _setup_auth(data)
    _setup_permissions(data)
    _setup_logging(data)


def run_interactive_setup(config_path: Path, force_full: bool = False) -> None:
    has_existing = config_path.is_file() and not force_full
    data: dict[str, Any] = load_saved_config(config_path) if config_path.is_file() else {}
    data.setdefault("server_name", f"mcp-{socket.gethostname()}")
    data.setdefault("tool_prefix", "")
    data.setdefault("transport", "http")
    data.setdefault("host", "127.0.0.1")
    data.setdefault("port", 8000)
    data.setdefault("auth_mode", "bearer")
    data.setdefault("read_only", False)
    data.setdefault("allow_secrets", False)
    data.setdefault("roots", [])
    data.setdefault("log_level", "INFO")
    data.setdefault("log_file", None)

    print_banner("Agent MCP 配置向导", f"配置文件: {config_path}")

    if not has_existing:
        print("未检测到配置文件，开始首次初始化...\n")
        _run_full_setup(data)
        save_config_file(config_path, data)
    else:
        while True:
            roots_desc = "全盘" if not data.get("roots") else f"{len(data['roots'])} 个目录"
            pfx_desc = data.get("tool_prefix") or "无"
            print("\n检测到已有配置，请选择要修改的项（输入 0 保存退出）:")
            print(f"  [1] 服务名称与工具前缀   : {data.get('server_name')} (前缀: {pfx_desc})")
            print(f"  [2] 传输模式与监听地址   : {data.get('transport')} ({data.get('host')}:{data.get('port')})")
            print(f"  [3] 鉴权方式与 OAuth     : {data.get('auth_mode')} ({data.get('oauth_base_url') or '-'})")
            print(f"  [4] 权限控制 (只读/目录) : read_only={data.get('read_only')}, roots={roots_desc}")
            print(f"  [5] 日志设置             : level={data.get('log_level')}, file={data.get('log_file') or '无'}")
            print("  [6] 全部重新初始化")
            print("  [0] 保存并退出")

            sel = _prompt("请选择 [0-6]", "0")
            if sel == "0":
                save_config_file(config_path, data)
                break
            elif sel == "1":
                _setup_identity(data)
            elif sel == "2":
                _setup_network(data)
            elif sel == "3":
                _setup_auth(data)
            elif sel == "4":
                _setup_permissions(data)
            elif sel == "5":
                _setup_logging(data)
            elif sel == "6":
                _run_full_setup(data)
            else:
                print("无效选项，请输入 0-6。")
                continue
            save_config_file(config_path, data)
            print("已保存当前修改。")

    print(f"\n配置已保存至: {config_path}")
    print("运行以下命令启动:")
    print("  python main.py gui   # 图形控制台")
    print("  python main.py run   # 命令行服务")


def _find_profile(profiles: list[dict[str, Any]], query: str) -> dict[str, Any] | None:
    q = query.strip().lower()
    for p in profiles:
        if str(p.get("id") or "").lower() == q or str(p.get("name") or "").lower() == q:
            return p
    return None


def _handle_profile_cmd(config: ServerConfig, sub_args: list[str]) -> None:
    saved = load_saved_config(config.config_file)
    profiles = ensure_profiles_in_config(saved)
    op = sub_args[0].lower() if sub_args else "list"

    if op in ("list", "ls"):
        print_profiles_table(profiles, no_color=config.no_color)
        return

    if op in ("enable", "disable"):
        if len(sub_args) < 2:
            print_message(f"用法: agent-mcp profile {op} <profile_id_or_name>", kind="err", no_color=config.no_color)
            sys.exit(2)
        target = _find_profile(profiles, sub_args[1])
        if not target:
            print_message(f"未找到 Profile: {sub_args[1]}", kind="err", no_color=config.no_color)
            sys.exit(1)
        target["enabled"] = op == "enable"
        saved["profiles"] = profiles
        save_config_file(config.config_file, saved)
        print_message(
            f"Profile '{target.get('name')}' ({target.get('id')}) 已{'启用' if target['enabled'] else '禁用'}。",
            kind="ok",
            no_color=config.no_color,
        )
        return

    print_message("用法: agent-mcp profile [list | enable <id> | disable <id>]", kind="warn", no_color=config.no_color)


def _handle_sub_cmd(config: ServerConfig, sub_args: list[str]) -> None:
    op = sub_args[0].lower() if sub_args else "list"

    if op in ("list", "ls"):
        entries = SUB_MCP_MANAGER.list_with_status()
        print_sub_mcps_table(entries, no_color=config.no_color)
        return

    if op in ("enable", "disable"):
        if len(sub_args) < 2:
            print_message(f"用法: agent-mcp sub {op} <server_name>", kind="err", no_color=config.no_color)
            sys.exit(2)
        name = sub_args[1]
        try:
            SUB_MCP_MANAGER.toggle_entry(name, op == "enable")
            print_message(
                f"Sub-MCP '{name}' 已{'启用' if op == 'enable' else '禁用'}。",
                kind="ok",
                no_color=config.no_color,
            )
        except Exception as exc:
            print_message(f"操作失败: {exc}", kind="err", no_color=config.no_color)
            sys.exit(1)
        return

    if op == "inspect":
        if len(sub_args) < 2:
            print_message("用法: agent-mcp sub inspect <server_name>", kind="err", no_color=config.no_color)
            sys.exit(2)
        name = sub_args[1]
        try:
            info = SUB_MCP_MANAGER.discover_tools(name, refresh=True)
            print(json.dumps(info, indent=2, ensure_ascii=False))
        except Exception as exc:
            print_message(f"检视失败: {exc}", kind="err", no_color=config.no_color)
            sys.exit(1)
        return

    print_message("用法: agent-mcp sub [list | enable <name> | disable <name> | inspect <name>]", kind="warn", no_color=config.no_color)


def _handle_tunnel_cmd(config: ServerConfig, sub_args: list[str]) -> None:
    saved = load_saved_config(config.config_file)
    profiles = ensure_profiles_in_config(saved)
    op = sub_args[0].lower() if sub_args else "status"

    if op in ("status", "ls", "list"):
        print_tunnels_table(profiles, TUNNEL_MANAGER.get_statuses(), no_color=config.no_color)
        return

    if op == "stop-all":
        TUNNEL_MANAGER.stop_all()
        print_message("已停止所有本地 Cloudflare Tunnel 进程。", kind="ok", no_color=config.no_color)
        return

    if op in ("start", "stop"):
        if len(sub_args) < 2:
            target = profiles[0] if profiles else None
        else:
            target = _find_profile(profiles, sub_args[1])
        if not target:
            print_message("未找到指定的 Profile。", kind="err", no_color=config.no_color)
            sys.exit(1)
        if op == "start":
            res = TUNNEL_MANAGER.start_tunnel(target, config.port)
            print_message(f"Tunnel 启动结果 ({target.get('id')}): {res}", kind="info", no_color=config.no_color)
        else:
            res = TUNNEL_MANAGER.stop_tunnel(str(target.get("id") or ""))
            print_message(f"Tunnel 停止结果 ({target.get('id')}): {res}", kind="ok", no_color=config.no_color)
        return

    print_message("用法: agent-mcp tunnel [status | start [profile] | stop [profile] | stop-all]", kind="warn", no_color=config.no_color)


def parse_cli(argv: list[str]) -> tuple[ServerConfig, str, int, list[str], bool]:
    normalized_argv = list(argv)
    action = "run"
    sub_args: list[str] = []

    if normalized_argv:
        first = normalized_argv[0].lower()
        second = normalized_argv[1].lower() if len(normalized_argv) > 1 else ""
        if first in ("help", "-h", "--help") and second in ("set", "setup", "auth"):
            return ServerConfig(), "help-set", 8779, [], False
        if first == "help":
            normalized_argv = ["--help"]
        elif first in ("setup", "set", "auth-setup"):
            action = "setup"
            normalized_argv = normalized_argv[1:]
        elif first == "gui":
            action = "gui"
            normalized_argv = normalized_argv[1:]
        elif first == "tui":
            action = "tui"
            normalized_argv = normalized_argv[1:]
        elif first == "config":
            action = "config"
            normalized_argv = normalized_argv[1:]
        elif first in ("profile", "profiles"):
            action = "profile"
            normalized_argv = normalized_argv[1:]
        elif first in ("sub", "sub-mcp", "submcp"):
            action = "sub"
            normalized_argv = normalized_argv[1:]
        elif first in ("tunnel", "tunnels"):
            action = "tunnel"
            normalized_argv = normalized_argv[1:]
        elif first == "run":
            normalized_argv = normalized_argv[1:]

    if action in ("profile", "sub", "tunnel"):
        # Separate positional subcommand args from global flags like --config / --no-color
        kept_flags: list[str] = []
        i = 0
        while i < len(normalized_argv):
            tok = normalized_argv[i]
            if tok in ("--config", "-c") and i + 1 < len(normalized_argv):
                kept_flags.extend([tok, normalized_argv[i + 1]])
                i += 2
            elif tok in ("--no-color", "-h", "--help"):
                kept_flags.append(tok)
                i += 1
            else:
                sub_args.append(tok)
                i += 1
        normalized_argv = kept_flags

    parser = argparse.ArgumentParser(
        prog="agent-mcp",
        description="Cross-platform Local Agent MCP Server (Filesystem + Command Execution + Sub-MCP Gateway + Desktop GUI).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Subcommands & Examples:\n"
            "  agent-mcp gui                                      # Launch Claude-style Desktop Console\n"
            "  agent-mcp tui                                      # Launch Claude-style Fullscreen TUI\n"
            "  agent-mcp setup                                    # Interactive wizard for Bearer / OAuth\n"
            "  agent-mcp run                                      # Run server with Rich startup card\n"
            "  agent-mcp config [--json]                          # Show effective config panel (or JSON)\n"
            "  agent-mcp profile [list|enable|disable]            # Manage access profiles\n"
            "  agent-mcp sub [list|enable|disable|inspect]        # Manage nested Sub-MCP servers\n"
            "  agent-mcp tunnel [status|start|stop|stop-all]      # Inspect or control Cloudflare Tunnels\n"
        ),
    )
    parser.add_argument("--config", "-c", default=str(DEFAULT_CONFIG_PATH), help="Path to config JSON.")
    parser.add_argument("--name", "-n", default=None, help="Custom MCP server name.")
    parser.add_argument("--tool-prefix", default=None, help="Prefix for all tool names.")
    parser.add_argument("--transport", "-t", choices=["dual", "stdio", "http", "streamable-http", "sse"], default=None)
    parser.add_argument("--host", default=None)
    parser.add_argument("--port", "-p", type=int, default=None)
    parser.add_argument("--gui-port", type=int, default=8779, help="Local port for Web GUI console (default: 8779).")
    parser.add_argument("--auth", choices=["none", "bearer", "oauth-local", "github", "google", "oauth-custom"], default=None)
    parser.add_argument("--api-key", default=None)
    parser.add_argument("--oauth-client-id", default=None)
    parser.add_argument("--oauth-client-secret", default=None)
    parser.add_argument("--oauth-base-url", default=None)
    parser.add_argument("--root", "-r", nargs="+", default=None)
    parser.add_argument("--allow-cwd", action="store_true")
    parser.add_argument("--read-only", action="store_true", default=None)
    parser.add_argument("--allow-secrets", action="store_true", default=None)
    parser.add_argument("--stateful", action="store_true")
    parser.add_argument("--timeout", type=int, default=None)
    parser.add_argument("--log-level", choices=["DEBUG", "INFO", "WARNING", "ERROR"], default=None)
    parser.add_argument("--log-file", default=None)
    parser.add_argument("--no-color", action="store_true")
    parser.add_argument("--json", action="store_true", dest="json_output", help="Output raw JSON (for `config`).")
    parser.add_argument("--print-config", action="store_true")
    parser.add_argument("--version", "-v", action="version", version=f"%(prog)s {VERSION}")

    args = parser.parse_args(normalized_argv)
    if args.print_config:
        action = "config"

    cfg_path = Path(os.path.expanduser(args.config)).resolve()
    saved = load_saved_config(cfg_path)

    server_name = args.name or os.environ.get("MCP_NAME") or saved.get("server_name") or "local-agent-mcp"
    tool_prefix = (
        args.tool_prefix
        if args.tool_prefix is not None
        else (os.environ.get("MCP_TOOL_PREFIX") or saved.get("tool_prefix") or "")
    )
    raw_transport = args.transport or os.environ.get("MCP_TRANSPORT") or saved.get("transport") or "stdio"
    transport = "http" if raw_transport == "streamable-http" else raw_transport

    host = args.host or os.environ.get("MCP_HOST") or saved.get("host") or "127.0.0.1"
    port = int(args.port or os.environ.get("MCP_PORT") or saved.get("port") or 8000)

    api_key = args.api_key or os.environ.get("MCP_API_KEY") or saved.get("api_key")
    auth_mode = args.auth or os.environ.get("MCP_AUTH_MODE") or saved.get("auth_mode") or "none"
    if args.api_key and not args.auth:
        auth_mode = "bearer"

    raw_roots = args.root if args.root is not None else saved.get("roots", [])
    roots: list[Path] = [Path(os.path.expanduser(r)).resolve() for r in raw_roots]
    if args.allow_cwd:
        cwd = Path.cwd().resolve()
        if cwd not in roots:
            roots.append(cwd)

    read_only = args.read_only if args.read_only is not None else bool(saved.get("read_only", False))
    allow_secrets = args.allow_secrets if args.allow_secrets is not None else bool(saved.get("allow_secrets", False))
    timeout = int(args.timeout or saved.get("default_timeout") or 60)

    cfg = ServerConfig(
        server_name=server_name,
        tool_prefix=tool_prefix,
        transport=transport,
        host=host,
        port=port,
        auth_mode=auth_mode,
        api_key=api_key,
        oauth_client_id=args.oauth_client_id or os.environ.get("MCP_OAUTH_CLIENT_ID") or saved.get("oauth_client_id"),
        oauth_client_secret=args.oauth_client_secret
        or os.environ.get("MCP_OAUTH_CLIENT_SECRET")
        or saved.get("oauth_client_secret"),
        oauth_base_url=args.oauth_base_url or os.environ.get("MCP_OAUTH_BASE_URL") or saved.get("oauth_base_url"),
        oauth_base_urls=list(saved.get("oauth_base_urls") or []),
        oauth_auth_url=saved.get("oauth_auth_url"),
        oauth_token_url=saved.get("oauth_token_url"),
        oauth_jwks_url=saved.get("oauth_jwks_url"),
        oauth_local_password_hash=saved.get("oauth_local_password_hash"),
        oauth_redirect_uris=list(saved.get("oauth_redirect_uris") or []),
        profiles=ensure_profiles_in_config(saved),
        roots=roots,
        read_only=read_only,
        allow_secrets=allow_secrets,
        default_timeout=timeout,
        stateless_http=not args.stateful,
        log_level=(args.log_level or os.environ.get("MCP_LOG_LEVEL") or saved.get("log_level") or "INFO").upper(),
        log_file=args.log_file or os.environ.get("MCP_LOG_FILE") or saved.get("log_file"),
        no_color=bool(args.no_color),
        config_file=cfg_path,
    )
    return cfg, action, args.gui_port, sub_args, bool(args.json_output)


def main() -> None:
    config, action, gui_port, sub_args, json_output = parse_cli(sys.argv[1:])

    if action == "help-set":
        print_setup_help()
        return

    if action == "gui":
        from .web_gui import run_web_gui

        run_web_gui(config.config_file, gui_port=gui_port)
        return

    if action == "tui":
        from .tui import run_tui

        run_tui(config.config_file)
        return

    if action == "setup":
        run_interactive_setup(config.config_file)
        return

    if action == "profile":
        _handle_profile_cmd(config, sub_args)
        return

    if action == "sub":
        _handle_sub_cmd(config, sub_args)
        return

    if action == "tunnel":
        _handle_tunnel_cmd(config, sub_args)
        return

    if action == "config":
        if not json_output:
            print_config_panel(config, no_color=config.no_color)
            return
        payload = {
            "server_name": config.server_name,
            "tool_prefix": sanitize_prefix(config.tool_prefix),
            "hostname": socket.gethostname(),
            "version": VERSION,
            "config_file": str(config.config_file),
            "transport": config.transport,
            "host": config.host,
            "port": config.port,
            "auth_mode": config.auth_mode,
            "api_key_configured": bool(config.api_key),
            "oauth_client_id": config.oauth_client_id or None,
            "oauth_client_secret_configured": bool(config.oauth_client_secret),
            "oauth_base_url": config.oauth_base_url,
            "oauth_redirect_uris": config.oauth_redirect_uris,
            "access_mode": "unrestricted" if config.unrestricted else "scoped",
            "roots": [str(r) for r in config.roots],
            "read_only": config.read_only,
            "allow_secrets": config.allow_secrets,
            "default_timeout": config.default_timeout,
            "stateless_http": config.stateless_http,
            "log_level": config.log_level,
            "log_file": config.log_file,
        }
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return

    setup_logging(config.log_level, config.log_file, config.server_name, no_color=config.no_color)
    try:
        sub_entries = SUB_MCP_MANAGER.load_entries()
        sub_total = len(sub_entries)
        sub_enabled = sum(1 for e in sub_entries if e.get("enabled", True))
    except Exception:
        sub_total, sub_enabled = 0, 0
    print_startup_card(config, sub_enabled=sub_enabled, sub_total=sub_total, no_color=config.no_color)
    LOGGER.info(
        "Starting %s v%s | transport=%s | auth=%s | scope=%s | read_only=%s | rg=%s",
        config.server_name,
        VERSION,
        config.transport,
        config.auth_mode,
        "unrestricted" if config.unrestricted else f"{len(config.roots)} roots",
        config.read_only,
        bool(shutil.which("rg")),
    )
    mcp = build_server(config)
    run_server(mcp, config)


def main_gui() -> None:
    """Direct entrypoint for `agent-mcp-gui`."""
    if len(sys.argv) <= 1 or sys.argv[1].startswith("-"):
        sys.argv.insert(1, "gui")
    main()
