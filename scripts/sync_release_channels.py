#!/usr/bin/env python3
"""Synchronize multi-channel cloud-drive links to GitHub Release & version.json,
or pull compiled CI multi-platform bundles into a local staging folder.

Usage examples:
  1. Download all compiled CI artifacts for v3.5.7 into cloud_drive_upload/v3.5.7:
     python scripts/sync_release_channels.py --download-ci-bundle v3.5.7

  2. Update release_channels.json with cloud-drive links, then push updated
     version.json + Release Notes to GitHub Release v3.5.7:
     python scripts/sync_release_channels.py --apply v3.5.7
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile

REPO = "iamr0s/agent-mcp"
ROOT = pathlib.Path(__file__).resolve().parent.parent


class _StripAuthOnCrossOriginRedirect(urllib.request.HTTPRedirectHandler):
    """GitHub Actions artifact downloads 302-redirect to Azure Blob Storage;
    forwarding GitHub's Authorization header to blob.core.windows.net fails."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new_req = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new_req is None:
            return None
        orig_host = urllib.request.urlparse(req.full_url).hostname or ""
        next_host = urllib.request.urlparse(newurl).hostname or ""
        if orig_host.lower() != next_host.lower():
            new_req.headers.pop("Authorization", None)
            new_req.unredirected_hdrs.pop("Authorization", None)
        return new_req


def _get_github_token() -> str:
    env_tok = (os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or "").strip()
    if env_tok:
        return env_tok
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"
    proc = subprocess.run(
        ["git", "credential", "fill"],
        input=f"protocol=https\nhost=github.com\npath={REPO}.git\n\n",
        text=True,
        capture_output=True,
        cwd=str(ROOT),
        env=env,
        timeout=15,
        check=False,
    )
    for line in proc.stdout.splitlines():
        if line.startswith("password="):
            tok = line.split("=", 1)[1].strip()
            if tok:
                return tok
    raise RuntimeError("Unable to obtain GitHub token from GITHUB_TOKEN or git credential fill.")


def _gh_request(
    method: str,
    url: str,
    token: str,
    data: bytes | None = None,
    content_type: str = "application/json",
    accept: str = "application/vnd.github+json",
) -> tuple[int, bytes]:
    opener = urllib.request.build_opener(_StripAuthOnCrossOriginRedirect)
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": accept,
        "User-Agent": "Agent-MCP-Release-Sync",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if data is not None:
        headers["Content-Type"] = content_type
    last_exc: Exception | None = None
    for attempt in range(1, 5):
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with opener.open(req, timeout=120) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as err:
            body = err.read()
            if err.code in (502, 503, 504) and attempt < 4:
                time.sleep(0.8 * attempt)
                continue
            raise RuntimeError(f"GitHub HTTP {err.code} on {method} {url}: {body[:400]!r}") from err
        except Exception as exc:
            last_exc = exc
            if attempt < 4:
                time.sleep(0.9 * attempt)
                continue
            raise
    raise RuntimeError(f"Request failed on {method} {url}: {last_exc}")


def load_channel_config() -> dict:
    cfg_path = ROOT / "release_channels.json"
    if not cfg_path.is_file():
        return {
            "publish_github_binaries": False,
            "enable_one_click_github_assets": False,
            "legacy_redirect_target": "primary_channel",
            "channels": [],
            "custom_assets": {},
        }
    return json.loads(cfg_path.read_text(encoding="utf-8"))


def normalize_channels(raw_channels: list) -> list[dict]:
    normalized: list[dict] = []
    for idx, item in enumerate(raw_channels or []):
        if not isinstance(item, dict):
            continue
        name = str(item.get("name") or item.get("label") or "").strip()
        url = str(item.get("url") or item.get("href") or "").strip()
        if not name or not url:
            continue
        cid = str(item.get("id") or f"channel_{idx}").strip()
        code = str(item.get("code") or item.get("extract_code") or "").strip()
        badge = str(item.get("badge") or "").strip()
        subtitle = str(item.get("subtitle") or item.get("desc") or "").strip()
        platforms = item.get("platforms") or ["all"]
        if isinstance(platforms, str):
            platforms = [p.strip() for p in platforms.split(",") if p.strip()] or ["all"]
        entry: dict = {
            "id": cid,
            "name": name,
            "url": url,
            "platforms": platforms,
        }
        if code:
            entry["code"] = code
        if badge:
            entry["badge"] = badge
        if subtitle:
            entry["subtitle"] = subtitle
        normalized.append(entry)
    return normalized


