import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter, PlatformDispatcher;

import 'package:agent_mcp_core/agent_mcp_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../theme/prism_theme.dart';

bool isInstallerLaunchArgs(List<String> args) {
  for (final a in args) {
    if (a.trim() == '--installer') return true;
  }
  return false;
}

Widget buildInstallerWizardApp(List<String> args) {
  return InstallerWizardApp(args: args);
}

@immutable
class InstallerLaunchConfig {
  final String payloadDir;
  final String? explicitDir;
  final String afterMode;
  final bool createShortcut;
  final bool autoConfirmClose;

  const InstallerLaunchConfig({
    required this.payloadDir,
    this.explicitDir,
    this.afterMode = 'gui',
    this.createShortcut = true,
    this.autoConfirmClose = false,
  });

  factory InstallerLaunchConfig.fromArgs(List<String> args) {
    String? payloadDir;
    String? explicitDir;
    var afterMode = 'gui';
    var createShortcut = true;
    var autoClose = false;

    for (var i = 0; i < args.length; i++) {
      final a = args[i].trim();
      final al = a.toLowerCase();
      if (al == '--payload-dir' && i + 1 < args.length) {
        payloadDir = args[++i].trim();
      } else if ((al == '--dir' || al == '-o' || al == '--target') &&
          i + 1 < args.length) {
        explicitDir = args[++i].trim();
      } else if (al == '--after' && i + 1 < args.length) {
        afterMode = args[++i].trim().toLowerCase();
      } else if (al.startsWith('--after=')) {
        afterMode = a.substring(8).trim().toLowerCase();
      } else if (al == '--no-shortcut') {
        createShortcut = false;
      } else if (al == '--yes' || al == '-y' || al == '--auto-close') {
        autoClose = true;
      }
    }

    final fallbackPayload = payloadDir != null && payloadDir.isNotEmpty
        ? payloadDir
        : File(Platform.resolvedExecutable).parent.path;

    return InstallerLaunchConfig(
      payloadDir: fallbackPayload,
      explicitDir: explicitDir,
      afterMode: afterMode,
      createShortcut: createShortcut,
      autoConfirmClose: autoClose,
    );
  }
}

class InstallerWizardApp extends StatefulWidget {
  final List<String> args;
  final Future<List<int>> Function(String targetDir)? overrideDetectRunningPids;
  final Future<void> Function(
    String payloadDir,
    String targetDir,
    bool createShortcut,
    bool launchAfter,
    String afterMode,
    void Function(double progress, String label) onProgress,
  )? overridePerformInstall;
  final Future<String?> Function()? overridePickDirectory;
  final VoidCallback? overrideCloseWindow;

  const InstallerWizardApp({
    super.key,
    this.args = const ['--installer'],
    this.overrideDetectRunningPids,
    this.overridePerformInstall,
    this.overridePickDirectory,
    this.overrideCloseWindow,
  });

  @override
  State<InstallerWizardApp> createState() => _InstallerWizardAppState();
}

class _InstallerWizardAppState extends State<InstallerWizardApp> {
  static const MethodChannel _winChannel = MethodChannel('agent_mcp/window');
  ThemeMode _themeMode = ThemeMode.system;
  PrismAccentId _accentId = PrismAccentId.indigo;

