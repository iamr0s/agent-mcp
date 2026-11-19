"""FastMCP server assembly, tool audit wrapper, and HTTP/SSE/STDIO runners."""

from __future__ import annotations

import functools
import json
import socket
import sys
import time
import uuid
from pathlib import Path
from typing import Any

from . import VERSION
from .auth import build_fastmcp_auth
from .config import (
    AccessPolicy,
    ServerConfig,
    TUNNEL_STATE_PATH,
    ensure_profiles_in_config,
    get_effective_policy,
    load_saved_config,
    reset_current_policy,
    sanitize_prefix,
    set_current_policy,
)
from .file_tools import READ_ONLY_ANN, UndoStore, register_file_tools
from .logging_utils import LOGGER, emit_structured_event, format_call_args
from .process_tools import ProcessManager, register_process_tools
from .sub_mcp import register_sub_mcp_tools
from .tray import APP_ICON_DATA_URI


def build_server(config: ServerConfig) -> Any:
    script_dir = str(Path(__file__).resolve().parent.parent)
    sys.path = [entry for entry in sys.path if (entry and str(Path(entry).resolve()) != script_dir)]
    try:
        from fastmcp import FastMCP
    except ImportError as exc:
        print(
            f"Error importing fastmcp: {exc}\n"
            "Make sure 'fastmcp' is installed in this Python: pip install fastmcp",
            file=sys.stderr,
        )
        raise SystemExit(1) from exc

    auth_provider = build_fastmcp_auth(config)
    mode_desc = "READ-ONLY" if config.read_only else "READ-WRITE + EXEC"
    scope_desc = "UNRESTRICTED" if config.unrestricted else f"SCOPED ({len(config.roots)} roots)"
    host_name = socket.gethostname()

    mcp_icons = None
    try:
        from mcp import types as mcp_types

        mcp_icons = [mcp_types.Icon(src=APP_ICON_DATA_URI, mimeType="image/svg+xml")]
    except Exception:
        mcp_icons = None

    mcp = FastMCP(
        name=config.server_name,
        version=VERSION,
        icons=mcp_icons,
        auth=auth_provider,
        instructions=(
            f"MCP server '{config.server_name}' on host '{host_name}' ({mode_desc}, {scope_desc}). "
            "Prefer stat_file before reading large files, use edit_file or apply_patch for "
            "surgical changes instead of rewriting whole files, use start_process + "
            "manage_process for long-running builds or servers, and use list_sub_mcps / "
            "inspect_sub_mcp / call_sub_mcp to discover and invoke nested Sub-MCP servers."
        ),
    )
    mcp._agent_auth_provider = auth_provider  # expose for ProfileRouterMiddleware token->client_id lookup

    prefix = sanitize_prefix(config.tool_prefix)

    def tool(annotations: dict[str, Any]):
        def _decorator(fn: Any) -> Any:
            tname = f"{prefix}{fn.__name__}" if prefix else fn.__name__

            is_write_or_exec = not bool(annotations.get("readOnlyHint", False))

            @functools.wraps(fn)
            def _wrapped(*args: Any, **kwargs: Any) -> Any:
                call_id = uuid.uuid4().hex[:10]
                policy = get_effective_policy(config)
                arg_summary = format_call_args(args, kwargs)
                LOGGER.info("[TOOL CALL] [%s] %s(%s)", policy.profile_name, tname, arg_summary)
                safe_kwargs = {
                    k: ("***" if any(s in k.lower() for s in ("password", "secret", "token", "api_key")) else v)
                    for k, v in kwargs.items()
                }
                emit_structured_event(
                    {
                        "call_id": call_id,
                        "status": "running",
                        "kind": "call",
                        "badge": "执行中",
                        "level": "INFO",
                        "tool": tname,
                        "source": policy.profile_name,
                        "source_host": policy.host,
                        "args": safe_kwargs,
                        "summary": arg_summary or "(无参数)",
                    }
                )
                if is_write_or_exec and policy.read_only:
                    deny_msg = f"Error: Read-only mode is enabled for profile '{policy.profile_name}'."
                    LOGGER.warning("[TOOL ERR] [%s] %s -> %s", policy.profile_name, tname, deny_msg)
                    emit_structured_event(
                        {
                            "call_id": call_id,
                            "status": "error",
                            "kind": "err",
                            "badge": "拒绝",
                            "level": "WARNING",
                            "tool": tname,
                            "source": policy.profile_name,
                            "source_host": policy.host,
                            "ms": 0.0,
                            "args": safe_kwargs,
                            "result": deny_msg,
                            "summary": deny_msg,
                        }
                    )
                    return deny_msg
                t0 = time.perf_counter()
                try:
                    result = fn(*args, **kwargs)
                except Exception as exc:
                    elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)
                    LOGGER.exception("[TOOL CRASH] [%s] %s (%.1fms): %s", policy.profile_name, tname, elapsed_ms, exc)
                    emit_structured_event(
                        {
                            "call_id": call_id,
                            "status": "error",
                            "kind": "err",
                            "badge": "异常",
                            "level": "ERROR",
                            "tool": tname,
                            "source": policy.profile_name,
                            "source_host": policy.host,
                            "ms": elapsed_ms,
                            "args": safe_kwargs,
                            "result": str(exc),
                            "summary": str(exc),
                        }
                    )
                    return f"Error: Unexpected exception in {tname}: {exc}"

                elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)
                res_str = str(result) if result is not None else ""
                preview = res_str.replace("\r", "").replace("\n", " ")
                if len(preview) > 360:
                    preview = preview[:360] + f"... (total {len(res_str)} chars)"
                is_err = res_str.startswith("Error:")
                if is_err:
                    LOGGER.warning("[TOOL ERR] [%s] %s (%.1fms) -> %s", policy.profile_name, tname, elapsed_ms, preview)
                else:
                    LOGGER.info("[TOOL OK] [%s] %s (%.1fms) -> %s", policy.profile_name, tname, elapsed_ms, preview)
                emit_structured_event(
                    {
                        "call_id": call_id,
                        "status": "error" if is_err else "done",
                        "kind": "err" if is_err else "ok",
                        "badge": "失败" if is_err else "完成",
                        "level": "WARNING" if is_err else "INFO",
                        "tool": tname,
                        "source": policy.profile_name,
                        "source_host": policy.host,
                        "ms": elapsed_ms,
                        "args": safe_kwargs,
                        "result": res_str[:4000] + (f"\n... (total {len(res_str)} chars)" if len(res_str) > 4000 else ""),
                        "summary": preview,
                    }
                )
                return result

            return mcp.tool(name=tname, annotations=annotations)(_wrapped)

        return _decorator

    if hasattr(mcp, "custom_route"):
        try:
            from starlette.responses import JSONResponse

            @mcp.custom_route("/health", methods=["GET"])
            async def health_check(_request: Any) -> Any:
                return JSONResponse(
                    {
                        "status": "ok",
                        "server_name": config.server_name,
                        "version": VERSION,
                        "auth_mode": config.auth_mode,
                        "read_only": config.read_only,
                    }
                )
        except Exception:
            pass

    @tool(READ_ONLY_ANN)
    def list_roots() -> str:
        """Inspect server access scope, allowed root directories, current working directory, and mode flags."""
        info = {
            "server_name": config.server_name,
            "tool_prefix": prefix,
            "hostname": socket.gethostname(),
            "version": VERSION,
            "os": sys.platform,
            "cwd": str(Path.cwd()),
            "access_mode": "unrestricted" if config.unrestricted else "scoped",
            "allowed_roots": [str(r) for r in config.roots],
            "read_only": config.read_only,
            "allow_secrets": config.allow_secrets,
            "auth_mode": config.auth_mode,
            "transport": config.transport,
        }
        return json.dumps(info, indent=2, ensure_ascii=False)

    undo_store = UndoStore()
    proc_mgr = ProcessManager()
    register_file_tools(tool, config, undo_store)
    register_process_tools(tool, config, proc_mgr)
    register_sub_mcp_tools(tool, config)
    return mcp