def extract_changelog_section(tag: str) -> tuple[str, str]:
    ver = tag.lstrip("vV")
    release_title = f"Agent MCP {tag}"
    notes_body = ""
    cl_path = ROOT / "CHANGELOG.md"
    if cl_path.is_file():
        lines = cl_path.read_text(encoding="utf-8").replace("\r\n", "\n").splitlines()
        hdr_re = re.compile(rf"^##\s+\[?v?{re.escape(ver)}\]?(?:\s*[—\-:]\s*(.+))?$")
        body_lines: list[str] = []
        in_sec = False
        for ln in lines:
            if not in_sec:
                m = hdr_re.match(ln.strip())
                if m:
                    in_sec = True
                    sub = (m.group(1) or "").strip()
                    if sub:
                        release_title = f"Agent MCP {tag} — {sub}"
            else:
                if re.match(r"^##\s+\[?v?\d", ln.strip()):
                    break
                body_lines.append(ln)
        notes_body = "\n".join(body_lines).strip()
    if not notes_body:
        notes_body = f"- Agent MCP {tag} 全平台桌面 GUI、移动端与 CLI 正式版更新。"
    return release_title, notes_body


def build_manifest_and_notes(
    tag: str,
    cfg: dict,
    published_at: str | None = None,
    computed_assets: dict | None = None,
) -> tuple[str, dict, str]:
    ver = tag.lstrip("vV")
    ver_parts = [int(p) if p.isdigit() else 0 for p in (ver.split(".") + ["0", "0", "0"])[:3]]
    build_num = ver_parts[0] * 1000 + ver_parts[1] * 100 + ver_parts[2]

    release_title, notes_body = extract_changelog_section(tag)
    channels = normalize_channels(cfg.get("channels") or [])
    gh_release_url = f"https://github.com/{REPO}/releases/tag/{tag}"

    legacy_target = str(cfg.get("legacy_redirect_target") or "primary_channel").strip().lower()
    if legacy_target == "primary_channel" and channels:
        release_url = channels[0]["url"]
    else:
        release_url = gh_release_url

    manifest_assets: dict = {}
    if cfg.get("publish_github_binaries") or cfg.get("enable_one_click_github_assets"):
        if computed_assets:
            manifest_assets.update(computed_assets)
    custom_assets = cfg.get("custom_assets")
    if isinstance(custom_assets, dict):
        for k, v in custom_assets.items():
            if isinstance(v, dict) and str(v.get("url") or "").strip():
                manifest_assets[str(k)] = v

    notes_prefix_lines: list[str] = []
    if channels:
        notes_prefix_lines.append("【多渠道下载说明】")
        for ch in channels:
            code_part = f"（提取码: {ch['code']}）" if ch.get("code") else ""
            badge_part = f" [{ch['badge']}]" if ch.get("badge") else ""
            notes_prefix_lines.append(f"• {ch['name']}{badge_part}{code_part}：{ch['url']}")
        notes_prefix_lines.append("")

    combined_notes = (
        f"{release_title}\n"
        + ("\n".join(notes_prefix_lines) + "\n" if notes_prefix_lines else "")
        + notes_body
    ).strip()

    pub_iso = published_at or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    manifest = {
        "version": ver,
        "tag": tag,
        "build": build_num,
        "published_at": pub_iso,
        "release_url": release_url,
        "github_release_url": gh_release_url,
        "download_channels": channels,
        "notes": combined_notes,
        "assets": manifest_assets,
    }

    md_parts = [f"## 更新亮点 / What's New\n\n{notes_body}"]
    if channels:
        table = [
            "### 多渠道下载 / Download Channels",
            "",
            "| 下载渠道 / Channel | 适用范围 / Scope | 提取码 / Access Code | 获取链接 / Link |",
            "| :--- | :--- | :--- | :--- |",
        ]
        for ch in channels:
            badge_str = f" `{ch['badge']}`" if ch.get("badge") else ""
            scope = ch.get("subtitle") or ", ".join(ch.get("platforms") or ["all"])
            code_cell = f"`{ch['code']}`" if ch.get("code") else "免提取码 / None"
            table.append(
                f"| **{ch['name']}**{badge_str} | {scope} | {code_cell} | [立即前往 / Open]({ch['url']}) |"
            )
        md_parts.append("\n".join(table))

    return release_title, manifest, "\n\n".join(md_parts) + "\n"