  @override
  void initState() {
    super.initState();
    PrismPalette.configureAccent(_accentId);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncNativeWindow());
  }

  Future<void> _syncNativeWindow() async {
    if (!Platform.isWindows) return;
    final platformDark =
        PlatformDispatcher.instance.platformBrightness == Brightness.dark;
    final isDark = switch (_themeMode) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system => platformDark,
    };
    try {
      await _winChannel.invokeMethod<void>('setDarkTheme', isDark);
    } catch (_) {}
  }

  void _cycleThemeMode(BuildContext ctx) {
    final next = switch (_themeMode) {
      ThemeMode.system => ThemeMode.light,
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
    };
    PrismThemeCrossFade.runThemeTransition(ctx, () {
      setState(() => _themeMode = next);
      unawaited(_syncNativeWindow());
    });
  }

  void _selectAccent(BuildContext ctx, PrismAccentId next) {
    if (_accentId == next) return;
    PrismThemeCrossFade.runThemeTransition(ctx, () {
      PrismPalette.configureAccent(next);
      setState(() => _accentId = next);
    });
  }

  @override
  Widget build(BuildContext context) {
    PrismPalette.configureAccent(_accentId);
    final platformBrightness = MediaQuery.maybePlatformBrightnessOf(context) ??
        PlatformDispatcher.instance.platformBrightness;

    return PrismThemeCrossFade(
      themeMode: _themeMode,
      platformBrightness: platformBrightness,
      child: MaterialApp(
        title: 'Agent MCP Setup',
        debugShowCheckedModeBanner: false,
        themeAnimationDuration: Duration.zero,
        theme: buildPrismTheme(PrismPalette.activeLight),
        darkTheme: buildPrismTheme(PrismPalette.activeDark),
        themeMode: _themeMode,
        home: InstallerWizardScreen(
          launchConfig: InstallerLaunchConfig.fromArgs(widget.args),
          themeMode: _themeMode,
          accentId: _accentId,
          onCycleTheme: _cycleThemeMode,
          onSelectAccent: _selectAccent,
          overrideDetectRunningPids: widget.overrideDetectRunningPids,
          overridePerformInstall: widget.overridePerformInstall,
          overridePickDirectory: widget.overridePickDirectory,
          overrideCloseWindow: widget.overrideCloseWindow,
        ),
      ),
    );
  }
}

class InstallerWizardScreen extends StatefulWidget {
  final InstallerLaunchConfig launchConfig;
  final ThemeMode themeMode;
  final PrismAccentId accentId;
  final void Function(BuildContext) onCycleTheme;
  final void Function(BuildContext, PrismAccentId) onSelectAccent;
  final Future<List<int>> Function(String targetDir)? overrideDetectRunningPids;
  final Future<void> Function(
    String payloadDir,
    String targetDir,
    bool createShortcut,
    bool launchAfter,
    String afterMode,
    void Function(double progress, String label) onProgress,
  )? overridePerformInstall;
  final Future<String?> Function()? overridePickDirectory;
  final VoidCallback? overrideCloseWindow;

  const InstallerWizardScreen({
    super.key,
    required this.launchConfig,
    required this.themeMode,
    required this.accentId,
    required this.onCycleTheme,
    required this.onSelectAccent,
    this.overrideDetectRunningPids,
    this.overridePerformInstall,
    this.overridePickDirectory,
    this.overrideCloseWindow,
  });

  @override
  State<InstallerWizardScreen> createState() => _InstallerWizardScreenState();
}

class _InstallerWizardScreenState extends State<InstallerWizardScreen> {
  static const MethodChannel _winChannel = MethodChannel('agent_mcp/window');

  late final TextEditingController _dirCtrl;
  bool _isUpgrade = false;
  bool _createShortcut = true;
  bool _launchAfter = true;
  bool _installing = false;
  bool _completed = false;
  double _progress = 0.0;
  String _statusLabel = '准备就绪 · 免管理员权限一键部署';
  String? _errorMsg;
  List<int>? _pendingRunningPids;

  @override
  void initState() {
    super.initState();
    _createShortcut = widget.launchConfig.createShortcut;
    _launchAfter = widget.launchConfig.afterMode != 'none';
    final initialDir = _resolveInitialInstallDir(widget.launchConfig.explicitDir);
    _dirCtrl = TextEditingController(text: initialDir);
    _refreshUpgradeFlag(initialDir);
    _dirCtrl.addListener(() => _refreshUpgradeFlag(_dirCtrl.text));
  }

  @override
  void dispose() {
    _dirCtrl.dispose();
    super.dispose();
  }

