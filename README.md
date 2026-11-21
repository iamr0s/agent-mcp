# Agent MCP v2.0

[中文](README.md) | [English](README.en.md)

[![Release](https://img.shields.io/github/v/release/iamr0s/agent-mcp?color=D97757&label=Release)](https://github.com/iamr0s/agent-mcp/releases)
[![Flutter 3.50+](https://img.shields.io/badge/Flutter-3.50%2B%20%7C%20Dart%20Native-02569B.svg)](https://flutter.dev/)
[![MCP 2025-03-26](https://img.shields.io/badge/Protocol-MCP%20Streamable%20HTTP%20%2B%20SSE%20%2B%20stdio-4D7C5D.svg)](https://modelcontextprotocol.io/)
[![Platform](https://img.shields.io/badge/Platform-Windows%2011%20Mica%20%7C%20Android%20Dual--Mode%20%7C%20Web%20%7C%20CLI-141413.svg)](#快速下载与安装)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

> 面向真实开发与移动终端环境的跨平台原生 **Agent MCP 宿主、嵌套子网关与多端控制台**；让云端与本地大模型跨过沙盒玻璃墙，在受控边界内直接读写工程、驱动终端并按需调度整座工具生态。
>
> **v2.0 跨代重构**：全栈基于原生 **Dart & Flutter** 重写，零 Python / Node 运行时依赖，一套引擎同步驱动 **Win11 云母无边框桌面端**、**Android 双模合一特权端（沙盒 / Shizuku / Root SU）**、**同端口加密 `/dashboard` 网页端**与**独立原生 CLI**。

<p align="center">
  <img src="assets/previews/hero_overview.png" width="92%" alt="Agent MCP v2.0 跨平台概览">
</p>

## 为什么做这件事

模型越训越聪明，却总像被关在防弹玻璃后面的参谋：能替你推演百行代码，却碰不到你硬盘上一行真实的工程；能写出漂亮的排障命令，却要由你充当人肉剪贴板，在聊天框与终端之间来回搬运报错与日志。各家客户端纷纷筑起自家的云端沙盒与专属插件，名为赋能，实则把算力、文件与工作流再一次拆成孤岛。

还有另一重荒诞：当你真想给模型接上十几个外部工具时，上百份冗长的 JSON Schema 在第一轮对话就塞满了上下文窗口——活还没干，注意力先被工具说明书耗去大半。

我们想把手脚还给模型，同时把缰绳留在自己手里：不绑死任何一家客户端，只按开放的 **Model Context Protocol (MCP)** 暴露能力；用外科手术式的原子编辑代替整文件覆写，用三枚极简元工具收拢整座子 MCP 生态，用多入口分流把多网卡直连、公网隧道、OAuth 2.1 鉴权与目录白名单锁进清晰边界。门可以向远端敞开，但门栓永远握在你自己的机器上。

> “我只能为你指明那扇门，走过去的路，得靠你自己。”
>
> —— 莫菲斯，《黑客帝国》

## 界面与真机预览

<table>
  <tr>
    <td width="50%">
      <img src="assets/previews/activity_and_submcp.png" alt="活动调用流与嵌套子网关">
      <p align="center"><sub><b>圆角胶囊活动流 & 三元渐进子 MCP 网关</b></sub></p>
    </td>
    <td width="50%">
      <img src="assets/previews/multi_ip_and_profiles.png" alt="多网卡直连多选与浮动协议复制菜单">
      <p align="center"><sub><b>本机多网卡/Tailscale 多选 & 浮动协议复制菜单</b></sub></p>
    </td>
  </tr>
  <tr>
    <td colspan="2">
      <p align="center">
        <img src="assets/previews/android_privilege_modes.png" width="84%" alt="Android 双模合一与三级特权架构">
      </p>
      <p align="center"><sub><b>Android 双模合一版：掌上多电脑节点远控 + 本机 Shizuku (ADB/Root) & Root SU 特权宿主</b></sub></p>
    </td>
  </tr>
</table>

## 核心设计亮点

### 1. 三元渐进发现，终结上下文工具爆炸
传统聚合器将下游所有子 MCP 的工具平铺注入首轮对话，动辄消耗数万 Token 并引发重名冲突。Agent MCP 始终只暴露 **3 枚极简元工具**（`list_sub_mcps` → `inspect_sub_mcp` → `call_sub_mcp`）：先看摘要目录，按需拉取单个工具 `inputSchema`，调用出错时自动附带 Schema 纠错提示，配置增删改**免重启秒级生效**。

### 2. 单端口多入口分流、本机多网卡多选与 OAuth 2.1 无感授权
- **直连 / 反代多地址叠加**：编辑入口时可直观多选本机 **局域网 (`192.168.x.x`)**、**Tailscale 组网 (`100.x.y.z`)** 与回环网卡（端口随基础配置自动跟随），同时叠加多条反代域名；若所选网卡未纳入监听，系统智能提示并支持保存时**一键同步开放网卡监听**。
- **自托管 OAuth 2.1 动态注册**：完整实现 RFC 7591 动态客户端注册 + PKCE (`S256`)，对接 Gemini Web、Claude Web 等远程客户端只需填入 `/mcp` 地址并输入一次本地密码即可持久绑定。
- **Cloudflared 隧道管家**：内置官方二进制断点续传下载、本地导入替换以及 `Named Token` 固定域名 / `Quick` 临时公网隧道守护。

### 3. Android 双模合一 APK 与三级特权引擎（参考 InstallerX-Revived）
- **模式 A · 掌上多电脑远控台**：顶栏下拉菜单支持保存并秒切多台远程电脑节点（局域网 / Tailscale / 公网 HTTPS），自动维护会话 Cookie 与 SSE 实时日志流。
- **模式 B · 手机本机特权 MCP 宿主**：支持 FlClash 风格下拉通知栏常驻保活（含 WakeLock / WifiLock 与快捷停止/重启按钮）、全面屏挖孔与底部小白条沉浸透传、可折叠透传悬浮胶囊底栏，并提供三级执行授权器：
  - **普通沙盒 (`App UID`)**：标准应用沙盒隔离，零额外授权。
  - **Shizuku (`ADB UID 2000 / Root UID 0`)**：集成官方 `Shizuku-API 13.1.5`，自动识别无线调试 Shell 或 Root 后端，一键弹窗授权。
  - **Root SU (`UID 0`)**：拉起持久 `su` 特权回环守护桥接（支持 `--mount-master` 全局挂载命名空间，兼容 **KernelSU / APatch / Magisk** 并支持一键跳转管理器授权），免重复弹窗，同步赋能全部 **12 项文件工具 + 3 项进程工具**！

### 4. 外科手术式原子编辑与原生四端体验
- **原子修改 + 单步反悔**：`edit_file` 强制精确上下文块匹配并在失配时返回近似行提示；配合 `apply_patch`、`replace_text` 预演模式与内存快照栈 `undo_edit`，彻底告别整文件覆写丢行。
- **原生 Win11 云母桌面端 & 独立 CLI**：无边框 `WS_OVERLAPPEDWINDOW` 原生窗口、Win11 DWM Mica 云母透光背板、自绘圆角深浅双色托盘菜单、Win32 `JobObject` 子进程防孤儿守护，以及自带 `doctor` / `tools` / `snippet` 的单文件原生 CLI。

## 架构链路

```text
AI Client (Gemini Web / Claude / Cursor / Codex / Antigravity / Custom Agent)
  -> Transport (Streamable HTTP `/mcp` | Legacy SSE `/sse` | Local `stdio`)
  -> Multi-NIC Direct / Reverse Proxy / Cloudflare Tunnel (`Token` or `Quick`)
  -> Hot-Reloading Profile Router (Host & Token Matching -> Per-Entry OAuth 2.1 / Bearer & AccessPolicy)
  -> Scope & Secret Guard (Allowed Roots + Read-Only + `.env` / Private Key Protection)
  -> Unified Dart Execution Engine
       ├─ 12 Atomic File Tools + Undo Snapshot Stack (`dart:io` + Android `PrivFs` Loopback Bridge)
       ├─ 3 Process Tools (`Win32 JobObject` / Android `Shizuku` & `Root SU` Tree Guard)
       └─ 3 Sub-MCP Meta-Tools (`list_sub_mcps` -> `inspect_sub_mcp` -> `call_sub_mcp`)
  -> Real-Time Structured Event Bus -> Win11 Mica GUI / Android App / Web `/dashboard/` / Native CLI
```

## 内置原子工具矩阵（19 项）

| 分类 | 工具名 | 权限级别 | 能力说明 |
| :--- | :--- | :---: | :--- |
| **作用域与读取** | `list_roots` | 只读 | 查看当前入口允许的根目录、读写/密钥策略及 Android 实时特权等级 |
| | `list_dir` | 只读 | 输出干净目录树，自动过滤 `.git`、`node_modules`、`build` 与 `.gitignore` |
| | `stat_file` | 只读 | 读取大文件前预检字节大小、行数、编码、换行符与预估 Token 数 |
| | `read_file` | 只读 | 带行号区间切片读取文本（自动兼容 UTF-8 / UTF-8 BOM / GBK） |
| | `read_files` | 只读 | 单次批量读取多个文件（含总字符预算保护），减少多轮往返 |
| **检索与定位** | `glob_files` | 只读 | 按通配符跨目录高速定位文件路径 |
| | `search_text` | 只读 | 正则/字面量全文检索（桌面优先调用 `ripgrep`，特权模式自动走特权桥接） |
| **外科手术编辑** | `create_file` | 写入 | 创建新文件并自动建父目录，覆盖已有文件须显式传 `overwrite=true` |
| | `edit_file` | 写入 | 原子级多处精确替换，失败时自动计算 Dice 相似度近似行号提示 |
| | `apply_patch` | 写入 | 应用标准 Unified Diff (`@@ -a,b +c,d @@`) 补丁，支持 `dry_run` 预演 |
| | `replace_text` | 写入 | 单文件或跨目录批量替换（含文件数安全上限与 `dry_run` 预览） |
| | `file_op` | 写入/删除 | 安全移动（支持跨盘自动回退复制删除）、复制或删除文件与目录 |
| | `undo_edit` | 写入 | 从内存快照栈一键回滚目标文件最近一次创建、编辑、补丁或删除 |
| **命令与进程** | `run_command` | 执行 | 同步执行命令（UTF-8/GBK 自适应解码、首尾截断防刷屏、超时整棵进程树强杀） |
| | `start_process` | 执行 | 启动长时后台任务（编译构建、开发服务器、持续日志监听）并返回 `process_id` |
| | `manage_process` | 执行 | 列出后台进程、增量读取尾部输出、向 `stdin` 发送输入或强杀进程树 |
| **子 MCP 网关** | `list_sub_mcps` | 只读 | 列出所有已启用嵌套子 MCP 服务摘要，零 Schema 膨胀 |
| | `inspect_sub_mcp` | 只读 | 按需查看指定子 MCP 的工具列表或单个工具的完整 JSON Schema |
| | `call_sub_mcp` | 代理调用 | 转发调用嵌套子 MCP 工具（支持 `stdio` 长连接池与 Streamable HTTP / SSE） |

## 快速下载与安装

前往 [**GitHub Releases**](https://github.com/iamr0s/agent-mcp/releases) 下载对应平台最新发行包：

| 平台 | 发行包 | 说明 |
| :--- | :--- | :--- |
| **Windows 10 / 11 (x64)** | `AgentMCP-v2.0.0-windows-x64-sfx.exe` | **推荐**：图形化便携自解压向导，一键创建桌面快捷方式并拉起云母控制台（内置 `agent-mcp.exe` CLI 与 `/dashboard/`） |
| **Windows 10 / 11 (x64)** | `AgentMCP-v2.0.0-windows-x64-portable.zip` | 纯净免安装绿色压缩包，解压即用，零注册表残留 |
| **Android (ARM64 真机推荐)** | `AgentMCP-v2.0.0-android-arm64-v8a.apk` | 轻量 `arm64-v8a` 双模合一安装包（支持远控电脑 + 本机 Shizuku / Root SU） |
| **Android (全架构通用)** | `AgentMCP-v2.0.0-android-universal.apk` | 含 `arm64-v8a` / `armeabi-v7a` / `x86_64` 通用安装包 |

## 命令行 (`agent-mcp`) 实战速查

随桌面端附带的独立原生二进制 `agent-mcp`（无需任何外部运行时）与图形界面实时共享配置：

```bash
# 1. 环境与连通性全面体检（探测在线延迟、本机局域网/Tailscale 网卡、隧道与活跃入口）
agent-mcp doctor

# 2. 生成 Claude Desktop / Cursor / Gemini Web / Codex 一键挂载配置片段
agent-mcp snippet

# 3. 启动原生桌面控制台（支持 --silent 静默驻留系统托盘）
agent-mcp gui
agent-mcp gui --silent

# 4. 启动多网卡 HTTP+SSE 服务端或作为本地 stdio 子进程挂载
agent-mcp run --host 127.0.0.1,100.77.167.127 -p 8000
agent-mcp run -t stdio --relaxed-cmd --allow-cwd

# 5. 多入口、子网关与隧道快捷运维（保存即刻热加载）
agent-mcp tools                          # 查看内置 19 项原子工具矩阵
agent-mcp config                         # 查看脱敏配置摘要（支持 --json）
agent-mcp profile list                   # 查看所有接入入口及解析后的完整 URL
agent-mcp profile add-ip default 100.77.167.127
agent-mcp sub inspect memory-mcp         # 实时探测子 MCP 工具清单
agent-mcp tunnel status                  # 查看或管理 Cloudflared 隧道
```

## 从源码构建

环境要求：**Flutter 3.50+ (Stable)**（含 Dart 3.14+）、Windows Visual Studio C++ 桌面工作负载（编译 Windows 端）或 Android SDK 35+ / JDK 17+（编译 Android 端）。

```powershell
git clone https://github.com/iamr0s/agent-mcp.git
cd agent-mcp
flutter pub get

# 运行代码静态检查与组件测试
dart analyze packages/agent_mcp_core
cd apps/agent_mcp_app && flutter test && cd ../..

# 一键构建 Windows 桌面端 + Web 管理台 + 原生 CLI + 便携/自解压包
powershell -ExecutionPolicy Bypass -File .\scripts\build_release.ps1 -NoReload
powershell -ExecutionPolicy Bypass -File .\scripts\package_sfx.ps1 -SkipBuild

# 一键构建 Android 双模 Universal 与 arm64-v8a APK
powershell -ExecutionPolicy Bypass -File .\scripts\build_android.ps1
```

## 工程目录结构

```text
agent-mcp/
├── packages/
│   └── agent_mcp_core/             # 纯 Dart 跨平台核心引擎与独立 CLI
│       ├── bin/agent_mcp.dart      # 原生 CLI (gui / run / doctor / tools / snippet / profile / sub / tunnel)
│       └── lib/src/
│           ├── server.dart         # Streamable HTTP + SSE + stdio 统一引擎与热加载多入口路由
│           ├── auth.dart           # 自托管 OAuth 2.1 (RFC 7591 + PKCE) 与 PBKDF2-SHA256 鉴权
│           ├── file_tools.dart     # 12 项原子文件工具与内存快照撤销栈
│           ├── process_tools.dart  # Win32 JobObject 与跨平台进程树管控
│           ├── privileged_exec.dart# Android Shizuku / Root SU 特权回环桥接层 (PrivFs & Process)
│           ├── sub_mcp.dart        # 嵌套子 MCP 渐进式发现与连接池
│           ├── tunnel.dart         # Cloudflared 断点续传安装与多隧道守护
│           └── dashboard_api.dart  # 同端口 /dashboard 静态资源 GZip 服务与管理 API
├── apps/
│   └── agent_mcp_app/              # Flutter 多端统一控制台 (Windows / Web / Android)
│       ├── lib/                    # Claude 暖纸超椭圆主题、活动流、子网关、多网卡配置与特权卡片
│       ├── windows/runner/         # Win11 DWM 云母、无边框窗口与 GDI+ 自绘圆角托盘菜单
│       └── android/app/            # 前台常驻保活服务、全面屏挖孔透传、Shizuku AIDL 与 Root SU 守护
├── .github/workflows/releases.yaml # GitHub Actions 跨平台自动构建与 Release 发布流水线
├── scripts/                        # Windows / Android 自动化构建与无痕打包脚本
└── examples/                       # 脱敏配置模板
```

## 安全边界说明

- **默认拦截敏感凭据**：除非显式开启 `allow_secrets`，文件读写与检索工具默认拦截 `.env`、私钥证书（`*.pem`、`*.key`、`*.p12`、`*.jks`）以及自身 `config/` 与 `data/` 目录，防止排障过程中意外外泄宿主机密钥。
- **公网与组网暴露务必设防**：绑定非回环网卡或开启 Cloudflare Tunnel 时，请始终启用 `OAuth 2.1` 或高强度 `Bearer Key`，并按最小权限原则配置入口级目录白名单（`roots`）或只读开关（`read_only`）。
- **Android 特权审慎授权**：开启 `Shizuku` 或 `Root SU` 后，MCP 工具将具备对应的 `ADB Shell (UID 2000)` 或 `Root (UID 0)` 系统级读写执行能力，请仅向可信客户端开放授权凭证。

## 捐赠

如果这个项目对你有帮助，欢迎自愿捐赠以示感谢。捐赠不构成任何支持承诺。

<p align="center">
  <img src="assets/donation/alipay.jpg" width="200" alt="支付宝">
  <img src="assets/donation/wxpay.jpg" width="200" alt="微信支付">
  <img src="assets/donation/binance.jpg" width="200" alt="Binance Pay">
</p>

<p align="center">支付宝 · 微信支付 · Binance Pay</p>

## 许可

GNU General Public License v3.0，详见 [LICENSE](LICENSE)。