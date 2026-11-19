"""Authentication providers: local self-hosted OAuth 2.1, GitHub, Google, OIDC Proxy."""

from __future__ import annotations

import hashlib
import hmac
import html
import json
import secrets
import threading
import time
from pathlib import Path
from typing import Any

from .config import OAUTH_STATE_PATH, ServerConfig, ensure_profiles_in_config
from .logging_utils import LOGGER


def hash_password(password: str, salt: str | None = None) -> str:
    s = salt or secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), s.encode("utf-8"), 100_000).hex()
    return f"{s}${digest}"


def verify_password(password: str, stored: str) -> bool:
    if "$" not in stored:
        return False
    salt, expected = stored.split("$", 1)
    actual = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt.encode("utf-8"), 100_000).hex()
    return hmac.compare_digest(actual, expected)


def create_local_oauth_provider(
    base_url: str,
    password_hash: str,
    static_client_id: str | None = None,
    static_client_secret: str | None = None,
    static_redirect_uris: list[str] | None = None,
    extra_static_clients: list[dict[str, Any]] | None = None,
    server_name: str = "Local Agent MCP",
    state_file: Path | None = None,
) -> Any:
    from fastmcp.server.auth import OAuthProvider
    from mcp.server.auth.provider import (
        AccessToken,
        AuthorizationCode,
        AuthorizationParams,
        RefreshToken,
        construct_redirect_uri,
    )
    from mcp.server.auth.settings import ClientRegistrationOptions
    from mcp.shared.auth import OAuthClientInformationFull, OAuthToken
    from pydantic import AnyUrl
    from starlette.requests import Request
    from starlette.responses import HTMLResponse, RedirectResponse
    from starlette.routing import Route

    class LocalOAuthProvider(OAuthProvider):
        def __init__(self) -> None:
            super().__init__(
                base_url=base_url,
                client_registration_options=ClientRegistrationOptions(
                    enabled=True,
                    valid_scopes=["mcp"],
                    default_scopes=["mcp"],
                ),
            )
            self._state_lock = threading.Lock()
            self._clients: dict[str, OAuthClientInformationFull] = {}
            self._pending: dict[str, tuple[OAuthClientInformationFull, AuthorizationParams, float]] = {}
            self._codes: dict[str, AuthorizationCode] = {}
            self._access_tokens: dict[str, AccessToken] = {}
            self._refresh_tokens: dict[str, RefreshToken] = {}
            self._load_state()
            if static_client_id and static_client_secret:
                uris = [AnyUrl(u) for u in (static_redirect_uris or []) if u.strip()]
                self._clients[static_client_id] = OAuthClientInformationFull(
                    client_id=static_client_id,
                    client_secret=static_client_secret,
                    client_name="Configured OAuth Client",
                    redirect_uris=uris or None,
                    grant_types=["authorization_code", "refresh_token"],
                    response_types=["code"],
                    scope="mcp",
                )
            for sc in extra_static_clients or []:
                cid = str(sc.get("client_id") or "").strip()
                csec = str(sc.get("client_secret") or "").strip()
                if cid and csec:
                    uris = [AnyUrl(u) for u in (sc.get("redirect_uris") or []) if str(u).strip()]
                    self._clients[cid] = OAuthClientInformationFull(
                        client_id=cid,
                        client_secret=csec,
                        client_name=str(sc.get("client_name") or "Configured OAuth Client"),
                        redirect_uris=uris or None,
                        grant_types=["authorization_code", "refresh_token"],
                        response_types=["code"],
                        scope="mcp",
                    )

        def resolve_token_client_id(self, token: str) -> str | None:
            at = self._access_tokens.get(token)
            return at.client_id if at is not None else None

        def sync_static_clients(self, profiles: list[dict[str, Any]]) -> None:
            """Hot-sync static OAuth clients from updated profiles without restarting the server."""
            with self._state_lock:
                for p in profiles:
                    if not p.get("enabled", True) or p.get("auth_mode") != "oauth-local":
                        continue
                    cid = str(p.get("oauth_client_id") or "").strip()
                    csec = str(p.get("oauth_client_secret") or "").strip()
                    if cid and csec:
                        uris = [AnyUrl(u) for u in (p.get("oauth_redirect_uris") or []) if str(u).strip()]
                        self._clients[cid] = OAuthClientInformationFull(
                            client_id=cid,
                            client_secret=csec,
                            client_name=str(p.get("name") or "OAuth Profile"),
                            redirect_uris=uris or None,
                            grant_types=["authorization_code", "refresh_token"],
                            response_types=["code"],
                            scope="mcp",
                        )

        def _load_state(self) -> None:
            if not state_file or not state_file.is_file():
                return
            try:
                raw = json.loads(state_file.read_text(encoding="utf-8"))
                for cid, cdata in raw.get("clients", {}).items():
                    self._clients[cid] = OAuthClientInformationFull.model_validate(cdata)
                now = time.time()
                for tok, tdata in raw.get("access_tokens", {}).items():
                    at = AccessToken.model_validate(tdata)
                    if not at.expires_at or at.expires_at > now:
                        self._access_tokens[tok] = at
                for tok, rdata in raw.get("refresh_tokens", {}).items():
                    rt = RefreshToken.model_validate(rdata)
                    if not rt.expires_at or rt.expires_at > now:
                        self._refresh_tokens[tok] = rt
            except Exception:
                pass

        def _save_state(self) -> None:
            if not state_file:
                return
            with self._state_lock:
                payload = {
                    "clients": {k: v.model_dump(mode="json") for k, v in self._clients.items()},
                    "access_tokens": {k: v.model_dump(mode="json") for k, v in self._access_tokens.items()},
                    "refresh_tokens": {k: v.model_dump(mode="json") for k, v in self._refresh_tokens.items()},
                }
                state_file.parent.mkdir(parents=True, exist_ok=True)
                state_file.write_text(json.dumps(payload, indent=2), encoding="utf-8")

        async def get_client(self, client_id: str) -> OAuthClientInformationFull | None:
            return self._clients.get(client_id)

        async def register_client(self, client_info: OAuthClientInformationFull) -> None:
            if client_info.client_id:
                self._clients[client_info.client_id] = client_info
                self._save_state()
                LOGGER.info("[OAUTH REGISTER] client_id=%s name=%s", client_info.client_id, client_info.client_name)

        async def authorize(self, client: OAuthClientInformationFull, params: AuthorizationParams) -> str:
            req_id = secrets.token_urlsafe(24)
            self._pending[req_id] = (client, params, time.time() + 300)
            LOGGER.info("[OAUTH AUTHORIZE] client_id=%s redirect_uri=%s", client.client_id, params.redirect_uri)
            clean_base = base_url.rstrip("/")
            return f"{clean_base}/local-login?req={req_id}"

        async def load_authorization_code(
            self, client: OAuthClientInformationFull, authorization_code: str
        ) -> AuthorizationCode | None:
            code_obj = self._codes.get(authorization_code)
            if not code_obj or code_obj.client_id != client.client_id:
                return None
            if code_obj.expires_at < time.time():
                self._codes.pop(authorization_code, None)
                return None
            return code_obj

        async def exchange_authorization_code(
            self, client: OAuthClientInformationFull, authorization_code: AuthorizationCode
        ) -> OAuthToken:
            self._codes.pop(authorization_code.code, None)
            access_str = secrets.token_urlsafe(32)
            refresh_str = secrets.token_urlsafe(32)
            expires_in = 3600 * 24
            scopes = authorization_code.scopes or ["mcp"]
            self._access_tokens[access_str] = AccessToken(
                token=access_str,
                client_id=client.client_id or "local-client",
                scopes=scopes,
                expires_at=int(time.time() + expires_in),
            )
            self._refresh_tokens[refresh_str] = RefreshToken(
                token=refresh_str,
                client_id=client.client_id or "local-client",
                scopes=scopes,
                expires_at=int(time.time() + 3600 * 24 * 30),
            )
            self._save_state()
            LOGGER.info("[OAUTH TOKEN] issued access+refresh token for client_id=%s", client.client_id)
            return OAuthToken(
                access_token=access_str,
                token_type="Bearer",
                expires_in=expires_in,
                refresh_token=refresh_str,
                scope=" ".join(scopes),
            )

        async def load_refresh_token(
            self, client: OAuthClientInformationFull, refresh_token: str
        ) -> RefreshToken | None:
            rt = self._refresh_tokens.get(refresh_token)
            if not rt or rt.client_id != client.client_id:
                return None
            if rt.expires_at and rt.expires_at < time.time():
                self._refresh_tokens.pop(refresh_token, None)
                return None
            return rt

        async def exchange_refresh_token(
            self, client: OAuthClientInformationFull, refresh_token: RefreshToken, scopes: list[str]
        ) -> OAuthToken:
            self._refresh_tokens.pop(refresh_token.token, None)
            new_access = secrets.token_urlsafe(32)
            new_refresh = secrets.token_urlsafe(32)
            expires_in = 3600 * 24
            final_scopes = scopes or refresh_token.scopes or ["mcp"]
            self._access_tokens[new_access] = AccessToken(
                token=new_access,
                client_id=client.client_id or "local-client",
                scopes=final_scopes,
                expires_at=int(time.time() + expires_in),
            )
            self._refresh_tokens[new_refresh] = RefreshToken(
                token=new_refresh,
                client_id=client.client_id or "local-client",
                scopes=final_scopes,
                expires_at=int(time.time() + 3600 * 24 * 30),
            )
            self._save_state()
            return OAuthToken(
                access_token=new_access,
                token_type="Bearer",
                expires_in=expires_in,
                refresh_token=new_refresh,
                scope=" ".join(final_scopes),
            )

        async def load_access_token(self, token: str) -> AccessToken | None:
            at = self._access_tokens.get(token)
            if not at:
                return None
            if at.expires_at and at.expires_at < time.time():
                self._access_tokens.pop(token, None)
                return None
            return at

        async def revoke_token(self, token: AccessToken | RefreshToken) -> None:
            if isinstance(token, AccessToken):
                self._access_tokens.pop(token.token, None)
            else:
                self._refresh_tokens.pop(token.token, None)
            self._save_state()

        def get_routes(self, mcp_path: str | None = None) -> list[Route]:
            routes = list(super().get_routes(mcp_path=mcp_path))

            async def local_login(request: Request) -> HTMLResponse | RedirectResponse:
                req_id = request.query_params.get("req", "")
                entry = self._pending.get(req_id)
                if not entry or entry[2] < time.time():
                    self._pending.pop(req_id, None)
                    return HTMLResponse("<h3>Authorization request expired or invalid.</h3>", status_code=400)

                client, params, _ = entry
                error_msg = ""
                if request.method == "POST":
                    form = await request.form()
                    pwd = str(form.get("password", ""))
                    if verify_password(pwd, password_hash):
                        self._pending.pop(req_id, None)
                        code_str = secrets.token_urlsafe(32)
                        self._codes[code_str] = AuthorizationCode(
                            code=code_str,
                            scopes=params.scopes or ["mcp"],
                            expires_at=time.time() + 300,
                            client_id=client.client_id or "local-client",
                            code_challenge=params.code_challenge,
                            redirect_uri=params.redirect_uri,
                            redirect_uri_provided_explicitly=params.redirect_uri_provided_explicitly,
                        )
                        target_url = construct_redirect_uri(
                            str(params.redirect_uri), code=code_str, state=params.state
                        )
                        LOGGER.info("[OAUTH LOGIN OK] client_id=%s", client.client_id)
                        return RedirectResponse(url=target_url, status_code=302)
                    LOGGER.warning("[OAUTH LOGIN FAIL] wrong password for client_id=%s", client.client_id)
                    error_msg = '<p style="color:#dc2626">密码错误，请重试。</p>'

                cname = html.escape(client.client_name or client.client_id or "MCP Client")
                sname = html.escape(server_name)
                page = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>{sname} - 授权确认</title>
