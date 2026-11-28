# Agent MCP v3.5.8

[中文](README.md) | [English](README.en.md)

[![Release](https://img.shields.io/github/v/release/iamr0s/agent-mcp?color=D97757&label=Release)](https://github.com/iamr0s/agent-mcp/releases)
[![Flutter 3.50+](https://img.shields.io/badge/Flutter-3.50%2B%20%7C%20Dart%20Native-02569B.svg)](https://flutter.dev/)
[![MCP 2025-03-26](https://img.shields.io/badge/Protocol-Streamable%20HTTP%20%2B%20SSE%20%2B%20stdio-3D8B63.svg)](https://modelcontextprotocol.io/)
[![Platform](https://img.shields.io/badge/Nodes-Linux%20Server%20%7C%20Android%20%7C%20Windows%20%7C%20SDK-141413.svg)](#downloads--installation)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

> **A zero-dependency native MCP execution node & Sub-MCP bastion you install on Linux servers, remote workstations, and Android phones — ready to be invoked from your computer's AI clients or your own code.**
>
> Local coding assistants already handle files on your laptop. The real friction starts when your workloads live on **headless Linux cloud servers, GPU boxes, NAS appliances, secondary Windows machines, or real Android test phones** where `localhost` `stdio` tools cannot reach.
>
> Built natively with **Dart & Flutter** (zero Python / Node.js runtime dependencies), **Agent MCP v3.5.8** drops onto any server, workstation, or Android device and exposes 22 surgical file, process, clipboard/screen, Universal Sub-MCP OAuth 2.1 hub, and instant link-sharing + **zero-token HTTP binary upload/download (`manage_expose`)** tools over standard **Streamable HTTP (`/mcp`) + SSE** with built-in **OAuth 2.1 (RFC 7591 + PKCE)**, **Bearer API keys**, and **Tailscale / Playit.gg** integration.

<p align="center">
  <img src="assets/previews/hero_overview.png" width="96%" alt="Agent MCP v3.5.8 Cross-Device Execution Node Overview">
</p>

## Downloads & Installation

Public [GitHub Releases](https://github.com/iamr0s/agent-mcp/releases) publish release changelogs and the `version.json` update index only. Download prebuilt multi-platform installers from any of the **four cloud-drive mirrors (`Agent MCP` folder)** below, or sign in to GitHub and download build artifacts directly from [**GitHub Actions**](https://github.com/iamr0s/agent-mcp/actions):

| Download Channel | Mirror Link | Access Code | Notes |
| :--- | :--- | :--- | :--- |
| **Quark Drive (夸克网盘)** | [Open `pan.quark.cn`](https://pan.quark.cn/s/ddb857fbeed4) | `6ERK` | Permanent `Agent MCP` folder with all platform packages |
| **UC Drive (UC网盘)** | [Open `drive.uc.cn`](https://drive.uc.cn/s/5a71a271af734) | `3azb` | Permanent `Agent MCP` folder, unthrottled download |
| **China Mobile Cloud (移动云盘)** | [Open `yun.139.com`](https://yun.139.com/shareweb/#/w/i/2yA8NTUbbXcav) | None | Password-free permanent `Agent MCP` folder |
| **Baidu Netdisk (百度网盘)** | [Open `pan.baidu.com`](https://pan.baidu.com/s/1_M-n0m-lnR8ddHMEakcfvw?pwd=j2zq) | `j2zq` | Permanent `Agent MCP` folder (code pre-filled in URL) |
| **GitHub Actions** | [Open Actions Artifacts](https://github.com/iamr0s/agent-mcp/actions) | GitHub Login | Download directly from the latest `Build & Publish Releases` workflow run |

<details>
<summary><b>View Cloud-Drive Folder Layout & Multi-Platform Package Matrix (windows / macos / linux / android → x64 / arm64)</b></summary>

<br>

| Target Platform | Folder Path & Release Asset | Description |
| :--- | :--- | :--- |
| **Windows 10 / 11 (x64 Installer)** | `windows/x64/AgentMCP-v3.5.8-windows-x64-sfx.exe` | Native Dart/Flutter `--installer` Prism setup wizard + Desktop Console + Web UI + `agent-mcp.exe` CLI |
| **Windows 10 / 11 (x64 Portable)** | `windows/x64/AgentMCP-v3.5.8-windows-x64-portable.zip` | Portable archive storing config & logs locally (`windows/x64/*-cli.zip` & `windows/arm64/*-cli.zip` also included) |
| **macOS Desktop (Apple Silicon)** | `macos/arm64/AgentMCP-v3.5.8-macos-arm64.dmg` | Native macOS desktop `.dmg` (`*-app.zip` & `*-cli.tar.gz` in same folder) |
| **macOS Desktop (Intel x64)** | `macos/x64/AgentMCP-v3.5.8-macos-x64.dmg` | Native Intel Mac desktop `.dmg` installer (`*-app.zip` & `*-cli.tar.gz` in same folder) |
| **Linux Desktop (x64 / ARM64 GUI)** | `linux/x64/AgentMCP-v3.5.8-linux-x64-gui.tar.gz` | Native GTK3 desktop GUI + `agent-mcp` CLI + `install-desktop.sh` (ARM64 under `linux/arm64/`) |
| **Linux Server / NAS (Headless CLI)** | `linux/x64/AgentMCP-v3.5.8-linux-x64-cli.tar.gz` | Standalone native `agent-mcp` binary + bundled `web_dashboard/` UI + `systemd` installer (ARM64 under `linux/arm64/`) |
| **Android (ARM64 Recommended)** | `android/arm64-v8a/AgentMCP-v3.5.8-android-arm64-v8a.apk` | Release-signed dual-mode remote multi-node controller + 3-tier local MCP server (`armeabi-v7a` & `x86_64` in sibling folders) |
| **Android (Universal)** | `android/universal/AgentMCP-v3.5.8-android-universal.apk` | Release-signed multi-ABI APK (`arm64-v8a`, `armeabi-v7a`, `x86_64`) |

</details>

## Sponsor & Support

If Agent MCP helps your cross-device engineering and AI workflows, optional tips are warmly appreciated!

<p align="center">
  <img src="assets/donation/alipay.jpg" width="200" alt="Alipay">
  <img src="assets/donation/wxpay.jpg" width="200" alt="WeChat Pay">
  <img src="assets/donation/binance.jpg" width="200" alt="Binance Pay">
</p>

<p align="center">Alipay · WeChat Pay · Binance Pay</p>

## 60-Second Cross-Device Quickstart

### 1. Deploy on a Headless Linux Server / GPU Host / NAS

```bash
# 1. Download the archive from a mirror listed on GitHub Releases & extract (includes `agent-mcp` binary and `/dashboard/` Web UI)
tar -xzf AgentMCP-v3.5.8-linux-x64-cli.tar.gz

# 2. One-line non-interactive setup (auto-detects LAN & Tailscale 100.x IPs + generates Bearer key)
./agent-mcp init --name gpu-server-01 --host 0.0.0.0 -p 8778 --auth bearer --generate-key

# 3. Install & start persistent Linux systemd service
./agent-mcp service install
```

Open `http://<server-ip>:8778/dashboard/` in any browser to manage profiles, live call streams, Sub-MCPs, and external shares visually.

### 2. Call Remotely from Your Computer's AI Client or Your Own Python / TS Code

**Option A — Connect Claude Code / Cursor / Windsurf / Antigravity to your remote server or phone:**

```json
{
  "mcpServers": {
    "gpu-server-01": {
      "url": "http://100.88.12.5:8778/mcp",
      "headers": {
        "Authorization": "Bearer sk-mcp-YOUR_KEY"
      }
    }
  }
}
```

**Option B — Call programmatically via Official Python MCP SDK (`pip install mcp`):**

```python
import asyncio
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

async def main():
    url = "http://100.88.12.5:8778/mcp"  # Linux server, Windows workstation, or Android phone
    headers = {"Authorization": "Bearer sk-mcp-YOUR_KEY"}

    async with streamablehttp_client(url, headers=headers) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            res = await session.call_tool("run_command", {"command": "nvidia-smi -L"})
            print(res.content[0].text)

asyncio.run(main())
```

**Option C — Direct CLI health check & remote invocation:**

```bash
agent-mcp remote http://100.88.12.5:8778 ping
agent-mcp remote http://100.88.12.5:8778 call list_roots '{}' -k sk-mcp-YOUR_KEY
```

## Highlights

- **4-Mode External Sharing (`file` | `folder` | `site` | `port`)**: Share (1) **Single Files** with HTTP `206 Range` media streaming (including >32MB Android Shizuku/Root streamed ranges), optional **PIN access codes**, and **`max_downloads` burn-after-download quotas**, (2) **Folder Directories** with breadcrumbs, 64KB zero-buffering `?zip=1` streaming PKZIP downloads, symlink-escape guards, and contextual **previous/next sibling navigation** inside single-file previews, (3) **Static Websites / Single `.html` Files** rendered full-screen, and (4) **Full-Duplex Port Forwarding** with native **`Upgrade: websocket` tunneling** for Vite / Next.js HMR, Gradio, and Jupyter, plus desktop drag-and-drop.
- **Universal Sub-MCP OAuth 2.1 Hub & Visual Playground**: Connect any upstream `auto` (Streamable HTTP -> SSE fallback), `stdio`, `http`, `sse`, or `ws` Sub-MCP with full OAuth 2.1 (`S256` PKCE, RFC 9728 PRM, CIMD, RFC 7591 DCR, silent refresh), M2M Client Credentials, Bearer, API Key, or Basic auth; toggle between 3-tool `gateway` bastion mode (`-96%` schema tokens) and `direct` (`<subname>__<tool>`) mounting, or test live `tools`/`resources`/`prompts` in the built-in Playground.
- **Switch-Driven Wildcard Whitelists & 1-Click Client Onboarding**: Master allow-all toggles (default ON) with row-by-row `*`/`**`/`?` glob editors for both OAuth redirect URIs and directory root whitelists, offline zero-leak vector QR codes, persistent + bi-directional upload folder shares, PBKDF2 encrypted config snapshots, and 1-click config injection into Claude Desktop, Cursor, VS Code, Windsurf, and Claude Code CLI.
- **Multi-NIC IP Picker & Per-Profile Isolation**: Multi-select LAN and Tailscale `100.x` IPs plus custom reverse-proxy URLs per profile, each with independent OAuth 2.1 / Bearer auth, read-only flags, and root whitelists.
- **Android Dual-Mode APK**: Control multiple remote Linux/Windows servers on the go, OR run an on-device wireless MCP server with 3 switchable privilege tiers (**App Sandbox**, **Shizuku ADB/Root**, and **Persistent Root SU Daemon** for KernelSU / APatch / Magisk) and foreground lock-screen keep-alive.

## License

Licensed under the GNU General Public License v3.0 — see [LICENSE](LICENSE).
