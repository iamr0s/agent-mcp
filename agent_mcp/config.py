"""Configuration, storage layout, lossless migration, per-request AccessPolicy, and profiles."""

from __future__ import annotations

import contextvars
import dataclasses
import fnmatch
import json
import os
import re
import shutil
import uuid
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CONFIG_DIR = PROJECT_ROOT / "config"
DATA_DIR = PROJECT_ROOT / "data"
CACHE_DIR = DATA_DIR / "cache"
LOGS_DIR = PROJECT_ROOT / "logs"
ASSETS_DIR = Path(__file__).resolve().parent / "assets"

DEFAULT_CONFIG_PATH = CONFIG_DIR / "mcp_config.json"
SUB_MCP_CONFIG_PATH = CONFIG_DIR / "mcp_sub_servers.json"
OAUTH_STATE_PATH = DATA_DIR / "oauth_state.json"
WINDOW_STATE_PATH = DATA_DIR / "window_state.json"
TUNNEL_STATE_PATH = DATA_DIR / "tunnel_state.json"
APP_ICON_PATH = ASSETS_DIR / "app_icon.ico"

_MIGRATED = False


def ensure_storage_layout() -> None:
    """Create config/data/logs folders and losslessly migrate legacy root-level files once."""
    global _MIGRATED
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    if _MIGRATED:
        return
    _MIGRATED = True

    migrations = [
        (PROJECT_ROOT / "mcp_config.json", DEFAULT_CONFIG_PATH),
        (PROJECT_ROOT / "mcp_sub_servers.json", SUB_MCP_CONFIG_PATH),
        (PROJECT_ROOT / "mcp_oauth_state.json", OAUTH_STATE_PATH),
        (PROJECT_ROOT / "mcp_window_state.json", WINDOW_STATE_PATH),
        (PROJECT_ROOT / "gui_crash.log", LOGS_DIR / "gui_crash.log"),
    ]
    archive_dir = PROJECT_ROOT / "_legacy" / "migrated_root"
    for src, dst in migrations:
        try:
            if src.is_file() and not dst.is_file():
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst)
                if dst.is_file() and dst.stat().st_size == src.stat().st_size:
                    archive_dir.mkdir(parents=True, exist_ok=True)
                    shutil.move(str(src), str(archive_dir / src.name))
        except Exception:
            pass


DEFAULT_IGNORE_DIRS = {
    ".git",
    ".hg",
    ".svn",
    "node_modules",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    ".venv",
    "venv",
    ".tox",
    "dist",
    "build",
    ".gradle",
    ".idea",
    ".vscode",
    "target",
    "bin",
    "obj",
}

SECRET_FILENAME_PATTERNS = [
    ".env",
    ".env.*",
    "*.pem",
    "*.key",
    "*.p12",
    "*.pfx",
    "*.jks",
    "*.keystore",
    "id_rsa",
    "id_rsa.*",
    "id_ed25519",
    "id_ed25519.*",
    "credentials.json",
    "secrets.json",
    "secrets.yaml",
    "secrets.yml",
    ".npmrc",
    ".pypirc",
    ".netrc",
    "mcp_config.json",
    "mcp_oauth_state.json",
    "oauth_state.json",
    "mcp_sub_servers.json",
]

SECRET_DIR_PARTS = {".ssh", ".aws", ".gnupg", ".kube", ".local-agent-mcp"}


@dataclasses.dataclass
class AccessPolicy:
    profile_id: str = "default"
    profile_name: str = "默认入口"
    host: str = ""
    read_only: bool = False
    allow_secrets: bool = False
    relaxed_command_annotations: bool = False
    roots: list[Path] = dataclasses.field(default_factory=list)


CURRENT_POLICY: contextvars.ContextVar[AccessPolicy | None] = contextvars.ContextVar(
    "mcp_current_policy", default=None
)


