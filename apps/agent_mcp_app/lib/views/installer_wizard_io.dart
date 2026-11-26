import 'dart:async';
import 'dart:convert';
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
class SixTierInstallDetection {
  final String directory;
  final String sourceCode;
  final String sourceLabel;
  final bool isUpgrade;

  const SixTierInstallDetection({
    required this.directory,
    required this.sourceCode,
    required this.sourceLabel,
    required this.isUpgrade,
  });

  static String labelForCode(String code, {required bool isUpgrade}) {
    return switch (code) {
      'explicit' => '命令行指定目录',
      'running_process' => '已定位运行中实例',
      'registry_install' => '注册表安装记录',
      'registry_autostart' => '开机自启项定位',
      'shortcut' => '桌面快捷方式定位',
      'manual_edit' => isUpgrade ? '覆盖升级目录' : '自定义安装目录',
      _ => isUpgrade ? '默认目录已有安装' : '默认用户目录',
    };
  }
}

String? _normalizeWindowsInstallCandidate(String? rawPathOrExe) {
  if (rawPathOrExe == null) return null;
  var clean = rawPathOrExe.trim();
  if (clean.startsWith('"') && clean.endsWith('"') && clean.length >= 2) {
    clean = clean.substring(1, clean.length - 1).trim();
  }
  if (clean.isEmpty) return null;
  final lower = clean.toLowerCase();
  if (lower.endsWith('.exe')) {
    final sepIdx = clean.lastIndexOf(RegExp(r'[\\/]'));
    if (sepIdx <= 0) return null;
    clean = clean.substring(0, sepIdx);
  }
  clean = clean.replaceAll(RegExp(r'[\\/]+$'), '');
  if (clean.isEmpty) return null;
  final tailName = clean.split(RegExp(r'[\\/]')).last.toLowerCase();
  if (tailName == 'bin') {
    final parentSep = clean.lastIndexOf(RegExp(r'[\\/]'));
    if (parentSep > 0) {
      clean = clean.substring(0, parentSep);
    }
  }
  if (clean.toLowerCase().contains('agentmcp-setup-')) {
    return null;
  }
  return clean;
}

String? _extractFirstExeFromWindowsCommand(String? rawCmd) {
  if (rawCmd == null) return null;
  final s = rawCmd.trim();
  if (s.isEmpty) return null;
  if (s.startsWith('"')) {
    final endQ = s.indexOf('"', 1);
    if (endQ > 1) return s.substring(1, endQ);
  }
  final m = RegExp(r'^(.+?\.exe)\b', caseSensitive: false).firstMatch(s);
  return m?.group(1)?.trim();
}

String? _extractExeTargetFromLnkBytes(Uint8List bytes) {
  String decodeUtf16LeAscii(Uint8List b) {
    final sb = StringBuffer();
    for (var i = 0; i + 1 < b.length; i += 2) {
      final code = b[i] | (b[i + 1] << 8);
      sb.writeCharCode((code >= 32 && code < 127) ? code : 0);
    }
    return sb.toString();
  }

  for (final text in [
    decodeUtf16LeAscii(bytes),
    String.fromCharCodes(bytes.map((c) => (c >= 32 && c < 127) ? c : 0)),
  ]) {
    final m = RegExp(
      r'([A-Za-z]:\\[^\x00"<>|?*]+?\\agent_mcp_app\.exe)',
      caseSensitive: false,
    ).firstMatch(text);
    if (m != null) return m.group(1);
  }
  return null;
}

