"""Sub-MCP gateway: config persistence, MCP Client routing, and 3 meta-tools."""

from __future__ import annotations

import asyncio
import concurrent.futures
import difflib
import json
import os
import re
import shutil
import threading
import time
from pathlib import Path
from typing import Any

from .config import SUB_MCP_CONFIG_PATH, ServerConfig, ensure_storage_layout
from .file_tools import READ_ONLY_ANN

SUB_CALL_ANN = {
    "readOnlyHint": False,
    "destructiveHint": False,
    "idempotentHint": False,
    "openWorldHint": True,
}

_NAME_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$")
_EXECUTOR = concurrent.futures.ThreadPoolExecutor(max_workers=4, thread_name_prefix="sub-mcp")


def _run_async(coro: Any) -> Any:
    """Run an async coroutine safely whether or not the current thread has an event loop."""
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.run(coro)
    return _EXECUTOR.submit(asyncio.run, coro).result()


def sanitize_sub_name(raw: str) -> str:
    cleaned = re.sub(r"[^a-zA-Z0-9._-]+", "-", raw.strip()).strip("-.")
    return cleaned[:64]


def normalize_sub_entry(raw: dict[str, Any]) -> dict[str, Any]:
    name = sanitize_sub_name(str(raw.get("name", "")))
    if not name or not _NAME_RE.match(name):
        raise ValueError("子 MCP 名称不能为空，仅支持字母、数字、点、下划线和短横线。")

    transport = str(raw.get("transport") or raw.get("type") or "").strip().lower()
    command = str(raw.get("command") or "").strip()
    url = str(raw.get("url") or "").strip()

    if transport in ("streamable-http", "streamable_http"):
        transport = "http"
    if not transport:
        if command:
            transport = "stdio"
        elif url.rstrip("/").endswith("/sse"):
            transport = "sse"
        else:
            transport = "http"
    if transport not in ("stdio", "http", "sse"):
        raise ValueError(f"不支持的传输协议: {transport}（仅支持 stdio / http / sse）")

    if transport == "stdio" and not command:
        raise ValueError("stdio 模式必须填写启动命令 (command)。")
    if transport in ("http", "sse") and not url:
        raise ValueError(f"{transport} 模式必须填写服务地址 (url)。")

    raw_args = raw.get("args", [])
    if isinstance(raw_args, str):
        args = [a for a in raw_args.splitlines() if a.strip()]
    elif isinstance(raw_args, list):
        args = [str(a) for a in raw_args if str(a).strip() != ""]
    else:
        args = []

    raw_env = raw.get("env", {})
    env: dict[str, str] = {}
    if isinstance(raw_env, dict):
        env = {str(k).strip(): str(v) for k, v in raw_env.items() if str(k).strip()}

    raw_headers = raw.get("headers", {})
    headers: dict[str, str] = {}
    if isinstance(raw_headers, dict):
        headers = {str(k).strip(): str(v) for k, v in raw_headers.items() if str(k).strip()}

    try:
        timeout = max(3, min(300, int(raw.get("timeout", 30))))
    except (TypeError, ValueError):
        timeout = 30

    return {
        "name": name,
        "description": str(raw.get("description") or "").strip(),
        "transport": transport,
        "enabled": bool(raw.get("enabled", True)),
        "command": command,
        "args": args,
        "cwd": str(raw.get("cwd") or "").strip(),
        "env": env,
        "url": url,
        "headers": headers,
        "timeout": timeout,
    }


def parse_mcp_servers_json(raw_text: str) -> list[dict[str, Any]]:
    """Parse standard Claude Desktop / Cursor / Antigravity mcpServers JSON into normalized entries."""
    try:
        data = json.loads(raw_text)
    except json.JSONDecodeError as exc:
        raise ValueError(f"JSON 格式无效: {exc}") from exc

    if isinstance(data, list):
        return [normalize_sub_entry(item) for item in data if isinstance(item, dict)]

    if not isinstance(data, dict):
        raise ValueError("顶层必须是 JSON 对象或数组。")

    servers_obj = data.get("mcpServers") if isinstance(data.get("mcpServers"), dict) else data
    if not isinstance(servers_obj, dict) or not servers_obj:
        raise ValueError("未找到有效的 mcpServers 配置项。")

    # Single server object directly pasted (has command or url at root)
    if "command" in servers_obj or "url" in servers_obj:
        if "name" not in servers_obj:
            servers_obj = dict(servers_obj)
            servers_obj["name"] = "sub-mcp"
        return [normalize_sub_entry(servers_obj)]

    entries: list[dict[str, Any]] = []
    for key, val in servers_obj.items():
        if not isinstance(val, dict):
            continue
        item = dict(val)
        item.setdefault("name", key)
        entries.append(normalize_sub_entry(item))
    if not entries:
        raise ValueError("未解析出任何有效的子 MCP 配置。")
    return entries


