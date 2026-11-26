# Changelog

## [v3.5.3] — Gemini Web & Strict-CSP MCP Icon Compatibility, Hybrid BMP+PNG `.ico`, `*.googleusercontent.com` OAuth Whitelist & Native Tray Flyout Prism Badge

- **Gemini 网页端与严格 CSP 宿主图标全链路修复**：
  - **`serverInfo.icons` 自包含 `data:image/png;base64,...` 置顶**：将 `64×64`、`128×128` 与 `48×48` 内联 PNG Data URI 提升至 `icons[0..2]` 首梯队（外链 `https://.../icon-192.png` 仅在确认为 `https://` 公网域名时置于末尾兜底），彻底避免 `gemini.google.com` / `claude.ai` 浏览器严格 `img-src` CSP 拦截首项第三方域名图片导致图标破损；同时为 `appIconSvg` 补齐显式 `width="64" height="64"` 固有尺寸属性，并对 `tools/list` 采用轻量级双项（`48×48` PNG + SVG）图标包降低载荷体积。
  - **Google Favicon 爬虫友好路由与反代 `https://` 自动识别**：免鉴权开放 `/robots.txt`、`/favicon-16x16.png`、`/favicon-32x32.png`、`/favicon-48x48.png`、`/favicon-96x96.png`、`/icon-128.png` 及根路径 `<link rel="shortcut icon" href="/favicon.ico">`（对齐 Google Favicon `48px` 整数倍抓取要求）；公网域名经 Cloudflare Tunnel 反代未透传 `X-Forwarded-Proto` 时自动推断为 `https://`，并将 `serverInfo.websiteUrl` 动态指向当前 HTTPS 实例根源以避免误抓 GitHub 图标。
  - **补齐 Gemini 自定义应用 OAuth 回调白名单**：默认白名单（`kDefaultOAuthRedirectUris`）与快捷预设新增 `https://*.googleusercontent.com/**`，原生放行 `oauth-redirect.googleusercontent.com` 重绑回调。
- **标准混合编码 Windows `.ico`、原生托盘菜单双环棱镜徽标与桌面 GUI 日志加固**：
  - **`16..128` `BMP/DIB` + `256` `PNG` 标准混合 `.ico`**：重写 `scripts/sync_brand_icons.py` 的 `.ico` 二进制封装器，小尺寸帧采用标准 32 位 BGRA `BITMAPINFOHEADER` DIB + 1-bpp AND 掩码，`256×256` 采用 PNG 帧，全面兼容 Win32 `LoadImageW`、`.NET csc /win32icon:`、桌面快捷方式与网页 Favicon 解析器。
  - **Windows 托盘弹出面板（`win32_window.cpp`）换装双环棱镜徽标**：移除托盘右键菜单左上角残留的旧版四角星矢量绘制，统一为高 DPI 抗锯齿双环折射棱镜徽标；子 MCP 列表遇到纯 `.svg` 远程图标时自动回退同源位图 Favicon；修复 Windows GUI 进程无控制台句柄导致 `stderr` 写入触发 `errno = 6` 的异常日志。

## [v3.5.2] — Default OAuth Callback Whitelist Mode, Full MCP Protocol Compliance (`icons`, Naming, `2024`–`2026` Dual-Stack, Sub-MCP Multimodal/Pagination, OAuth CIMD/`iss`), Smart 6-Tier Install Detection & Call-Stream Timestamps

- **默认开启 OAuth 2.1 回调地址白名单模式（`oauth_allow_all_redirects = false`）与通配符安全收敛**：
  - 全局配置、服务入口（Profile）与新建入口弹窗默认启用**指定回调白名单模式**（`oauth_allow_all_redirects: false`），开箱预置本地环回（`http://127.0.0.1:*/**`、`http://localhost:*/**`）与主流官方客户端回调通配符（Gemini `https://*.google.com/**` / `https://vertexaisearch.cloud.google.com/**`、Claude `https://*.claude.ai/**` / `https://claude.ai/**`、ChatGPT `https://chatgpt.com/**` / `https://*.openai.com/**`、Cursor `cursor://**`、VS Code `vscode://**`），拦截陌生第三方钓鱼回调域名的同时保持主流客户端零配置连接。
  - 单星号 `*` 收敛为单段主机/端口/路径匹配（`[^/?#]*`），阻断跨路径伪造子域绕过；双星号 `**` 匹配任意多级子路径与查询参数。
