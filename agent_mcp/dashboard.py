"""Password-protected Web Dashboard mounted directly at /dashboard on the MCP server port."""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import html
import json
import secrets
import time
import urllib.parse
from typing import Any

from . import VERSION
from .auth import hash_password, verify_password
from .config import (
    ServerConfig,
    clean_storage,
    ensure_profiles_in_config,
    get_storage_stats,
    load_saved_config,
    normalize_profile,
    sanitize_prefix,
    save_config_file,
)
from .logging_utils import (
    LOGGER,
    clear_event_history,
    get_event_history,
    subscribe_events,
    unsubscribe_events,
)
from .sub_mcp import SUB_MCP_MANAGER
from .tray import APP_ICON_DATA_URI
from .tunnel import (
    TUNNEL_MANAGER,
    cancel_cloudflared_download,
    import_cloudflared_bytes,
    pause_cloudflared_download,
    start_cloudflared_download,
    uninstall_cloudflared,
)

_COOKIE_NAME = "mcp_dash_session"
_SESSION_TTL = 86_400  # 24 hours
_MAX_FAILS = 5
_LOCKOUT_SECONDS = 60

_LOGIN_HTML_TEMPLATE = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<link rel="icon" type="image/svg+xml" href="__FAVICON__" />
<title>登录 · __SERVER_NAME__ Dashboard</title>
<style>
:root{
  --paper:#FAF9F5;--paper-2:#F3F1EA;--paper-3:#E9E6DC;--ink:#141413;--ink-soft:#3A3935;
  --muted:#6E6C66;--hairline:#E4E1D6;--clay:#D97757;--clay-h:#C56647;--danger:#C94A4A;
  --font-serif:"Iowan Old Style","Georgia","Songti SC","Noto Serif SC",serif;
  --font-sans:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;
}
@media (prefers-color-scheme: dark){
  :root:not([data-theme="light"]){
    --paper:#181715;--paper-2:#21201D;--paper-3:#2B2925;--ink:#F2EFE8;--ink-soft:#D4D0C7;
    --muted:#9E9A90;--hairline:#33312C;--clay:#E08262;--clay-h:#EA9072;--danger:#E06C6C;
  }
}
:root[data-theme="dark"]{
  --paper:#181715;--paper-2:#21201D;--paper-3:#2B2925;--ink:#F2EFE8;--ink-soft:#D4D0C7;
  --muted:#9E9A90;--hairline:#33312C;--clay:#E08262;--clay-h:#EA9072;--danger:#E06C6C;
}
*{box-sizing:border-box}
body{
  margin:0;min-height:100vh;display:grid;place-items:center;padding:20px;
  background:var(--paper);color:var(--ink);font-family:var(--font-sans);
  -webkit-font-smoothing:antialiased;
}
@keyframes cardIn{from{opacity:0;transform:translateY(12px) scale(.98)}to{opacity:1;transform:none}}
@keyframes shake{0%,100%{transform:translateX(0)}20%,60%{transform:translateX(-6px)}40%,80%{transform:translateX(6px)}}
.card{
  width:min(400px,100%);background:var(--paper-2);border:1px solid var(--hairline);
  border-radius:18px;padding:30px 28px 26px;box-shadow:0 18px 48px rgba(20,20,19,.08);
  animation:cardIn .28s cubic-bezier(.22,1,.36,1) both;
}
.card.shake{animation:shake .34s ease}
.brand{display:flex;align-items:center;gap:10px;margin-bottom:14px}
.brand-name{font-family:var(--font-serif);font-size:21px;font-weight:500;letter-spacing:-.01em}
.sub{font-size:13px;color:var(--muted);line-height:1.55;margin:0 0 22px}
.pwd-wrap{position:relative;display:flex;align-items:center;margin-bottom:14px}
.input{
  width:100%;height:42px;padding:0 40px 0 14px;border-radius:11px;
  border:1px solid var(--hairline);background:var(--paper);color:var(--ink);
  font-size:14px;outline:none;transition:border-color .16s,box-shadow .16s;
}
.input:focus{border-color:var(--clay);box-shadow:0 0 0 3px rgba(217,119,87,.16)}
.eye{
  position:absolute;right:8px;width:30px;height:30px;border:0;background:transparent;
  color:var(--muted);border-radius:8px;cursor:pointer;display:grid;place-items:center;
  outline:none;-webkit-tap-highlight-color:transparent;touch-action:manipulation;
  transition:background .12s,color .12s,transform .1s cubic-bezier(.22,1,.36,1);
}
.eye:hover{background:var(--paper-3);color:var(--ink)}
.eye:active{transform:scale(.86);background:var(--paper-3)}
.eye svg{width:17px;height:17px}
.btn{
  width:100%;height:42px;border:0;border-radius:11px;background:var(--clay);color:#FAF9F5;
  font-size:14px;font-weight:600;cursor:pointer;outline:none;
  -webkit-tap-highlight-color:transparent;touch-action:manipulation;
  transition:background .14s,transform .11s cubic-bezier(.22,1,.36,1),filter .12s,opacity .15s;
}
.btn:hover{background:var(--clay-h)}
.btn:active{transform:scale(.965);background:var(--clay-h);filter:brightness(.92)}
.btn:disabled{opacity:.6;cursor:not-allowed}
.err{
  min-height:20px;margin-top:12px;font-size:12.5px;color:var(--danger);text-align:center;
}
.foot{margin-top:18px;text-align:center;font-size:11.5px;color:var(--muted)}
</style>
</head>
<body>
<div class="card" id="login-card">
  <div class="brand">
    <svg width="24" height="24" viewBox="0 0 24 24" fill="none">
      <path d="M12 2L14.2 9.2L21.5 11.5L14.2 13.8L12 21L9.8 13.8L2.5 11.5L9.8 9.2L12 2Z" fill="#D97757"/>
    </svg>
    <div class="brand-name">__SERVER_NAME__</div>
  </div>
  <p class="sub">请输入本地授权密码以访问 Web Dashboard（与 OAuth 本地授权密码一致）。</p>
  <form id="login-form" onsubmit="doLogin(event)">
    <div class="pwd-wrap">
      <input id="pwd" class="input" type="password" placeholder="输入管理密码..." autocomplete="current-password" autofocus required />
      <button type="button" class="eye" id="eye-btn" title="显示 / 隐藏密码" onclick="toggleEye()"></button>
    </div>
    <button type="submit" class="btn" id="submit-btn">进入控制台</button>
  </form>
  <div class="err" id="err-msg"></div>
  <div class="foot">Agent MCP Dashboard · v__VERSION__</div>