def apply_to_github_release(tag: str) -> None:
    token = _get_github_token()
    cfg = load_channel_config()

    _, raw_rel = _gh_request(
        "GET",
        f"https://api.github.com/repos/{REPO}/releases/tags/{tag}",
        token,
    )
    rel = json.loads(raw_rel.decode("utf-8"))
    release_id = rel["id"]
    published_at = rel.get("published_at") or None

    release_title, manifest, release_md = build_manifest_and_notes(
        tag=tag,
        cfg=cfg,
        published_at=published_at,
    )

    patch_payload = json.dumps(
        {
            "name": release_title,
            "body": release_md,
        },
        ensure_ascii=False,
    ).encode("utf-8")
    _gh_request(
        "PATCH",
        f"https://api.github.com/repos/{REPO}/releases/{release_id}",
        token,
        data=patch_payload,
    )

    for asset in rel.get("assets") or []:
        if asset.get("name") == "version.json":
            _gh_request(
                "DELETE",
                f"https://api.github.com/repos/{REPO}/releases/assets/{asset['id']}",
                token,
            )

    version_bytes = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    _gh_request(
        "POST",
        f"https://uploads.github.com/repos/{REPO}/releases/{release_id}/assets?name=version.json",
        token,
        data=version_bytes,
        content_type="application/json",
    )
    print(
        f"[OK] Synced GitHub Release {tag} (id={release_id}): "
        f"channels={len(manifest['download_channels'])}, "
        f"release_url={manifest['release_url']}"
    )


def download_ci_bundle(tag: str, out_dir: pathlib.Path) -> None:
    token = _get_github_token()
    _, raw_runs = _gh_request(
        "GET",
        f"https://api.github.com/repos/{REPO}/actions/runs?per_page=20",
        token,
    )
    runs = json.loads(raw_runs.decode("utf-8")).get("workflow_runs") or []
    target_run = None
    for r in runs:
        if r.get("head_branch") == tag or (r.get("display_title") or "").strip() == tag:
            if r.get("status") == "completed":
                target_run = r
                break
    if target_run is None:
        raise RuntimeError(f"No completed GitHub Actions workflow run found for {tag}.")

    run_id = target_run["id"]
    _, raw_arts = _gh_request(
        "GET",
        f"https://api.github.com/repos/{REPO}/actions/runs/{run_id}/artifacts?per_page=50",
        token,
    )
    artifacts = json.loads(raw_arts.decode("utf-8")).get("artifacts") or []
    if not artifacts:
        raise RuntimeError(f"Workflow run {run_id} for {tag} has no uploaded artifacts.")

    out_dir.mkdir(parents=True, exist_ok=True)
    extracted_files: list[pathlib.Path] = []

    for art in artifacts:
        if art.get("expired"):
            continue
        art_name = str(art.get("name") or "")
        if "artifact" not in art_name.lower():
            continue
        print(f"[DL] Fetching CI artifact '{art_name}'...")
        _, zip_bytes = _gh_request(
            "GET",
            art["archive_download_url"],
            token,
            accept="application/vnd.github+json",
        )
        with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zf:
            for member in zf.infolist():
                if member.is_dir():
                    continue
                fname = pathlib.Path(member.filename).name
                if not (fname.startswith("AgentMCP-") or fname == "SHA256SUMS.txt"):
                    continue
                dest = out_dir / fname
                with zf.open(member, "r") as src, dest.open("wb") as dst:
                    shutil.copyfileobj(src, dst)
                extracted_files.append(dest)

    checksum_lines: list[str] = []
    for pkg in sorted(out_dir.glob("AgentMCP-*")):
        if not pkg.is_file():
            continue
        h = hashlib.sha256()
        with pkg.open("rb") as fp:
            for chunk in iter(lambda: fp.read(65536), b""):
                h.update(chunk)
        checksum_lines.append(f"{h.hexdigest()}  {pkg.name}")

    if checksum_lines:
        (out_dir / "SHA256SUMS.txt").write_text("\n".join(checksum_lines) + "\n", encoding="utf-8")

    print(f"[OK] Unpacked {len(extracted_files)} files into {out_dir}:")
    for f in sorted(out_dir.iterdir()):
        if f.is_file():
            mb = f.stat().st_size / (1024 * 1024)
            print(f"  - {f.name} ({mb:.2f} MB)")


def main() -> int:
    parser = argparse.ArgumentParser(description="Sync multi-channel cloud-drive links & CI bundles.")
    parser.add_argument("--apply", metavar="TAG", help="Update GitHub Release notes & version.json for TAG")
    parser.add_argument(
        "--download-ci-bundle",
        metavar="TAG",
        help="Download all multi-platform CI packages for TAG into local cloud_drive_upload/<TAG>",
    )
    parser.add_argument(
        "--out-dir",
        help="Optional custom output directory for --download-ci-bundle",
    )
    args = parser.parse_args()

    if not args.apply and not args.download_ci_bundle:
        parser.print_help()
        return 1

    if args.download_ci_bundle:
        tag = args.download_ci_bundle.strip()
        if not tag.startswith("v"):
            tag = f"v{tag}"
        dest = pathlib.Path(args.out_dir) if args.out_dir else (ROOT / "cloud_drive_upload" / tag)
        download_ci_bundle(tag, dest)

    if args.apply:
        tag = args.apply.strip()
        if not tag.startswith("v"):
            tag = f"v{tag}"
        apply_to_github_release(tag)

    return 0


if __name__ == "__main__":
    sys.exit(main())