- **全链路对齐 MCP 官方图标规范（SEP-973 `icons` + 同源免鉴权图标 + OAuth `logo_uri` + Server Card）**：
  - **`Implementation.icons` 与 `Tool.icons` 补齐必选 `image/png`**：`scripts/sync_brand_icons.py` 自动将 `64×64` 同心折射棱镜 PNG 字节同步内嵌至 `version.dart`（`appIconPngDataUri`），`initialize` 与 `server/discover` 同时输出同源 `192×192`/`64×64` `image/png`、内嵌 `64×64` `image/png` Data URI（含 `light`/`dark` 主题标记）与矢量 `image/svg+xml`（`sizes: ['any']`），解决严格客户端拒收 SVG 显示字母占位符的问题。
  - **免鉴权同源图标与预连接发现路由**：遵循 MCP 规范「不带凭证从同源拉取图标」准则，在鉴权拦截器前放行 `/favicon.ico`、`/favicon.png`、`/icon.png`、`/icon-64.png`、`/icon-192.png`、`/icon-512.png`、`/apple-touch-icon.png`、`/icon.svg`、根路径 `/`（含全套 `<link rel="icon">`）与 MCP Server Card（`/.well-known/mcp.json`、`/mcp/server-card`），并在 OAuth `.well-known` 元数据中补齐 `logo_uri`。
  - **子 MCP 客户端反向图标解析**：自动解析并清洗下游子 MCP 的 `serverInfo.icons`，在桌面与 Web 控制台子 MCP 列表卡片中直接渲染真实上游图标。
- **MCP 跨版本双栈兼容（`2024-11-05` ↔ `2025-11-25` ↔ `2026-07-28`）、命名安全与子 MCP 深度补齐**：
  - **严格工具命名与 `Implementation` 字段分离**：`serverInfo` 分离机器标识 `name`（纯 ASCII slug）与人类可读 `title`、`description`、`websiteUrl`；`direct` 直挂子 MCP 工具引入 `buildSafeMcpToolName`（严格收敛至 `[A-Za-z0-9_-]{1,64}`，超 64 字符自动缩写加短哈希防碰撞，调用时无损还原原始工具名）。
  - **上下版本双向兼容**：服务端显式协商 `2024-11-05` ~ `2026-07-28`（未知未来版本规范回退至 `2025-11-25`），原生新增 `2026-07-28` 无状态 `server/discover`、`resultType: "complete"`、缓存 `ttlMs`/`cacheScope`、`_meta['io.modelcontextprotocol/serverInfo']` 与 CORS `Mcp-Method`/`Mcp-Name`；补齐 `resources/read`、`prompts/get`（桥接已启用子 MCP 资源与提示词模板）及 `logging/setLevel`、`completion/complete`。
  - **子 MCP 分页、协议头与多模态图片直通**：子 MCP 客户端补齐 `MCP-Protocol-Version` 请求头与纯 `2026-07-28` 服务端自动切换 `server/discover` 容错，支持多页 `nextCursor` 循环拉取，并打通下游 `image` / `audio` / `resource_link` / `structuredContent` 原生多模态内容块无损透传。
  - **OAuth 2.1 新规范对齐**：登录回调附带 RFC 9207 `iss` 防混淆参数，`.well-known` 补齐路径级子端点匹配、`authorization_response_iss_parameter_supported` 与 SEP-991 `client_id_metadata_document_supported`（原生拉取校验 `https://` CIMD 客户端元数据）。