  String _resolveInitialInstallDir(String? explicitDir) {
    if (explicitDir != null && explicitDir.trim().isNotEmpty) {
      return explicitDir.trim();
    }
    if (Platform.isWindows) {
      try {
        final regRes = Process.runSync('reg', [
          'query',
          r'HKCU\Software\AgentMCP',
          '/v',
          'InstallDir',
        ]);
        if (regRes.exitCode == 0) {
          final out = regRes.stdout.toString();
          final m = RegExp(r'InstallDir\s+REG_SZ\s+(.+)$', multiLine: true)
              .firstMatch(out);
          if (m != null) {
            final d = m.group(1)!.trim();
            if (d.isNotEmpty) return d;
          }
        }
      } catch (_) {}
      final localApp = Platform.environment['LOCALAPPDATA'] ??
          p.join(
            Platform.environment['USERPROFILE'] ?? r'C:\Users\Default',
            'AppData',
            'Local',
          );
      return p.join(localApp, 'Programs', 'AgentMCP');
    }
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    return p.join(home, '.local', 'share', 'AgentMCP');
  }

  void _refreshUpgradeFlag(String rawDir) {
    final d = rawDir.trim();
    if (d.isEmpty) return;
    bool exists = false;
    try {
      final exeName = Platform.isWindows ? 'agent_mcp_app.exe' : 'agent_mcp_app';
      exists = File(p.join(d, exeName)).existsSync();
    } catch (_) {}
    if (exists != _isUpgrade && mounted) {
      setState(() => _isUpgrade = exists);
    } else {
      _isUpgrade = exists;
    }
  }

  Future<void> _pickFolder() async {
    if (_installing) return;
    final picked = widget.overridePickDirectory != null
        ? await widget.overridePickDirectory!()
        : await pickNativeLocalPath(directory: true);
    if (picked != null && picked.trim().isNotEmpty && mounted) {
      setState(() {
        _dirCtrl.text = picked.trim();
        _errorMsg = null;
      });
    }
  }

  Future<void> _closeWizard() async {
    if (widget.overrideCloseWindow != null) {
      widget.overrideCloseWindow!();
      return;
    }
    final payloadDir = widget.launchConfig.payloadDir;
    _scheduleTempPayloadCleanupIfTemp(payloadDir);
    if (Platform.isWindows) {
      try {
        await _winChannel.invokeMethod<void>('forceClose');
        return;
      } catch (_) {}
    }
    exit(0);
  }