/// Pure testable 6-tier current install location resolver shared with Windows SFX:
/// 1) `explicit` (`--dir`) -> 2) `running_process` (`agent_mcp_app` / `agent-mcp`) ->
/// 3) `registry_install` (`HKCU\Software\AgentMCP\InstallDir`, verified non-stale) ->
/// 4) `registry_autostart` (`HKCU\...\Run\AgentMCP`) ->
/// 5) `shortcut` (Desktop / Start Menu `.lnk`) -> 6) `default_dir` (`%LOCALAPPDATA%\Programs\AgentMCP`).
SixTierInstallDetection resolveSixTierInstallLocation({
  String? explicitDir,
  String? preDetectedDir,
  String? preDetectedSource,
  List<String> Function()? probeRunningExePaths,
  String? Function()? readRegistryInstallDir,
  String? Function()? readAutoStartCommand,
  List<String> Function()? readShortcutTargetPaths,
  bool Function(String dir)? hasInstallSignature,
  String? defaultInstallDir,
}) {
  final checkSig = hasInstallSignature ??
      (String d) {
        try {
          if (!Directory(d).existsSync()) return false;
          return File(p.join(d, 'agent_mcp_app.exe')).existsSync() ||
              File(p.join(d, 'agent-mcp.exe')).existsSync() ||
              File(p.join(d, 'bin', 'agent-mcp.exe')).existsSync();
        } catch (_) {
          return false;
        }
      };

  // Tier 1: Explicit CLI directory
  if (explicitDir != null && explicitDir.trim().isNotEmpty) {
    final clean = explicitDir.trim();
    final upg = checkSig(clean);
    return SixTierInstallDetection(
      directory: clean,
      sourceCode: 'explicit',
      sourceLabel: SixTierInstallDetection.labelForCode('explicit', isUpgrade: upg),
      isUpgrade: upg,
    );
  }

  // Honor bootstrapper pre-detected Tier 2..5 result if valid
  if (preDetectedDir != null &&
      preDetectedDir.trim().isNotEmpty &&
      preDetectedSource != null &&
      preDetectedSource != 'default_dir') {
    final cleanPre = preDetectedDir.trim();
    if (checkSig(cleanPre)) {
      return SixTierInstallDetection(
        directory: cleanPre,
        sourceCode: preDetectedSource,
        sourceLabel: SixTierInstallDetection.labelForCode(
          preDetectedSource,
          isUpgrade: true,
        ),
        isUpgrade: true,
      );
    }
  }

  // Tier 2: Running `agent_mcp_app.exe` or `agent-mcp.exe` process image path
  final exePaths = probeRunningExePaths != null
      ? probeRunningExePaths()
      : (() {
          if (!Platform.isWindows) return const <String>[];
          try {
            final selfPid = pid;
            final res = Process.runSync('powershell.exe', [
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              "Get-Process -Name 'agent_mcp_app','agent-mcp' -ErrorAction SilentlyContinue | Where-Object { \$_.Id -ne $selfPid -and \$_.Path } | Select-Object -ExpandProperty Path",
            ]);
            if (res.exitCode != 0) return const <String>[];
            return res.stdout
                .toString()
                .split(RegExp(r'\r?\n'))
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList();
          } catch (_) {
            return const <String>[];
          }
        })();
  for (final ep in exePaths) {
    final cand = _normalizeWindowsInstallCandidate(ep);
    if (cand != null && checkSig(cand)) {
      return SixTierInstallDetection(
        directory: cand,
        sourceCode: 'running_process',
        sourceLabel: SixTierInstallDetection.labelForCode(
          'running_process',
          isUpgrade: true,
        ),
        isUpgrade: true,
      );
    }
  }

  // Tier 3: Registry `HKCU\Software\AgentMCP\InstallDir` (skip deleted stale dirs!)
  final regDirRaw = readRegistryInstallDir != null
      ? readRegistryInstallDir()
      : (() {
          if (!Platform.isWindows) return null;
          try {
            final r = Process.runSync('reg', [
              'query',
              r'HKCU\Software\AgentMCP',
              '/v',
              'InstallDir',
            ]);
            if (r.exitCode == 0) {
              final m = RegExp(
                r'InstallDir\s+REG_SZ\s+(.+)$',
                multiLine: true,
              ).firstMatch(r.stdout.toString());
              return m?.group(1)?.trim();
            }
          } catch (_) {}
          return null;
        })();
  final regCand = _normalizeWindowsInstallCandidate(regDirRaw);
  if (regCand != null && checkSig(regCand)) {
    return SixTierInstallDetection(
      directory: regCand,
      sourceCode: 'registry_install',
      sourceLabel: SixTierInstallDetection.labelForCode(
        'registry_install',
        isUpgrade: true,
      ),
      isUpgrade: true,
    );
  }

  // Tier 4: Registry Auto-Start `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\AgentMCP`
  final autoCmdRaw = readAutoStartCommand != null
      ? readAutoStartCommand()
      : (() {
          if (!Platform.isWindows) return null;
          try {
            final r = Process.runSync('reg', [
              'query',
              r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
              '/v',
              'AgentMCP',
            ]);
            if (r.exitCode == 0) {
              final m = RegExp(
                r'AgentMCP\s+REG_SZ\s+(.+)$',
                multiLine: true,
              ).firstMatch(r.stdout.toString());
              return m?.group(1)?.trim();
            }
          } catch (_) {}
          return null;
        })();
  final autoCand = _normalizeWindowsInstallCandidate(
    _extractFirstExeFromWindowsCommand(autoCmdRaw),
  );
  if (autoCand != null && checkSig(autoCand)) {
    return SixTierInstallDetection(
      directory: autoCand,
      sourceCode: 'registry_autostart',
      sourceLabel: SixTierInstallDetection.labelForCode(
        'registry_autostart',
        isUpgrade: true,
      ),
      isUpgrade: true,
    );
  }

  // Tier 5: Desktop & Start Menu `Agent MCP Console.lnk`
  final shortcutTargets = readShortcutTargetPaths != null
      ? readShortcutTargetPaths()
      : (() {
          if (!Platform.isWindows) return const <String>[];
          final out = <String>[];
          final userProf = Platform.environment['USERPROFILE'] ?? '';
          final appData = Platform.environment['APPDATA'] ?? '';
          final lnkFiles = <String>[
            if (userProf.isNotEmpty)
              p.join(userProf, 'Desktop', 'Agent MCP Console.lnk'),
            if (appData.isNotEmpty)
              p.join(
                appData,
                'Microsoft',
                'Windows',
                'Start Menu',
                'Programs',
                'Agent MCP Console.lnk',
              ),
          ];
          for (final lf in lnkFiles) {
            try {
              final f = File(lf);
              if (f.existsSync()) {
                final t = _extractExeTargetFromLnkBytes(f.readAsBytesSync());
                if (t != null) out.add(t);
              }
            } catch (_) {}
          }
          return out;
        })();
  for (final st in shortcutTargets) {
    final scCand = _normalizeWindowsInstallCandidate(st);
    if (scCand != null && checkSig(scCand)) {
      return SixTierInstallDetection(
        directory: scCand,
        sourceCode: 'shortcut',
        sourceLabel: SixTierInstallDetection.labelForCode(
          'shortcut',
          isUpgrade: true,
        ),
        isUpgrade: true,
      );
    }
  }

  // Tier 6: Default user-mode directory
  final defDir = defaultInstallDir ??
      (() {
        if (Platform.isWindows) {
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
      })();
  final defUpg = checkSig(defDir);
  return SixTierInstallDetection(
    directory: defDir,
    sourceCode: 'default_dir',
    sourceLabel: SixTierInstallDetection.labelForCode(
      'default_dir',
      isUpgrade: defUpg,
    ),
    isUpgrade: defUpg,
  );
}

@immutable
class InstallerLaunchConfig {
  final String payloadDir;
  final String? explicitDir;
  final String? detectedDir;
  final String? detectedSource;
  final String afterMode;
  final bool createShortcut;
  final bool autoConfirmClose;

  const InstallerLaunchConfig({
    required this.payloadDir,
    this.explicitDir,
    this.detectedDir,
    this.detectedSource,
    this.afterMode = 'gui',
    this.createShortcut = true,
    this.autoConfirmClose = false,
  });

  factory InstallerLaunchConfig.fromArgs(List<String> args) {
    String? payloadDir;
    String? explicitDir;
    String? detectedDir;
    String? detectedSource;
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
      } else if (al == '--detected-dir' && i + 1 < args.length) {
        detectedDir = args[++i].trim();
      } else if (al == '--detected-source' && i + 1 < args.length) {
        detectedSource = args[++i].trim();
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
      detectedDir: detectedDir,
      detectedSource: detectedSource,
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

  void _toggleTheme(BuildContext ctx, bool currentlyDark) {
    final next = currentlyDark ? ThemeMode.light : ThemeMode.dark;
    unawaited(
      PrismThemeCrossFade.runThemeTransition(ctx, () {
        setState(() => _themeMode = next);
        unawaited(_syncNativeWindow());
      }),
    );
  }

  void _selectAccent(BuildContext ctx, PrismAccentId next) {
    if (_accentId == next) return;
    unawaited(
      PrismThemeCrossFade.runThemeTransition(ctx, () {
        PrismPalette.configureAccent(next);
        setState(() => _accentId = next);
      }),
    );
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
          onToggleTheme: _toggleTheme,
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
  final void Function(BuildContext, bool currentlyDark) onToggleTheme;
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
    required this.onToggleTheme,
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
  late String _initialDetectedDir;
  String _detectedSourceCode = 'default_dir';
  String _detectedSourceLabel = '默认用户目录';
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
    final resolved = resolveSixTierInstallLocation(
      explicitDir: widget.launchConfig.explicitDir,
      preDetectedDir: widget.launchConfig.detectedDir,
      preDetectedSource: widget.launchConfig.detectedSource,
    );
    _initialDetectedDir = resolved.directory;
    _detectedSourceCode = resolved.sourceCode;
    _detectedSourceLabel = resolved.sourceLabel;
    _isUpgrade = resolved.isUpgrade;
    _dirCtrl = TextEditingController(text: resolved.directory);
    _dirCtrl.addListener(() => _refreshUpgradeFlag(_dirCtrl.text));
  }

  @override
  void dispose() {
    _dirCtrl.dispose();
    super.dispose();
  }

  void _refreshUpgradeFlag(String rawDir) {
    final d = rawDir.trim();
    if (d.isEmpty) return;
    bool exists = false;
    try {
      final exeName = Platform.isWindows ? 'agent_mcp_app.exe' : 'agent_mcp_app';
      final cliName = Platform.isWindows ? 'agent-mcp.exe' : 'agent-mcp';
      exists = File(p.join(d, exeName)).existsSync() ||
          File(p.join(d, cliName)).existsSync() ||
          File(p.join(d, 'bin', cliName)).existsSync();
    } catch (_) {}
    final nextLabel = d.toLowerCase() == _initialDetectedDir.toLowerCase()
        ? SixTierInstallDetection.labelForCode(
            _detectedSourceCode,
            isUpgrade: exists,
          )
        : SixTierInstallDetection.labelForCode(
            'manual_edit',
            isUpgrade: exists,
          );
    if ((exists != _isUpgrade || nextLabel != _detectedSourceLabel) && mounted) {
      setState(() {
        _isUpgrade = exists;
        _detectedSourceLabel = nextLabel;
      });
    } else {
      _isUpgrade = exists;
      _detectedSourceLabel = nextLabel;
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

      await Future<void>.delayed(const Duration(milliseconds: 360));
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

    // Carry over the theme & accent previewed during fresh install so the console
    // opens seamlessly in the exact same appearance.
    try {
      final cfgFile = File(p.join(dstRoot.path, 'config', 'mcp_config.json'));
      if (!cfgFile.existsSync()) {
        cfgFile.parent.createSync(recursive: true);
        final modeStr = switch (widget.themeMode) {
          ThemeMode.light => 'light',
          ThemeMode.dark => 'dark',
          ThemeMode.system => 'system',
        };
        cfgFile.writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert({
            'theme_mode': modeStr,
            'accent_theme': widget.accentId.key,
          })}\n',
          flush: true,
        );
      }
    } catch (_) {}

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

  Widget _buildEditorialHeaderBar(BuildContext context, PrismPalette c) {
    final activeSpec = PrismAccentSpec.of(widget.accentId);
    return Container(
      height: 44,
      color: c.sidebar,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) {
                if (Platform.isWindows) {
                  _winChannel.invokeMethod<void>('startDragging');
                }
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 14),
            child: Row(
              children: [
                const PrismSparkIcon(size: 18),
                const SizedBox(width: 9),
                Text(
                  'Agent MCP 安装向导',
                  style: sansStyle(
                    c,
                    size: 12.8,
                    weight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
                const SizedBox(width: 8),
                PrismPill(
                  text: 'Prism Setup',
                  fg: c.muted,
                  bg: c.paper2,
                ),
                const Spacer(),
                // 6-accent live preview capsule matching ConsoleShellScreen
                DecoratedBox(
                  decoration: ShapeDecoration(
                    color: c.paper2,
                    shape: StadiumBorder(
                      side: BorderSide(
                        color: c.hairline.withValues(alpha: 0.72),
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 4.5,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0;
                            i < PrismAccentSpec.presets.length;
                            i++) ...[
                          if (i > 0) const SizedBox(width: 5),
                          _AccentDotSwatch(
                            spec: PrismAccentSpec.presets[i],
                            selected:
                                widget.accentId == PrismAccentSpec.presets[i].id,
                            palette: c,
                            onTap: () => widget.onSelectAccent(
                              context,
                              PrismAccentSpec.presets[i].id,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                PrismActionMenuButton(
                  tooltip: '切换主题色 · 当前：${activeSpec.label}',
                  minMenuWidth: 204,
                  actions: [
                    for (final spec in PrismAccentSpec.presets)
                      PrismMenuAction(
                        label: spec.label,
                        badge: widget.accentId == spec.id
                            ? '当前'
                            : (spec.badge.isNotEmpty ? spec.badge : null),
                        icon: widget.accentId == spec.id
                            ? Icons.radio_button_checked_rounded
                            : Icons.circle,
                        highlight: widget.accentId == spec.id,
                        onTap: () => widget.onSelectAccent(context, spec.id),
                      ),
                  ],
                  customTrigger: Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: ShapeDecoration(
                      color: c.paper3.withValues(alpha: 0.55),
                      shape: StadiumBorder(
                        side: BorderSide(
                          color: c.hairline.withValues(alpha: 0.72),
                        ),
                      ),
                    ),
                    child: Icon(
                      Icons.palette_outlined,
                      size: 14.5,
                      color: c.inkSoft,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                PrismButton(
                  key: const ValueKey('installer-theme-toggle'),
                  label: '',
                  compact: true,
                  variant: PrismBtnVariant.ghost,
                  tooltip: c.isDark ? '切换至浅色模式' : '切换至暗色模式',
                  leading: PrismFadeBox(
                    alignment: Alignment.center,
                    child: Icon(
                      c.isDark
                          ? Icons.light_mode_outlined
                          : Icons.dark_mode_outlined,
                      key: ValueKey(c.isDark),
                      size: 15.5,
                    ),
                  ),
                  onPressed: () => widget.onToggleTheme(context, c.isDark),
                ),
                const SizedBox(width: 6),
                Container(width: 1, height: 15, color: c.hairline),
                const SizedBox(width: 2),
                PrismWindowCaptionButton(
                  tooltip: '最小化',
                  glyph: PrismCaptionGlyph.minimize,
                  palette: c,
                  onTap: () {
                    if (Platform.isWindows) {
                      _winChannel.invokeMethod<void>('minimize');
                    }
                  },
                ),
                PrismWindowCaptionButton(
                  key: const ValueKey('installer-close-btn'),
                  tooltip: '退出向导',
                  glyph: PrismCaptionGlyph.close,
                  isClose: true,
                  enabled: !_installing,
                  palette: c,
                  onTap: _installing ? null : _closeWizard,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);

    return Scaffold(
      backgroundColor: c.sidebar,
      body: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildEditorialHeaderBar(context, c),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                  child: CustomPaint(
                    foregroundPainter: PrismSpecularRimPainter(
                      radius: 24,
                      isDark: c.isDark,
                      intensity: c.isDark ? 0.68 : 0.88,
                    ),
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        color: c.paper,
                        shape: prismSuperellipse(
                          24,
                          side: BorderSide(
                            color: c.hairline.withValues(alpha: 0.65),
                          ),
                        ),
                        shadows: c.whisperShadow,
                      ),
                      child: ClipRSuperellipse(
                        borderRadius: BorderRadius.circular(24),
                        child: Stack(
                          children: [
                            // Subtle ambient refraction glow inside 24px stage island
                            Positioned(
                              top: -110,
                              right: -60,
                              child: IgnorePointer(
                                child: Container(
                                  width: 300,
                                  height: 230,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: RadialGradient(
                                      colors: [
                                        c.clay.withValues(
                                          alpha: c.isDark ? 0.16 : 0.10,
                                        ),
                                        c.clay.withValues(alpha: 0.0),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(24, 18, 24, 16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // Hero Identity Header (matches UpdateAvailableDialog)
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      DecoratedBox(
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(14),
                                          boxShadow: [
                                            BoxShadow(
                                              color: c.clay.withValues(
                                                alpha: c.isDark ? 0.34 : 0.20,
                                              ),
                                              blurRadius: 12,
                                              offset: const Offset(0, 4),
                                            ),
                                          ],
                                        ),
                                        child: const PrismSparkIcon(size: 46),
                                      ),
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Wrap(
                                              spacing: 8,
                                              runSpacing: 4,
                                              crossAxisAlignment:
                                                  WrapCrossAlignment.center,
                                              children: [
                                                Text(
                                                  'Agent MCP Console',
                                                  style: serifTitleStyle(
                                                    c,
                                                    size: 20,
                                                    weight: FontWeight.w700,
                                                  ),
                                                ),
                                                PrismPill(
                                                  text: 'v$agentMcpVersion',
                                                  fg: c.clay,
                                                  bg: c.clay.withValues(
                                                    alpha: 0.12,
                                                  ),
                                                ),
                                                PrismPill(
                                                  text: _isUpgrade
                                                      ? '无损覆盖升级'
                                                      : '免 UAC 用户态部署',
                                                  mono: false,
                                                  fg: _isUpgrade
                                                      ? c.clay
                                                      : c.sage,
                                                  bg: _isUpgrade
                                                      ? c.purpleBg
                                                      : c.sageBg,
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              _isUpgrade
                                                  ? '检测到已有安装实例 · 升级过程完整保留配置、子 MCP 授权与日志'
                                                  : '原生系统托盘常驻 · 全协议子 MCP 网关 · 四态外链分享中枢',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: sansStyle(
                                                c,
                                                size: 12.2,
                                                color: c.muted,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),

                                  const SizedBox(height: 15),

                                  // 22px PrismListGroup: Target Directory + 14px Recessed Input + 999px PrismButton
                                  PrismListGroup(
                                    radius: 22,
                                    children: [
                                      PrismSettingsRow(
                                        icon: Icons.folder_open_rounded,
                                        iconColor: c.clay,
                                        title: '目标安装位置',
                                        subtitle: _isUpgrade
                                            ? '覆盖更新程序文件，现有配置与授权数据自动保留'
                                            : '自动创建目标文件夹，无需管理员权限',
                                        trailing: PrismPill(
                                          key: const ValueKey(
                                            'installer-source-pill',
                                          ),
                                          text: _detectedSourceLabel,
                                          mono: false,
                                          fg: _isUpgrade ? c.clay : c.muted,
                                          bg: _isUpgrade
                                              ? c.purpleBg
                                              : c.recessed,
                                        ),
                                        bottomChild: Row(
                                          children: [
                                            Expanded(
                                              child: TextField(
                                                key: const ValueKey(
                                                  'installer-dir-input',
                                                ),
                                                controller: _dirCtrl,
                                                enabled: !_installing,
                                                style: monoStyle(
                                                  c,
                                                  size: 12.2,
                                                  color: c.ink,
                                                ),
                                                decoration:
                                                    const InputDecoration(
                                                  hintText:
                                                      r'C:\Users\...\AppData\Local\Programs\AgentMCP',
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            PrismButton(
                                              key: const ValueKey(
                                                'installer-browse-btn',
                                              ),
                                              label: '浏览...',
                                              leading: const Icon(
                                                Icons.drive_folder_upload_rounded,
                                              ),
                                              onPressed: _installing
                                                  ? null
                                                  : _pickFolder,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),

                                  const SizedBox(height: 11),

                                  // 22px PrismListGroup: Options with 38x22 PrismSwitch
                                  PrismListGroup(
                                    radius: 22,
                                    children: [
                                      PrismSettingsRow(
                                        icon: Icons.desktop_windows_rounded,
                                        title: '创建桌面快捷方式',
                                        subtitle: '在桌面生成 Agent MCP Console 启动图标',
                                        onTap: _installing
                                            ? null
                                            : () => setState(
                                                  () => _createShortcut =
                                                      !_createShortcut,
                                                ),
                                        trailing: PrismSwitch(
                                          key: const ValueKey(
                                            'installer-shortcut-switch',
                                          ),
                                          value: _createShortcut,
                                          onChanged: _installing
                                              ? null
                                              : (v) => setState(
                                                    () => _createShortcut = v,
                                                  ),
                                        ),
                                      ),
                                      PrismSettingsRow(
                                        icon: Icons.rocket_launch_rounded,
                                        title: '安装完成后立即打开控制台',
                                        subtitle: '部署完毕自动唤醒图形工作台并挂载后台服务',
                                        onTap: _installing
                                            ? null
                                            : () => setState(
                                                  () => _launchAfter =
                                                      !_launchAfter,
                                                ),
                                        trailing: PrismSwitch(
                                          key: const ValueKey(
                                            'installer-launch-switch',
                                          ),
                                          value: _launchAfter,
                                          onChanged: _installing
                                              ? null
                                              : (v) => setState(
                                                    () => _launchAfter = v,
                                                  ),
                                        ),
                                      ),
                                    ],
                                  ),

                                  if (_errorMsg != null) ...[
                                    const SizedBox(height: 10),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 8,
                                      ),
                                      decoration: ShapeDecoration(
                                        color: c.dangerBg,
                                        shape: prismSuperellipse(
                                          14,
                                          side: BorderSide(
                                            color: c.danger.withValues(
                                              alpha: 0.30,
                                            ),
                                          ),
                                        ),
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
                                              style: sansStyle(
                                                c,
                                                size: 12,
                                                color: c.danger,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],

                                  const Spacer(),

                                  // Sculpted 999px Stadium Progress Capsule & PrismButton Footer
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Row(
                                        children: [
                                          PrismStatusDot(
                                            color: _completed
                                                ? c.sage
                                                : (_installing
                                                    ? c.clay
                                                    : c.meta),
                                            pulsing: _installing,
                                            size: 6.4,
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              _statusLabel,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: sansStyle(
                                                c,
                                                size: 12.0,
                                                weight:
                                                    _installing || _completed
                                                        ? FontWeight.w600
                                                        : FontWeight.w400,
                                                color: _completed
                                                    ? c.sage
                                                    : (_installing
                                                        ? c.ink
                                                        : c.muted),
                                              ),
                                            ),
                                          ),
                                          if (_installing || _completed)
                                            PrismPill(
                                              text:
                                                  '${(_progress * 100).round()}%',
                                              fg: c.clay,
                                              bg: c.clay.withValues(
                                                alpha: 0.12,
                                              ),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Container(
                                        height: 7,
                                        decoration: ShapeDecoration(
                                          color: c.recessed,
                                          shape: StadiumBorder(
                                            side: BorderSide(
                                              color: c.hairline.withValues(
                                                alpha: 0.72,
                                              ),
                                            ),
                                          ),
                                        ),
                                        clipBehavior: Clip.antiAlias,
                                        child: TweenAnimationBuilder<double>(
                                          tween: Tween<double>(
                                            begin: 0,
                                            end: (_installing || _completed)
                                                ? _progress.clamp(0.0, 1.0)
                                                : 0.0,
                                          ),
                                          duration:
                                              const Duration(milliseconds: 220),
                                          curve: Curves.easeOutCubic,
                                          builder: (ctx, val, _) {
                                            return Align(
                                              alignment: Alignment.centerLeft,
                                              child: FractionallySizedBox(
                                                widthFactor: val,
                                                heightFactor: 1.0,
                                                child: DecoratedBox(
                                                  decoration: ShapeDecoration(
                                                    gradient: LinearGradient(
                                                      colors: [
                                                        c.clay,
                                                        c.clayHover,
                                                      ],
                                                    ),
                                                    shape:
                                                        const StadiumBorder(),
                                                  ),
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                      const SizedBox(height: 13),
                                      Row(
                                        children: [
                                          Text(
                                            '便携包内核 · 支持随时迁移目录',
                                            style: sansStyle(
                                              c,
                                              size: 11.5,
                                              color: c.meta,
                                            ),
                                          ),
                                          const Spacer(),
                                          PrismButton(
                                            label: '取消',
                                            variant: PrismBtnVariant.ghost,
                                            onPressed: _installing
                                                ? null
                                                : _closeWizard,
                                          ),
                                          const SizedBox(width: 8),
                                          PrismButton(
                                            key: const ValueKey(
                                              'installer-submit-btn',
                                            ),
                                            label: _completed
                                                ? '已完成部署'
                                                : (_installing
                                                    ? '正在部署...'
                                                    : (_isUpgrade
                                                        ? '立即覆盖升级'
                                                        : '立即安装')),
                                            variant: PrismBtnVariant.clay,
                                            loading: _installing,
                                            leading: Icon(
                                              _completed
                                                  ? Icons.check_circle_rounded
                                                  : (_isUpgrade
                                                      ? Icons
                                                          .system_update_alt_rounded
                                                      : Icons
                                                          .download_done_rounded),
                                            ),
                                            onPressed:
                                                _installing || _completed
                                                    ? null
                                                    : () => _startInstall(),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ],
                              ),
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

          // Concentric 28px Frosted-Glass Running Instance Confirmation Modal
          if (_pendingRunningPids != null)
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: ColoredBox(
                  color: const Color(0x59080B12),
                  child: Center(
                    child: CustomPaint(
                      foregroundPainter: PrismSpecularRimPainter(
                        radius: 28,
                        isDark: c.isDark,
                        intensity: c.isDark ? 0.72 : 0.90,
                      ),
                      child: Container(
                        width: 436,
                        padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
                        decoration: ShapeDecoration(
                          color: c.paper2,
                          shape: prismSuperellipse(
                            28,
                            side: BorderSide(
                              color: c.hairline.withValues(alpha: 0.72),
                            ),
                          ),
                          shadows: c.popoverShadow,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 36,
                                  height: 36,
                                  decoration: ShapeDecoration(
                                    color: c.clay.withValues(alpha: 0.12),
                                    shape: prismSuperellipse(13),
                                  ),
                                  alignment: Alignment.center,
                                  child: Icon(
                                    Icons.sync_rounded,
                                    size: 17,
                                    color: c.clay,
                                  ),
                                ),
                                const SizedBox(width: 11),
                                Expanded(
                                  child: Text(
                                    '检测到 Agent MCP 正在后台运行',
                                    style: serifTitleStyle(c, size: 16.5),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 11),
                            Text(
                              '当前检测到运行实例（PID: ${_pendingRunningPids!.join(', ')}）。继续升级将平滑关闭旧进程并替换程序文件，您的配置文件、子 MCP 授权与历史日志将被完整保留。',
                              style: sansStyle(
                                c,
                                size: 13.0,
                                height: 1.56,
                                color: c.muted,
                              ),
                            ),
                            const SizedBox(height: 18),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                PrismButton(
                                  label: '暂不升级',
                                  compact: true,
                                  onPressed: () => setState(
                                    () => _pendingRunningPids = null,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                PrismButton(
                                  key: const ValueKey(
                                    'installer-confirm-close-running',
                                  ),
                                  label: '平滑关闭并升级',
                                  compact: true,
                                  variant: PrismBtnVariant.clay,
                                  leading: const Icon(
                                    Icons.system_update_alt_rounded,
                                  ),
                                  onPressed: () => _startInstall(
                                    confirmedCloseRunning: true,
                                  ),
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
            ),
        ],
      ),
    );
  }
}

class _AccentDotSwatch extends StatefulWidget {
  final PrismAccentSpec spec;
  final bool selected;
  final PrismPalette palette;
  final VoidCallback onTap;

  const _AccentDotSwatch({
    required this.spec,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  @override
  State<_AccentDotSwatch> createState() => _AccentDotSwatchState();
}

class _AccentDotSwatchState extends State<_AccentDotSwatch> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.palette;
    final sz = widget.selected ? 13.5 : (_hovered ? 12.5 : 11.0);
    return Tooltip(
      message: widget.spec.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: PrismMotion.editorialOut,
            width: sz,
            height: sz,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [widget.spec.swatchStart, widget.spec.swatchEnd],
              ),
              border: Border.all(
                color: widget.selected
                    ? c.ink
                    : Colors.white.withValues(alpha: c.isDark ? 0.25 : 0.70),
                width: widget.selected ? 1.5 : 1.0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