def set_current_policy(policy: AccessPolicy | None) -> contextvars.Token[AccessPolicy | None]:
    return CURRENT_POLICY.set(policy)


def reset_current_policy(token: contextvars.Token[AccessPolicy | None]) -> None:
    CURRENT_POLICY.reset(token)


def get_effective_policy(config: ServerConfig) -> AccessPolicy:
    p = CURRENT_POLICY.get()
    if p is not None:
        return p
    return AccessPolicy(
        profile_id="global",
        profile_name="本地 stdio" if config.transport == "stdio" else "默认入口",
        host="",
        read_only=config.read_only,
        allow_secrets=config.allow_secrets,
        relaxed_command_annotations=config.relaxed_command_annotations,
        roots=list(config.roots),
    )


@dataclasses.dataclass
class ServerConfig:
    server_name: str = "local-agent-mcp"
    tool_prefix: str = ""
    transport: str = "stdio"
    host: str = "127.0.0.1"
    port: int = 8000
    auth_mode: str = "none"  # none | bearer | oauth-local | github | google | oauth-custom
    api_key: str | None = None
    oauth_client_id: str | None = None
    oauth_client_secret: str | None = None
    oauth_base_url: str | None = None
    oauth_base_urls: list[str] = dataclasses.field(default_factory=list)
    oauth_auth_url: str | None = None
    oauth_token_url: str | None = None
    oauth_jwks_url: str | None = None
    oauth_local_password_hash: str | None = None
    oauth_redirect_uris: list[str] = dataclasses.field(default_factory=list)
    profiles: list[dict[str, Any]] = dataclasses.field(default_factory=list)
    roots: list[Path] = dataclasses.field(default_factory=list)
    read_only: bool = False
    allow_secrets: bool = False
    relaxed_command_annotations: bool = False
    max_read_chars: int = 60_000
    max_cmd_chars: int = 15_000
    default_timeout: int = 60
    stateless_http: bool = True
    log_level: str = "INFO"
    log_file: str | None = None
    no_color: bool = False
    config_file: Path = DEFAULT_CONFIG_PATH

    @property
    def unrestricted(self) -> bool:
        return len(self.roots) == 0


def normalize_profile(raw: dict[str, Any], idx: int = 0) -> dict[str, Any]:
    pid = str(raw.get("id") or f"prof-{uuid.uuid4().hex[:8]}").strip()
    name = str(raw.get("name") or f"入口 #{idx + 1}").strip()
    transport = str(raw.get("transport") or "dual").strip().lower()
    if transport not in ("dual", "http", "sse"):
        transport = "dual"
    auth_mode = str(raw.get("auth_mode") or "oauth-local").strip().lower()
    if auth_mode not in ("none", "bearer", "oauth-local", "github", "google", "oauth-custom"):
        auth_mode = "oauth-local"
    base_url = str(raw.get("base_url") or "").strip().rstrip("/")
    ruris = raw.get("oauth_redirect_uris") or []
    if isinstance(ruris, str):
        ruris = [x.strip() for x in re.split(r"[\r\n,]+", ruris) if x.strip()]
    roots_raw = raw.get("roots") or []
    if isinstance(roots_raw, str):
        roots_raw = [x.strip() for x in re.split(r"[\r\n,]+", roots_raw) if x.strip()]
    tunnel_mode = str(raw.get("tunnel_mode") or "none").strip().lower()
    if tunnel_mode not in ("none", "token", "quick"):
        tunnel_mode = "none"
    return {
        "id": pid,
        "name": name,
        "enabled": bool(raw.get("enabled", True)),
        "transport": transport,
        "base_url": base_url,
        "auth_mode": auth_mode,
        "api_key": str(raw.get("api_key") or "").strip() or None,
        "oauth_client_id": str(raw.get("oauth_client_id") or "").strip() or None,
        "oauth_client_secret": str(raw.get("oauth_client_secret") or "").strip() or None,
        "oauth_redirect_uris": [str(u).strip() for u in ruris if str(u).strip()],
        "tunnel_mode": tunnel_mode,
        "tunnel_token": str(raw.get("tunnel_token") or "").strip() or None,
        "tunnel_auto_start": bool(raw.get("tunnel_auto_start", True)),
        "inherit_permissions": bool(raw.get("inherit_permissions", True)),
        "read_only": bool(raw.get("read_only", False)),
        "allow_secrets": bool(raw.get("allow_secrets", False)),
        "relaxed_command_annotations": bool(raw.get("relaxed_command_annotations", False)),
        "roots": [str(r).strip() for r in roots_raw if str(r).strip()],
    }