  Future<List<int>> _detectRunningPids(String targetDir) async {
    if (widget.overrideDetectRunningPids != null) {
      return widget.overrideDetectRunningPids!(targetDir);
    }
    if (!Platform.isWindows) return const [];
    try {
      final selfPid = pid;
      final res = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "Get-Process -Name 'agent_mcp_app','agent-mcp' -ErrorAction SilentlyContinue | Where-Object { \$_.Id -ne $selfPid } | Select-Object -ExpandProperty Id",
      ]);
      if (res.exitCode != 0) return const [];
      return res.stdout
          .toString()
          .split(RegExp(r'\r?\n'))
          .map((s) => int.tryParse(s.trim()))
          .whereType<int>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _startInstall({bool confirmedCloseRunning = false}) async {
    final targetDir = _dirCtrl.text.trim();
    if (targetDir.isEmpty) {
      setState(() => _errorMsg = '请选择有效的目标安装目录。');
      return;
    }

    setState(() => _errorMsg = null);

    if (!confirmedCloseRunning && !widget.launchConfig.autoConfirmClose) {
      final pids = await _detectRunningPids(targetDir);
      if (pids.isNotEmpty) {
        if (mounted) {
          setState(() => _pendingRunningPids = pids);
        }
        return;
      }
    }

    setState(() {
      _pendingRunningPids = null;
      _installing = true;
      _progress = 0.04;
      _statusLabel = '正在准备安装环境...';
    });

    try {
      if (widget.overridePerformInstall != null) {
        await widget.overridePerformInstall!(
          widget.launchConfig.payloadDir,
          targetDir,
          _createShortcut,
          _launchAfter,
          widget.launchConfig.afterMode,
          (ratio, label) {
            if (!mounted) return;
            setState(() {
              _progress = ratio.clamp(0.0, 1.0);
              _statusLabel = label;
            });
          },
        );
      } else {
        await _executeRealWindowsInstall(targetDir);
      }

      if (!mounted) return;
      setState(() {
        _progress = 1.0;
        _completed = true;
        _statusLabel = '安装完成！正在为您启动控制台...';
      });

      await Future<void>.delayed(const Duration(milliseconds: 380));
      await _closeWizard();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _installing = false;
        _errorMsg = '$e';
        _statusLabel = '安装遇到问题，可修改目录后重试';
      });
    }
  }

  Future<void> _executeRealWindowsInstall(String targetDir) async {
    final runningPids = await _detectRunningPids(targetDir);
    if (runningPids.isNotEmpty) {
      if (mounted) {
        setState(() {
          _progress = 0.08;
          _statusLabel = '正在平滑停止运行中的旧实例...';
        });
      }
      final idList = runningPids.join(',');
      await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "\$procs = Get-Process -Id $idList -ErrorAction SilentlyContinue; "
            "foreach (\$p in \$procs) { try { \$_ = \$p.CloseMainWindow() } catch {} }; "
            "Start-Sleep -Milliseconds 900; "
            "Stop-Process -Id $idList -Force -ErrorAction SilentlyContinue; "
            "Start-Sleep -Milliseconds 350",
      ]);
    }

    final srcRoot = Directory(widget.launchConfig.payloadDir);
    final dstRoot = Directory(targetDir);
    if (!dstRoot.existsSync()) {
      dstRoot.createSync(recursive: true);
    }

    final srcCanonical = p.canonicalize(srcRoot.path);
    final dstCanonical = p.canonicalize(dstRoot.path);
    if (srcCanonical.toLowerCase() != dstCanonical.toLowerCase()) {
      final files = srcRoot
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .toList();
      final total = files.isEmpty ? 1 : files.length;
      const preservedRelPrefixes = <String>[
        r'config\',
        r'logs\',
      ];
      const preservedExactRels = <String>{
        r'data\oauth_state.json',
        r'data\sub_mcp_tokens.json',
        r'data\exposures_state.json',
        r'data\window_state.json',
        r'data\tunnel_state.json',
        r'data\update_prefs.json',
        r'data\remote_nodes.json',
      };

      for (var i = 0; i < files.length; i++) {
        final srcFile = files[i];
        final rel = p.relative(srcFile.path, from: srcRoot.path);
        final relNorm = rel.replaceAll('/', r'\').toLowerCase();
        final dstPath = p.join(dstRoot.path, rel);
        final dstFile = File(dstPath);

        final isPreserved = preservedExactRels.contains(relNorm) ||
            preservedRelPrefixes.any((pre) => relNorm.startsWith(pre));
        if (isPreserved && dstFile.existsSync()) {
          continue;
        }

        dstFile.parent.createSync(recursive: true);
        Object? copyErr;
        for (var attempt = 0; attempt < 6; attempt++) {
          try {
            await srcFile.copy(dstPath);
            copyErr = null;
            break;
          } catch (e) {
            copyErr = e;
            await Future<void>.delayed(const Duration(milliseconds: 240));
          }
        }
        if (copyErr != null) {
          throw StateError('无法写入文件 ${p.basename(dstPath)}: $copyErr');
        }

        if (i % 4 == 0 || i == files.length - 1) {
          final ratio = 0.12 + 0.78 * ((i + 1) / total);
          if (mounted) {
            setState(() {
              _progress = ratio;
              _statusLabel =
                  '正在部署 (${(ratio * 100).round()}%) · ${p.basename(srcFile.path)}';
            });
          }
          await Future<void>.delayed(Duration.zero);
        }
      }
    }

    if (Platform.isWindows) {
      if (mounted) {
        setState(() {
          _progress = 0.94;
          _statusLabel = '正在写入安装信息与快捷方式...';
        });
      }
      final exePath = p.join(dstRoot.path, 'agent_mcp_app.exe');
      final icoPath = p.join(dstRoot.path, 'app_icon.ico');
      final escapedTarget = dstRoot.path.replaceAll("'", "''");
      final escapedExe = exePath.replaceAll("'", "''");
      final escapedIco = icoPath.replaceAll("'", "''");
      final psLines = <String>[
        r"$reg = New-Item -Path 'HKCU:\Software\AgentMCP' -Force;",
        "Set-ItemProperty -Path \$reg.PSPath -Name 'InstallDir' -Value '$escapedTarget';",
        "Set-ItemProperty -Path \$reg.PSPath -Name 'Version' -Value '$agentMcpVersion';",
        "Set-ItemProperty -Path \$reg.PSPath -Name 'UpdatedAt' -Value ([DateTime]::UtcNow.ToString('o'));",
        if (_createShortcut) ...[
          r"$desk = [Environment]::GetFolderPath('Desktop');",
          r"$lnk = Join-Path $desk 'Agent MCP Console.lnk';",
          r"$ws = New-Object -ComObject WScript.Shell;",
          r"$sc = $ws.CreateShortcut($lnk);",
          "\$sc.TargetPath = '$escapedExe';",
          "\$sc.WorkingDirectory = '$escapedTarget';",
          "\$sc.Description = 'Agent MCP Console';",
          "if (Test-Path '$escapedIco') { \$sc.IconLocation = '$escapedIco' };",
          r"$sc.Save();",
        ],
      ];
      await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        psLines.join(' '),
      ]);

      if (_launchAfter && File(exePath).existsSync()) {
        final launchFlag =
            widget.launchConfig.afterMode == 'tray' ? '--silent' : '--show';
        await Process.start(
          exePath,
          [launchFlag],
          workingDirectory: dstRoot.path,
          mode: ProcessStartMode.detached,
        );
      }
    }
  }

  void _scheduleTempPayloadCleanupIfTemp(String payloadDir) {
    if (!Platform.isWindows) return;
    try {
      final norm = p.canonicalize(payloadDir).toLowerCase();
      if (!norm.contains('agentmcp-setup-')) return;
      final safeDir = payloadDir.replaceAll('"', '');
      Process.start(
        'cmd.exe',
        ['/c', 'ping 127.0.0.1 -n 4 >nul & rmdir /s /q "$safeDir"'],
        mode: ProcessStartMode.detached,
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    final themeIcon = switch (widget.themeMode) {
      ThemeMode.light => Icons.wb_sunny_rounded,
      ThemeMode.dark => Icons.dark_mode_rounded,
      ThemeMode.system => Icons.brightness_auto_rounded,
    };

    return Scaffold(
      backgroundColor: c.paper,
      body: Stack(
        children: [
          // Subtle top ambient refraction glow matching ConsoleShellScreen
          Positioned(
            top: -110,
            right: -60,
            child: IgnorePointer(
              child: Container(
                width: 300,
                height: 240,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      c.clay.withValues(alpha: c.isDark ? 0.18 : 0.11),
                      c.clay.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),

          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Native frameless drag header + theme & accent controls
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: (_) {
                  if (Platform.isWindows) {
                    _winChannel.invokeMethod<void>('startDragging');
                  }
                },
                child: Container(
                  height: 46,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      _PrismSetupMiniMark(accent: c.clay, isDark: c.isDark),
                      const SizedBox(width: 9),
                      Text(
                        'Agent MCP 安装向导',
                        style: TextStyle(
                          fontFamily: kFontSans,
                          fontFamilyFallback: kSansFallback,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: c.inkSoft,
                        ),
                      ),
                      const Spacer(),
                      // 6-accent mini dots for instant live preview
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final spec in PrismAccentSpec.presets)
                            Padding(
                              padding: const EdgeInsets.only(right: 5),
                              child: Tooltip(
                                message: spec.label,
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: () =>
                                      widget.onSelectAccent(context, spec.id),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 180),
                                    width: widget.accentId == spec.id ? 14 : 11,
                                    height:
                                        widget.accentId == spec.id ? 14 : 11,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: LinearGradient(
                                        colors: [
                                          spec.swatchStart,
                                          spec.swatchEnd,
                                        ],
                                      ),
                                      border: Border.all(
                                        color: widget.accentId == spec.id
                                            ? c.ink
                                            : Colors.transparent,
                                        width: 1.4,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        key: const ValueKey('installer-theme-toggle'),
                        tooltip: '切换明暗主题',
                        visualDensity: VisualDensity.compact,
                        iconSize: 16,
                        onPressed: () => widget.onCycleTheme(context),
                        icon: Icon(themeIcon, color: c.inkSoft),
                      ),
                      IconButton(
                        tooltip: '最小化',
                        visualDensity: VisualDensity.compact,
                        iconSize: 16,
                        onPressed: () {
                          if (Platform.isWindows) {
                            _winChannel.invokeMethod<void>('minimize');
                          }
                        },
                        icon: Icon(Icons.remove_rounded, color: c.inkSoft),
                      ),
                      IconButton(
                        key: const ValueKey('installer-close-btn'),
                        tooltip: '退出向导',
                        visualDensity: VisualDensity.compact,
                        iconSize: 16,
                        onPressed: _installing ? null : _closeWizard,
                        icon: Icon(Icons.close_rounded, color: c.inkSoft),
                      ),
                    ],
                  ),
                ),
              ),

              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(26, 6, 26, 22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Hero Identity Card
                      Row(
                        children: [
                          _PrismHeroEmblem(accent: c.clay, isDark: c.isDark),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                  spacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Text(
                                      'Agent MCP Console',
                                      style: TextStyle(
                                        fontFamily: kFontSerif,
                                        fontFamilyFallback: kSerifFallback,
                                        fontSize: 20,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: -0.3,
                                        color: c.ink,
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2.5,
                                      ),
                                      decoration: ShapeDecoration(
                                        color: c.purpleBg,
                                        shape: prismSuperellipse(99),
                                      ),
                                      child: Text(
                                        'v$agentMcpVersion',
                                        style: TextStyle(
                                          fontFamily: kFontMono,
                                          fontFamilyFallback: kMonoFallback,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: c.clay,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 5),
                                Row(
                                  children: [
                                    Icon(
                                      _isUpgrade
                                          ? Icons.auto_awesome_rounded
                                          : Icons.verified_user_outlined,
                                      size: 14,
                                      color: c.clay,
                                    ),
                                    const SizedBox(width: 5),
                                    Expanded(
                                      child: Text(
                                        _isUpgrade
                                            ? '检测到已有版本 · 无损覆盖升级（完整保留配置、密钥与日志）'
                                            : '全新零 UAC 用户态部署 · 原生系统托盘与多端协议中枢',
                                        style: TextStyle(
                                          fontSize: 12.2,
                                          color: c.inkSoft,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 18),

                      // Target Directory Card
                      Container(
                        padding: const EdgeInsets.fromLTRB(16, 13, 16, 14),
                        decoration: ShapeDecoration(
                          color: c.paper2,
                          shape: prismSuperellipse(
                            16,
                            side: BorderSide(color: c.hairline),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.folder_open_rounded,
                                  size: 15,
                                  color: c.clay,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '目标安装位置',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: c.ink,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  _isUpgrade ? '覆盖升级目录' : '自动创建目录',
                                  style: TextStyle(
                                    fontSize: 11.2,
                                    color: c.muted,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 9),
                            Row(
                              children: [
                                Expanded(
                                  child: SizedBox(
                                    height: 38,
                                    child: TextField(
                                      key: const ValueKey('installer-dir-input'),
                                      controller: _dirCtrl,
                                      enabled: !_installing,
                                      style: TextStyle(
                                        fontFamily: kFontMono,
                                        fontFamilyFallback: kMonoFallback,
                                        fontSize: 12.2,
                                        color: c.ink,
                                      ),
                                      decoration: InputDecoration(
                                        isDense: true,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 10,
                                        ),
                                        filled: true,
                                        fillColor: c.paper,
                                        border: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(10),
                                          borderSide:
                                              BorderSide(color: c.hairline),
                                        ),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(10),
                                          borderSide:
                                              BorderSide(color: c.hairline),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SizedBox(
                                  height: 38,
                                  child: OutlinedButton.icon(
                                    key: const ValueKey('installer-browse-btn'),
                                    onPressed: _installing ? null : _pickFolder,
                                    icon: const Icon(
                                      Icons.drive_folder_upload_rounded,
                                      size: 16,
                                    ),
                                    label: const Text('浏览...'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),

                      // Options Card
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        decoration: ShapeDecoration(
                          color: c.paper2,
                          shape: prismSuperellipse(
                            16,
                            side: BorderSide(color: c.hairline),
                          ),
                        ),
                        child: Column(
                          children: [
                            _InstallerOptionSwitchRow(
                              switchKey:
                                  const ValueKey('installer-shortcut-switch'),
                              icon: Icons.desktop_windows_rounded,
                              title: '创建桌面快捷方式',
                              subtitle: '在桌面生成 Agent MCP Console 启动图标',
                              value: _createShortcut,
                              enabled: !_installing,
                              onChanged: (v) =>
                                  setState(() => _createShortcut = v),
                            ),
                            Divider(height: 1, color: c.hairline),
                            _InstallerOptionSwitchRow(
                              switchKey:
                                  const ValueKey('installer-launch-switch'),
                              icon: Icons.rocket_launch_rounded,
                              title: '安装完成后立即打开控制台',
                              subtitle: '自动唤醒桌面图形界面并挂载后台服务',
                              value: _launchAfter,
                              enabled: !_installing,
                              onChanged: (v) =>
                                  setState(() => _launchAfter = v),
                            ),
                          ],
                        ),
                      ),

                      if (_errorMsg != null) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: ShapeDecoration(
                            color: c.danger.withValues(alpha: 0.10),
                            shape: prismSuperellipse(10),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.error_outline_rounded,
                                size: 15,
                                color: c.danger,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _errorMsg!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: c.danger,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      const Spacer(),

                      // Progress & Primary Action Footer
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _statusLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11.8,
                                    color: _completed ? c.clay : c.inkSoft,
                                    fontWeight: _installing || _completed
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                              if (_installing || _completed)
                                Text(
                                  '${(_progress * 100).round()}%',
                                  style: TextStyle(
                                    fontFamily: kFontMono,
                                    fontFamilyFallback: kMonoFallback,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: c.clay,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(99),
                            child: TweenAnimationBuilder<double>(
                              tween: Tween<double>(begin: 0, end: _progress),
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeOutCubic,
                              builder: (ctx, val, _) {
                                return LinearProgressIndicator(
                                  value: _installing || _completed ? val : 0.0,
                                  minHeight: 6,
                                  backgroundColor:
                                      c.hairline.withValues(alpha: 0.7),
                                  valueColor:
                                      AlwaysStoppedAnimation<Color>(c.clay),
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Text(
                                '便携包内核 · 支持随时迁移目录',
                                style: TextStyle(
                                  fontSize: 11.3,
                                  color: c.muted,
                                ),
                              ),
                              const Spacer(),
                              TextButton(
                                onPressed: _installing ? null : _closeWizard,
                                child: const Text('取消'),
                              ),
                              const SizedBox(width: 8),
                              FilledButton.icon(
                                key: const ValueKey('installer-submit-btn'),
                                onPressed: _installing || _completed
                                    ? null
                                    : () => _startInstall(),
                                style: FilledButton.styleFrom(
                                  backgroundColor: c.clay,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 22,
                                    vertical: 12,
                                  ),
                                  shape: prismSuperellipse(12),
                                ),
                                icon: Icon(
                                  _completed
                                      ? Icons.check_circle_rounded
                                      : (_isUpgrade
                                          ? Icons.system_update_alt_rounded
                                          : Icons.download_done_rounded),
                                  size: 17,
                                ),
                                label: Text(
                                  _completed
                                      ? '已完成部署'
                                      : (_installing
                                          ? '正在部署...'
                                          : (_isUpgrade ? '立即覆盖升级' : '立即安装')),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          // Frosted-glass running instance confirmation overlay
          if (_pendingRunningPids != null)
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: c.isDark ? 0.55 : 0.30),
                  child: Center(
                    child: Container(
                      width: 430,
                      padding: const EdgeInsets.all(22),
                      decoration: ShapeDecoration(
                        color: c.paper2,
                        shape: prismSuperellipse(
                          20,
                          side: BorderSide(color: c.hairline),
                        ),
                        shadows: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.22),
                            blurRadius: 28,
                            offset: const Offset(0, 12),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 34,
                                height: 34,
                                decoration: ShapeDecoration(
                                  color: c.purpleBg,
                                  shape: prismSuperellipse(10),
                                ),
                                child: Icon(
                                  Icons.sync_rounded,
                                  size: 18,
                                  color: c.clay,
                                ),
                              ),
                              const SizedBox(width: 11),
                              Expanded(
                                child: Text(
                                  '检测到 Agent MCP 正在后台运行',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: c.ink,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '当前检测到运行实例（PID: ${_pendingRunningPids!.join(', ')}）。继续升级将自动平滑关闭旧进程并替换程序文件，您的配置文件、子 MCP 授权与历史日志将被完整保留。',
                            style: TextStyle(
                              fontSize: 12.6,
                              height: 1.5,
                              color: c.inkSoft,
                            ),
                          ),
                          const SizedBox(height: 18),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () =>
                                    setState(() => _pendingRunningPids = null),
                                child: const Text('暂不升级'),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                key: const ValueKey(
                                  'installer-confirm-close-running',
                                ),
                                style: FilledButton.styleFrom(
                                  backgroundColor: c.clay,
                                  foregroundColor: Colors.white,
                                  shape: prismSuperellipse(10),
                                ),
                                onPressed: () =>
                                    _startInstall(confirmedCloseRunning: true),
                                child: const Text('平滑关闭并升级'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _InstallerOptionSwitchRow extends StatelessWidget {
  final Key? switchKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _InstallerOptionSwitchRow({
    this.switchKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    return InkWell(
      onTap: enabled ? () => onChanged(!value) : null,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
        child: Row(
          children: [
            Icon(icon, size: 17, color: c.inkSoft),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 12.6,
                      fontWeight: FontWeight.w600,
                      color: c.ink,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11.2,
                      color: c.muted,
                    ),
                  ),
                ],
              ),
            ),
            Transform.scale(
              scale: 0.82,
              child: Switch(
                key: switchKey,
                value: value,
                onChanged: enabled ? onChanged : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrismSetupMiniMark extends StatelessWidget {
  final Color accent;
  final bool isDark;
  const _PrismSetupMiniMark({required this.accent, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: ShapeDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent,
            Color.lerp(accent, Colors.black, isDark ? 0.35 : 0.22)!,
          ],
        ),
        shape: prismSuperellipse(6.5),
      ),
      child: CustomPaint(painter: _ConcentricFacetPainter()),
    );
  }
}

class _PrismHeroEmblem extends StatelessWidget {
  final Color accent;
  final bool isDark;
  const _PrismHeroEmblem({required this.accent, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      decoration: ShapeDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent,
            Color.lerp(accent, const Color(0xFF1E1B4B), isDark ? 0.45 : 0.30)!,
          ],
        ),
        shape: prismSuperellipse(16),
        shadows: [
          BoxShadow(
            color: accent.withValues(alpha: isDark ? 0.32 : 0.24),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: CustomPaint(painter: _ConcentricFacetPainter()),
    );
  }
}

class _ConcentricFacetPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w * 0.5;
    final cy = h * 0.5;

    final outer = Path()
      ..moveTo(cx, h * 0.18)
      ..lineTo(w * 0.80, cy)
      ..lineTo(cx, h * 0.82)
      ..lineTo(w * 0.20, cy)
      ..close();
    canvas.drawPath(
      outer,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.22)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      outer,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.72)
        ..style = PaintingStyle.stroke
        ..strokeWidth = (w * 0.042).clamp(1.0, 2.2),
    );

    final inner = Path()
      ..moveTo(cx, h * 0.33)
      ..lineTo(w * 0.67, cy)
      ..lineTo(cx, h * 0.67)
      ..lineTo(w * 0.33, cy)
      ..close();
    canvas.drawPath(
      inner,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.94)
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