def _tool_to_dict(tool_obj: Any) -> dict[str, Any]:
    """Convert an mcp.types.Tool object into a clean JSON-serializable dict."""
    if hasattr(tool_obj, "model_dump"):
        d = tool_obj.model_dump(exclude_none=True)
    else:
        d = {
            "name": getattr(tool_obj, "name", ""),
            "description": getattr(tool_obj, "description", "") or "",
            "inputSchema": getattr(tool_obj, "inputSchema", None) or getattr(tool_obj, "input_schema", None) or {},
        }
    return {
        "name": d.get("name", ""),
        "description": d.get("description", "") or "",
        "inputSchema": d.get("inputSchema") or d.get("input_schema") or {"type": "object", "properties": {}},
        "annotations": d.get("annotations"),
    }


def _format_call_result(res: Any) -> str:
    """Format a FastMCP / MCP CallToolResult cleanly for the parent LLM."""
    is_error = bool(getattr(res, "is_error", False) or getattr(res, "isError", False))
    structured = getattr(res, "structured_content", None) or getattr(res, "structuredContent", None)
    content = getattr(res, "content", None) or []

    parts: list[str] = []
    for block in content:
        btype = getattr(block, "type", None) or (block.get("type") if isinstance(block, dict) else None)
        if btype == "text":
            txt = getattr(block, "text", None) if not isinstance(block, dict) else block.get("text")
            if txt is not None:
                parts.append(str(txt))
        elif btype == "image":
            mime = getattr(block, "mimeType", "image/*") if not isinstance(block, dict) else block.get("mimeType", "image/*")
            parts.append(f"[Image content: {mime}]")
        elif btype == "resource":
            res_obj = getattr(block, "resource", None) if not isinstance(block, dict) else block.get("resource")
            uri = getattr(res_obj, "uri", "") if res_obj is not None else ""
            txt = getattr(res_obj, "text", "") if res_obj is not None else ""
            parts.append(f"[Resource {uri}]\n{txt}" if txt else f"[Resource {uri}]")
        else:
            if hasattr(block, "model_dump"):
                parts.append(json.dumps(block.model_dump(exclude_none=True), ensure_ascii=False))
            else:
                parts.append(str(block))

    if not parts and structured is not None:
        parts.append(json.dumps(structured, indent=2, ensure_ascii=False))

    body = "\n".join(parts).strip() or "(empty result)"
    if is_error and not body.startswith("Error:"):
        return f"Error: {body}"
    return body