def ensure_profiles_in_config(data: dict[str, Any]) -> list[dict[str, Any]]:
    """Return normalized profiles list, seamlessly migrating legacy flat config on first load."""
    raw_profiles = data.get("profiles")
    if isinstance(raw_profiles, list) and len(raw_profiles) > 0:
        return [normalize_profile(p, i) for i, p in enumerate(raw_profiles) if isinstance(p, dict)]

    # Auto-build initial profile(s) from legacy top-level fields without losing anything
    bases: list[str] = []
    if data.get("oauth_base_url"):
        bases.append(str(data["oauth_base_url"]).strip().rstrip("/"))
    for u in data.get("oauth_base_urls") or []:
        s = str(u).strip().rstrip("/")
        if s and s not in bases:
            bases.append(s)
    if not bases:
        bases = [""]

    tr = str(data.get("transport") or "dual").lower()
    if tr not in ("dual", "http", "sse"):
        tr = "dual"
    am = str(data.get("auth_mode") or "oauth-local").lower()
    out: list[dict[str, Any]] = []
    for idx, b in enumerate(bases):
        out.append(
            normalize_profile(
                {
                    "id": "default" if idx == 0 else f"prof-{idx + 1}",
                    "name": "主入口" if idx == 0 else f"备用入口 #{idx}",
                    "enabled": True,
                    "transport": tr,
                    "base_url": b,
                    "auth_mode": am,
                    "api_key": data.get("api_key"),
                    "oauth_client_id": data.get("oauth_client_id"),
                    "oauth_client_secret": data.get("oauth_client_secret"),
                    "oauth_redirect_uris": list(data.get("oauth_redirect_uris") or []),
                    "inherit_permissions": True,
                    "read_only": bool(data.get("read_only", False)),
                    "allow_secrets": bool(data.get("allow_secrets", False)),
                    "relaxed_command_annotations": bool(data.get("relaxed_command_annotations", False)),
                    "roots": list(data.get("roots") or []),
                },
                idx,
            )
        )
    return out


def sanitize_prefix(raw: str) -> str:
    cleaned = re.sub(r"[^a-zA-Z0-9_]+", "_", raw.strip()).strip("_")
    return f"{cleaned}_" if cleaned else ""


def is_within(target: Path, root: Path) -> bool:
    try:
        target.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def normalize_path(raw_path: str, roots: list[Path]) -> Path:
    p = Path(os.path.expanduser(raw_path))
    if not p.is_absolute():
        base = Path.cwd()
        if roots and not any(is_within(base, r) for r in roots):
            base = roots[0]
        p = base / p
    return p.resolve()


