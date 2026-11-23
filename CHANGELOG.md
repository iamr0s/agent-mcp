# Changelog

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
