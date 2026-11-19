"""Filesystem reading, searching, surgical editing, patching, and undo tools."""

from __future__ import annotations

import difflib
import fnmatch
import json
import os
import re
import shutil
import subprocess
import threading
import time
from collections import deque
from pathlib import Path
from typing import Annotated, Any, Callable, Literal

from pydantic import Field

from .config import DEFAULT_IGNORE_DIRS, ServerConfig, check_access, get_effective_policy, normalize_path

READ_ONLY_ANN = {"readOnlyHint": True, "destructiveHint": False, "idempotentHint": True, "openWorldHint": False}
SAFE_WRITE_ANN = {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": False, "openWorldHint": False}
DESTRUCTIVE_ANN = {"readOnlyHint": False, "destructiveHint": True, "idempotentHint": False, "openWorldHint": True}


def is_binary_bytes(sample: bytes) -> bool:
    if not sample:
        return False
    if b"\x00" in sample:
        return True
    text_chars = bytearray({7, 8, 9, 10, 12, 13, 27} | set(range(0x20, 0x100)) - {0x7F})
    non_text = sample.translate(None, text_chars)
    return (len(non_text) / len(sample)) > 0.30


def read_text_smart(path: Path) -> tuple[str, str, str]:
    raw = path.read_bytes()
    if is_binary_bytes(raw[:8192]):
        raise ValueError(f"'{path}' appears to be a binary file.")
    newline = "\r\n" if b"\r\n" in raw[:8192] else "\n"
    for enc in ("utf-8-sig", "utf-8", "gb18030", "latin-1"):
        try:
            return raw.decode(enc), ("utf-8" if enc == "utf-8-sig" else enc), newline
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace"), "utf-8", newline


def write_text_preserving(path: Path, text: str, encoding: str = "utf-8", newline: str = "\n") -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    normalized = text.replace("\r\n", "\n")
    if newline == "\r\n":
        normalized = normalized.replace("\n", "\r\n")
    data = normalized.encode(encoding, errors="replace")
    path.write_bytes(data)
    return len(data)


def decode_bytes_smart(data: bytes) -> str:
    if not data:
        return ""
    for enc in ("utf-8", "gb18030", "cp936", "latin-1"):
        try:
            return data.decode(enc)
        except UnicodeDecodeError:
            continue
    return data.decode("utf-8", errors="replace")


def truncate_head_tail(text: str, max_chars: int) -> tuple[str, bool]:
    if len(text) <= max_chars:
        return text, False
    head_len = int(max_chars * 0.35)
    tail_len = max_chars - head_len
    omitted = len(text) - max_chars
    result = (
        text[:head_len]
        + f"\n\n... [TRUNCATED {omitted} chars to protect context; showing head + tail] ...\n\n"
        + text[-tail_len:]
    )
    return result, True


def make_unified_diff(old_text: str, new_text: str, path: Path) -> str:
    diff = difflib.unified_diff(
        old_text.splitlines(keepends=True),
        new_text.splitlines(keepends=True),
        fromfile=f"a/{path.name}",
        tofile=f"b/{path.name}",
    )
    return "".join(diff)


def load_gitignore_patterns(root: Path) -> list[str]:
    gi = root / ".gitignore"
    if not gi.is_file():
        return []
    patterns: list[str] = []
    try:
        for line in gi.read_text(encoding="utf-8", errors="replace").splitlines():
            s = line.strip()
            if s and not s.startswith("#") and not s.startswith("!"):
                patterns.append(s.rstrip("/"))
    except OSError:
        pass
    return patterns


def is_ignored(rel_path: Path, name: str, gi_patterns: list[str], show_hidden: bool) -> bool:
    if not show_hidden and name.startswith(".") and name not in {".env.example"}:
        return True
    if name in DEFAULT_IGNORE_DIRS:
        return True
    rel_posix = rel_path.as_posix()
    for pat in gi_patterns:
        if fnmatch.fnmatch(name, pat) or fnmatch.fnmatch(rel_posix, pat):
            return True
    return False


class UndoStore:
    def __init__(self, max_per_file: int = 10) -> None:
        self._lock = threading.Lock()
        self._history: dict[str, deque[tuple[bool, bytes | None, str]]] = {}
        self._max = max_per_file

    def save(self, path: Path, note: str) -> None:
        key = str(path.resolve())
        existed = path.exists()
        data = path.read_bytes() if existed and path.is_file() else None
        with self._lock:
            dq = self._history.setdefault(key, deque(maxlen=self._max))
            dq.append((existed, data, note))

    def pop(self, path: Path) -> tuple[bool, bytes | None, str] | None:
        key = str(path.resolve())
        with self._lock:
            dq = self._history.get(key)
            if not dq:
                return None
            return dq.pop()


def _lines_match(orig: list[str], start: int, expected: list[str]) -> bool:
    if start + len(expected) > len(orig):
        return False
    for i, exp in enumerate(expected):
        if orig[start + i].rstrip("\r\n") != exp.rstrip("\r\n"):
            return False
    return True


def _find_hunk_position(orig: list[str], expected: list[str], min_start: int) -> int | None:
    if not expected:
        return min_start
    for pos in range(min_start, len(orig) - len(expected) + 1):
        if _lines_match(orig, pos, expected):
            return pos
    return None


def apply_unified_diff_text(original: str, diff_text: str) -> str:
    orig_lines = original.splitlines(keepends=True)
    diff_lines = diff_text.splitlines(keepends=True)
    hunk_header_re = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
    hunks: list[tuple[int, list[str]]] = []
    idx = 0
    while idx < len(diff_lines):
        m = hunk_header_re.match(diff_lines[idx])
        if m:
            old_start = int(m.group(1))
            idx += 1
            body: list[str] = []
            while idx < len(diff_lines) and not diff_lines[idx].startswith("@@ "):
                line = diff_lines[idx]
                if line.startswith((" ", "-", "+", "\\")):
                    body.append(line)
                idx += 1
            hunks.append((old_start, body))
        else:
            idx += 1
    if not hunks:
        raise ValueError("No valid unified diff hunks (@@ -a,b +c,d @@) found.")

    result: list[str] = []
    cursor = 0
    for old_start, body in hunks:
        expected_old = [l[1:] for l in body if l.startswith((" ", "-"))]
        new_chunk = [l[1:] for l in body if l.startswith((" ", "+"))]
        target_idx = max(0, old_start - 1)
        if not _lines_match(orig_lines, target_idx, expected_old):
            found = _find_hunk_position(orig_lines, expected_old, cursor)
            if found is None:
                raise ValueError(
                    f"Hunk at line {old_start} failed to match file content. "
                    "Ensure context lines match the current file."
                )
            target_idx = found
        if target_idx < cursor:
            raise ValueError(f"Overlapping hunk near line {old_start}.")
        result.extend(orig_lines[cursor:target_idx])
        result.extend(new_chunk)
        cursor = target_idx + len(expected_old)
    result.extend(orig_lines[cursor:])
    return "".join(result)


def register_file_tools(tool: Callable[[dict[str, Any]], Any], config: ServerConfig, undo_store: UndoStore) -> None:
    @tool(READ_ONLY_ANN)
    def stat_file(
        path: Annotated[str, Field(description="Absolute or relative file/directory path.")],
    ) -> str:
        """Check file or directory metadata (size, line count, estimated tokens, type) before reading."""
        target = normalize_path(path, get_effective_policy(config).roots)
        if err := check_access(target, config):
            return f"Error: {err}"
        if not target.exists():
            return f"Error: Path does not exist: {target}"

        st = target.stat()
        info: dict[str, Any] = {
            "path": str(target),
            "type": "directory" if target.is_dir() else "file",
            "size_bytes": st.st_size,
            "modified_time": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(st.st_mtime)),
        }
        if target.is_file():
            try:
                text, enc, nl = read_text_smart(target)
                lines = text.splitlines()
                info.update(
                    {
                        "is_binary": False,
                        "encoding": enc,
                        "newline": "CRLF" if nl == "\r\n" else "LF",
                        "total_lines": len(lines),
                        "total_chars": len(text),
                        "estimated_tokens": max(1, len(text) // 4),
                    }
                )
            except ValueError:
                info["is_binary"] = True
        return json.dumps(info, indent=2, ensure_ascii=False)

    @tool(READ_ONLY_ANN)
    def read_file(
        path: Annotated[str, Field(description="File path to read.")],
        offset: Annotated[int, Field(description="1-based starting line number.", ge=1)] = 1,
        limit: Annotated[int, Field(description="Maximum number of lines to return.", ge=1, le=2000)] = 200,
    ) -> str:
        """Read a text file with line numbers and range slicing to save context."""
        target = normalize_path(path, get_effective_policy(config).roots)
        if err := check_access(target, config):
            return f"Error: {err}"
        if not target.is_file():
            return f"Error: Not a file or does not exist: {target}"

        try:
            text, _, _ = read_text_smart(target)
        except ValueError as exc:
            return f"Error: {exc}"

        lines = text.splitlines()
        total = len(lines)
        if total == 0:
            return f"File: {target} (empty file, 0 lines)"
        if offset > total:
            return f"Error: offset {offset} exceeds total lines ({total}) in {target}."

        end = min(total, offset + limit - 1)
        width = len(str(end))
        numbered = [f"{i:>{width}} | {lines[i - 1]}" for i in range(offset, end + 1)]
        body, truncated = truncate_head_tail("\n".join(numbered), config.max_read_chars)

        header = f"File: {target} (lines {offset}-{end} of {total})"
        footer = ""
        if end < total:
            footer = f"\n\n[More lines available: call read_file(path={json.dumps(str(target))}, offset={end + 1}, limit={limit})]"
        if truncated:
            footer += "\n[Output was character-truncated; use a smaller limit.]"
        return f"{header}\n{body}{footer}"

    @tool(READ_ONLY_ANN)
    def read_files(
        paths: Annotated[list[str], Field(description="List of file paths to read in one batch (max 20).")],
        max_lines_per_file: Annotated[int, Field(description="Max lines per file.", ge=1, le=500)] = 150,
    ) -> str:
        """Batch-read multiple files in a single tool call to reduce round-trips."""
        if len(paths) > 20:
            return "Error: Maximum 20 files per batch."
        chunks: list[str] = []
        total_chars = 0
        for p in paths:
            res = read_file(path=p, offset=1, limit=max_lines_per_file)
            if total_chars + len(res) > config.max_read_chars:
                chunks.append(f"=== {p} ===\n[Skipped: batch character budget reached; read individually]")
                continue
            chunks.append(res)
            total_chars += len(res)
        return "\n\n---\n\n".join(chunks)

    @tool(READ_ONLY_ANN)
    def list_dir(
        path: Annotated[str, Field(description="Directory path to list.")] = ".",
        max_depth: Annotated[int, Field(description="Directory traversal depth (1 = immediate children).", ge=1, le=6)] = 2,
        show_hidden: Annotated[bool, Field(description="Include dotfiles/hidden entries.")] = False,
        max_entries: Annotated[int, Field(description="Maximum entries to return.", ge=10, le=1000)] = 300,
    ) -> str:
        """List directory contents as a clean tree, skipping .git, node_modules, build, and .gitignore matches."""
        root = normalize_path(path, get_effective_policy(config).roots)
        if err := check_access(root, config):
            return f"Error: {err}"
        if not root.is_dir():
            return f"Error: Not a directory: {root}"

        gi_patterns = load_gitignore_patterns(root)
        lines: list[str] = [f"{root}/"]
        count = 0
        hit_limit = False

        def _walk(cur: Path, depth: int, prefix: str) -> None:
            nonlocal count, hit_limit
            if depth > max_depth or hit_limit:
                return
            try:
                entries = sorted(cur.iterdir(), key=lambda e: (not e.is_dir(), e.name.lower()))
            except PermissionError:
                lines.append(f"{prefix}[Permission Denied]")
                return

            visible = [e for e in entries if not is_ignored(e.relative_to(root), e.name, gi_patterns, show_hidden)]
            for idx, entry in enumerate(visible):
                if count >= max_entries:
                    hit_limit = True
                    return
                is_last = idx == len(visible) - 1
                connector = "└── " if is_last else "├── "
                child_prefix = prefix + ("    " if is_last else "│   ")
                count += 1
                if entry.is_dir():
                    lines.append(f"{prefix}{connector}{entry.name}/")
                    _walk(entry, depth + 1, child_prefix)
                else:
                    try:
                        lines.append(f"{prefix}{connector}{entry.name} ({entry.stat().st_size} B)")
                    except OSError:
                        lines.append(f"{prefix}{connector}{entry.name}")

        _walk(root, 1, "")
        if hit_limit:
            lines.append(f"\n[Truncated at {max_entries} entries. Narrow path or reduce max_depth.]")
        return "\n".join(lines)

    @tool(READ_ONLY_ANN)
    def glob_files(
        pattern: Annotated[str, Field(description="Glob pattern, e.g. '**/*.py' or 'src/*.kt'.")],
        path: Annotated[str, Field(description="Base directory to search from.")] = ".",
        max_results: Annotated[int, Field(description="Maximum matching paths to return.", ge=1, le=500)] = 200,
    ) -> str:
        """Find files matching a glob pattern while respecting default ignore directories."""
        root = normalize_path(path, get_effective_policy(config).roots)
        if err := check_access(root, config):
            return f"Error: {err}"
        if not root.is_dir():
            return f"Error: Not a directory: {root}"

        gi_patterns = load_gitignore_patterns(root)
        matches: list[str] = []
        for cur_root, dirs, files in os.walk(root):
            cur_path = Path(cur_root)
            rel_dir = cur_path.relative_to(root)
            dirs[:] = sorted(d for d in dirs if not is_ignored(rel_dir / d, d, gi_patterns, show_hidden=False))
            for fname in sorted(files):
                rel_file = rel_dir / fname
                if is_ignored(rel_file, fname, gi_patterns, show_hidden=False):
                    continue
                if fnmatch.fnmatch(rel_file.as_posix(), pattern) or fnmatch.fnmatch(fname, pattern):
                    fpath = cur_path / fname
                    if check_access(fpath, config) is None:
                        matches.append(str(fpath))
                        if len(matches) >= max_results:
                            break
            if len(matches) >= max_results:
                break

        if not matches:
            return f"No files matched '{pattern}' under {root}."
        suffix = f"\n[Showing first {max_results} matches]" if len(matches) >= max_results else ""
        return "\n".join(matches) + suffix

    @tool(READ_ONLY_ANN)
    def search_text(
        pattern: Annotated[str, Field(description="Search pattern (regex by default, or literal if regex=False).")],
        path: Annotated[str, Field(description="File or directory to search.")] = ".",
        glob: Annotated[str | None, Field(description="Optional file glob filter, e.g. '*.py' or '*.ts'.")] = None,
        case_sensitive: Annotated[bool, Field(description="Case-sensitive matching.")] = True,
        regex: Annotated[bool, Field(description="Treat pattern as regular expression.")] = True,
        context_lines: Annotated[int, Field(description="Number of context lines around each match.", ge=0, le=5)] = 0,
        max_results: Annotated[int, Field(description="Maximum matches to return.", ge=1, le=200)] = 50,
    ) -> str:
        """Search file contents (uses ripgrep if available, otherwise Python fallback)."""
        target = normalize_path(path, get_effective_policy(config).roots)
        if err := check_access(target, config):
            return f"Error: {err}"
        if not target.exists():
            return f"Error: Path does not exist: {target}"

        rg_bin = shutil.which("rg")
        if rg_bin:
            cmd = [rg_bin, "--line-number", "--no-heading", "--color", "never"]
            if not case_sensitive:
                cmd.append("--ignore-case")
            if not regex:
                cmd.append("--fixed-strings")
            if context_lines > 0:
                cmd.extend(["-C", str(context_lines)])
            if glob:
                cmd.extend(["--glob", glob])
            cmd.extend(["--max-count", str(max_results), pattern, str(target)])
            try:
                rg_kw: dict[str, Any] = {"capture_output": True, "timeout": 20, "check": False}
                if os.name == "nt":
                    rg_kw["creationflags"] = subprocess.CREATE_NO_WINDOW
                res = subprocess.run(cmd, **rg_kw)
                out = decode_bytes_smart(res.stdout).strip()
                if res.returncode == 1 or not out:
                    return f"No matches found for '{pattern}' in {target}."
                if res.returncode == 0:
                    lines = out.splitlines()
                    if len(lines) > max_results * (1 + 2 * context_lines):
                        lines = lines[: max_results * (1 + 2 * context_lines)]
                        lines.append("... [Truncated output; refine query or glob]")
                    return "\n".join(lines)
            except Exception:
                pass

        flags = 0 if case_sensitive else re.IGNORECASE
        expr = pattern if regex else re.escape(pattern)
        try:
            compiled = re.compile(expr, flags)
        except re.error as exc:
            return f"Error: Invalid regex '{pattern}': {exc}"

        files_to_scan: list[Path] = []
        if target.is_file():
            files_to_scan.append(target)
        else:
            gi_patterns = load_gitignore_patterns(target)
            for cur_root, dirs, files in os.walk(target):
                cur_p = Path(cur_root)
                rel_d = cur_p.relative_to(target)
                dirs[:] = sorted(d for d in dirs if not is_ignored(rel_d / d, d, gi_patterns, False))
                for fn in sorted(files):
                    if glob and not fnmatch.fnmatch(fn, glob):
                        continue
                    fp = cur_p / fn
                    if check_access(fp, config) is None:
                        files_to_scan.append(fp)

        hits: list[str] = []
        for fp in files_to_scan:
            try:
                text, _, _ = read_text_smart(fp)
            except Exception:
                continue
            file_lines = text.splitlines()
            for idx, line in enumerate(file_lines, start=1):
                if compiled.search(line):
                    if context_lines == 0:
                        hits.append(f"{fp}:{idx}:{line}")
                    else:
                        start_c = max(1, idx - context_lines)
                        end_c = min(len(file_lines), idx + context_lines)
                        hits.append(f"--- {fp}:{idx} ---")
                        for c_i in range(start_c, end_c + 1):
                            marker = ">" if c_i == idx else " "
                            hits.append(f"{marker} {c_i}: {file_lines[c_i - 1]}")
                    if len(hits) >= max_results * (1 + 2 * context_lines):
                        hits.append(f"... [Stopped after {max_results} matches]")
                        return "\n".join(hits)

        return "\n".join(hits) if hits else f"No matches found for '{pattern}' in {target}."

    has_writable_profile = any(
        p.get("enabled", True) and not (config.read_only if p.get("inherit_permissions", True) else p.get("read_only", False))
        for p in (config.profiles or [])
    )
    if config.read_only and not has_writable_profile:
        return

    @tool(SAFE_WRITE_ANN)
    def create_file(
        path: Annotated[str, Field(description="Target file path to create or overwrite.")],
        content: Annotated[str, Field(description="Full text content to write.")],
        overwrite: Annotated[bool, Field(description="Must be True to replace an existing file.")] = False,
    ) -> str:
        """Create a new file (creating parent directories automatically) or overwrite if overwrite=True."""
        target = normalize_path(path, get_effective_policy(config).roots)
        if err := check_access(target, config):
            return f"Error: {err}"
        if target.exists():
            if target.is_dir():
                return f"Error: Target is a directory: {target}"
            if not overwrite:
                return f"Error: File already exists: {target}. Pass overwrite=True or use edit_file."
            undo_store.save(target, "create_file(overwrite=True)")
        else:
            undo_store.save(target, "create_file(new)")

        written = write_text_preserving(target, content)
        return f"Written {written} bytes ({len(content.splitlines())} lines) to {target}."

    @tool(SAFE_WRITE_ANN)
    def edit_file(
        path: Annotated[str, Field(description="File path to edit.")],
        edits: Annotated[
            list[dict[str, Any]],
            Field(description="List of edit objects: [{'old_str': '...', 'new_str': '...', 'replace_all': False}]. Applied atomically."),
        ],
        dry_run: Annotated[bool, Field(description="Preview unified diff without modifying the file.")] = False,
    ) -> str:
        """Apply exact surgical text replacements to a file atomically, with close-match hints on failure."""
        target = normalize_path(path, get_effective_policy(config).roots)
        if err := check_access(target, config):
            return f"Error: {err}"
        if not target.is_file():
            return f"Error: File does not exist: {target}"

        try:
            orig_text, enc, nl = read_text_smart(target)
        except ValueError as exc:
            return f"Error: {exc}"

        working = orig_text.replace("\r\n", "\n")
        for idx, item in enumerate(edits, start=1):
            old_str = item.get("old_str")
            new_str = item.get("new_str")
            replace_all = bool(item.get("replace_all", False))
            if old_str is None or new_str is None:
                return f"Error: Edit #{idx} must contain 'old_str' and 'new_str'."

            old_norm = str(old_str).replace("\r\n", "\n")
            new_norm = str(new_str).replace("\r\n", "\n")
            count = working.count(old_norm)

            if count == 0:
                first_line = old_norm.splitlines()[0] if old_norm.splitlines() else old_norm
                file_lines = working.splitlines()
                close = difflib.get_close_matches(first_line, file_lines, n=3, cutoff=0.5)
                hint = ""
                if close:
                    hint_lines = [f"  line {file_lines.index(c) + 1}: {c}" for c in close]
                    hint = "\nClosest lines in file:\n" + "\n".join(hint_lines)
                return f"Error: Edit #{idx} 'old_str' not found in {target}.{hint}"

            if count > 1 and not replace_all:
                return (
                    f"Error: Edit #{idx} 'old_str' matched {count} times in {target}. "
                    "Include more surrounding context to make it unique, or set replace_all=True."
                )

            working = working.replace(old_norm, new_norm) if replace_all else working.replace(old_norm, new_norm, 1)

        diff_preview = make_unified_diff(orig_text.replace("\r\n", "\n"), working, target)
        if dry_run:
            return f"[DRY RUN] Diff for {target}:\n{diff_preview or '(no changes)'}"

        undo_store.save(target, f"edit_file({len(edits)} edits)")
        write_text_preserving(target, working, encoding=enc, newline=nl)
        return f"Successfully applied {len(edits)} edit(s) to {target}.\n{diff_preview}"

    @tool(SAFE_WRITE_ANN)
    def apply_patch(
        path: Annotated[str, Field(description="Target file path to patch.")],
        unified_diff: Annotated[str, Field(description="Unified diff text containing @@ hunks.")],
        dry_run: Annotated[bool, Field(description="Preview result without writing to disk.")] = False,
    ) -> str:
        """Apply a unified diff patch to a file with optional dry-run preview."""
        target = normalize_path(path, get_effective_policy(config).roots)
        if err := check_access(target, config):
            return f"Error: {err}"
        if not target.is_file():
            return f"Error: File does not exist: {target}"

        try:
            orig_text, enc, nl = read_text_smart(target)
            patched = apply_unified_diff_text(orig_text.replace("\r\n", "\n"), unified_diff)
        except ValueError as exc:
            return f"Error: {exc}"

        diff_preview = make_unified_diff(orig_text.replace("\r\n", "\n"), patched, target)
        if dry_run:
            return f"[DRY RUN] Patch preview for {target}:\n{diff_preview or '(no changes)'}"

        undo_store.save(target, "apply_patch")
        write_text_preserving(target, patched, encoding=enc, newline=nl)
        return f"Patch applied to {target}.\n{diff_preview}"

    @tool(DESTRUCTIVE_ANN)
    def replace_text(
        pattern: Annotated[str, Field(description="Text or regex pattern to replace.")],
        replacement: Annotated[str, Field(description="Replacement string.")],
        path: Annotated[str, Field(description="File or directory to process.")] = ".",
        glob: Annotated[str | None, Field(description="Optional file glob filter, e.g. '*.py'.")] = None,
        regex: Annotated[bool, Field(description="Treat pattern as regular expression.")] = False,
        case_sensitive: Annotated[bool, Field(description="Case-sensitive match.")] = True,
        dry_run: Annotated[bool, Field(description="Preview changes across files without modifying disk.")] = False,
        max_files: Annotated[int, Field(description="Safety cap on modified files.", ge=1, le=200)] = 50,
    ) -> str:
        """Find and replace text across one or multiple files, with dry-run diff preview."""
        target = normalize_path(path, get_effective_policy(config).roots)
        if err := check_access(target, config):
            return f"Error: {err}"
        if not target.exists():
            return f"Error: Path does not exist: {target}"

        flags = 0 if case_sensitive else re.IGNORECASE
        expr = pattern if regex else re.escape(pattern)
        try:
            compiled = re.compile(expr, flags)
        except re.error as exc:
            return f"Error: Invalid regex '{pattern}': {exc}"

        candidates: list[Path] = []
        if target.is_file():
            candidates.append(target)
        else:
            gi_patterns = load_gitignore_patterns(target)
            for cur_root, dirs, files in os.walk(target):
                cur_p = Path(cur_root)
                rel_d = cur_p.relative_to(target)
                dirs[:] = sorted(d for d in dirs if not is_ignored(rel_d / d, d, gi_patterns, False))
                for fn in sorted(files):
                    if glob and not fnmatch.fnmatch(fn, glob):
                        continue
                    fp = cur_p / fn
                    if check_access(fp, config) is None:
                        candidates.append(fp)

        changed_reports: list[str] = []
        modified_files = 0
        for fp in candidates:
            try:
                orig_text, enc, nl = read_text_smart(fp)
            except Exception:
                continue
            new_text, count = compiled.subn(replacement, orig_text.replace("\r\n", "\n"))
            if count > 0:
                modified_files += 1
                if modified_files > max_files:
                    changed_reports.append(f"[Stopped: exceeded max_files={max_files}]")
                    break
                if not dry_run:
                    undo_store.save(fp, f"replace_text({pattern})")
                    write_text_preserving(fp, new_text, encoding=enc, newline=nl)
                changed_reports.append(f"{fp}: {count} replacement(s)")

        if not changed_reports:
            return f"No occurrences of '{pattern}' found in {target}."
        prefix = "[DRY RUN] " if dry_run else ""
        return f"{prefix}Updated {len(changed_reports)} file(s):\n" + "\n".join(changed_reports)

    @tool(DESTRUCTIVE_ANN)
    def file_op(
        action: Annotated[Literal["move", "copy", "delete"], Field(description="Operation to perform.")],
        src: Annotated[str, Field(description="Source file or directory path.")],
        dst: Annotated[str | None, Field(description="Destination path (required for move/copy).")] = None,
        overwrite: Annotated[bool, Field(description="Allow overwriting destination if it exists.")] = False,
    ) -> str:
        """Move, copy, or delete a file or directory safely."""
        src_path = normalize_path(src, get_effective_policy(config).roots)
        if err := check_access(src_path, config):
            return f"Error: {err}"
        if not src_path.exists():
            return f"Error: Source does not exist: {src_path}"

        if action == "delete":
            if src_path.is_file():
                undo_store.save(src_path, "file_op(delete)")
                src_path.unlink()
                return f"Deleted file: {src_path} (undoable via undo_edit)."
            shutil.rmtree(src_path)
            return f"Deleted directory: {src_path}"

        if not dst:
            return f"Error: 'dst' is required for action='{action}'."
        dst_path = normalize_path(dst, get_effective_policy(config).roots)
        if err := check_access(dst_path, config):
            return f"Error: {err}"
        if dst_path.exists() and not overwrite:
            return f"Error: Destination exists: {dst_path}. Set overwrite=True to replace."

        dst_path.parent.mkdir(parents=True, exist_ok=True)
        if dst_path.is_file() and overwrite:
            undo_store.save(dst_path, f"file_op({action}, overwrite)")

        if action == "move":
            if dst_path.exists():
                if dst_path.is_dir():
                    shutil.rmtree(dst_path)
                else:
                    dst_path.unlink()
            shutil.move(str(src_path), str(dst_path))
            return f"Moved {src_path} -> {dst_path}"

        if src_path.is_dir():
            shutil.copytree(src_path, dst_path, dirs_exist_ok=overwrite)
        else:
            shutil.copy2(src_path, dst_path)
        return f"Copied {src_path} -> {dst_path}"

    @tool(SAFE_WRITE_ANN)
    def undo_edit(
        path: Annotated[str, Field(description="File path to restore to its previous version.")],
    ) -> str:
        """Undo the most recent create/edit/patch/delete operation on a file."""
        target = normalize_path(path, get_effective_policy(config).roots)
        if err := check_access(target, config):
            return f"Error: {err}"
        snap = undo_store.pop(target)
        if snap is None:
            return f"Error: No undo history available for {target}."
        existed, data, note = snap
        if not existed:
            if target.exists() and target.is_file():
                target.unlink()
            return f"Undid '{note}': removed newly created {target}."
        assert data is not None
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        return f"Undid '{note}': restored {target} ({len(data)} bytes)."