def check_access(path: Path, config: ServerConfig) -> str | None:
    policy = get_effective_policy(config)
    roots = policy.roots
    if roots and not any(is_within(path, r) for r in roots):
        allowed = ", ".join(str(r) for r in roots)
        return f"Access denied: '{path}' is outside allowed roots [{allowed}] for profile '{policy.profile_name}'."

    if not policy.allow_secrets:
        resolved = path.resolve()
        if resolved == config.config_file.resolve() or is_within(resolved, CONFIG_DIR) or is_within(resolved, DATA_DIR):
            return (
                f"Access blocked for protected MCP config/data file '{path}'. "
                "Enable allow_secrets on this profile if you intentionally need access."
            )
        name_lower = path.name.lower()
        for pat in SECRET_FILENAME_PATTERNS:
            if fnmatch.fnmatch(name_lower, pat.lower()):
                return (
                    f"Access blocked for secret file '{path.name}'. "
                    "Enable allow_secrets on this profile if you intentionally need access."
                )
        if any(part.lower() in SECRET_DIR_PARTS for part in path.parts):
            return (
                f"Access blocked inside sensitive directory '{path}'. "
                "Enable allow_secrets on this profile if you intentionally need access."
            )
    return None


def load_saved_config(config_path: Path) -> dict[str, Any]:
    ensure_storage_layout()
    if not config_path.is_file():
        return {}
    try:
        data = json.loads(config_path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def save_config_file(config_path: Path, data: dict[str, Any]) -> None:
    ensure_storage_layout()
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if os.name != "nt":
        try:
            os.chmod(config_path, 0o600)
        except OSError:
            pass


def _dir_stats(path: Path) -> dict[str, Any]:
    total_bytes = 0
    file_count = 0
    if path.exists():
        for f in path.rglob("*"):
            if f.is_file():
                file_count += 1
                try:
                    total_bytes += f.stat().st_size
                except OSError:
                    pass
    return {"path": str(path), "files": file_count, "bytes": total_bytes}


def get_storage_stats() -> dict[str, Any]:
    ensure_storage_layout()
    pycache_bytes = 0
    pycache_files = 0
    for pc in PROJECT_ROOT.rglob("__pycache__"):
        if pc.is_dir():
            st = _dir_stats(pc)
            pycache_bytes += st["bytes"]
            pycache_files += st["files"]
    cache_st = _dir_stats(CACHE_DIR)
    cache_st["bytes"] += pycache_bytes
    cache_st["files"] += pycache_files
    return {
        "config": _dir_stats(CONFIG_DIR),
        "data": _dir_stats(DATA_DIR),
        "cache": cache_st,
        "logs": _dir_stats(LOGS_DIR),
    }


def clean_storage(target: str) -> dict[str, Any]:
    """Clean 'cache', 'logs', 'window', or 'oauth' safely without touching user config."""
    ensure_storage_layout()
    removed = 0
    if target == "cache":
        if CACHE_DIR.is_dir():
            for item in list(CACHE_DIR.iterdir()):
                try:
                    if item.is_dir():
                        shutil.rmtree(item, ignore_errors=True)
                    else:
                        item.unlink(missing_ok=True)
                    removed += 1
                except Exception:
                    pass
        for pc in list(PROJECT_ROOT.rglob("__pycache__")):
            if pc.is_dir():
                shutil.rmtree(pc, ignore_errors=True)
                removed += 1
        return {"ok": True, "target": target, "removed": removed, "message": "缓存与临时字节码已清理"}

    if target == "logs":
        if LOGS_DIR.is_dir():
            for f in list(LOGS_DIR.rglob("*")):
                if f.is_file():
                    try:
                        f.unlink(missing_ok=True)
                        removed += 1
                    except Exception:
                        pass
        return {"ok": True, "target": target, "removed": removed, "message": f"已清理 {removed} 个日志文件"}

    if target == "window":
        if WINDOW_STATE_PATH.is_file():
            WINDOW_STATE_PATH.unlink(missing_ok=True)
            removed = 1
        return {"ok": True, "target": target, "removed": removed, "message": "窗口位置与尺寸已重置，下次启动生效"}

    if target == "oauth":
        if OAUTH_STATE_PATH.is_file():
            OAUTH_STATE_PATH.unlink(missing_ok=True)
            removed = 1
        return {"ok": True, "target": target, "removed": removed, "message": "OAuth 持久化会话已清空，重启服务后生效"}

    return {"ok": False, "error": f"未知清理目标: {target}"}