- **Windows 安装器 6 级当前安装位置精准识别 + 调用流时间显示修复**：
  - 统一打通 SFX 零界面引导壳（`package_sfx.ps1`）与原生 Flutter `--installer` 向导（`installer_wizard_io.dart`）的 6 级检测链：`1) 命令行 --dir` → `2) 正在运行的 agent_mcp_app / agent-mcp 进程路径（覆盖免安装绿色版）` → `3) 注册表 HKCU\Software\AgentMCP\InstallDir（自动跳过已删除残留目录）` → `4) 开机自启项 HKCU\...\Run\AgentMCP` → `5) 桌面/开始菜单快捷方式 Agent MCP Console.lnk` → `6) 默认用户态目录`，并以同源 `PrismPill` 展示识别来源。
  - 修复桌面宽屏分栏模式（`splitMode`）下「活动与调用流」列表行因 `!widget.splitMode` 导致调用时间隐藏的问题，并在右侧详情检查器顶栏新增完整时间戳与来源胶囊展示。

## [v3.5.1] — 100% Authentic Prism Design System Unification Across Setup Wizard & Structured Editors

- **Windows 原生安装向导（`--installer`）全量对齐主工作台同源 Prism 视觉语言**：
  - **外框 + `24px` 超椭圆主舞台岛 + 原生标题栏**：移除平底 `Scaffold` 与原生 `IconButton`，完整复刻主界面 `c.sidebar` 建筑感外框包裹 `24px` 超椭圆舞台岛（含 `PrismSpecularRimPainter` 顶缘镜面高光与 `whisperShadow`），顶部 `44px` 拖拽栏换装真实 `PrismSparkIcon` 品牌徽标、6 色实时胶囊预览、下拉色板菜单与 Windows 11 矢量 `PrismWindowCaptionButton`（`1px` 最小化横线与红底悬停关闭叉号）。
  - **100% 纯正 `PrismButton`、`PrismSwitch`、`PrismListGroup` 与 `14px` 内凹输入框**：彻底清除向导内全部 7 处原生 Material `FilledButton`/`OutlinedButton`/`TextButton` 与原生 `Switch`，全部替换为 `999px` `StadiumBorder` 高光回弹胶囊 `PrismButton`、`38×22` 弹簧开关 `PrismSwitch`、`22px` `PrismListGroup` + `38×38` `13px` 内凹图标槽 `PrismSettingsRow` 以及 `999px` 渐变胶囊进度槽；移除目录输入框手写的 `10px` 覆盖边框，完整恢复全局 `14px` `c.recessed` 内凹输入框（含悬停 `ringHover` 与聚焦 `1.4px` `focusRing`），并在全新安装时自动将向导所选主题色同步至主程序配置。
  - **全量接入 `PrismSans + NotoSansSC` 同源字体栈**：清除向导内全部 16 处裸 `TextStyle(...)`，统一走 `serifTitleStyle`、`sansStyle` 与 `monoStyle`，并补齐 `buildPrismTheme` 全量 15 档 `TextTheme` 回退链，确保中英文与等宽数字 100% 锐利一致。
- **结构化编辑组件与新增弹窗同心圆角收口**：将通配符白名单卡片升级为带 `PrismSpecularRimPainter` 镜面高光的 `20px` 超椭圆卡片，快捷预设标签由原生 `ActionChip` 替换为紧凑 `PrismButton`，并将客户端一键接入、配置快照与子 MCP 在线调试台弹窗统一对齐为 `28px` 同心圆角。

## [v3.5.0] — Native Flutter Setup Wizard, Universal Sub-MCP OAuth 2.1 Hub, Switch-Driven Wildcard Whitelists & Full-Platform Audit Upgrade

- **真 Dart / Flutter 同源 Windows 安装向导（`--installer` 模式 + 极简零界面 SFX 引导壳）**：
  - 彻底移除旧版 `.NET 4.0` WinForms/GDI+ 独立绘制窗口，改为无感解压临时载荷并拉起原生硬件加速 `agent_mcp_app.exe --installer` 向导窗口（`660×520` Windows 11 原生 `DWMWCP_ROUND` 圆角），完整复用主程序全套 **Prism 双维主题（浅色/暗色 × 6 款主题色实时点选预览 + 光标精确落点水波纹扩散）**、同心折射棱镜矢量徽标与 Windows 11 现代 `IFileOpenDialog` 目录选择器。
  - 原生 C++ 启动层针对 `--installer` 自动绕过后台单实例互斥锁与托盘常驻钩子，避免后台托盘运行中双击安装包被静默吞没；自动识别已有安装目录切换「全新安装 / 无损覆盖升级」，遇到运行中实例时弹出毛玻璃确认卡片平滑关闭旧进程，完整保留 `config/`、`data/` 与 `logs/`，并在安装完成后通过独立自清理进程静默回收临时目录。