class SubMcpManager:
    """Thread-safe manager for sub-MCP configurations, tool discovery cache, and RPC calls."""

    def __init__(self, config_path: Path = SUB_MCP_CONFIG_PATH) -> None:
        self.config_path = config_path
        self._lock = threading.RLock()
        self._cache: dict[str, dict[str, Any]] = {}

    def load_entries(self) -> list[dict[str, Any]]:
        ensure_storage_layout()
        with self._lock:
            if not self.config_path.is_file():
                return []
            try:
                raw = json.loads(self.config_path.read_text(encoding="utf-8"))
                items = raw.get("servers", []) if isinstance(raw, dict) else (raw if isinstance(raw, list) else [])
                result: list[dict[str, Any]] = []
                for it in items:
                    if isinstance(it, dict):
                        try:
                            result.append(normalize_sub_entry(it))
                        except ValueError:
                            continue
                return result
            except Exception:
                return []

    def save_entries(self, entries: list[dict[str, Any]]) -> None:
        with self._lock:
            self.config_path.parent.mkdir(parents=True, exist_ok=True)
            payload = {"version": 1, "servers": entries}
            self.config_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            if os.name != "nt":
                try:
                    os.chmod(self.config_path, 0o600)
                except OSError:
                    pass

    def get_entry(self, name: str) -> dict[str, Any] | None:
        for e in self.load_entries():
            if e["name"] == name:
                return e
        return None

    def list_with_status(self) -> list[dict[str, Any]]:
        entries = self.load_entries()
        with self._lock:
            out: list[dict[str, Any]] = []
            for e in entries:
                c = self._cache.get(e["name"], {})
                item = dict(e)
                item["status"] = c.get("status", "idle")
                item["tool_count"] = len(c.get("tools", [])) if "tools" in c else None
                item["tools"] = [
                    {"name": t["name"], "description": t.get("description", "")}
                    for t in c.get("tools", [])
                ]
                item["last_error"] = c.get("error")
                item["last_ms"] = c.get("ms")
                out.append(item)
            return out

    def upsert_entry(self, raw: dict[str, Any], old_name: str | None = None) -> dict[str, Any]:
        entry = normalize_sub_entry(raw)
        with self._lock:
            entries = self.load_entries()
            target_old = old_name or entry["name"]
            if old_name and old_name != entry["name"] and any(e["name"] == entry["name"] for e in entries):
                raise ValueError(f"已存在名为 '{entry['name']}' 的子 MCP。")
            updated = False
            new_entries: list[dict[str, Any]] = []
            for e in entries:
                if e["name"] == target_old:
                    new_entries.append(entry)
                    updated = True
                else:
                    new_entries.append(e)
            if not updated:
                new_entries.append(entry)
            self.save_entries(new_entries)
            if old_name and old_name != entry["name"]:
                self._cache.pop(old_name, None)
            self._cache.pop(entry["name"], None)
            return entry

    def import_json(self, raw_text: str) -> list[dict[str, Any]]:
        parsed = parse_mcp_servers_json(raw_text)
        with self._lock:
            entries = self.load_entries()
            by_name = {e["name"]: e for e in entries}
            order = [e["name"] for e in entries]
            for item in parsed:
                if item["name"] not in by_name:
                    order.append(item["name"])
                by_name[item["name"]] = item
                self._cache.pop(item["name"], None)
            self.save_entries([by_name[n] for n in order])
        return parsed

    def toggle_entry(self, name: str, enabled: bool) -> dict[str, Any]:
        with self._lock:
            entries = self.load_entries()
            for e in entries:
                if e["name"] == name:
                    e["enabled"] = bool(enabled)
                    self.save_entries(entries)
                    return e
        raise KeyError(f"未找到子 MCP: {name}")

    def delete_entry(self, name: str) -> bool:
        with self._lock:
            entries = self.load_entries()
            new_entries = [e for e in entries if e["name"] != name]
            if len(new_entries) == len(entries):
                return False
            self.save_entries(new_entries)
            self._cache.pop(name, None)
            return True

    def _build_transport(self, entry: dict[str, Any]) -> Any:
        from fastmcp.client.transports import SSETransport, StdioTransport, StreamableHttpTransport

        tr = entry["transport"]
        if tr == "stdio":
            cmd = entry["command"]
            if os.name == "nt":
                resolved = shutil.which(cmd)
                if resolved:
                    cmd = resolved
            merged_env = dict(os.environ)
            merged_env.update(entry.get("env") or {})
            cwd = entry.get("cwd") or None
            return StdioTransport(command=cmd, args=entry.get("args") or [], env=merged_env, cwd=cwd)
        if tr == "sse":
            return SSETransport(url=entry["url"], headers=entry.get("headers") or None)
        return StreamableHttpTransport(url=entry["url"], headers=entry.get("headers") or None)

    async def _discover_tools_async(self, entry: dict[str, Any]) -> list[dict[str, Any]]:
        from fastmcp import Client

        transport = self._build_transport(entry)
        timeout = float(entry.get("timeout", 30))
        async with Client(transport, timeout=timeout, init_timeout=timeout) as client:
            tools = await client.list_tools()
            return [_tool_to_dict(t) for t in tools]

    async def _call_tool_async(
        self,
        entry: dict[str, Any],
        tool_name: str,
        arguments: dict[str, Any],
        timeout_override: int | None = None,
    ) -> str:
        from fastmcp import Client

        transport = self._build_transport(entry)
        timeout = float(timeout_override or entry.get("timeout", 30))
        async with Client(transport, timeout=timeout, init_timeout=timeout) as client:
            res = await client.call_tool(tool_name, arguments, timeout=timeout, raise_on_error=False)
            return _format_call_result(res)

    async def _probe_draft_async(self, entry: dict[str, Any]) -> dict[str, Any]:
        from fastmcp import Client

        transport = self._build_transport(entry)
        timeout = float(entry.get("timeout", 30))
        async with Client(transport, timeout=timeout, init_timeout=timeout) as client:
            init_res = getattr(client, "initialize_result", None)
            server_info = getattr(init_res, "serverInfo", None) if init_res is not None else getattr(client, "server_info", None)
            raw_name = (getattr(server_info, "name", None) or "").strip() if server_info is not None else ""
            version = (getattr(server_info, "version", None) or "").strip() if server_info is not None else ""
            instructions = (getattr(init_res, "instructions", None) or "").strip() if init_res is not None else ""
            tools = [_tool_to_dict(t) for t in await client.list_tools()]
            return {
                "raw_name": raw_name,
                "version": version,
                "instructions": instructions,
                "tools": tools,
            }

    def probe_draft(self, raw: dict[str, Any]) -> dict[str, Any]:
        """Connect to an unsaved Sub-MCP config and auto-detect its name, description, and tool count."""
        draft = dict(raw)
        draft["name"] = draft.get("name") or "probe-temp"
        try:
            entry = normalize_sub_entry(draft)
        except ValueError as exc:
            return {"ok": False, "error": str(exc)}

        t0 = time.perf_counter()
        try:
            info = _run_async(self._probe_draft_async(entry))
            elapsed = round((time.perf_counter() - t0) * 1000, 1)
            raw_name = info["raw_name"]
            suggested_name = sanitize_sub_name(raw_name) if raw_name else ""
            tools = info["tools"]
            instructions = info["instructions"]
            if instructions:
                first_para = instructions.splitlines()[0].strip()
                desc = (first_para[:180] + "...") if len(first_para) > 180 else first_para
            elif tools:
                sample = ", ".join(t["name"] for t in tools[:5])
                suffix = " 等" if len(tools) > 5 else ""
                ver_tag = f"v{info['version']} · " if info["version"] else ""
                desc = f"{ver_tag}提供 {len(tools)} 个工具（{sample}{suffix}）"
            else:
                desc = f"{raw_name} {info['version']}".strip()
            return {
                "ok": True,
                "name": suggested_name,
                "raw_name": raw_name,
                "version": info["version"],
                "description": desc,
                "tool_count": len(tools),
                "ms": elapsed,
            }
        except Exception as exc:
            elapsed = round((time.perf_counter() - t0) * 1000, 1)
            return {"ok": False, "error": f"{type(exc).__name__}: {exc}", "ms": elapsed}

    def discover_tools(self, name: str, refresh: bool = False) -> dict[str, Any]:
        entry = self.get_entry(name)
        if not entry:
            return {"ok": False, "error": f"Sub-MCP '{name}' not found."}
        with self._lock:
            cached = self._cache.get(name)
            if not refresh and cached and cached.get("status") == "ok" and "tools" in cached:
                return {"ok": True, "tools": cached["tools"], "ms": cached.get("ms", 0.0), "cached": True}

        t0 = time.perf_counter()
        try:
            tools = _run_async(self._discover_tools_async(entry))
            elapsed = round((time.perf_counter() - t0) * 1000, 1)
            with self._lock:
                self._cache[name] = {"status": "ok", "tools": tools, "error": None, "ms": elapsed, "ts": time.time()}
            return {"ok": True, "tools": tools, "ms": elapsed, "cached": False}
        except Exception as exc:
            elapsed = round((time.perf_counter() - t0) * 1000, 1)
            err_msg = f"{type(exc).__name__}: {exc}"
            with self._lock:
                self._cache[name] = {"status": "error", "tools": [], "error": err_msg, "ms": elapsed, "ts": time.time()}
            return {"ok": False, "error": err_msg, "ms": elapsed}

    def call_tool(
        self,
        server_name: str,
        tool_name: str,
        arguments: dict[str, Any] | None = None,
        timeout: int | None = None,
    ) -> str:
        entry = self.get_entry(server_name)
        if not entry:
            avail = [e["name"] for e in self.load_entries() if e.get("enabled", True)]
            return f"Error: Sub-MCP '{server_name}' not found. Available enabled sub-MCPs: {avail}"
        if not entry.get("enabled", True):
            return f"Error: Sub-MCP '{server_name}' is currently disabled."
        args = arguments if isinstance(arguments, dict) else {}
        try:
            res = _run_async(self._call_tool_async(entry, tool_name, args, timeout_override=timeout))
            if res.startswith("Error:"):
                schema_hint = self._get_cached_schema_hint(server_name, tool_name)
                if schema_hint:
                    return f"{res}\n\n[Hint: expected inputSchema for {server_name}/{tool_name}]\n{schema_hint}"
            return res
        except Exception as exc:
            schema_hint = self._get_cached_schema_hint(server_name, tool_name)
            msg = f"Error: Sub-MCP call '{server_name}/{tool_name}' failed: {type(exc).__name__}: {exc}"
            if schema_hint:
                msg += f"\n\n[Hint: expected inputSchema for {server_name}/{tool_name}]\n{schema_hint}"
            return msg

    def _get_cached_schema_hint(self, server_name: str, tool_name: str) -> str | None:
        with self._lock:
            cached = self._cache.get(server_name)
            if not cached or not cached.get("tools"):
                return None
            for t in cached["tools"]:
                if t.get("name") == tool_name:
                    return json.dumps(t.get("inputSchema", {}), indent=2, ensure_ascii=False)
        return None


