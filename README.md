# Agent MCP v2.0

[中文](README.md) | [English](README.en.md)

[![Release](https://img.shields.io/github/v/release/iamr0s/agent-mcp?color=D97757&label=Release)](https://github.com/iamr0s/agent-mcp/releases)
[![Flutter 3.50+](https://img.shields.io/badge/Flutter-3.50%2B%20%7C%20Dart%20Native-02569B.svg)](https://flutter.dev/)
[![MCP 2025-03-26](https://img.shields.io/badge/Protocol-Streamable%20HTTP%20%2B%20SSE%20%2B%20stdio-4D7C5D.svg)](https://modelcontextprotocol.io/)
[![Platform](https://img.shields.io/badge/Platform-Windows%2011%20%7C%20Android%20%7C%20Web%20%7C%20CLI-141413.svg)](#快速下载与安装)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

> **让大模型真正长出手脚，同时把开关和边界稳稳握在你自己手里。**
>
> **Agent MCP v2.0** 基于原生 **Dart & Flutter** 全新打造，零 Python / Node 环境依赖，解压即用。连上 Gemini、Claude、Cursor 或 Codex 后，AI 可以直接读写本地工程、跑终端测试、按需调度十几个外部子服务，还能**把刚生成的视频或本地网站一键映射成手机可打开的分享链接**；配合 **Android 双模客户端**，一部手机既能随身遥控多台电脑，也能在手机本机按需提权运行。

<p align="center">
  <img src="assets/previews/hero_overview.png" width="94%" alt="Agent MCP v2.0 跨端工作台概览">
</p>

## 界面预览

<table>
  <tr>
    <td width="50%">
      <img src="assets/previews/activity_and_submcp.png" alt="实时调用流与子 MCP 网关">
      <p align="center"><sub><b>实时调用流 & 子 MCP 二级网关</b></sub></p>
    </td>
    <td width="50%">
      <img src="assets/previews/multi_ip_and_profiles.png" alt="多网卡直连多选与 Tailscale 外网分享设置">
      <p align="center"><sub><b>多网卡直连多选 & Tailscale 外网分享总控</b></sub></p>
    </td>
  </tr>
  <tr>
    <td colspan="2">
      <p align="center">
        <img src="assets/previews/android_privilege_modes.png" width="88%" alt="Android 双模客户端与三档执行权限">
      </p>
      <p align="center"><sub><b>Android 双模客户端：随身遥控多台电脑 + 本机普通沙盒 / Shizuku / Root SU 一键切换</b></sub></p>
    </td>
  </tr>
</table>

## 五大核心功能与用法

### 1. 代码修改、终端执行与一键反悔（20 项内置工具）
不用再把几百行报错在聊天框和编辑器之间来回粘贴。连上 Agent MCP 后，直接对 AI 说需求即可：
- **精准改文件不丢代码**：AI 使用 `edit_file` 与 `apply_patch` 定位上下文行修改；如果某次改动不满意，直接说一句“撤回刚才的修改”，`undo_edit` 会从快照中秒级还原。
- **跑编译、盯长任务**：短命令走 `run_command`（自动兼容中文 UTF-8 / GBK 输出），像前端开发服务器或长时构建则走 `start_process` + `manage_process` 后台运行并随时查看尾部日志。

### 2. 外网映射与链接分享（`manage_expose` + 独立「外网与分享」页）
AI 刚帮你做好一段演示视频、生成了网页报告，或者在本地 `:3000` 跑起了网站，想立刻用手机或发给外部预览？
- **一句话让 AI 发链接**：直接告诉 AI *“把刚生成的视频映射出来发我链接看，看完再关掉”*，AI 会自动调用 `manage_expose` 并返回可直接点开的预览地址（MP4 视频自带在线播放器并支持任意拖动进度条）。
- **独立管理页随时掌控**：切到左侧 **「外网与分享」** 页面，可随时手动新建端口 / 文件 / 静态目录分享、复制多通道地址（公网域名 / Tailscale / 局域网）、查看实时访问次数与流量，或点 **「全部关闭」** 一键收回。
- **设置页总开关联动 Tailscale**：在 **「服务配置 -> Tailscale 与外网分享设置」** 中，可一键开关 AI 映射权限、选择 **Tailscale Funnel 公网优先** 或 **仅组网内私享**，并设置默认自动到期时长（30 分钟 / 2 小时 / 24 小时 / 手动关闭）。

### 3. 多网卡直连多选与分入口权限隔离
同一台电脑既想在局域网连、又想走 Tailscale 组网连，还要给网页端开一条公网隧道？
- **怎么配**：打开 **「服务配置 -> 传输、鉴权与权限入口」** 点编辑，选择 `直连 / 反代` 模式即可直接多选本机 **局域网 IP** 与 **Tailscale 100 段 IP**，同时叠加多条自定义反代域名；若所选网卡尚未监听，勾上“保存时自动开放监听”即可一键同步。
- **怎么连**：在入口卡片点 **「复制地址」**，下拉菜单里想用哪条通道点哪条。每个入口还能单独设置登录密码（内置 OAuth 2.1 无感授权）、Bearer 密钥、只读开关或允许访问的文件夹范围。

### 4. 子 MCP 二级网关：装再多工具也不卡顿
往客户端里一次性塞进十几个外部 MCP 服务，还没开始聊就先耗掉几万 Token。
- **怎么用**：切到 **「子 MCP 网关」** 页，点“导入 JSON”把你现有的 `mcpServers` 配置粘贴进去即可。Agent MCP 对外始终只暴露 `list_sub_mcps`、`inspect_sub_mcp`、`call_sub_mcp` **3 个固定入口**，AI 需要用哪个服务再去按需拉取工具说明，增删改免重启即时生效。

### 5. Android 双模客户端：既能管电脑，也能跑本机
手机安装 APK 后拥有两种用法，随时通过顶部菜单切换：
- **随身遥控多台电脑**：点顶部节点下拉菜单添加家里台式机或办公室电脑地址，在外随时手机查看实时调用流、开关子服务或管理外网分享。
- **手机本机运行 MCP（三档权限点选即换）**：
  - **普通沙盒**：零额外授权，安装即用，适合读写手机共享文件夹。
  - **Shizuku（无线调试 ADB / Root）**：免 Root 解锁系统级排障能力。先在手机上启动 Shizuku，再回本应用点「授权 Shizuku」，即可让 AI 执行 `pm` / `dumpsys` / `logcat` 等命令。
  - **Root SU（支持 KernelSU / APatch / Magisk）**：点选后在 Root 管理器里允许一次即可常驻生效，免去每次执行命令重复弹窗，可读写 `/data/adb` 等系统路径。
- **锁屏常驻与全面屏透传**：开启服务后自动挂起低打扰常驻通知，锁屏不掉线，下拉通知栏即可一键停止或重启；底部悬浮导航栏可随时收起成迷你横条，不挡正文。

## 快速下载与安装

前往 [**GitHub Releases**](https://github.com/iamr0s/agent-mcp/releases) 下载对应平台安装包：

| 平台 | 文件名 | 适用说明 |
| :--- | :--- | :--- |
| **Windows 10 / 11 (x64)** | `AgentMCP-v2.0.0-windows-x64-sfx.exe` | **推荐桌面用户**：自带图形化安装向导与桌面快捷方式，内含云母桌面端、网页管理台与 `agent-mcp.exe` 命令行 |
| **Windows 10 / 11 (x64)** | `AgentMCP-v2.0.0-windows-x64-portable.zip` | 免安装便携压缩包，解压双击即用，所有配置保存在当前目录 |
| **Android (ARM64 手机推荐)** | `AgentMCP-v2.0.0-android-arm64-v8a.apk` | 适用于主流 64 位骁龙 / 天玑 / Tensor 安卓手机与平板，体积轻巧 |
| **Android (全架构通用)** | `AgentMCP-v2.0.0-android-universal.apk` | 同时包含 `arm64-v8a`、`armeabi-v7a` 与 `x86_64`（兼容模拟器与旧机型） |
| **Linux (x64 服务器/NAS)** | `AgentMCP-v2.0.0-linux-x64-cli.tar.gz` | 零依赖单文件原生命令行服务端，解压即可在云服务器或容器中运行 |

## 内置工具一览（20 项）

| 分类 | 工具名 | 用途说明 |
| :--- | :--- | :--- |
| **环境与读取** | `list_roots` | 查看当前入口可访问的目录范围、读写开关与手机端实时权限档位 |
| | `list_dir` | 输出清爽目录树，自动跳过 `.git`、`node_modules`、`build` 等杂项 |
| | `stat_file` | 读大文件前先看大小、行数、编码和预估 Token 开销 |
| | `read_file` / `read_files` | 按行号切片读取单个文件，或一次批量读取多个文件（自动识别 UTF-8 / GBK） |
| **查找与检索** | `glob_files` / `search_text` | 按通配符快速找文件，或跨目录全文搜索关键字与正则表达式 |
| **精准改代码** | `create_file` / `edit_file` | 自动创建目录写新文件，或按精确上下文修改局部代码（失配时提示相近行号） |
| | `apply_patch` / `replace_text` | 应用标准 Diff 补丁或批量替换文本，均支持 `dry_run` 预览变更 |
| | `file_op` / `undo_edit` | 安全移动、复制、删除文件，或用 `undo_edit` 一键撤回上一次修改 |
| **终端与后台** | `run_command` | 执行终端命令并返回结果，超时自动清理整棵子进程树 |
| | `start_process` / `manage_process` | 启动长时运行的网站或编译任务，随时读取新日志、发送输入或停止进程 |
| **外网映射分享** | `manage_expose` | **一键将本地视频/文件、静态网页目录或本地端口映射为 Tailscale / 公网链接，支持随时查询与关闭** |
| **子服务网关** | `list_sub_mcps` / `inspect_sub_mcp` / `call_sub_mcp` | 用 3 个轻量入口按需浏览并调用任意数量的嵌套外部 MCP 服务 |

## 命令行 (`agent-mcp`) 常用速查

桌面包内置独立单文件命令行 `agent-mcp`，与图形界面实时共用同一份配置：

```bash
# 1. 一键环境体检（检查服务状态、本机局域网/Tailscale 网卡、隧道与外网分享开关）
agent-mcp doctor

# 2. 生成 Claude Desktop / Cursor / Gemini / Codex 即拷即用接入配置
agent-mcp snippet

# 3. 打开桌面控制台（加 --silent 可静默驻留到右下角托盘）
agent-mcp gui
agent-mcp gui --silent

# 4. 直接在终端启动多网卡 HTTP 服务，或以本地 stdio 模式挂载
agent-mcp run --host 127.0.0.1,100.77.167.127 -p 8000
agent-mcp run -t stdio --relaxed-cmd --allow-cwd

# 5. 查看 20 项内置工具、脱敏配置与多入口地址
agent-mcp tools
agent-mcp config
agent-mcp profile list
```

## 从源码构建

环境要求：**Flutter 3.50+ (Stable)**，编译 Windows 桌面端需安装 Visual Studio C++ 桌面开发组件，编译 Android 端需安装 Android SDK 与 JDK 21。

```powershell
git clone https://github.com/iamr0s/agent-mcp.git
cd agent-mcp
flutter pub get

# 运行核心测试与界面组件测试
cd packages/agent_mcp_core && dart test && cd ../..
cd apps/agent_mcp_app && flutter test && cd ../..

# 打包 Windows 桌面端 + 网页端 + 命令行 + 自解压安装包
powershell -ExecutionPolicy Bypass -File .\scripts\build_release.ps1 -NoReload
powershell -ExecutionPolicy Bypass -File .\scripts\package_sfx.ps1 -SkipBuild

# 打包 Android 双模 APK
powershell -ExecutionPolicy Bypass -File .\scripts\build_android.ps1
```

## 安全使用建议

- **默认保护隐私凭据**：默认自动拦截 `.env`、私钥证书（`*.pem`、`*.key`、`*.jks`）与程序自身的配置目录，避免排障时误传敏感文件。
- **外网连接请开启验证**：绑定局域网 / 公网或开启隧道时，建议为入口开启 `OAuth 2.1` 密码验证或高强度 `Bearer` 密钥，并限定可访问的工程目录。
- **临时分享用完即关**：对外分享视频或测试网站时，建议保持默认的“2 小时自动关闭”或在预览结束后点击「全部关闭」。

## 捐赠

如果这个工具帮到了你的日常开发工作流，欢迎自愿赞赏支持。

<p align="center">
  <img src="assets/donation/alipay.jpg" width="200" alt="支付宝">
  <img src="assets/donation/wxpay.jpg" width="200" alt="微信支付">
  <img src="assets/donation/binance.jpg" width="200" alt="Binance Pay">
</p>

<p align="center">支付宝 · 微信支付 · Binance Pay</p>

## 许可

采用 GNU General Public License v3.0 开源许可，详见 [LICENSE](LICENSE)。