- **全协议子 MCP 中枢（OAuth 2.1 动态授权 + 五态传输 + 直挂穿透 + 可视化调试台）**：
  - **完整客户端侧 OAuth 2.1 授权引擎（`oauth2_pkce`）**：支持 `401 WWW-Authenticate` 自动探测 RFC 9728 受保护资源元数据、RFC 8414 / OIDC 双重授权发现、三级客户端身份协商（预设 Client ID → CIMD 元数据文档 → RFC 7591 动态客户端注册）、`S256` PKCE 浏览器回环一键登录、`resource` 受众绑定、`iss` 签发者校验、`403 insufficient_scope` 增量授权提示与后台静默 `refresh_token` 续期，令牌隔离存储于 `data/sub_mcp_tokens.json`；同步支持 `oauth2_client_credentials`（M2M）、`Bearer`、`API Key`（Header / Query）、`Basic` 与 `${ENV:VAR}` 环境变量占位注入。
  - **全栈传输、全原语与双模式挂载**：支持 `auto`（Streamable HTTP 遇到 `404/405` 自动无感回退 Legacy SSE）、`stdio` 热驻留池、`http`（会话过期自动重握手）、`sse` 与 `ws`（WebSocket JSON-RPC），并支持单服务独立 HTTP 代理与自签名证书开关；除 `tools` 外全面打通 `resources` 与 `prompts` 原语，支持 **网关聚合（`gateway`）** 与 **直挂主工具列表（`direct`，`<subname>__<tool>`）** 双模式切换、单工具细粒度启停、多客户端格式智能粘贴导入（Claude Desktop / Cursor / VS Code / 单行 `npx` / `uvx` / URL）以及内置 **Sub-MCP Playground 可视化在线调试抽屉**。
- **「默认全放行开关 + 逐行通配符列表」白名单交互重构**：
  - **OAuth 回调地址白名单（`oauth_allow_all_redirects`）**：新增顶层总开关（默认开启，允许任意回调地址以兼容各类本地随机端口与 Web AI 客户端）；关闭后平滑展开逐行增删卡片，支持 `*` / `**` / `?` 通配符（如 `http://127.0.0.1:*/callback`、`https://*.claude.ai/**`）与常用预设一键填入，并在静态客户端、RFC 7591 `/register` 动态注册与 `/authorize` 全链路统一强制校验；重新打开总开关时自动保留已填规则不丢失。
  - **目录访问白名单（`allow_all_roots`）**：全局设置与各独立接入入口（Profile）同步升级为「允许访问本机所有目录」总开关（默认开启）+ 关闭后逐行选择/输入目录或通配符规则（如 `D:\Projects\*`），每行均配原生文件夹浏览按钮，切换开关无损保留已有路径列表。
