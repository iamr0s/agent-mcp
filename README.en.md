# Agent MCP

[中文](README.md) | English

[![Python 3.10+](https://img.shields.io/badge/Python-3.10%2B-3776AB.svg)](https://www.python.org/)
[![MCP](https://img.shields.io/badge/Protocol-MCP%20%2F%20FastMCP-D97757.svg)](https://modelcontextprotocol.io/)
[![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20Linux%20%7C%20macOS-lightgrey.svg)](#installation--launch)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

> A cross-platform local Agent MCP host, nested Sub-MCP gateway, and console—letting cloud and local models step past the sandbox glass wall to inspect, edit, and drive real workspaces and toolchains within explicit boundaries.
>
> Ships with **four synchronized surfaces** backed by one engine: a **Claude warm-paper frameless Desktop GUI**, a **1:1 fullscreen Terminal TUI**, a **same-port encrypted Web `/dashboard`**, and a **Rich CLI**.

## Why this exists

Models grow sharper every quarter, yet most of the time they remain advisers locked behind bulletproof glass: capable of reasoning through hundreds of lines of code while unable to touch a single file on your disk; fluent at diagnosing a broken build while reducing you to a human clipboard ferrying logs and commands between a browser tab and a terminal. Meanwhile, every client builds its own cloud sandbox and proprietary plugin silo—promising agency while fragmenting your local workflow all over again.

And when you finally wire a dozen MCP servers into a client, another absurdity appears: hundreds of verbose tool schemas flood the context window on turn one, burning attention on tool manuals before any real work begins.

We want to give models real hands while keeping the reins on your own machine: no lock-in to a single vendor client, everything spoken over the open **Model Context Protocol (MCP)**; surgical atomic edits instead of blind whole-file rewrites; three compact meta-tools standing in front of an entire Sub-MCP ecosystem; and multi-profile routing that binds public tunnels, OAuth 2.1 credentials, and directory boundaries cleanly per entry. The door can open to the cloud, but the bolt stays on your desk.

> “I can only show you the door. You're the one that has to walk through it.”
>
> — Morpheus, *The Matrix*

## Donation

If this project has helped you, you are welcome to donate as a thank-you. Donations are optional and do not constitute any support commitment.

<p align="center">
  <img src="assets/donation/alipay.jpg" width="200" alt="Alipay">
  <img src="assets/donation/wxpay.jpg" width="200" alt="WeChat Pay">
  <img src="assets/donation/binance.jpg" width="200" alt="Binance Pay">
</p>

<p align="center">Alipay · WeChat Pay · Binance Pay</p>

## What this is

Agent MCP is a system-level local MCP server and gateway built on `FastMCP`. Whether your AI client connects remotely from the web (via Cloudflare Tunnel + OAuth 2.1) or locally from an IDE / desktop app (via Streamable HTTP, SSE, or `stdio`), every call travels through a single observable, hot-reloadable pipeline:

```text
AI Client (Gemini / Claude / Cursor / Antigravity / Custom Agent)
  -> Transport (Streamable HTTP `/mcp` | SSE `/sse` | `stdio`)
  -> Cloudflare Tunnel (Quick trycloudflare / Named Token) or Local Loopback
  -> Multi-Profile Router (Host / Credential Matching -> Per-Entry Auth & AccessPolicy)
  -> Secret & Scope Guard (Allowed Roots + Read-Only + `.env`/Key Protection)
  -> Tool Execution
       ├─ Atomic Filesystem & Undo Stack
       ├─ Sync Command (UTF-8/GBK + Process-Tree Kill) & Async Background Daemons
       └─ Sub-MCP Gateway (`list_sub_mcps` -> `inspect_sub_mcp` -> `call_sub_mcp`)
  -> Live Structured Telemetry (`GuiController` -> Desktop GUI / Terminal TUI / `/dashboard`)
```

## Core Design Decisions

### 1. Progressive Discovery Over Tool Bloat
Traditional aggregators flatten every downstream Sub-MCP tool into the main server, dumping dozens of schemas into the prompt and risking name collisions. Agent MCP exposes **only 3 meta-tools** (`list_sub_mcps`, `inspect_sub_mcp`, `call_sub_mcp`): the model browses available servers first, inspects exact `inputSchema` definitions on demand, and invokes tools only when needed. Adding, toggling, or editing Sub-MCPs takes effect **immediately without restarting the main server**.

### 2. Single-Port Multi-Profile Routing & Live Hot-Reload
A single port can host multiple independent entry profiles side by side: expose a named Cloudflare Tunnel with `OAuth 2.1` and full read-write access for your primary assistant, spin up a temporary `Quick` tunnel with a `Bearer Key` locked to read-only on one repository for an audit bot, and keep a local loopback profile for scripts. Toggling profiles, injecting live tunnel URLs, and adjusting directory policies all **hot-reload in place** without dropping active sessions.

### 3. Surgical File Edits & Single-Step Undo
Asking an LLM to rewrite an entire source file invites truncated code and broken indentation. `edit_file` enforces atomic exact-block replacements and returns fuzzy close-match line hints on mismatch; paired with `apply_patch` (unified diff with `dry_run`), `replace_text` (multi-file preview & replace), and an in-memory snapshot stack powering `undo_edit`, any unwanted write can be reverted in one call.

### 4. Four Surfaces, Zero Compromise on Headless Hosts
- **Frameless Desktop Console (`agent-mcp gui`)**: Claude warm-paper & dark slate themes (auto-following OS), smooth native edge-resize/drag, and system tray residency.
- **1:1 Fullscreen Terminal Console (`agent-mcp tui`)**: powered by `Textual`, mirroring the exact 3-tab sidebar, expandable tool-call cards (with green/red unified diff highlighting), Sub-MCP probing, and all 5 setup cards—bringing the full GUI experience over SSH.
- **Same-Port Encrypted Web Console (`/dashboard`)**: mounted directly on the MCP port behind your global password—no extra firewall ports required.
- **Rich Modern CLI (`agent-mcp run/config/profile/sub/tunnel`)**: clean startup cards and quick management subcommands for scripts and terminals alike.

## Built-in Tool Matrix (19 Tools)

Every tool carries standard MCP `ToolAnnotations` (distinguishing read-only, mutating, destructive, and external calls) and is enforced per request by the matched profile's `AccessPolicy`:

| Category | Tool | Access | Behavior |
| :--- | :--- | :---: | :--- |
| **Inspect & Read** | `list_roots` | Read-Only | Inspect allowed roots, working directory, and active policy flags |
| | `list_dir` | Read-Only | Clean directory tree skipping `.git`, `node_modules`, and build noise |
| | `stat_file` | Read-Only | Check byte size, line count, and estimated tokens before reading large files |
| | `read_file` | Read-Only | Read numbered line slices with smart UTF-8 / GBK fallback decoding |
| | `read_files` | Read-Only | Batch-read multiple files in a single round-trip |
| **Search** | `glob_files` | Read-Only | Fast glob file matching across allowed roots |
| | `search_text` | Read-Only | Regex / literal search (`ripgrep` when installed, pure-Python fallback) |
| **Surgical Write** | `create_file` | Write | Create new files (auto-creating parent dirs); requires `overwrite=True` to replace |
| | `edit_file` | Write | Atomic multi-hunk exact replacement with close-match line hints on failure |
| | `apply_patch` | Write | Apply unified diff patches with optional `dry_run` preview |
| | `replace_text` | Write | Single-file or multi-file find & replace with `dry_run` diff preview |
| | `file_op` | Write/Delete | Safely move, copy, or delete files and directories |
| | `undo_edit` | Write | Revert the most recent create, edit, patch, or delete on a target file |
| **Process Control** | `run_command` | Exec | Synchronous shell command with smart decoding, head+tail truncation & process-tree timeout kill |
| | `start_process` | Exec | Spawn long-running background processes (dev servers, watchers, builds) |
| | `manage_process` | Exec | List background processes, read incremental output, send `stdin`, or terminate |
| **Sub-MCP Gateway** | `list_sub_mcps` | Read-Only | List enabled nested Sub-MCP servers without polluting primary tool context |
| | `inspect_sub_mcp` | Read-Only | Discover tool summaries or inspect a specific tool's full `inputSchema` |
| | `call_sub_mcp` | Proxy | Invoke a nested Sub-MCP tool with automatic schema hints on argument errors |

## Requirements

- **Python 3.10+**
- Recommended (optional): [`ripgrep`](https://github.com/BurntSushi/ripgrep) (`rg`) on `PATH` for instant code search (gracefully falls back to Python if absent).
- Full install (`pip install -e ".[full]"`) includes the native desktop window (`pywebview`), system tray (`pystray` + `pillow`), and fullscreen TUI (`textual`); core headless server requires only `fastmcp`.

## Installation & Launch

```bash
git clone https://github.com/iamr0s/agent-mcp.git
cd agent-mcp
```

### Windows

Sets up a virtual environment, registers global `agent-mcp` / `agent-mcp-gui` commands, and creates shortcuts on both your **Desktop** and the **Windows Start Menu** (`C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Agent MCP.lnk`):

```powershell
# Recommended: run as Administrator or with Windows 11 sudo (All-Users Start Menu + Desktop + User PATH)
sudo powershell -ExecutionPolicy Bypass -File .\scripts\install_windows.ps1

# Non-admin install (falls back to Current User Start Menu + Desktop)
powershell -ExecutionPolicy Bypass -File .\scripts\install_windows.ps1

# Or double-click scripts\install_windows.bat

# Headless CLI server only (skip GUI dependencies & shortcuts)
.\scripts\install_windows.ps1 -CliOnly

# Remove shortcuts (keeps source & local config intact)
sudo powershell -ExecutionPolicy Bypass -File .\scripts\install_windows.ps1 -Uninstall
```

### Linux

Creates `.venv`, symlinks CLI commands into `~/.local/bin`, installs an XDG desktop entry (`~/.local/share/applications/agent-mcp.desktop`), and optionally enables a `systemd --user` service:

```bash
chmod +x scripts/install_linux.sh

# Standard install (CLI + application menu entry + TUI)
./scripts/install_linux.sh

# Also add a shortcut onto ~/Desktop
./scripts/install_linux.sh --desktop

# Headless server: core CLI + systemd user daemon
./scripts/install_linux.sh --cli-only --systemd

# Uninstall shortcuts, symlinks & systemd unit
./scripts/install_linux.sh --uninstall
```

### macOS

Creates `.venv`, symlinks CLI commands into `~/.local/bin`, builds a native `~/Applications/Agent MCP.app` bundle (launchable via Finder / Spotlight), and optionally loads a `launchd` agent:

```bash
chmod +x scripts/install_macos.sh

# Standard install (CLI + ~/Applications/Agent MCP.app + TUI)
./scripts/install_macos.sh

# Headless auto-start via LaunchAgent
./scripts/install_macos.sh --cli-only --launchd

# Uninstall .app, symlinks & LaunchAgent
./scripts/install_macos.sh --uninstall
```

### Manual Install (Generic Virtualenv)

```bash
python -m venv .venv
# Windows: .venv\Scripts\activate
# Linux / macOS: source .venv/bin/activate

pip install -e ".[full]"   # Full suite (Desktop GUI + Fullscreen TUI + Tray)
pip install -e ".[tui]"    # Server + Fullscreen TUI (ideal for SSH hosts)
pip install -e .           # Minimal headless server
```

## Surfaces & CLI Usage

Once installed, run `agent-mcp` from anywhere (or `python main.py` from the repo root):

```bash
# 1. Frameless Desktop Console (default local UI port: 8779)
agent-mcp gui
agent-mcp-gui

# 2. Fullscreen Terminal Console (1:1 parity with Desktop GUI; built for SSH & terminals)
agent-mcp tui

# 3. Interactive wizard & configuration inspector
agent-mcp setup                  # Step-by-step terminal setup wizard
agent-mcp config                 # Rich summary panel + profiles table
agent-mcp config --json          # Machine-readable masked JSON

# 4. Start the MCP server (Rich startup card + aligned color logs)
agent-mcp run

# 5. Quick management subcommands (live-synced with GUI / TUI / Dashboard)
agent-mcp profile list           # List all entry profiles
agent-mcp profile enable <id>    # Enable or disable a profile
agent-mcp sub list               # List nested Sub-MCP servers & status
agent-mcp sub inspect <name>     # Probe tools exposed by a Sub-MCP
agent-mcp tunnel status          # Inspect or start / stop / stop-all Cloudflared tunnels
```

### CLI Overrides & Local `stdio` Mode

CLI flags override environment variables and `config/mcp_config.json`:

```bash
# Run dual (HTTP + SSE) mode with Bearer auth scoped to one workspace
agent-mcp run -t dual --host 127.0.0.1 -p 8000 --auth bearer --api-key sk-your-token -r /path/to/repo

# Strict read-only audit mode (blocks all file writes, deletes & command execution)
agent-mcp run --read-only --allow-cwd

# Attach directly as a local stdio server in Claude Desktop / Cursor / Antigravity
agent-mcp run -t stdio --allow-cwd
```

Environment variables supported for containers and service units: `MCP_NAME`, `MCP_TOOL_PREFIX`, `MCP_TRANSPORT`, `MCP_HOST`, `MCP_PORT`, `MCP_AUTH_MODE`, `MCP_API_KEY`, `MCP_OAUTH_BASE_URL`, `MCP_OAUTH_CLIENT_ID`, `MCP_OAUTH_CLIENT_SECRET`, `MCP_LOG_LEVEL`, `MCP_LOG_FILE`.

## Module Layout

```text
agent-mcp/
├── main.py                     # Unified CLI / GUI / TUI entrypoint
├── launch_gui.pyw              # Silent Windows GUI launcher with crash dialog fallback
├── agent_mcp/
│   ├── config.py               # Storage layout, lossless migration, profiles & secret guard
│   ├── server.py               # FastMCP assembly, HTTP+SSE dual router & per-request policy
│   ├── auth.py                 # Bearer, self-issued OAuth 2.1, GitHub/Google & custom OIDC
│   ├── file_tools.py           # Smart decoding, ripgrep search, surgical edits, patch & undo
│   ├── process_tools.py        # Process-tree timeout sync commands & async background pool
│   ├── sub_mcp.py              # Nested Sub-MCP client pool, schema probe & 3-meta-tool proxy
│   ├── tunnel.py               # Cloudflared downloader (pause/resume/import) & tunnel supervisor
│   ├── web_gui.py              # GuiController engine & frameless desktop console
│   ├── tui.py                  # Textual fullscreen terminal console (1:1 with Desktop GUI)
│   ├── dashboard.py            # Password-protected /dashboard mounted on the MCP server port
│   ├── cli.py / cli_ui.py      # CLI subcommands, interactive wizard & Rich panels
│   ├── tray.py                 # Cross-platform system tray integration
│   └── logging_utils.py        # Structured JSON event bus & aligned terminal logging
├── scripts/                    # Windows / Linux / macOS installers, shortcuts & service units
└── examples/                   # Sanitized config templates (mcp_config / mcp_sub_servers)
```

## Security Boundaries & Non-Goals

- **Secret Guard on by Default**: unless `allow_secrets` is explicitly enabled, file and search tools block access to `.env`, private keys (`*.pem`, `*.key`, `*.p12`), and Agent MCP's own `config/` and `data/` state files so models cannot accidentally leak host credentials while debugging.
- **Always Authenticate Public Tunnels**: when exposing an entry via Cloudflare Tunnel, always use `OAuth 2.1` or a strong `Bearer Key`, and scope access with `roots` or `read_only` where appropriate.
- **Real Host Execution, Not a VM**: this project intentionally connects models to your **actual operating system**. On read-write profiles, `run_command` executes with the privileges of the current OS user—guard your tokens and OAuth password as carefully as an SSH key.
- **Runtime State Stays Local**: `config/*.json`, `data/`, `logs/`, `bin/cloudflared*`, and `.env` are git-ignored by design. Never force-add live credentials to a public repository.

## License

GNU General Public License v3.0. See [LICENSE](LICENSE) for details.