SUB_MCP_MANAGER = SubMcpManager()


def register_sub_mcp_tools(tool: Any, _config: ServerConfig) -> None:
    """Register the 3 progressive-discovery meta-tools for nested Sub-MCP servers."""

    @tool(READ_ONLY_ANN)
    def list_sub_mcps() -> str:
        """List all configured and enabled nested Sub-MCP servers without polluting the main toolset.
        Call this first to discover available Sub-MCP servers, then use inspect_sub_mcp() and call_sub_mcp()."""
        items = SUB_MCP_MANAGER.list_with_status()
        enabled_items = [
            {
                "name": it["name"],
                "description": it.get("description") or "(no description)",
                "transport": it["transport"],
                "status": it.get("status", "idle"),
                "cached_tool_count": it.get("tool_count"),
            }
            for it in items
            if it.get("enabled", True)
        ]
        payload = {
            "count": len(enabled_items),
            "sub_mcps": enabled_items,
            "usage": (
                "1) Call inspect_sub_mcp(server_name) to list tool names and summaries. "
                "2) Call inspect_sub_mcp(server_name, tool_name) to inspect exact inputSchema before calling. "
                "3) Call call_sub_mcp(server_name, tool_name, arguments={...}) to execute."
            ),
        }
        return json.dumps(payload, indent=2, ensure_ascii=False)

    @tool(READ_ONLY_ANN)
    def inspect_sub_mcp(server_name: str, tool_name: str | None = None, refresh: bool = False) -> str:
        """Inspect tools exposed by a nested Sub-MCP server.
        Omit tool_name to get a compact list of tool names & descriptions; pass tool_name to get its full inputSchema."""
        entry = SUB_MCP_MANAGER.get_entry(server_name)
        if not entry:
            avail = [e["name"] for e in SUB_MCP_MANAGER.load_entries() if e.get("enabled", True)]
            return f"Error: Sub-MCP '{server_name}' not found. Available enabled sub-MCPs: {avail}"
        if not entry.get("enabled", True):
            return f"Error: Sub-MCP '{server_name}' is disabled."

        res = SUB_MCP_MANAGER.discover_tools(server_name, refresh=refresh)
        if not res.get("ok"):
            return f"Error: Failed to connect to Sub-MCP '{server_name}': {res.get('error')}"

        tools = res.get("tools", [])
        if tool_name:
            for t in tools:
                if t["name"] == tool_name:
                    return json.dumps(
                        {
                            "server_name": server_name,
                            "tool": t,
                        },
                        indent=2,
                        ensure_ascii=False,
                    )
            names = [t["name"] for t in tools]
            close = difflib.get_close_matches(tool_name, names, n=5, cutoff=0.4)
            return (
                f"Error: Tool '{tool_name}' not found in Sub-MCP '{server_name}'. "
                f"Close matches: {close or names[:10]}"
            )

        compact = [
            {
                "name": t["name"],
                "description": (t.get("description") or "").strip().splitlines()[0][:200] if t.get("description") else "",
            }
            for t in tools
        ]
        return json.dumps(
            {
                "server_name": server_name,
                "description": entry.get("description", ""),
                "transport": entry["transport"],
                "tool_count": len(compact),
                "tools": compact,
                "hint": "Call inspect_sub_mcp(server_name, tool_name) to view full parameter schema before calling.",
            },
            indent=2,
            ensure_ascii=False,
        )

    @tool(SUB_CALL_ANN)
    def call_sub_mcp(
        server_name: str,
        tool_name: str,
        arguments: dict[str, Any] | None = None,
        timeout: int | None = None,
    ) -> str:
        """Invoke a specific tool on a nested Sub-MCP server by server_name, tool_name, and arguments dict.
        Always inspect_sub_mcp(server_name, tool_name) first if you are unsure about required parameter names or types."""
        return SUB_MCP_MANAGER.call_tool(server_name, tool_name, arguments=arguments, timeout=timeout)