- **全仓深度体验审计修复与生产力能力扩展（内置工具扩充至 22 项）**：
  - **告别手写多行纯文本**：子 MCP 编辑弹窗的启动参数 `args`、环境变量 `env` 与自定义请求头 `headers` 全面升级为结构化逐行增删列表（自动对敏感密钥掩码显示），工作目录 `cwd` 补齐原生文件夹选择按钮。
  - **零外网泄露矢量二维码 & 外网分享持久化 + 双向投递**：移除原先请求外部 `api.qrserver.com` 的隐私泄露隐患，自研纯 Dart 零依赖 ISO/IEC 18004 离线矢量二维码引擎（服务端 SVG + 客户端 `CustomPainter`）；活跃分享条目自动持久化至 `data/exposures_state.json`（重启自动恢复未过期分享），并为文件夹分享新增可选 **访客拖拽上传（`双向收件箱`）** 开关。
  - **跨端细节打磨与生产力新特性**：修复启动首帧主题闪烁并将 6 款主题色同步至服务端 OAuth/分享网页；补齐 macOS 点击 Dock 重开窗口、Linux GTK 初始暗色背景适配与 macOS/Linux 应用内一键拉起升级包；新增细粒度高危能力开关（终端命令 / 后台进程 / 外网分享 / 剪贴板与截屏）、内置 `manage_clipboard` 与多模态 `capture_screen` 屏幕截图工具（共 **22 项**标准工具）、**AI 客户端一键写入向导**（Claude Desktop / Cursor / VS Code / Windsurf / Claude Code CLI）、**PBKDF2 + AES 加密/脱敏配置快照导入导出** 以及多节点并发 `/health` 毫秒级延迟心跳探测。

## [v3.4.2] — Continuous Dock-to-Pill Liquid Morph & Seamless Multi-Step Share Dialog Choreography

- **移动端底栏单壳连续浓缩形变（告别双组件上下断层）**：将四栏液态玻璃导航坞与收起态迷你指示条合并为**同一个圆角玻璃胶囊壳体**；向下滚动收起时，外层胶囊宽度从整栏平滑向中心收缩至 `86px`、高度从 `58px` 连续压扁至 `26px`，四栏文字图标向内微缩淡出，而当前激活的液态透镜则同步滑向正中凝聚为迷你胶囊内芯并浮现 `━ ∧` 展开手柄；点按或向上轻拂迷你胶囊时以弹簧曲线（`snappySpring`）从中心原地撑开复原。
- **「新建外网分享」多步与切模式全连贯过渡**：为分享向导弹窗引入外层 `AnimatedSize` 柔顺高度呼吸、第 1 步（选分享类型）↔ 第 2 步（填参数 / 选目录方式）的水平共享轴滑动（`PrismSharedAxisSwitcher`）以及底栏「生成分享链接」按钮的平滑显隐缩放；同时为四态模式（端口 / 单文件 / 文件夹 / 静态网页）目标区与触屏点选卡片补齐连续形变与按压回弹，全程在同一个 `28px` 弹窗内丝滑衔接。

## [v3.4.1] — 1:1 Finger-Locked Mobile Gestures & Edge-to-Edge Full-Bleed Stage

- **移动端双指示器 1:1 零延迟跟手（`0ms` 锁死指尖）**：
  - **二级设置页右滑返回胶囊（`setup-swipe-back-pill`）**：横向实时贴合上层详情页左侧切缝（`sheetLeft - 36px`），纵向实时跟随当前手指触摸高度（`_swipePointerY`），告别此前定死屏幕正中且右滑超 `26px` 即脱节卡顿的问题；当从 Android 系统左边缘（`< 28px`）触发原生灰底返回箭头时自动隐退避让，消除双指示器重叠。
  - **底部液态透镜导航坞（`_MobileMorphingJewelDock`）**：手指按住横向滑动期间透镜胶囊中心直接与指尖横坐标 1:1 同步锁死，消除弹簧阻尼带来的 `45–65ms` 拖尾滞后；松手或轻点切换时再交由柔顺弹簧自动吸附归位，并在左右两端圆弧封口处收窄横向拉伸，保证两侧 `4.0px` 同心间距严丝合缝。
- **消除移动端左右 `18px` 裁切留白墙与左上角缩放缺口**：
  - 将移动端主舞台水平内边距下沉至各独立页面内部，使 Tab 横向切换与二级页面视差右滑全程铺满 `0 .. 屏幕宽度` 无界过渡，彻底消除此前左右两侧 `18px` 垂直硬裁切（如左露半个「置」字、右切半个「`+` / 编辑」按钮）。
  - 移除二级页面右滑过程中的纵向微缩（`l2Scale`）与临时圆角，保持全高平直左侧细线边框与柔和投影，彻底消除顶栏 `< 返回` 下方交界处的暗色三角缺口。