</div>
<script>
const savedTheme = localStorage.getItem('mcp_theme');
if(savedTheme === 'light' || savedTheme === 'dark') document.documentElement.setAttribute('data-theme', savedTheme);
const EYE_OPEN = '<svg viewBox="0 0 20 20" fill="none"><path d="M2 10s3-5.5 8-5.5S18 10 18 10s-3 5.5-8 5.5S2 10 2 10z" stroke="currentColor" stroke-width="1.5"/><circle cx="10" cy="10" r="2.3" stroke="currentColor" stroke-width="1.5"/></svg>';
const EYE_OFF = '<svg viewBox="0 0 20 20" fill="none"><path d="M3 3l14 14M8.4 8.5A2.3 2.3 0 0011.5 11.6M5.4 5.9C3.3 7.3 2 10 2 10s3 5.5 8 5.5c1.6 0 3-.5 4.2-1.3M9 4.6c.3 0 .7-.1 1-.1 5 0 8 5.5 8 5.5s-1 1.8-2.7 3.3" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>';
document.getElementById('eye-btn').innerHTML = EYE_OPEN;
function toggleEye(){
  const inp = document.getElementById('pwd');
  const show = inp.type === 'password';
  inp.type = show ? 'text' : 'password';
  document.getElementById('eye-btn').innerHTML = show ? EYE_OFF : EYE_OPEN;
}
async function doLogin(e){
  e.preventDefault();
  const btn = document.getElementById('submit-btn');
  const err = document.getElementById('err-msg');
  const card = document.getElementById('login-card');
  err.textContent = '';
  btn.disabled = true;
  btn.textContent = '验证中...';
  try{
    const res = await fetch('/dashboard/api/login', {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body:JSON.stringify({password: document.getElementById('pwd').value}),
    });
    const d = await res.json();
    if(d.ok){
      location.href = '/dashboard';
      return;
    }
    err.textContent = d.error || '密码不正确';
    card.classList.remove('shake');
    void card.offsetWidth;
    card.classList.add('shake');
  }catch(_){
    err.textContent = '网络请求失败，请检查服务是否在线';
  }finally{
    btn.disabled = false;
    btn.textContent = '进入控制台';
  }
}
</script>
</body>
</html>
"""


def _verify_dashboard_password(password: str, config: ServerConfig) -> tuple[bool, str | None]:
    """Verify against oauth_local_password_hash (preferred) or api_key fallback. Never allows empty/unconfigured."""
    saved = load_saved_config(config.config_file)
    pwd_hash = saved.get("oauth_local_password_hash") or config.oauth_local_password_hash
    if pwd_hash:
        return (verify_password(password, str(pwd_hash)), None)
    api_key = saved.get("api_key") or config.api_key
    if api_key:
        return (hmac.compare_digest(password.encode("utf-8"), str(api_key).encode("utf-8")), None)
    return (False, "服务端尚未设置本地授权密码或 API Key，请先在 mcp_config.json 或桌面端配置密码。")


def mount_dashboard_routes(app: Any, config: ServerConfig) -> None:
    """Attach password-protected /dashboard and /dashboard/api/* routes onto an existing Starlette ASGI app."""
    from starlette.requests import Request
    from starlette.responses import HTMLResponse, JSONResponse, StreamingResponse
    from starlette.routing import Route

    from .web_gui import HTML_PAGE

    signing_secret = secrets.token_bytes(32)
    fail_tracker: dict[str, list[float]] = {}

    def _sign_token() -> str:
        exp = str(int(time.time()) + _SESSION_TTL)
        nonce = secrets.token_hex(12)
        msg = f"{exp}.{nonce}".encode("ascii")
        sig = hmac.new(signing_secret, msg, hashlib.sha256).hexdigest()
        return f"{exp}.{nonce}.{sig}"

    def _check_cookie(req: Request) -> bool:
        tok = req.cookies.get(_COOKIE_NAME, "")
        parts = tok.split(".")
        if len(parts) != 3:
            return False
        exp_s, nonce, sig = parts
        try:
            if int(exp_s) < int(time.time()):
                return False
        except ValueError:
            return False
        expected = hmac.new(signing_secret, f"{exp_s}.{nonce}".encode("ascii"), hashlib.sha256).hexdigest()
        return hmac.compare_digest(sig, expected)

    def _client_ip(req: Request) -> str:
        fwd = req.headers.get("x-forwarded-for")
        if fwd:
            return fwd.split(",")[0].strip()
        return req.client.host if req.client else "unknown"

    def _is_locked_out(ip: str) -> int:
        now = time.time()
        attempts = [t for t in fail_tracker.get(ip, []) if now - t < _LOCKOUT_SECONDS]
        fail_tracker[ip] = attempts
        if len(attempts) >= _MAX_FAILS:
            return max(1, int(_LOCKOUT_SECONDS - (now - attempts[0])))
        return 0

    def _render_login() -> HTMLResponse:
        page = (
            _LOGIN_HTML_TEMPLATE.replace("__SERVER_NAME__", html.escape(config.server_name))
            .replace("__VERSION__", html.escape(VERSION))
            .replace("__FAVICON__", APP_ICON_DATA_URI)
        )
        return HTMLResponse(page)

    async def dash_index(req: Request) -> HTMLResponse:
        if not _check_cookie(req):
            return _render_login()
        return HTMLResponse(HTML_PAGE.replace("__FAVICON__", APP_ICON_DATA_URI))

    async def dash_login(req: Request) -> JSONResponse:
        ip = _client_ip(req)
        wait_s = _is_locked_out(ip)
        if wait_s > 0:
            return JSONResponse({"ok": False, "error": f"密码错误次数过多，请 {wait_s} 秒后再试。"}, status_code=429)
        try:
            body = await req.json()
            pwd = str(body.get("password", ""))
        except Exception:
            return JSONResponse({"ok": False, "error": "请求格式错误"}, status_code=400)

        ok, setup_err = _verify_dashboard_password(pwd, config)
        if setup_err:
            return JSONResponse({"ok": False, "error": setup_err}, status_code=403)
        if not ok:
            fail_tracker.setdefault(ip, []).append(time.time())
            LOGGER.warning("[AUTH 401] Dashboard login failed from %s", ip)
            return JSONResponse({"ok": False, "error": "密码不正确，请重试。"}, status_code=401)

        fail_tracker.pop(ip, None)
        LOGGER.info("[OAUTH OK] Dashboard login succeeded from %s", ip)
        resp = JSONResponse({"ok": True})
        resp.set_cookie(
            _COOKIE_NAME,
            _sign_token(),
            max_age=_SESSION_TTL,
            httponly=True,
            samesite="lax",
            path="/dashboard",
        )
        return resp

    async def dash_logout(_req: Request) -> JSONResponse:
        resp = JSONResponse({"ok": True})
        resp.delete_cookie(_COOKIE_NAME, path="/dashboard")
        return resp

    def _unauth() -> JSONResponse:
        return JSONResponse({"ok": False, "error": "Unauthorized"}, status_code=401)

    def _file_rev(p: Any) -> int:
        try:
            return int(p.stat().st_mtime_ns) if p.is_file() else 0
        except OSError:
            return 0

    async def api_status(req: Request) -> JSONResponse:
        if not _check_cookie(req):
            return _unauth()
        saved = load_saved_config(config.config_file)
        saved["profiles"] = ensure_profiles_in_config(saved)
        return JSONResponse(
            {
                "running": True,
                "version": VERSION,
                "tray_enabled": False,
                "dashboard_mode": True,
                "config_rev": _file_rev(config.config_file),
                "sub_rev": _file_rev(SUB_MCP_MANAGER.config_path),
                "tunnels": TUNNEL_MANAGER.get_statuses(),
                "config": saved,
            }
        )

    async def api_config(req: Request) -> JSONResponse:
        if not _check_cookie(req):
            return _unauth()
        body = await req.json()
        cur = load_saved_config(config.config_file)
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
        save_config_file(config.config_file, cur)
        return JSONResponse({"ok": True})

    async def api_logs(req: Request) -> JSONResponse:
        if not _check_cookie(req):
            return _unauth()
        return JSONResponse({"logs": get_event_history()})

    async def api_logs_clear(req: Request) -> JSONResponse:
        if not _check_cookie(req):
            return _unauth()
        clear_event_history()
        return JSONResponse({"ok": True})

    async def api_logs_stream(req: Request) -> Any:
        if not _check_cookie(req):
            return _unauth()
        loop = asyncio.get_running_loop()
        q: asyncio.Queue[dict[str, Any]] = asyncio.Queue(maxsize=500)

        def _on_event(ev: dict[str, Any]) -> None:
            def _put() -> None:
                if not q.full():
                    q.put_nowait(ev)

            try:
                loop.call_soon_threadsafe(_put)
            except Exception:
                pass

        subscribe_events(_on_event)

        async def _gen():
            try:
                while True:
                    if await req.is_disconnected():
                        break
                    try:
                        ev = await asyncio.wait_for(q.get(), timeout=15.0)
                        yield f"data: {json.dumps(ev, ensure_ascii=False)}\n\n"
                    except asyncio.TimeoutError:
                        yield ": ping\n\n"
            finally:
                unsubscribe_events(_on_event)

        return StreamingResponse(_gen(), media_type="text/event-stream")

    async def api_health_check(req: Request) -> JSONResponse:
        if not _check_cookie(req):
            return _unauth()
        target_url = req.query_params.get("url", "").strip()
        if target_url:
            import urllib.request

            hurl = target_url.rstrip("/") + "/health"
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
        body = json.dumps(
            {
                "status": "ok",
                "server_name": config.server_name,
                "version": VERSION,
                "auth_mode": config.auth_mode,
                "read_only": config.read_only,
            },
            ensure_ascii=False,
        )
        return JSONResponse({"ok": True, "url": "/health", "body": body})

    async def api_storage(req: Request) -> JSONResponse:
        if not _check_cookie(req):
            return _unauth()
        return JSONResponse({"ok": True, "stats": get_storage_stats()})

    async def api_storage_clean(req: Request) -> JSONResponse:
        if not _check_cookie(req):
            return _unauth()
        body = await req.json()
        target = str(body.get("target", "")).strip()
        if target == "logs":
            clear_event_history()
        res = clean_storage(target)
        res["stats"] = get_storage_stats()
        return JSONResponse(res)

    async def api_tunnel_start(req: Request) -> JSONResponse:
        if not _check_cookie(req):
            return _unauth()
        pid = req.path_params["pid"]
        saved = load_saved_config(config.config_file)
        profs = ensure_profiles_in_config(saved)
        prof = next((p for p in profs if p.get("id") == pid), None)
        if not prof:
            return JSONResponse({"ok": False, "error": "未找到该入口配置"}, status_code=404)
        res = TUNNEL_MANAGER.start_tunnel(prof, int(saved.get("port") or config.port))
        return JSONResponse(res)

    async def api_tunnel_stop(req: Request) -> JSONResponse:
        if not _check_cookie(req):
            return _unauth()
        pid = req.path_params["pid"]
        return JSONResponse(TUNNEL_MANAGER.stop_tunnel(pid))

    async def api_tunnel_install(req: Request) -> JSONResponse:
        if not _check_cookie(req):
            return _unauth()
        force, resume = False, False
        try:
            body = await req.json()
            force = bool(body.get("force", False))
            resume = bool(body.get("resume", False))
        except Exception:
            pass
        return JSONResponse(start_cloudflared_download(force_update=force, resume=resume))

    async def api_tunnel_pause(req: Request) -> JSONResponse:
        if not _check_cookie(req):
            return _unauth()
        return JSONResponse(pause_cloudflared_download())

    async def api_tunnel_cancel(req: Request) -> JSONResponse:
        if not _check_cookie(req):
            return _unauth()
        return JSONResponse(cancel_cloudflared_download())

    async def api_tunnel_import(req: Request) -> JSONResponse:
        if not _check_cookie(req):
            return _unauth()
        raw_name = req.headers.get("X-Filename") or req.query_params.get("filename") or "cloudflared"
        filename = urllib.parse.unquote(raw_name)
        data = await req.body()
        res = await asyncio.to_thread(import_cloudflared_bytes, filename, data)
        return JSONResponse(res)

    async def api_tunnel_uninstall(req: Request) -> JSONResponse:
        if not _check_cookie(req):
            return _unauth()
        return JSONResponse(uninstall_cloudflared())

    async def api_sub_list(req: Request) -> JSONResponse:
        if not _check_cookie(req):
            return _unauth()
        return JSONResponse({"ok": True, "servers": SUB_MCP_MANAGER.list_with_status()})

    async def api_sub_upsert(req: Request) -> JSONResponse:
        if not _check_cookie(req):
            return _unauth()
        try:
            body = await req.json()
            old_name = body.pop("old_name", None)
            entry = SUB_MCP_MANAGER.upsert_entry(body, old_name=old_name)
            return JSONResponse({"ok": True, "entry": entry})
        except Exception as exc:
            return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)

    async def api_sub_import(req: Request) -> JSONResponse:
        if not _check_cookie(req):
            return _unauth()
        try:
            body = await req.json()
            imported = SUB_MCP_MANAGER.import_json(str(body.get("raw", "")))
            return JSONResponse({"ok": True, "count": len(imported), "entries": imported})
        except Exception as exc:
            return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)

    async def api_sub_toggle(req: Request) -> JSONResponse:
        if not _check_cookie(req):
            return _unauth()
        name = req.path_params["name"]
        try:
            body = await req.json()
            entry = SUB_MCP_MANAGER.toggle_entry(name, bool(body.get("enabled", True)))
            return JSONResponse({"ok": True, "entry": entry})
        except Exception as exc:
            return JSONResponse({"ok": False, "error": str(exc)}, status_code=404)

    async def api_sub_delete(req: Request) -> JSONResponse:
        if not _check_cookie(req):
            return _unauth()
        name = req.path_params["name"]
        return JSONResponse({"ok": SUB_MCP_MANAGER.delete_entry(name)})

    async def api_sub_test(req: Request) -> JSONResponse:
        if not _check_cookie(req):
            return _unauth()
        name = req.path_params["name"]
        res = await asyncio.to_thread(SUB_MCP_MANAGER.discover_tools, name, True)
        return JSONResponse(res)

    async def api_sub_probe(req: Request) -> JSONResponse:
        if not _check_cookie(req):
            return _unauth()
        try:
            body = await req.json()
        except Exception:
            return JSONResponse({"ok": False, "error": "请求格式错误"}, status_code=400)
        res = await asyncio.to_thread(SUB_MCP_MANAGER.probe_draft, body)
        return JSONResponse(res)

    dash_routes = [
        Route("/dashboard", dash_index),
        Route("/dashboard/", dash_index),
        Route("/dashboard/api/login", dash_login, methods=["POST"]),
        Route("/dashboard/api/logout", dash_logout, methods=["POST"]),
        Route("/dashboard/api/status", api_status),
        Route("/dashboard/api/config", api_config, methods=["POST"]),
        Route("/dashboard/api/logs", api_logs),
        Route("/dashboard/api/logs/clear", api_logs_clear, methods=["POST"]),
        Route("/dashboard/api/logs/stream", api_logs_stream),
        Route("/dashboard/api/health-check", api_health_check),
        Route("/dashboard/api/storage", api_storage),
        Route("/dashboard/api/storage/clean", api_storage_clean, methods=["POST"]),
        Route("/dashboard/api/tunnels/install", api_tunnel_install, methods=["POST"]),
        Route("/dashboard/api/tunnels/pause", api_tunnel_pause, methods=["POST"]),
        Route("/dashboard/api/tunnels/cancel", api_tunnel_cancel, methods=["POST"]),
        Route("/dashboard/api/tunnels/import", api_tunnel_import, methods=["POST"]),
        Route("/dashboard/api/tunnels/uninstall", api_tunnel_uninstall, methods=["POST"]),
        Route("/dashboard/api/tunnels/{pid}/start", api_tunnel_start, methods=["POST"]),
        Route("/dashboard/api/tunnels/{pid}/stop", api_tunnel_stop, methods=["POST"]),
        Route("/dashboard/api/sub-mcps", api_sub_list),
        Route("/dashboard/api/sub-mcps", api_sub_upsert, methods=["POST"]),
        Route("/dashboard/api/sub-mcps/import", api_sub_import, methods=["POST"]),
        Route("/dashboard/api/sub-mcps/probe", api_sub_probe, methods=["POST"]),
        Route("/dashboard/api/sub-mcps/{name}/toggle", api_sub_toggle, methods=["POST"]),
        Route("/dashboard/api/sub-mcps/{name}", api_sub_delete, methods=["DELETE"]),
        Route("/dashboard/api/sub-mcps/{name}/test", api_sub_test, methods=["POST"]),
    ]
    app.router.routes.extend(dash_routes)