<style>
:root{{--bg:#FAF9F5;--card:#fff;--border:#E5E0D5;--ink:#1F1E1D;--muted:#6E6A63;--in-bg:#FAF9F5;--clay:#D97757;--clay-h:#C46142}}
@media (prefers-color-scheme: dark){{:root{{--bg:#1A1917;--card:#23221F;--border:#35332E;--ink:#F3F1EA;--muted:#9C988E;--in-bg:#1A1917;--clay:#E08263;--clay-h:#EC9477}}}}
*{{box-sizing:border-box}}
body{{font-family:system-ui,-apple-system,"Microsoft YaHei UI",sans-serif;background:var(--bg);color:var(--ink);max-width:420px;margin:70px auto;padding:20px}}
.card{{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:26px;box-shadow:0 6px 24px rgba(0,0,0,.08)}}
.pw-box{{position:relative;margin:12px 0}}
input{{width:100%;padding:10px 38px 10px 12px;background:var(--in-bg);color:var(--ink);border:1px solid var(--border);border-radius:8px;font-size:14px;outline:none}}
input:focus{{border-color:var(--clay)}}
.eye{{position:absolute;right:8px;top:50%;transform:translateY(-50%);border:0;background:transparent;color:var(--muted);cursor:pointer;padding:4px;display:inline-flex}}
.eye:hover{{color:var(--ink)}}
.submit{{width:100%;padding:11px;background:var(--clay);color:#fff;border:0;border-radius:8px;font-size:15px;font-weight:600;cursor:pointer}}
.submit:hover{{background:var(--clay-h)}}
</style>
</head><body><div class="card">
<h2 style="margin-top:0">{sname} 授权</h2>
<p style="color:var(--muted)">客户端 <b>{cname}</b> 请求访问你的本地 MCP 服务。</p>
{error_msg}
<form method="post">
<label style="font-size:13px;color:var(--muted)">输入本地授权密码：</label>
<div class="pw-box">
<input id="pwd" type="password" name="password" autofocus required />
<button type="button" class="eye" onclick="const i=document.getElementById('pwd');i.type=i.type==='password'?'text':'password'" title="显示 / 隐藏密码">
<svg width="16" height="16" viewBox="0 0 20 20" fill="none"><path d="M2 10s3-5.5 8-5.5S18 10 18 10s-3 5.5-8 5.5S2 10 2 10z" stroke="currentColor" stroke-width="1.5"/><circle cx="10" cy="10" r="2.3" stroke="currentColor" stroke-width="1.5"/></svg>
</button>
</div>
<button class="submit" type="submit">确认授权</button>
</form></div></body></html>"""
                return HTMLResponse(page)

            routes.append(Route("/local-login", local_login, methods=["GET", "POST"]))
            return routes

    return LocalOAuthProvider()


def build_fastmcp_auth(config: ServerConfig) -> Any:
    profiles = [p for p in (config.profiles or []) if p.get("enabled", True)]
    oauth_local_profiles = [p for p in profiles if p.get("auth_mode") == "oauth-local"]

    effective_mode = config.auth_mode
    if oauth_local_profiles and effective_mode in ("none", "bearer"):
        effective_mode = "oauth-local"

    if effective_mode in ("none", "bearer"):
        return None

    primary_base = (
        (oauth_local_profiles[0].get("base_url") if oauth_local_profiles else None)
        or config.oauth_base_url
        or f"http://{config.host}:{config.port}"
    )

    if effective_mode == "oauth-local":
        if not config.oauth_local_password_hash:
            raise SystemExit("Error: oauth-local requires a local password. Run setup first.")
        extra_clients = [
            {
                "client_id": p.get("oauth_client_id"),
                "client_secret": p.get("oauth_client_secret"),
                "redirect_uris": p.get("oauth_redirect_uris") or [],
                "client_name": p.get("name") or "OAuth Profile",
            }
            for p in oauth_local_profiles
            if p.get("oauth_client_id") and p.get("oauth_client_secret")
        ]
        return create_local_oauth_provider(
            base_url=primary_base,
            password_hash=config.oauth_local_password_hash,
            static_client_id=config.oauth_client_id,
            static_client_secret=config.oauth_client_secret,
            static_redirect_uris=config.oauth_redirect_uris,
            extra_static_clients=extra_clients,
            server_name=config.server_name,
            state_file=OAUTH_STATE_PATH,
        )

    base_url = primary_base

    if config.auth_mode == "github":
        if not config.oauth_client_id or not config.oauth_client_secret:
            raise SystemExit("Error: GitHub OAuth requires client_id and client_secret.")
        from fastmcp.server.auth.providers.github import GitHubProvider

        return GitHubProvider(
            client_id=config.oauth_client_id,
            client_secret=config.oauth_client_secret,
            base_url=base_url,
        )

    if config.auth_mode == "google":
        if not config.oauth_client_id or not config.oauth_client_secret:
            raise SystemExit("Error: Google OAuth requires client_id and client_secret.")
        from fastmcp.server.auth.providers.google import GoogleProvider

        return GoogleProvider(
            client_id=config.oauth_client_id,
            client_secret=config.oauth_client_secret,
            base_url=base_url,
        )

    if config.auth_mode == "oauth-custom":
        missing = [
            name
            for name, val in [
                ("oauth_auth_url", config.oauth_auth_url),
                ("oauth_token_url", config.oauth_token_url),
                ("oauth_jwks_url", config.oauth_jwks_url),
                ("oauth_client_id", config.oauth_client_id),
                ("oauth_client_secret", config.oauth_client_secret),
            ]
            if not val
        ]
        if missing:
            raise SystemExit(f"Error: Custom OAuth requires {', '.join(missing)}.")
        from fastmcp.server.auth import OAuthProxy
        from fastmcp.server.auth.providers.jwt import JWTVerifier

        return OAuthProxy(
            upstream_authorization_endpoint=config.oauth_auth_url,
            upstream_token_endpoint=config.oauth_token_url,
            upstream_client_id=config.oauth_client_id,
            upstream_client_secret=config.oauth_client_secret,
            token_verifier=JWTVerifier(jwks_uri=config.oauth_jwks_url),
            base_url=base_url,
        )

    raise SystemExit(f"Error: Unsupported auth_mode '{config.auth_mode}'.")