## [v3.4.0] — Concentric Prism Brand Icon, Click-Origin Theme Ripple, Prism Windows Installer & Full macOS/Linux GUI Matrix

- **全新「同心折射棱镜（Concentric Refracted Prism）」全平台品牌图标**：摒弃原先繁杂的多层四角星+交叉杆圆点，采用深邃曜石靛蓝超椭圆玻璃底座（`#161838 → #090A16`）搭配双层互锁同心圆角菱形棱镜（前景纯白水晶环 + 后景星芒靛蓝折射光晕），从 `16px` 任务栏托盘到 `1024px` macOS Dock 均清晰锐利；新增 `scripts/sync_brand_icons.py` 一键同步桌面、托盘、Web Favicon/PWA、Web 加载动画、OAuth/分享网页、macOS、Linux 与 Android 全端 24 处资产。
- **指尖/光标精确落点主题水波纹切换**：`PrismThemeCrossFade` 最外层接入全局透传指针坐标捕获（覆盖页面、6 款主题色胶囊、明暗分段胶囊、顶栏下拉色板菜单与模态弹窗），点哪里就从哪里向外扩散圆环水波纹。
- **Windows 智能免 UAC 安装器重构为 Prism 画廊主题**：采用高 DPI 抗锯齿 GDI+ 与 Windows 11 原生圆角窗口（`DWMWCP_ROUND`），自动识别系统浅色/暗色外观并支持安装界面一键切换明暗，配备 `22px` 同心卡片、`13px` 内嵌路径栏、`999px` 雕塑感星芒靛蓝主胶囊按钮与圆角渐变进度条。
- **补全 macOS（Apple Silicon + Intel）与 Linux（x64 + ARM64）原生桌面 GUI 发布包**：
  - 新增 macOS `.dmg` 拖拽安装镜像与内置 `web_dashboard` / `agent-mcp` CLI 的完整 `.app` 包，配置数据自动存储于 `~/Library/Application Support/AgentMCP` 并解除非商店沙盒对本地 `:8000` 端口与子进程的限制。
  - 新增 Linux `x64` 与 `arm64` 原生 GTK3 桌面 GUI 压缩包（含 `install-desktop.sh` 桌面启动器安装脚本），应用内更新中心全平台精准匹配对应架构 GUI 安装包。
- **动态化 GitHub Release 标题与更新日志**：修复构建流水线此前硬编码旧版文案的问题，现自动从 `CHANGELOG.md` / Git 附注标签提取每次发版的真实标题与更新说明，同步写入 `version.json` 与 GitHub Releases 页面。

## [v3.3.0] — Prism Design System Rebrand, 2D Theme Engine & Windows 11 Tray Auto-Promotion

- **自主 Prism（星芒棱镜）设计系统重命名**：全面移除遗留 `claude_*` / `Claude*` / `Anthropic*` 代码与字体文件命名，升级为 `prism_theme.dart`、`prism_motion.dart` 与 `PrismSans` / `PrismSerif`。
- **「浅色/暗色 × 6 款主题色」双维色彩系统**：首项默认对齐星芒靛蓝（`#4F46E5` / `#818CF8`），另提供温润青玉、深海钴蓝、陶土暖珀、极光紫晶、曜石极简共 6 款高对比度主题色。
- **Windows 11 系统托盘自动置顶与胶囊弹层升级**：首次运行自动置顶任务栏托盘图标（告别折叠进 `^` 隐藏抽屉），标题栏新增收起到托盘按钮，并消除桌面与窄窗的重复返回按钮。

## [v3.2.1] — Zero-Jitter Pinned Desktop Header & Concentric Large-Radius Unification

- **桌面端滚动零抖动顶栏**：桌面模式固定 `48px` 顶栏与侧栏基准线，彻底消除滚轮上下翻动时的画面跳动。
- **全局同心大圆角与胶囊按钮统一**：建立 `28px` 弹窗 → `24px` 舞台卡片 → `14px` 内槽 → `999px` 胶囊按钮的同心几何层级。