def _build_dual_http_sse_app(mcp: Any, stateless_http: bool) -> Any:
    """Mount Streamable HTTP (/mcp) and legacy SSE (/sse + /messages) on a single ASGI app."""
    from contextlib import AsyncExitStack, asynccontextmanager
    from starlette.applications import Starlette

    http_app = mcp.http_app(transport="http", stateless_http=stateless_http)
    sse_app = mcp.http_app(transport="sse")

    existing_paths = {getattr(r, "path", None) for r in http_app.routes}
    combined_routes = list(http_app.routes)
    for route in sse_app.routes:
        if getattr(route, "path", None) not in existing_paths:
            combined_routes.append(route)
            existing_paths.add(getattr(route, "path", None))

    @asynccontextmanager
    async def _combined_lifespan(app: Any):
        async with AsyncExitStack() as stack:
            for sub in (http_app, sse_app):
                lf = getattr(sub.router, "lifespan_context", None)
                if lf is not None:
                    await stack.enter_async_context(lf(sub))
            yield

    return Starlette(
        routes=combined_routes,
        middleware=list(getattr(http_app, "user_middleware", [])),
        lifespan=_combined_lifespan,
    )


def run_server(mcp: Any, config: ServerConfig) -> None:
    if config.transport == "stdio":
        mcp.run(transport="stdio")
        return

    import uvicorn
    from .dashboard import mount_dashboard_routes

    if config.transport == "dual":
        app = _build_dual_http_sse_app(mcp, stateless_http=config.stateless_http)
        LOGGER.info(
            "Dual transport ready on http://%s:%s -> /mcp (Streamable HTTP), /sse (SSE), /dashboard (Web UI)",
            config.host,
            config.port,
        )
    else:
        app_kwargs: dict[str, Any] = {"transport": config.transport}
        if config.transport == "http":
            app_kwargs["stateless_http"] = config.stateless_http
        app = mcp.http_app(**app_kwargs)
        LOGGER.info(
            "Server ready on http://%s:%s -> /%s & /dashboard (password-protected Web UI)",
            config.host,
            config.port,
            "sse" if config.transport == "sse" else "mcp",
        )

    mount_dashboard_routes(app, config)

    from urllib.parse import urlparse

    auth_provider = getattr(mcp, "_agent_auth_provider", None)

    def _build_routing_state(
        raw_profiles: list[dict[str, Any]],
        global_ro: bool,
        global_sec: bool,
        global_roots: list[Path],
        global_auth_mode: str,
        global_api_key: str | None,
        global_base_url: str | None,
        global_base_urls: list[str],
        active_tunnel_ids: set[str] | None = None,
    ) -> dict[str, Any]:
        active_tunnel_ids = active_tunnel_ids or set()
        enabled = [p for p in raw_profiles if p.get("enabled", True)]
        cid_map: dict[str, dict[str, Any]] = {}
        key_map: dict[str, dict[str, Any]] = {}
        hp_map: dict[str, dict[str, Any]] = {}
        hb_map: dict[str, str] = {}
        all_bases: list[str] = []

        for u in ([global_base_url] if global_base_url else []) + list(global_base_urls or []):
            cleaned = str(u).strip().rstrip("/")
            if cleaned and cleaned not in all_bases:
                all_bases.append(cleaned)

        for p in enabled:
            tmode = str(p.get("tunnel_mode") or "none").lower()
            if tmode in ("quick", "token") and str(p.get("id") or "") not in active_tunnel_ids:
                # Tunnel-backed profile stays closed until its cloudflared tunnel is running
                continue
            if p.get("oauth_client_id"):
                cid_map[str(p["oauth_client_id"])] = p
            if p.get("auth_mode") == "bearer" and p.get("api_key"):
                key_map[str(p["api_key"])] = p
            b = str(p.get("base_url") or "").strip().rstrip("/")
            if b:
                if b not in all_bases:
                    all_bases.append(b)
                parsed = urlparse(b)
                if parsed.netloc:
                    hp_map[parsed.netloc.lower()] = p
                    if parsed.hostname:
                        hp_map.setdefault(parsed.hostname.lower(), p)

        if global_auth_mode == "bearer" and global_api_key and global_api_key not in key_map:
            key_map[global_api_key] = {"id": "global-bearer", "name": "主入口 (Bearer)", "inherit_permissions": True}

        for u in all_bases:
            parsed = urlparse(u)
            if parsed.netloc:
                hb_map[parsed.netloc.lower()] = u
                if parsed.hostname:
                    hb_map.setdefault(parsed.hostname.lower(), u)

        primary = all_bases[0] if all_bases else ""
        req_bearer = (auth_provider is None) and bool(key_map) and (
            global_auth_mode == "bearer" or (bool(enabled) and all(p.get("auth_mode") == "bearer" for p in enabled))
        )
        return {
            "enabled": enabled,
            "by_id": {str(p.get("id") or ""): p for p in enabled},
            "client_id_map": cid_map,
            "api_key_map": key_map,
            "host_profile_map": hp_map,
            "host_base_map": hb_map,
            "primary_base": primary,
            "primary_bytes": primary.encode("utf-8") if primary else b"",
            "require_bearer_only": req_bearer,
            "global_ro": global_ro,
            "global_sec": global_sec,
            "global_roots": global_roots,
        }

    cfg_cache: dict[str, Any] = {
        "mtime": -1,
        "state": _build_routing_state(
            list(config.profiles or []),
            config.read_only,
            config.allow_secrets,
            list(config.roots),
            config.auth_mode,
            config.api_key,
            config.oauth_base_url,
            list(config.oauth_base_urls or []),
        ),
    }

    def _read_active_tunnel_ids() -> tuple[int, set[str]]:
        try:
            mt = TUNNEL_STATE_PATH.stat().st_mtime_ns if TUNNEL_STATE_PATH.is_file() else 0
        except OSError:
            mt = 0
        if not mt:
            return 0, set()
        try:
            raw_t = json.loads(TUNNEL_STATE_PATH.read_text(encoding="utf-8"))
            if isinstance(raw_t, dict):
                return mt, {str(k) for k in raw_t.keys()}
        except Exception:
            pass
        return mt, set()

    def _get_live_state() -> dict[str, Any]:
        """Hot-reload profiles, auth keys, OAuth clients, active tunnels, and permissions whenever config/tunnel changes."""
        try:
            mt = config.config_file.stat().st_mtime_ns if config.config_file.is_file() else 0
        except OSError:
            mt = 0
        t_mt, active_tids = _read_active_tunnel_ids()
        combined_key = (mt, t_mt)
        if combined_key != cfg_cache["mtime"]:
            saved = load_saved_config(config.config_file)
            if saved:
                profs = ensure_profiles_in_config(saved)
                g_roots = [Path(r).expanduser().resolve() for r in (saved.get("roots") or []) if str(r).strip()]
                cfg_cache["state"] = _build_routing_state(
                    profs,
                    bool(saved.get("read_only", config.read_only)),
                    bool(saved.get("allow_secrets", config.allow_secrets)),
                    g_roots,
                    str(saved.get("auth_mode") or config.auth_mode),
                    saved.get("api_key") or config.api_key,
                    saved.get("oauth_base_url") or config.oauth_base_url,
                    list(saved.get("oauth_base_urls") or []),
                    active_tunnel_ids=active_tids,
                )
                if auth_provider is not None and hasattr(auth_provider, "sync_static_clients"):
                    auth_provider.sync_static_clients(profs)
            cfg_cache["mtime"] = combined_key
        return cfg_cache["state"]

    def _policy_from_profile(prof: dict[str, Any], st: dict[str, Any], host_str: str = "") -> AccessPolicy:
        if prof.get("inherit_permissions", True):
            return AccessPolicy(
                profile_id=str(prof.get("id") or "default"),
                profile_name=str(prof.get("name") or "主入口"),
                host=host_str,
                read_only=st["global_ro"],
                allow_secrets=st["global_sec"],
                roots=list(st["global_roots"]),
            )
        roots = [Path(r).expanduser().resolve() for r in (prof.get("roots") or []) if str(r).strip()]
        return AccessPolicy(
            profile_id=str(prof.get("id") or "default"),
            profile_name=str(prof.get("name") or "主入口"),
            host=host_str,
            read_only=bool(prof.get("read_only", False)),
            allow_secrets=bool(prof.get("allow_secrets", False)),
            roots=roots,
        )

    tunnel_cache: dict[str, Any] = {"mtime": -1, "host_base": {}, "host_prof": {}}

    def _refresh_live_tunnels(by_id: dict[str, dict[str, Any]]) -> tuple[dict[str, str], dict[str, dict[str, Any]]]:
        try:
            mt = TUNNEL_STATE_PATH.stat().st_mtime_ns if TUNNEL_STATE_PATH.is_file() else 0
        except OSError:
            mt = 0
        if mt != tunnel_cache["mtime"]:
            hb: dict[str, str] = {}
            hp: dict[str, dict[str, Any]] = {}
            if mt:
                try:
                    raw_t = json.loads(TUNNEL_STATE_PATH.read_text(encoding="utf-8"))
                    if isinstance(raw_t, dict):
                        for pid, info in raw_t.items():
                            lu = str((info or {}).get("live_url") or "").strip().rstrip("/")
                            if lu:
                                parsed = urlparse(lu)
                                if parsed.netloc:
                                    hb[parsed.netloc.lower()] = lu
                                    if parsed.hostname:
                                        hb[parsed.hostname.lower()] = lu
                                    if pid in by_id:
                                        hp[parsed.netloc.lower()] = by_id[pid]
                                        if parsed.hostname:
                                            hp[parsed.hostname.lower()] = by_id[pid]
                except Exception:
                    pass
            tunnel_cache["mtime"] = mt
            tunnel_cache["host_base"] = hb
            tunnel_cache["host_prof"] = hp
        return tunnel_cache["host_base"], tunnel_cache["host_prof"]

    class ProfileRouterMiddleware:
        """Hot-reloading middleware for per-request AccessPolicy, source attribution, multi-domain OAuth 2.1, and Bearer auth."""

        def __init__(self, inner_app: Any) -> None:
            self.inner_app = inner_app

        async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
            if scope["type"] != "http":
                await self.inner_app(scope, receive, send)
                return

            path = scope.get("path", "")
            req_headers = {k.lower(): v.decode("latin-1") for k, v in scope.get("headers", [])}
            raw_host = (req_headers.get(b"x-forwarded-host") or req_headers.get(b"host") or "").split(",")[0].strip().lower()
            host_no_port = raw_host.split(":")[0]

            # 1. Bypass MCP auth for /health and /dashboard (which has its own password+cookie auth)
            if path == "/health" or path == "/dashboard" or path.startswith("/dashboard/"):
                await self.inner_app(scope, receive, send)
                return

            st = _get_live_state()
            live_hb, live_hp = _refresh_live_tunnels(st["by_id"])

            # 2. Multi-domain OAuth 2.1 discovery / authorize rewriting (Option B + live Quick Tunnel URLs)
            primary_bytes = st["primary_bytes"]
            primary_base = st["primary_base"]
            if primary_bytes and (
                path.startswith("/.well-known/")
                or path.startswith("/oauth/")
                or path in ("/authorize", "/token", "/register")
            ):
                target_base = (
                    st["host_base_map"].get(raw_host)
                    or st["host_base_map"].get(host_no_port)
                    or live_hb.get(raw_host)
                    or live_hb.get(host_no_port)
                )
                if target_base and target_base != primary_base:
                    target_bytes = target_base.encode("utf-8")
                    start_msg: dict[str, Any] = {}
                    body_chunks: list[bytes] = []

                    async def _capture_send(msg: dict[str, Any]) -> None:
                        if msg["type"] == "http.response.start":
                            start_msg.update(msg)
                        elif msg["type"] == "http.response.body":
                            body_chunks.append(msg.get("body", b""))
                            if not msg.get("more_body", False):
                                raw_body = b"".join(body_chunks)
                                new_headers: list[tuple[bytes, bytes]] = []
                                ctype = ""
                                for hk, hv in start_msg.get("headers", []):
                                    lk = hk.lower()
                                    if lk == b"content-type":
                                        ctype = hv.decode("latin-1").lower()
                                    if lk == b"content-length":
                                        continue
                                    if lk == b"location" and primary_bytes in hv:
                                        hv = hv.replace(primary_bytes, target_bytes)
                                    new_headers.append((hk, hv))
                                if any(t in ctype for t in ("json", "html", "text")) and primary_bytes in raw_body:
                                    raw_body = raw_body.replace(primary_bytes, target_bytes)
                                new_headers.append((b"content-length", str(len(raw_body)).encode("ascii")))
                                start_msg["headers"] = new_headers
                                await send(start_msg)
                                await send({"type": "http.response.body", "body": raw_body, "more_body": False})

                    await self.inner_app(scope, receive, _capture_send)
                    return

            # 3. Identify caller profile & enforce Bearer auth when applicable
            auth_hdr = req_headers.get(b"authorization", "")
            x_key = req_headers.get(b"x-api-key", "")
            bearer_tok = auth_hdr[7:].strip() if auth_hdr.lower().startswith("bearer ") else x_key.strip()

            matched_profile: dict[str, Any] | None = None
            if bearer_tok and bearer_tok in st["api_key_map"]:
                matched_profile = st["api_key_map"][bearer_tok]
            elif bearer_tok and auth_provider is not None and hasattr(auth_provider, "resolve_token_client_id"):
                cid = auth_provider.resolve_token_client_id(bearer_tok)
                if cid and cid in st["client_id_map"]:
                    matched_profile = st["client_id_map"][cid]

            if matched_profile is None:
                matched_profile = (
                    st["host_profile_map"].get(raw_host)
                    or st["host_profile_map"].get(host_no_port)
                    or live_hp.get(raw_host)
                    or live_hp.get(host_no_port)
                )

            if st["require_bearer_only"] and (not bearer_tok or bearer_tok not in st["api_key_map"]):
                LOGGER.warning("[AUTH 401] Rejected unauthorized %s %s", scope.get("method"), path)
                body = b'{"error": "Unauthorized: invalid or missing Bearer token / API key"}'
                await send(
                    {
                        "type": "http.response.start",
                        "status": 401,
                        "headers": [(b"content-type", b"application/json")],
                    }
                )
                await send({"type": "http.response.body", "body": body})
                return

            if matched_profile is not None:
                policy = _policy_from_profile(matched_profile, st, host_str=raw_host)
            else:
                default_name = st["enabled"][0]["name"] if st["enabled"] else "默认入口"
                policy = AccessPolicy(
                    profile_id="default",
                    profile_name=default_name,
                    host=raw_host,
                    read_only=st["global_ro"],
                    allow_secrets=st["global_sec"],
                    roots=list(st["global_roots"]),
                )

            token = set_current_policy(policy)
            try:
                await self.inner_app(scope, receive, send)
            finally:
                reset_current_policy(token)

    app = ProfileRouterMiddleware(app)
    uvicorn.run(app, host=config.host, port=config.port, log_config=None)
