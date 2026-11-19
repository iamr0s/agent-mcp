# Agent MCP

[中文](README.md) | [English](README.en.md)

[![Python 3.10+](https://img.shields.io/badge/Python-3.10%2B-3776AB.svg)](https://www.python.org/)
[![MCP](https://img.shields.io/badge/Protocol-MCP%20%2F%20FastMCP-D97757.svg)](https://modelcontextprotocol.io/)
[![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20Linux%20%7C%20macOS-lightgrey.svg)](#安装与启动)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

> 面向本地真实开发环境的跨平台 Agent MCP 服务端、子网关与控制台；让云端与本地大模型跨过沙盒玻璃墙，在受控边界内直接读写工程、驱动终端并调度工具链。
>
> 支持 **Claude 暖纸风无边框桌面端（GUI）**、**1:1 全屏终端控制台（TUI）**、**同端口加密管理页（`/dashboard`）** 与 **Rich 命令行** 四端同源运行。

## 为什么做这件事

模型越训越聪明，却总像被关在防弹玻璃后面的参谋：能替你推演百行代码，却碰不到你硬盘上一行真实的工程；能写出漂亮的排障命令，却要由你充当人肉剪贴板，在聊天框与终端之间来回搬运报错与日志。各家客户端纷纷筑起自家的云端沙盒与专属插件，名为赋能，实则把算力、文件与工作流再一次拆成孤岛。

还有另一重荒诞：当你真想给模型接上十几个外部工具时，上百份冗长的 JSON Schema 在第一轮对话就塞满了上下文窗口——活还没干，注意力先被工具说明书耗去大半。

我们想把手脚还给模型，同时把缰绳留在自己手里：不绑死任何一家客户端，只按开放的 **Model Context Protocol (MCP)** 暴露能力；用外科手术式的原子编辑代替整文件覆写，用三枚极简元工具收拢整座子 MCP 生态，用多入口分流把公网隧道、OAuth 2.1 鉴权与目录白名单锁进清晰边界。门可以向远端敞开，但门栓永远握在你自己的机器上。

> “我只能为你指明那扇门，走过去的路，得靠你自己。”
>
> —— 莫菲斯，《黑客帝国》

## 捐赠

如果这个项目对你有帮助，欢迎自愿捐赠以示感谢。捐赠不构成任何支持承诺。

<p align="center">
  <img src="assets/donation/alipay.jpg" width="200" alt="支付宝">
  <img src="assets/donation/wxpay.jpg" width="200" alt="微信支付">
  <img src="assets/donation/binance.jpg" width="200" alt="Binance Pay">
</p>

<p align="center">支付宝 · 微信支付 · Binance Pay</p>

## 这是什么

Agent MCP 是基于 `FastMCP` 构建的本地系统级 MCP 宿主与聚合网关。无论客户端是网页端大模型（通过 Cloudflare Tunnel + OAuth 2.1 远程接入），还是本机 IDE / 桌面客户端（通过 HTTP、SSE 或 `stdio` 直连），所有请求都沿着同一条可观测、可热更新的链路流转：

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

## 核心设计取舍

### 1. 三元渐进发现，拒绝工具爆炸
传统网关把下游所有子 MCP 的工具一股脑平铺给模型，动辄上百个函数声明直接撑爆上下文并引发重名冲突。Agent MCP 的子网关始终只向主模型暴露 **3 个元工具**（`list_sub_mcps`、`inspect_sub_mcp`、`call_sub_mcp`）：模型先看目录，需要哪个工具再按需拉取它的精确 `inputSchema` 并调用；配置增删改**即时生效**，无需重启主服务。

### 2. 同端口多入口（Profiles）与实时热加载
一个本地端口即可同时承载多套接入入口：你可以给主力云端助手开一条带 `OAuth 2.1` 与读写权限的固定域名隧道，给代码审查 Agent 开一条带 `Bearer Key` 且限定单目录只读的 `Quick` 临时隧道，再给本机脚本留一条回环直连。入口的启停、公网地址热注入与权限边界修改全部**秒级热加载**，不断连现有会话。

### 3. 外科手术式文件修改与单步反悔
模型直接重写大文件极易丢行或破坏缩进。内置 `edit_file` 强制要求原子级精确块匹配，匹配失败时自动计算并返回上下文近似行提示；配合 `apply_patch`（统一 Diff 补丁，支持 `dry_run`）、`replace_text`（多文件批量替换预览）以及内存快照栈驱动的 `undo_edit`，任何一次误改都能一键回滚。

### 4. 四端同源，不为无桌面环境妥协
- **无边框桌面控制台（`agent-mcp gui`）**：Claude 暖羊皮纸与深色双主题（支持跟随系统）、自定义流畅缩放拖拽、系统托盘驻留。
- **1:1 全屏终端控制台（`agent-mcp tui`）**：基于 `Textual` 完整复刻桌面端三栏布局、活动调用卡片展开（含红绿 Diff 高亮）、子 MCP 探测与五张配置卡片，SSH 连上无头服务器也有完整图形化体验。
- **同端口加密管理页（`/dashboard`）**：无需额外开放管理端口，凭全局密码即可在任意浏览器远程管理。
- **Rich 现代命令行（`agent-mcp run/config/profile/sub/tunnel`）**：启动状态卡片与快捷子命令，兼顾脚本自动化与人类阅读体验。

## 内置工具矩阵（19 项）

所有工具均附带标准 MCP `ToolAnnotations`（区分只读、修改、破坏性与外部调用），并受当前入口 `AccessPolicy` 实时约束：

| 分类 | 工具名 | 权限级别 | 能力说明 |
| :--- | :--- | :---: | :--- |
| **目录与读取** | `list_roots` | 只读 | 查看当前会话允许的根目录、工作目录与读写/密钥策略 |
| | `list_dir` | 只读 | 输出干净的目录树，自动跳过 `.git`、`node_modules` 等噪音目录 |
| | `stat_file` | 只读 | 读取大文件前预检字节大小、行数、预估 Token 数与类型 |
| | `read_file` | 只读 | 带行号与区间切片读取文本（自动兼容 UTF-8 / GBK 编码） |
| | `read_files` | 只读 | 单次批量读取多个文件，减少多轮往返延迟 |
| **检索与定位** | `glob_files` | 只读 | 按通配符高速匹配文件路径 |
| | `search_text` | 只读 | 全文正则/字面量检索（优先调用 `ripgrep`，缺失时自动回退 Python） |
| **原子编辑** | `create_file` | 写入 | 创建新文件（自动建父目录），覆盖已有文件需显式传 `overwrite=True` |
| | `edit_file` | 写入 | 原子级多处精确文本替换，失败时附带近似片段行号提示 |
| | `apply_patch` | 写入 | 应用标准 Unified Diff 补丁，支持 `dry_run` 预演 |
| | `replace_text` | 写入 | 单文件或跨目录批量查找替换，支持 `dry_run` Diff 预览 |
| | `file_op` | 写入/删除 | 安全移动、复制或删除文件与目录 |
| | `undo_edit` | 写入 | 撤销某路径最近一次创建、编辑、补丁或删除操作 |
| **命令与进程** | `run_command` | 执行 | 同步执行命令（智能解码、首尾截断防刷屏、超时整棵进程树强杀） |
| | `start_process` | 执行 | 启动长时后台进程（如本地开发服、编译监听、日志跟踪） |
| | `manage_process` | 执行 | 列出后台进程、增量读取输出、写入 `stdin` 或终止进程 |
| **子 MCP 网关** | `list_sub_mcps` | 只读 | 列出已启用的嵌套子 MCP 服务摘要 |
| | `inspect_sub_mcp` | 只读 | 按需查看指定子 MCP 的工具清单或单个工具的完整参数 Schema |
| | `call_sub_mcp` | 代理调用 | 向嵌套子 MCP 转发工具调用，参数错误时自动附带 Schema 纠错提示 |

## 环境要求

- **Python 3.10+**
- 推荐（可选）：系统安装 [`ripgrep`](https://github.com/BurntSushi/ripgrep)（`rg`）以获得毫秒级代码搜索；未安装时会自动降级至纯 Python 实现。
- 完整安装（`pip install -e ".[full]"`）包含桌面窗口（`pywebview`）、系统托盘（`pystray` + `pillow`）与全屏 TUI（`textual`）；纯服务端仅依赖 `fastmcp`。

## 安装与启动

```bash
git clone https://github.com/iamr0s/agent-mcp.git
cd agent-mcp
```

### Windows

安装脚本会自动准备虚拟环境、注册全局命令 `agent-mcp` / `agent-mcp-gui`，并写入**桌面快捷方式**与**系统开始菜单**（`C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Agent MCP.lnk`）：

```powershell
# 推荐：以管理员或 Windows 11 sudo 运行（写入系统级开始菜单 + 桌面 + 用户 PATH）
sudo powershell -ExecutionPolicy Bypass -File .\scripts\install_windows.ps1

# 普通权限运行（自动回退至当前用户开始菜单 + 桌面）
powershell -ExecutionPolicy Bypass -File .\scripts\install_windows.ps1

# 也可直接双击 scripts\install_windows.bat

# 仅安装无头 CLI 服务端（跳过 GUI 依赖与快捷方式）
.\scripts\install_windows.ps1 -CliOnly

# 移除快捷方式（保留源码与本地配置）
sudo powershell -ExecutionPolicy Bypass -File .\scripts\install_windows.ps1 -Uninstall
```

### Linux

自动创建 `.venv`、软链 CLI 至 `~/.local/bin`、生成 XDG 桌面菜单项（`~/.local/share/applications/agent-mcp.desktop`），并支持注册 `systemd --user` 常驻服务：

```bash
chmod +x scripts/install_linux.sh

# 标准安装（CLI + 桌面应用菜单入口 + TUI）
./scripts/install_linux.sh

# 同时在桌面生成快捷图标
./scripts/install_linux.sh --desktop

# 无头服务器推荐：仅装核心依赖并启用 systemd 用户级后台自启
./scripts/install_linux.sh --cli-only --systemd

# 卸载快捷方式、软链与 systemd 单元
./scripts/install_linux.sh --uninstall
```

### macOS

自动创建 `.venv`、软链 CLI 至 `~/.local/bin`、生成原生 `~/Applications/Agent MCP.app` 应用包（支持访达与聚焦搜索启动），并可选配置 `launchd` 自启：

```bash
chmod +x scripts/install_macos.sh

# 标准安装（CLI + ~/Applications/Agent MCP.app + TUI）
./scripts/install_macos.sh

# 无头常驻：仅装 CLI 并加载 LaunchAgent
./scripts/install_macos.sh --cli-only --launchd

# 卸载 .app、软链与 LaunchAgent
./scripts/install_macos.sh --uninstall
```

### 手动安装（通用虚拟环境）

```bash
python -m venv .venv
# Windows: .venv\Scripts\activate
# Linux / macOS: source .venv/bin/activate

pip install -e ".[full]"   # 完整安装（桌面 GUI + 全屏 TUI + 托盘）
pip install -e ".[tui]"    # 服务端 + 全屏 TUI（适合远程服务器）
pip install -e .           # 最简核心服务端
```

## 交互形态与命令行用法

安装完成后，可在任意目录调用 `agent-mcp`（或在仓库根目录使用 `python main.py`）：

```bash
# 1. 桌面无边框控制台（默认管理端口 8779）
agent-mcp gui
agent-mcp-gui

# 2. 全屏终端控制台（与桌面 GUI 1:1 对齐，SSH / 终端首选）
agent-mcp tui

# 3. 交互式向导与配置面板
agent-mcp setup                  # 终端分步引导配置
agent-mcp config                 # Rich 面板查看当前生效配置与入口列表
agent-mcp config --json          # 输出脱敏 JSON（便于脚本读取）

# 4. 启动 MCP 服务（自动输出 Rich 状态卡片 + 实时彩色日志流）
agent-mcp run

# 5. 快捷运维子命令（与 GUI / TUI / Dashboard 实时共享配置）
agent-mcp profile list           # 查看所有接入入口
agent-mcp profile enable <id>    # 启用 / 停用 (disable) 指定入口
agent-mcp sub list               # 查看嵌套子 MCP 列表与状态
agent-mcp sub inspect <name>     # 实时探测子 MCP 暴露的工具清单
agent-mcp tunnel status          # 查看或启停 (start / stop / stop-all) Cloudflared 隧道
```

### 命令行参数覆盖与 `stdio` 接入

命令行参数优先级高于环境变量与 `config/mcp_config.json`：

```bash
# 临时指定双模监听、Bearer 鉴权与受限目录启动
agent-mcp run -t dual --host 127.0.0.1 -p 8000 --auth bearer --api-key sk-your-token -r /path/to/repo

# 纯只读安全审计模式（禁止一切写文件、删文件与命令执行）
agent-mcp run --read-only --allow-cwd

# 作为本地 stdio 子进程直接挂载到 Claude Desktop / Cursor / Antigravity
agent-mcp run -t stdio --allow-cwd
```

也支持通过环境变量在容器或守护进程中注入配置：`MCP_NAME`、`MCP_TOOL_PREFIX`、`MCP_TRANSPORT`、`MCP_HOST`、`MCP_PORT`、`MCP_AUTH_MODE`、`MCP_API_KEY`、`MCP_OAUTH_BASE_URL`、`MCP_OAUTH_CLIENT_ID`、`MCP_OAUTH_CLIENT_SECRET`、`MCP_LOG_LEVEL`、`MCP_LOG_FILE`。

## 模块分层

```text
agent-mcp/
├── main.py                     # 统一 CLI / GUI / TUI 启动入口
├── launch_gui.pyw              # Windows 无控制台窗口静默启动器（含崩溃弹窗兜底）
├── agent_mcp/
│   ├── config.py               # 存储布局、无损迁移、多 Profile 与敏感路径守卫
│   ├── server.py               # FastMCP 组装、HTTP+SSE 双模路由、动态按请求策略注入
│   ├── auth.py                 # Bearer、本地自签发 OAuth 2.1、GitHub/Google/自定义 OIDC
│   ├── file_tools.py           # 编码自适应读取、ripgrep 检索、原子替换、Diff 补丁与撤销栈
│   ├── process_tools.py        # 进程树超时清理的同步命令与异步后台进程池
│   ├── sub_mcp.py              # 嵌套子 MCP 连接池、Schema 探测与三元渐进代理
│   ├── tunnel.py               # Cloudflared 在线安装/断点续传/本地导入与多隧道守护
│   ├── web_gui.py              # GuiController 核心控制器与无边框桌面控制台
│   ├── tui.py                  # 与桌面端 1:1 对齐的 Textual 全屏终端控制台
│   ├── dashboard.py            # 挂载于主服务端口 /dashboard 的密码保护远程管理页
│   ├── cli.py / cli_ui.py      # 命令行路由、子命令与 Rich 终端面板
│   ├── tray.py                 # 跨平台系统托盘驻留
│   └── logging_utils.py        # 结构化 JSON 事件总线与对齐彩色日志
├── scripts/                    # Windows / Linux / macOS 安装、快捷方式与服务注册脚本
└── examples/                   # 脱敏配置模板（mcp_config / mcp_sub_servers）
```

## 安全边界与非目标

- **默认拦截敏感凭据**：除非显式开启 `allow_secrets`，文件读写与搜索工具默认拒绝访问 `.env`、私钥证书（`*.pem`、`*.key`、`*.p12`）以及 Agent MCP 自身的 `config/` 与 `data/` 状态文件，防止模型在排障时意外读取并外泄宿主机密钥。
- **公网暴露必须设防**：通过 Cloudflare Tunnel 将服务暴露至公网时，请始终启用 `OAuth 2.1` 或高强度 `Bearer Key`，并结合入口级目录白名单（`roots`）或只读开关（`read_only`）收敛权限。
- **非沙盒虚拟化**：本项目的目标是让模型操作**真实的宿主机环境**；在开启读写执行权限的入口下，`run_command` 拥有与当前操作系统用户同等的执行权限，请像对待 SSH 密钥一样保管你的授权凭据。
- **运行态与代码严格分离**：`config/*.json`、`data/`、`logs/`、`bin/cloudflared*` 与 `.env` 均已列入 `.gitignore`，切勿强行提交至公开仓库。

## 许可

GNU General Public License v3.0，详见 [LICENSE](LICENSE)。
