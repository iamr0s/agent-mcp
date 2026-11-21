# Agent MCP v2.0

[中文](README.md) | English

[![Release](https://img.shields.io/github/v/release/iamr0s/agent-mcp?color=D97757&label=Release)](https://github.com/iamr0s/agent-mcp/releases)
[![Flutter 3.50+](https://img.shields.io/badge/Flutter-3.50%2B%20%7C%20Dart%20Native-02569B.svg)](https://flutter.dev/)
[![MCP 2025-03-26](https://img.shields.io/badge/Protocol-Streamable%20HTTP%20%2B%20SSE%20%2B%20stdio-4D7C5D.svg)](https://modelcontextprotocol.io/)
[![Platform](https://img.shields.io/badge/Platform-Windows%2011%20%7C%20Android%20%7C%20Web%20%7C%20CLI-141413.svg)](#downloads)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

> **Give AI real hands on your workspace—while keeping every switch and permission boundary on your own device.**
>
> Built natively with **Dart & Flutter** with zero Python/Node dependencies, **Agent MCP v2.0** lets Gemini, Claude, Cursor, and Codex edit code surgically, run terminal builds, route dozens of Sub-MCP servers on demand, **instantly share generated videos or local web ports via Tailscale & public links (`manage_expose`)**, and control everything from **Windows 11**, **Web**, **CLI**, or an **Android Dual-Mode app**.

<p align="center">
  <img src="assets/previews/hero_overview.png" width="94%" alt="Agent MCP v2.0 Overview">
</p>

## Visual Tour

<table>
  <tr>
    <td width="50%">
      <img src="assets/previews/activity_and_submcp.png" alt="Live Activity & Sub-MCP Gateway">
      <p align="center"><sub><b>Live Call Stream & On-Demand Sub-MCP Gateway</b></sub></p>
    </td>
    <td width="50%">
      <img src="assets/previews/multi_ip_and_profiles.png" alt="Multi-IP Picker & Tailscale Share Controls">
      <p align="center"><sub><b>Multi-NIC Picker & Tailscale External Share Controls</b></sub></p>
    </td>
  </tr>
  <tr>
    <td colspan="2">
      <p align="center">
        <img src="assets/previews/android_privilege_modes.png" width="88%" alt="Android Dual-Mode App">
      </p>
      <p align="center"><sub><b>Android Dual-Mode App: Remote Multi-PC Controller + Local Sandbox / Shizuku / Root SU</b></sub></p>
    </td>
  </tr>
</table>

## What You Can Do & How to Use It

1. **Edit Files, Run Commands & Undo in One Step (20 Built-in Tools)**: Connect your AI client and ask directly—surgical `edit_file` / `apply_patch` edits with `undo_edit` snapshots, plus `run_command` / `start_process` / `manage_process` for builds and dev servers.
2. **Instant External Sharing with Tailscale (`manage_expose` + Share Tab)**: Just generated an MP4 video or started a site on `:3000`? Ask AI to expose it—or click **+ New Share** in the **External Share** tab—to get an instant mobile-ready link (with HTTP Range video scrubbing) over Tailscale, your active gateway domain, or a temporary Cloudflare HTTPS tunnel. Toggle master access and Tailscale mode anytime in **Settings**.
3. **Multi-NIC Direct Picker & Per-Profile Auth**: Select LAN and Tailscale IPs side-by-side when editing a Direct/Reverse-Proxy profile, auto-sync unbound NIC listeners on save, and copy any channel URL from the dropdown menu.
4. **Zero-Bloat Sub-MCP Gateway**: Paste your existing `mcpServers` JSON into the **Sub-MCP Gateway** tab. Only 3 compact tools (`list_sub_mcps`, `inspect_sub_mcp`, `call_sub_mcp`) are exposed upfront so context stays fast and clean.
5. **Android Dual-Mode APK**: Switch between remote desktop nodes from the top bar, or run a local MCP server on your phone with one-tap switching across **App Sandbox**, **Shizuku (Wireless ADB / Root)**, and **Root SU (KernelSU / APatch / Magisk)**.

## Downloads

Grab the latest release from [**GitHub Releases**](https://github.com/iamr0s/agent-mcp/releases):
- **Windows 10/11 (`x64`)**: `AgentMCP-v2.0.0-windows-x64-sfx.exe` (installer wizard) or `AgentMCP-v2.0.0-windows-x64-portable.zip`.
- **Android**: `AgentMCP-v2.0.0-android-arm64-v8a.apk` (recommended for modern phones) or `AgentMCP-v2.0.0-android-universal.apk`.
- **Linux (`x64` CLI)**: `AgentMCP-v2.0.0-linux-x64-cli.tar.gz`.

## CLI Quickstart

```bash
agent-mcp doctor                  # Check health, LAN/Tailscale IPs, tunnels & share status
agent-mcp snippet                 # Generate ready-to-paste Claude / Cursor / Gemini / Codex config
agent-mcp gui --silent            # Launch native desktop console into the system tray
agent-mcp run -t stdio            # Run as a local stdio MCP server
agent-mcp tools                   # List all 20 built-in tools (including manage_expose)
```

## Donation

<p align="center">
  <img src="assets/donation/alipay.jpg" width="200" alt="Alipay">
  <img src="assets/donation/wxpay.jpg" width="200" alt="WeChat Pay">
  <img src="assets/donation/binance.jpg" width="200" alt="Binance Pay">
</p>

## License

GNU General Public License v3.0. See [LICENSE](LICENSE).