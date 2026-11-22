import 'dart:async';
import 'dart:convert';
import 'dart:ui' show PlatformDispatcher, lerpDouble;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/console_backend.dart';
import 'theme/claude_theme.dart';
import 'views/activity_page.dart';
import 'views/exposure_page.dart';
import 'views/setup_page.dart';
import 'views/remote_nodes_dialog.dart';
import 'views/sub_mcp_page.dart';
import 'views/update_dialog.dart';

void main([List<String> _ = const []]) {
  late ConsoleBackend backend;
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      backend = createPlatformConsoleBackend();

      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        backend.recordUnhandledError(
          details.exception,
          details.stack ?? StackTrace.current,
        );
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        backend.recordUnhandledError(error, stack);
        return true;
      };

      await backend.init();
      runApp(AgentMcpConsoleApp(backend: backend));
    },
    (error, stack) {
      try {
        backend.recordUnhandledError(error, stack);
      } catch (_) {}
    },
  );
}

class AgentMcpConsoleApp extends StatefulWidget {
  final ConsoleBackend backend;
  const AgentMcpConsoleApp({super.key, required this.backend});

  @override
  State<AgentMcpConsoleApp> createState() => _AgentMcpConsoleAppState();
}

class _AgentMcpConsoleAppState extends State<AgentMcpConsoleApp> {
  ThemeMode _themeMode = ThemeMode.system;
  bool _dynamicColor = false;
  bool _dynamicColorSupported = false;
  final ValueNotifier<({String? message, int tick})> _toastNotifier =
      ValueNotifier((message: null, tick: 0));
  Timer? _globalToastTimer;

  @override
  void initState() {
    super.initState();
    _initAndroidDynamicColor();
  }

  Future<void> _initAndroidDynamicColor() async {
    if (!widget.backend.isAndroidPlatform) return;
    final dyn = await widget.backend.getAndroidDynamicColors();
    if (dyn['supported'] == true) {
      final lVal = dyn['accentLight'];
      final dVal = dyn['accentDark'];
      if (lVal is int && dVal is int) {
        ClaudePalette.configureDynamicColor(
          enabled: _dynamicColor,
          lightAccent: Color(lVal),
          darkAccent: Color(dVal),
        );
        if (mounted) {
          setState(() => _dynamicColorSupported = true);
        }
      }
    }
  }

  void _setDynamicColor(bool enabled) {
    ClaudePalette.configureDynamicColor(enabled: enabled);
    if (_dynamicColor != enabled) {
      setState(() => _dynamicColor = enabled);
    }
  }

  @override
  void dispose() {
    _globalToastTimer?.cancel();
    _toastNotifier.dispose();
    super.dispose();
  }

  void _showTopLevelToast(String msg) {
    _globalToastTimer?.cancel();
    _toastNotifier.value = (
      message: msg,
      tick: _toastNotifier.value.tick + 1,
    );
    _globalToastTimer = Timer(const Duration(milliseconds: 2500), () {
      _toastNotifier.value = (
        message: null,
        tick: _toastNotifier.value.tick,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final platformBrightness = MediaQuery.maybePlatformBrightnessOf(context) ??
        WidgetsBinding.instance.platformDispatcher.platformBrightness;

    return ClaudeThemeCrossFade(
      themeMode: _themeMode,
      platformBrightness: platformBrightness,
      child: MaterialApp(
        title: 'Agent MCP Console',
        debugShowCheckedModeBanner: false,
        scrollBehavior: const _ConsoleScrollBehavior(),
        themeAnimationDuration: Duration.zero,
        theme: buildClaudeTheme(
          ClaudePalette.activeLight,
          transparentScaffold: widget.backend.hasCustomTitleBar,
        ),
        darkTheme: buildClaudeTheme(
          ClaudePalette.activeDark,
          transparentScaffold: widget.backend.hasCustomTitleBar,
        ),
        themeMode: _themeMode,
        builder: (ctx, navChild) {
          return Stack(
            children: [
              if (navChild != null) navChild,
              _TopLevelToastLayer(notifier: _toastNotifier),
            ],
          );
        },
        home: ConsoleShellScreen(
          backend: widget.backend,
          themeMode: _themeMode,
          dynamicColor: _dynamicColor,
          dynamicColorSupported: _dynamicColorSupported,
          onDynamicColorChanged: _setDynamicColor,
          onGlobalToast: _showTopLevelToast,
          onThemeChanged: (m) {
            if (_themeMode != m) {
              setState(() => _themeMode = m);
            }
          },
        ),
      ),
    );
  }
}

class _TopLevelToastLayer extends StatelessWidget {
  final ValueNotifier<({String? message, int tick})> notifier;

  const _TopLevelToastLayer({required this.notifier});

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final isMobile = MediaQuery.sizeOf(context).width < 700;

    final safePad = MediaQuery.paddingOf(context);
    return ValueListenableBuilder<({String? message, int tick})>(
      valueListenable: notifier,
      builder: (ctx, state, _) {
        return Positioned(
          right: (isMobile ? 16.0 : 24.0) + safePad.right,
          left: isMobile ? 16.0 + safePad.left : null,
          bottom: (isMobile ? 82.0 : 44.0) + safePad.bottom,
          child: IgnorePointer(
            ignoring: true,
            child: Align(
              alignment: Alignment.bottomRight,
              child: AnimatedSwitcher(
                duration: ClaudeMotion.duration(
                  context,
                  const Duration(milliseconds: 230),
                ),
                reverseDuration: ClaudeMotion.duration(
                  context,
                  const Duration(milliseconds: 150),
                ),
                switchInCurve: ClaudeMotion.snappySpring,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, anim) {
                  return FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.24),
                        end: Offset.zero,
                      ).animate(anim),
                      child: child,
                    ),
                  );
                },
                child: state.message == null
                    ? const SizedBox.shrink(key: ValueKey('no-toast'))
                    : Material(
                        key: ValueKey('toast-${state.tick}'),
                        type: MaterialType.transparency,
                        child: ClaudeGlassBar(
                          blurSigma: 20,
                          borderRadius: 14,
                          tintColor: c.isDark
                              ? const Color(0xEB181A20)
                              : const Color(0xEB1A1D24),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10.5,
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x42000000),
                              blurRadius: 22,
                              offset: Offset(0, 8),
                            ),
                            BoxShadow(
                              color: Color(0x1E000000),
                              blurRadius: 6,
                              offset: Offset(0, 2),
                            ),
                          ],
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 420),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ClaudeSparkIcon(
                                  size: 14,
                                  color: c.isDark
                                      ? c.clay
                                      : const Color(0xFF818CF8),
                                ),
                                const SizedBox(width: 9),
                                Flexible(
                                  child: Text(
                                    state.message!,
                                    style: sansStyle(
                                      c,
                                      size: 13,
                                      color: const Color(0xFFFAF9F5),
                                      height: 1.25,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class ConsoleShellScreen extends StatefulWidget {
  final ConsoleBackend backend;
  final ThemeMode themeMode;
  final bool dynamicColor;
  final bool dynamicColorSupported;
  final ValueChanged<bool>? onDynamicColorChanged;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<String>? onGlobalToast;

  const ConsoleShellScreen({
    super.key,
    required this.backend,
    required this.themeMode,
    this.dynamicColor = false,
    this.dynamicColorSupported = false,
    this.onDynamicColorChanged,
    required this.onThemeChanged,
    this.onGlobalToast,
  });

  @override
  State<ConsoleShellScreen> createState() => _ConsoleShellScreenState();
}

class _ConsoleShellScreenState extends State<ConsoleShellScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  bool _checkingAuth = true;
  bool _authenticated = false;
  String _serverName = 'Agent MCP';
  String _version = '2.5.1';
  bool _dashboardMode = false;

  int _tabIndex = 0; // 0: Activity, 1: Sub-MCP, 2: Setup
  bool _sidebarManualCollapsed = false;
  bool _isRunning = false;
  bool _togglingService = false;
  bool _restartingService = false;
  int _evSeq = 0;
  bool? _lastSyncedWindowDark;
  String _lastStatusSignature = '';
  String _remoteConnError = '';

  Map<String, dynamic> _config = {};
  Map<String, dynamic> _tunnelInfo = {'installed': false, 'tunnels': {}};
  Map<String, dynamic> _storageStats = {};
  Map<String, dynamic> _exposureSummary = const {'enabled': true, 'active_count': 0, 'items': <dynamic>[]};
  List<Map<String, dynamic>> _subMcps = [];
  final List<Map<String, dynamic>> _events = [];

  StreamSubscription<Map<String, dynamic>>? _eventSub;
  Timer? _pollTimer;
  String? _toastMessage;
  int _toastTick = 0;
  Timer? _toastTimer;
  UpdatePreferences _updatePrefs = const UpdatePreferences();
  bool _checkingUpdate = false;
  UpdateInfo? _latestUpdate;
  bool _updateDialogOpen = false;
  Timer? _updateStartupTimer;
  Timer? _updatePeriodicTimer;

  late final AnimationController _sidebarCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    value: 1.0,
  );

  StreamSubscription<List<String>>? _dropSub;
  StreamSubscription<String>? _trayCmdSub;
  final ValueNotifier<String?> _droppedSharePath = ValueNotifier<String?>(null);
  final GlobalKey _themeBtnKey = GlobalKey();
  AppLifecycleState _appLifecycle = AppLifecycleState.resumed;

  static String _computeSearchBlob(Map<String, dynamic> ev) {
    final tool = (ev['tool'] ?? '').toString();
    final source = (ev['source'] ?? '').toString();
    final summary = (ev['summary'] ?? '').toString();
    final result = (ev['result'] ?? '').toString();
    final args = ev['args'] != null ? jsonEncode(ev['args']) : '';
    return '$tool $source $summary $result $args'.toLowerCase();
  }

  void _syncAnimationActivityState() {
    final winHidden = !widget.backend.windowState.value.isVisible;
    final appBackgrounded = _appLifecycle == AppLifecycleState.paused ||
        _appLifecycle == AppLifecycleState.hidden ||
        _appLifecycle == AppLifecycleState.detached;
    ClaudePulseClock.instance.setPaused(winHidden || appBackgrounded);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycle = state;
    _syncAnimationActivityState();
    if (state == AppLifecycleState.resumed && _authenticated && mounted) {
      unawaited(_refreshStatus());
    }
  }

  void _onWindowStateChanged() {
    _syncAnimationActivityState();
  }

  void _onExternalBackendSignal() {
    if (!mounted) return;
    _lastStatusSignature = '';
    if (_authenticated) {
      unawaited(_refreshStatus());
    } else {
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.backend.windowState.addListener(_onWindowStateChanged);
    widget.backend.externalRefreshSignal.addListener(_onExternalBackendSignal);
    _dropSub = widget.backend.droppedFilesStream.listen((paths) {
      if (!mounted || !_authenticated || paths.isEmpty) return;
      setState(() {
        _tabIndex = 2;
        _chromeVisible = true;
      });
      _droppedSharePath.value = paths.first;
    });
    _trayCmdSub = widget.backend.trayCommandStream.listen((cmd) {
      if (!mounted || !_authenticated) return;
      if (cmd == 'open_share') {
        setState(() {
          _tabIndex = 2;
          _chromeVisible = true;
        });
      } else if (cmd == 'check_update') {
        unawaited(_checkForUpdates(manual: true));
      }
    });
    _syncAnimationActivityState();
    _bootstrap();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncSidebarToViewport();
  }

  void _syncSidebarToViewport() {
    final width = MediaQuery.sizeOf(context).width;
    final isMobile = width < 700;
    if (isMobile) return;
    final shouldCollapse = _sidebarManualCollapsed || width < 960;
    final targetVal = shouldCollapse ? 0.0 : 1.0;
    if ((_sidebarCtrl.value - targetVal).abs() > 0.001 &&
        !_sidebarCtrl.isAnimating) {
      final d = ClaudeMotion.duration(
        context,
        const Duration(milliseconds: 240),
      );
      if (d == Duration.zero) {
        _sidebarCtrl.value = targetVal;
      } else {
        unawaited(
          _sidebarCtrl.animateTo(
            targetVal,
            duration: d,
            curve: ClaudeMotion.editorialOut,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.backend.windowState.removeListener(_onWindowStateChanged);
    _dropSub?.cancel();
    _trayCmdSub?.cancel();
    _droppedSharePath.dispose();
    _eventSub?.cancel();
    _pollTimer?.cancel();
    _toastTimer?.cancel();
    _updateStartupTimer?.cancel();
    _updatePeriodicTimer?.cancel();
    widget.backend.externalRefreshSignal.removeListener(_onExternalBackendSignal);
    _sidebarCtrl.dispose();
    super.dispose();
  }

  void _showToast(String msg) {
    if (!mounted) return;
    if (widget.onGlobalToast != null) {
      widget.onGlobalToast!(msg);
      return;
    }
    _toastTimer?.cancel();
    setState(() {
      _toastMessage = msg;
      _toastTick++;
    });
    _toastTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _toastMessage = null);
    });
  }

  Future<void> _bootstrap() async {
    _remoteConnError = '';
    try {
      final auth = await widget.backend.checkAuthState();
      _serverName = (auth['server_name'] ?? widget.backend.activeNode.name).toString();
      _version = (auth['version'] ?? '2.5.1').toString();
      _dashboardMode =
          auth['dashboard_mode'] == true || widget.backend.isRemoteNodeActive;
      _authenticated = auth['authenticated'] == true;
    } catch (e) {
      if (widget.backend.isWebMode || widget.backend.isRemoteNodeActive) {
        _authenticated = false;
        if (widget.backend.isRemoteNodeActive) {
          _serverName = widget.backend.activeNode.name;
          _remoteConnError = '无法连接远程节点（${widget.backend.activeNode.hostLabel}），请检查网络或切换回本机服务';
        }
      } else {
        _authenticated = true;
      }
    }
    if (mounted) setState(() => _checkingAuth = false);
    if (_authenticated) {
      await _startAuthenticatedSession();
    }
  }

  Future<void> _switchActiveNode(String nodeId) async {
    if (nodeId == '__manage_nodes__') {
      await _openRemoteNodesDialog();
      return;
    }
    await _eventSub?.cancel();
    _pollTimer?.cancel();
    setState(() {
      _checkingAuth = true;
      _lastStatusSignature = '';
      _events.clear();
      _subMcps = [];
    });
    await widget.backend.selectNode(nodeId);
    await _bootstrap();
    if (mounted) {
      _showToast('已切换至：${widget.backend.activeNode.name}');
    }
  }

  Future<void> _openCommandPalette() async {
    if (!mounted || !_authenticated) return;
    final res = await showClaudeDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _GlobalCommandPaletteDialog(
        serverName: _serverName,
        isRunning: _isRunning,
        isDark: Theme.of(context).brightness == Brightness.dark,
        activeNodeName: widget.backend.activeNode.name,
      ),
    );
    if (!mounted || res == null) return;
    final action = (res['action'] ?? '').toString();
    switch (action) {
      case 'share_direct':
        final target = (res['target'] ?? '').toString().trim();
        if (target.isNotEmpty) {
          setState(() {
            _tabIndex = 2;
            _chromeVisible = true;
          });
          _droppedSharePath.value = target;
        }
        break;
      case 'tab':
        final idx = (res['index'] as int?) ?? 0;
        _selectTab(idx);
        break;
      case 'nodes':
        if (widget.backend.supportsNodeSwitching) {
          await _openRemoteNodesDialog();
        }
        break;
      case 'restart':
        await _restartService();
        break;
      case 'toggle_theme':
        final isDark = Theme.of(context).brightness == Brightness.dark;
        _applyThemeWithSnapshot(isDark ? ThemeMode.light : ThemeMode.dark);
        break;
      case 'check_update':
        await _checkForUpdates(manual: true);
        break;
    }
  }

  Future<void> _openRemoteNodesDialog() async {
    await showRemoteNodesManagerDialog(
      context,
      backend: widget.backend,
      onToast: _showToast,
      onSwitchNode: _switchActiveNode,
    );
    if (mounted) setState(() {});
  }


  Future<void> _initUpdateScheduler() async {
    final prefs = await widget.backend.loadUpdatePreferences();
    if (!mounted) return;
    setState(() => _updatePrefs = prefs);

    _updateStartupTimer?.cancel();
    _updatePeriodicTimer?.cancel();

    if (prefs.isCheckDue()) {
      _updateStartupTimer = Timer(const Duration(seconds: 5), () {
        if (mounted && _authenticated && _updatePrefs.isCheckDue()) {
          unawaited(_checkForUpdates(manual: false));
        }
      });
    }

    _updatePeriodicTimer = Timer.periodic(const Duration(hours: 1), (_) {
      if (mounted &&
          _authenticated &&
          !ClaudePulseClock.instance.isPaused &&
          _updatePrefs.isCheckDue()) {
        unawaited(_checkForUpdates(manual: false));
      }
    });
  }

  Future<void> _handleUpdatePrefsChanged(UpdatePreferences next) async {
    await widget.backend.saveUpdatePreferences(next);
    if (!mounted) return;
    setState(() => _updatePrefs = next);
  }

  Future<void> _checkForUpdates({required bool manual}) async {
    if (_checkingUpdate) return;
    if (mounted) setState(() => _checkingUpdate = true);
    try {
      final res = await widget.backend.checkForUpdates(manual: manual);
      final latestPrefs = await widget.backend.loadUpdatePreferences();
      if (!mounted) return;
      setState(() {
        _updatePrefs = latestPrefs;
        _checkingUpdate = false;
        if (res.ok && res.latest != null) {
          _latestUpdate = res.latest;
        }
      });

      if (!res.ok) {
        if (manual) _showToast('检查更新失败：${res.error ?? '网络不可达'}');
        return;
      }

      if (res.hasUpdate && res.latest != null) {
        if (!res.skipped || manual) {
          await _showUpdateAvailableDialog(res.latest!, currentVersion: res.currentVersion);
        }
      } else if (manual) {
        _showToast('当前已是最新版本 (v${res.currentVersion})');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _checkingUpdate = false);
        if (manual) _showToast('检查更新失败：$e');
      }
    }
  }

  Future<void> _showUpdateAvailableDialog(
    UpdateInfo latest, {
    required String currentVersion,
  }) async {
    if (!mounted || _updateDialogOpen) return;
    _updateDialogOpen = true;
    try {
      final outcome = await showClaudeDialog<UpdateDialogOutcome>(
        context: context,
        builder: (_) => UpdateAvailableDialog(
          backend: widget.backend,
          currentVersion: currentVersion,
          latest: latest,
          mirrorPrefix: _updatePrefs.mirrorPrefix,
          onToast: _showToast,
        ),
      );
      if (!mounted) return;
      if (outcome == UpdateDialogOutcome.skipThisVersion) {
        final next = _updatePrefs.copyWith(skippedVersion: latest.version);
        await widget.backend.saveUpdatePreferences(next);
        if (mounted) {
          setState(() => _updatePrefs = next);
          _showToast('已忽略 v${latest.version} 更新提醒');
        }
      }
    } finally {
      _updateDialogOpen = false;
    }
  }

  Future<void> _startAuthenticatedSession() async {
    await Future.wait([
      _refreshStatus(),
      _loadInitialLogs(),
      _refreshSubMcps(),
      _refreshStorage(),
    ]);
    await _eventSub?.cancel();
    _eventSub = widget.backend.subscribeEvents().listen(_upsertEvent);
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!ClaudePulseClock.instance.isPaused) {
        _refreshStatus();
      }
    });
    unawaited(_initUpdateScheduler());
  }

  void _upsertEvent(Map<String, dynamic> rawEv) {
    if (!mounted) return;
    final callId = (rawEv['call_id'] ?? '').toString();
    setState(() {
      if (callId.isNotEmpty) {
        final idx = _events.indexWhere((x) => x['call_id'] == callId);
        if (idx != -1) {
          final prev = _events[idx];
          final merged = <String, dynamic>{
            ...prev,
            ...rawEv,
            '_seq': prev['_seq'],
            'args': rawEv['args'] ?? prev['args'],
          };
          merged['_search_blob'] = _computeSearchBlob(merged);
          _events[idx] = merged;
          return;
        }
      }
      final added = <String, dynamic>{...rawEv, '_seq': ++_evSeq};
      added['_search_blob'] = _computeSearchBlob(added);
      _events.add(added);
      if (_events.length > 3000) {
        _events.removeAt(0);
      }
    });
  }

  Future<void> _loadInitialLogs() async {
    try {
      final list = await widget.backend.getLogs();
      if (!mounted) return;
      setState(() {
        _events.clear();
        for (final item in list) {
          final callId = (item['call_id'] ?? '').toString();
          if (callId.isNotEmpty) {
            final idx = _events.indexWhere((x) => x['call_id'] == callId);
            if (idx != -1) {
              final prev = _events[idx];
              final merged = <String, dynamic>{
                ...prev,
                ...item,
                '_seq': prev['_seq'],
                'args': item['args'] ?? prev['args'],
              };
              merged['_search_blob'] = _computeSearchBlob(merged);
              _events[idx] = merged;
              continue;
            }
          }
          final added = <String, dynamic>{...item, '_seq': ++_evSeq};
          added['_search_blob'] = _computeSearchBlob(added);
          _events.add(added);
        }
      });
    } on UnauthorizedConsoleException {
      _handleUnauthorized();
    } catch (_) {}
  }

  Future<void> _refreshStatus() async {
    try {
      final st = await widget.backend.getStatus();
      if (!mounted) return;
      final sig = jsonEncode({
        'r': st['running'],
        'v': st['version'],
        'd': st['dashboard_mode'],
        'c': st['config'],
        't': st['tunnels'],
        'e': st['exposures'],
      });
      if (sig == _lastStatusSignature) {
        return; // Zero setState / zero rebuild when idle!
      }
      _lastStatusSignature = sig;
      setState(() {
        _isRunning = st['running'] == true;
        _version = (st['version'] ?? _version).toString();
        _dashboardMode = st['dashboard_mode'] == true;
        if (st['config'] is Map) {
          _config = Map<String, dynamic>.from(st['config'] as Map);
          _serverName = (_config['server_name'] ?? _serverName).toString();
          if (_config['dynamic_color'] is bool &&
              _config['dynamic_color'] != widget.dynamicColor) {
            final nextDyn = _config['dynamic_color'] == true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              widget.onDynamicColorChanged?.call(nextDyn);
            });
          }
        }
        if (st['tunnels'] is Map) {
          _tunnelInfo = Map<String, dynamic>.from(st['tunnels'] as Map);
        }
        if (st['exposures'] is Map) {
          _exposureSummary = Map<String, dynamic>.from(st['exposures'] as Map);
        }
      });
    } on UnauthorizedConsoleException {
      _handleUnauthorized();
    } catch (_) {}
  }

  Future<void> _refreshSubMcps() async {
    try {
      final list = await widget.backend.listSubMcps();
      if (!mounted) return;
      if (jsonEncode(list) == jsonEncode(_subMcps)) return;
      setState(() => _subMcps = list);
    } catch (_) {}
  }

  Future<void> _refreshStorage() async {
    try {
      final r = await widget.backend.getStorage();
      if (mounted && r['stats'] is Map) {
        final next = Map<String, dynamic>.from(r['stats'] as Map);
        if (jsonEncode(next) == jsonEncode(_storageStats)) return;
        setState(() => _storageStats = next);
      }
    } catch (_) {}
  }

  void _handleUnauthorized() {
    _eventSub?.cancel();
    _pollTimer?.cancel();
    if (mounted) setState(() => _authenticated = false);
  }

  Future<void> _toggleService() async {
    if (_togglingService || _restartingService) return;
    setState(() => _togglingService = true);
    try {
      await runWithMinDuration(() async {
        if (_isRunning) {
          await widget.backend.stopService();
        } else {
          await widget.backend.startService();
        }
        _lastStatusSignature = '';
        await _refreshStatus();
      });
      _showToast(_isRunning ? 'MCP 服务已启动' : 'MCP 服务已停止');
    } finally {
      if (mounted) setState(() => _togglingService = false);
    }
  }

  Future<void> _restartService() async {
    if (_togglingService || _restartingService) return;
    setState(() => _restartingService = true);
    try {
      await runWithMinDuration(() async {
        await widget.backend.restartService();
        _lastStatusSignature = '';
        await _refreshStatus();
      });
      _showToast('MCP 服务已重启');
    } finally {
      if (mounted) setState(() => _restartingService = false);
    }
  }

  Future<void> _exportLogs() async {
    final lines = _events.map((e) => jsonEncode(e)).join('\n');
    final name = 'agent_mcp_${DateTime.now().millisecondsSinceEpoch}.log';
    await widget.backend.exportLogsFile(name, lines);
    _showToast('已导出日志: $name');
  }

  bool _chromeVisible = true;
  double _scrollAccum = 0.0;
  int _dockCollapseTick = 0;

  void _setChromeVisible(bool visible) {
    if (_chromeVisible == visible) return;
    setState(() => _chromeVisible = visible);
  }

  void _collapseDockOnScroll() {
    _dockCollapseTick++;
  }

  void _setChromeVisibleManual(bool visible) {
    _scrollAccum = 0.0;
    setState(() {
      if (!visible) {
        _collapseDockOnScroll();
      }
      _chromeVisible = visible;
    });
  }

  void _applyScrollDelta(double delta, {double? pixels}) {
    if (delta.abs() > 2.0) {
      setState(_collapseDockOnScroll);
    }
    if (pixels != null && pixels <= 8 && delta < -1.5) {
      _scrollAccum = 0.0;
      _setChromeVisible(true);
      return;
    }
    if (delta == 0.0) return;
    if ((delta > 0 && _scrollAccum < 0) || (delta < 0 && _scrollAccum > 0)) {
      _scrollAccum = 0.0;
    }
    _scrollAccum += delta;
    if (_scrollAccum > 14) {
      _scrollAccum = 0.0;
      _setChromeVisible(false);
    } else if (_scrollAccum < -6) {
      _scrollAccum = 0.0;
      _setChromeVisible(true);
    }
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      // Captures mouse wheel scroll even when page is empty (maxScrollExtent == 0).
      _applyScrollDelta(event.scrollDelta.dy);
    }
  }

  void _handlePanZoomUpdate(PointerPanZoomUpdateEvent event) {
    // Captures Windows Precision Touchpad two-finger swipe even when empty.
    if (event.panDelta.dy.abs() > 0.5) {
      _applyScrollDelta(-event.panDelta.dy);
    }
  }

  bool _handleShellScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n is ScrollStartNotification && n.dragDetails != null) {
      setState(_collapseDockOnScroll);
    } else if (n is ScrollUpdateNotification) {
      final delta = n.scrollDelta ?? 0.0;
      // Ignore ballistic elastic bounce-back after releasing overscroll on empty/short pages.
      final isBallisticOverscrollReturn = n.dragDetails == null &&
          (n.metrics.outOfRange ||
              n.metrics.pixels > n.metrics.maxScrollExtent ||
              n.metrics.pixels < n.metrics.minScrollExtent);
      if (isBallisticOverscrollReturn) {
        return false;
      }
      _applyScrollDelta(delta, pixels: n.metrics.pixels);
    } else if (n is OverscrollNotification) {
      // Only treat user-driven overscroll (not ballistic recoil) as intent.
      if (n.dragDetails != null || n.velocity == 0.0) {
        _applyScrollDelta(n.overscroll);
      }
    }
    return false;
  }

  void _selectTab(int idx) {
    if (_tabIndex == idx) return;
    setState(() {
      _tabIndex = idx;
      _chromeVisible = true;
      _scrollAccum = 0.0;
    });
    if (idx == 1) unawaited(_refreshSubMcps());
    if (idx == 2) {
      _lastStatusSignature = '';
      unawaited(_refreshStatus());
    }
    if (idx == 3) {
      unawaited(_refreshStatus());
      unawaited(_refreshStorage());
    }
  }

  Offset? _themeToggleOrigin() {
    final box = _themeBtnKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      return box.localToGlobal(box.size.center(Offset.zero));
    }
    return null;
  }

  void _applyThemeWithSnapshot(ThemeMode next, {Offset? origin}) {
    if (widget.themeMode == next) return;
    unawaited(
      ClaudeThemeCrossFade.runThemeTransition(
        context,
        () => widget.onThemeChanged(next),
        origin: origin ?? _themeToggleOrigin(),
      ),
    );
  }

  void _cycleTheme(ClaudePalette c) {
    final next = c.isDark ? ThemeMode.light : ThemeMode.dark;
    _applyThemeWithSnapshot(next, origin: _themeToggleOrigin());
  }

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    if ((widget.backend.hasCustomTitleBar || widget.backend.isAndroidPlatform) && _lastSyncedWindowDark != c.isDark) {
      _lastSyncedWindowDark = c.isDark;
      unawaited(widget.backend.syncNativeWindowTheme(c.isDark));
    }

    return ValueListenableBuilder<DesktopWindowState>(
      valueListenable: widget.backend.windowState,
      builder: (ctx, winState, _) {
        final nativeMica =
            widget.backend.hasCustomTitleBar && winState.windowEffect;
        final micaActive = winState.windowEffect;

        if (_checkingAuth) {
          return Scaffold(
            backgroundColor: nativeMica ? Colors.transparent : c.paper,
            body: Column(
              children: [
                if (widget.backend.hasCustomTitleBar)
                  _buildEditorialHeaderBar(
                    c,
                    winState: winState,
                    micaActive: micaActive,
                    showAuthControls: false,
                  ),
                const Expanded(
                  child: Center(child: ClaudeSparkIcon(size: 28)),
                ),
              ],
            ),
          );
        }

        if (!_authenticated) {
          return _DashboardLoginScreen(
            key: ValueKey('login-${widget.backend.activeNode.id}'),
            serverName: _serverName,
            version: _version,
            initialError: _remoteConnError,
            backend: widget.backend,
            onLoggedIn: () {
              setState(() {
                _remoteConnError = '';
                _authenticated = true;
              });
              _startAuthenticatedSession();
            },
            onSwitchToLocal: widget.backend.isRemoteNodeActive
                ? () => _switchActiveNode('local')
                : null,
            onManageNodes: widget.backend.supportsNodeSwitching
                ? _openRemoteNodesDialog
                : null,
          );
        }

        return _buildConsoleShell(
          context,
          c,
          winState: winState,
          micaActive: micaActive,
        );
      },
    );
  }

  Widget _buildEditorialHeaderBar(
    ClaudePalette c, {
    required DesktopWindowState winState,
    required bool micaActive,
    bool showAuthControls = true,
  }) {
    final hasCustomBar = widget.backend.hasCustomTitleBar;
    final viewW = MediaQuery.sizeOf(context).width;
    final safePad = MediaQuery.paddingOf(context);
    final topSafe = safePad.top;
    final showModeBadge = viewW >= 760;
    final nodes = widget.backend.savedNodes;
    final activeNode = widget.backend.activeNode;

    String modeBadgeText = 'Desktop Native';
    if (widget.backend.isWebMode) {
      modeBadgeText = 'Web Dashboard';
    } else if (widget.backend.isRemoteNodeActive) {
      modeBadgeText = 'Remote · ${activeNode.hostLabel}';
    } else if (widget.backend.isAndroidPlatform) {
      modeBadgeText = 'Android · Dual-Mode';
    } else if (micaActive) {
      modeBadgeText = 'Desktop · Mica';
    }

    return SizedBox(
      height: 46 + topSafe,
      child: ClaudeGlassBar(
        blurSigma: 18,
        tintColor: micaActive ? c.micaSidebarTint : c.glassBarTint,
        border: Border(bottom: BorderSide(color: c.hairline.withValues(alpha: 0.45))),
        child: Padding(
          padding: EdgeInsets.only(top: topSafe),
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (hasCustomBar)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) => widget.backend.startWindowDrag(),
                    onDoubleTap: widget.backend.toggleMaximizeWindow,
                  ),
                ),
              Padding(
                padding: EdgeInsets.only(
                  left: 14 + safePad.left,
                  right: (hasCustomBar ? 0.0 : 12.0) + safePad.right,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: IgnorePointer(
                        ignoring: hasCustomBar,
                        child: Row(
                          children: [
                            const ClaudeSparkIcon(size: 17),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                viewW < 420 ? _serverName : '$_serverName Console',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: serifTitleStyle(c, size: 15.2),
                              ),
                            ),
                            if (showModeBadge) ...[
                              const SizedBox(width: 10),
                              ClaudePill(
                                text: modeBadgeText,
                                mono: false,
                                bg: c.paper2.withValues(alpha: 0.85),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (showAuthControls && viewW >= 860) ...[
                      InkWell(
                        onTap: _openCommandPalette,
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          height: 28,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: c.paper2.withValues(alpha: c.isDark ? 0.72 : 0.88),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: c.hairline.withValues(alpha: 0.9),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.search_rounded, size: 13.5, color: c.meta),
                              const SizedBox(width: 6),
                              Text(
                                '指令、切节点或贴路径秒享…',
                                style: sansStyle(c, size: 11.8, color: c.muted),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1.5,
                                ),
                                decoration: BoxDecoration(
                                  color: c.recessed,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: c.hairline),
                                ),
                                child: Text(
                                  'Ctrl K',
                                  style: monoStyle(c, size: 10, color: c.meta),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (showAuthControls &&
                            widget.backend.supportsNodeSwitching) ...[
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: (hasCustomBar && viewW < 460) ? 90 : (viewW < 430 ? 124 : 210),
                            ),
                            child: ClaudeDropMenu<String>(
                              value: activeNode.id,
                              tooltip: '切换本机服务或远程电脑节点',
                              leadingIcon: activeNode.isLocal
                                  ? (widget.backend.isAndroidPlatform
                                      ? Icons.smartphone_rounded
                                      : Icons.dns_rounded)
                                  : Icons.cloud_done_rounded,
                              highlightActive: !activeNode.isLocal,
                              minMenuWidth: 230,
                              items: [
                                for (final n in nodes)
                                  ClaudeDropMenuItem<String>(
                                    value: n.id,
                                    label: (hasCustomBar && viewW < 460 && n.isLocal)
                                        ? '本机'
                                        : (viewW < 430 && n.isLocal ? '本机服务' : n.name),
                                    icon: n.isLocal
                                        ? (widget.backend.isAndroidPlatform
                                            ? Icons.smartphone_rounded
                                            : Icons.dns_rounded)
                                        : Icons.computer_rounded,
                                    badge: n.isLocal ? 'LOCAL' : n.hostLabel,
                                  ),
                                const ClaudeDropMenuItem<String>(
                                  value: '__manage_nodes__',
                                  label: '管理远程节点...',
                                  icon: Icons.add_link_rounded,
                                ),
                              ],
                              onChanged: _switchActiveNode,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        ClaudeButton(
                        key: _themeBtnKey,
                        label: '',
                        compact: true,
                        variant: ClaudeBtnVariant.ghost,
                        tooltip: c.isDark ? '切换至暖纸浅色' : '切换至深岩暗色',
                        leading: ClaudeFadeBox(
                          alignment: Alignment.center,
                          child: Icon(
                            c.isDark
                                ? Icons.light_mode_outlined
                                : Icons.dark_mode_outlined,
                            key: ValueKey(c.isDark),
                            size: 15.5,
                          ),
                        ),
                        onPressed: () => _cycleTheme(c),
                      ),
                      if (showAuthControls && _dashboardMode) ...[
                        const SizedBox(width: 6),
                        ClaudeButton(
                          label: viewW >= 480 ? '退出登录' : '',
                          compact: true,
                          tooltip: '退出登录',
                          leading: const Icon(Icons.logout_rounded),
                          onPressed: () async {
                            await widget.backend.logout();
                            _handleUnauthorized();
                          },
                        ),
                      ],
                      if (hasCustomBar) ...[
                        const SizedBox(width: 6),
                        Container(
                          width: 1,
                          height: 16,
                          color: c.hairline,
                        ),
                        const SizedBox(width: 2),
                        ClaudeWindowCaptionActions(
                          isMaximized: winState.isMaximized,
                          isPinned: winState.isPinned,
                          onTogglePin: widget.backend.togglePinWindow,
                          onMinimize: widget.backend.minimizeWindow,
                          onToggleMaximize: widget.backend.toggleMaximizeWindow,
                          onCloseToTray: widget.backend.hideWindowToTray,
                        ),
                      ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConsoleShell(
    BuildContext context,
    ClaudePalette c, {
    required DesktopWindowState winState,
    required bool micaActive,
  }) {
    final width = MediaQuery.sizeOf(context).width;
    final isMobile = width < 700;
    final shouldCollapse =
        _sidebarManualCollapsed || (width < 960 && !isMobile);

    final enabledSubCount =
        _subMcps.where((s) => s['enabled'] != false).length;
    final activeExposeCount =
        int.tryParse('${_exposureSummary['active_count'] ?? 0}') ?? 0;

    final rawHosts = (_config['hosts'] as List?)
            ?.map((e) => e.toString().trim())
            .where((s) => s.isNotEmpty)
            .toList() ??
        const <String>[];
    final hostCfg = rawHosts.isNotEmpty
        ? rawHosts.first
        : (_config['host'] ?? kLoopbackIpv4).toString();
    final dispHost =
        (hostCfg == '0.0.0.0' || hostCfg == '::') ? kLoopbackIpv4 : hostCfg;
    final extraHostNote = rawHosts.length > 1
        ? ' (+${rawHosts.length - 1})'
        : (hostCfg == '0.0.0.0' ? ' (全网卡)' : '');
    final endpointStr =
        'http://$dispHost:${_config['port'] ?? 8000}/mcp$extraHostNote';

    final safePad = MediaQuery.paddingOf(context);
    final safeTop = safePad.top;
    final safeBottom = safePad.bottom;
    final safeLeft = safePad.left;
    final safeRight = safePad.right;

    final chromeDur = ClaudeMotion.duration(
      context,
      const Duration(milliseconds: 220),
    );
    // Floating immersive header on Android & Web so scrolling content invades
    // right behind the frosted glass header, status bar, and camera cutout!
    final useFloatingTopBar = isMobile || !widget.backend.hasCustomTitleBar;
    final hideTopOnScroll = true;
    final showTopChrome = !hideTopOnScroll || _chromeVisible;
    final pageTopInset = useFloatingTopBar
        ? (46.0 + safeTop + (isMobile ? 14.0 : 22.0))
        : 0.0;
    final pageExtraBottom = isMobile ? safeBottom : 0.0;

    final pages = <Widget>[
      ActivityFeedPage(
        key: const ValueKey('page-activity'),
        events: _events,
        topPadding: pageTopInset,
        extraBottomPadding: pageExtraBottom,
        onClear: () async {
          await widget.backend.clearLogs();
          setState(_events.clear);
          _showToast('已清空活动记录');
        },
        onExport: _exportLogs,
        onToast: _showToast,
      ),
      SubMcpGatewayPage(
        key: const ValueKey('page-submcp'),
        backend: widget.backend,
        servers: _subMcps,
        topPadding: pageTopInset,
        extraBottomPadding: pageExtraBottom,
        onRefresh: _refreshSubMcps,
        onToast: _showToast,
      ),
      ExposureSharePage(
        key: const ValueKey('page-exposure'),
        backend: widget.backend,
        exposureSummary: _exposureSummary,
        droppedPathSignal: _droppedSharePath,
        onConsumeDroppedPath: () => _droppedSharePath.value = null,
        topPadding: pageTopInset,
        extraBottomPadding: pageExtraBottom,
        onRefresh: () async {
          _lastStatusSignature = '';
          await _refreshStatus();
        },
        onToast: _showToast,
      ),
      ServiceSetupPage(
        key: const ValueKey('page-setup'),
        backend: widget.backend,
        config: _config,
        tunnelInfo: _tunnelInfo,
        storageStats: _storageStats,
        exposureSummary: _exposureSummary,
        isRunning: _isRunning,
        themeMode: widget.themeMode,
        topPadding: pageTopInset,
        extraBottomPadding: pageExtraBottom,
        onThemeChanged: _applyThemeWithSnapshot,
        dynamicColor: widget.dynamicColor,
        dynamicColorSupported: widget.dynamicColorSupported,
        onDynamicColorChanged: (v) async {
          widget.onDynamicColorChanged?.call(v);
          try {
            await widget.backend.saveConfig({'dynamic_color': v});
          } catch (_) {}
        },
        onRefreshStatus: () async {
          _lastStatusSignature = '';
          await _refreshStatus();
        },
        onRefreshStorage: _refreshStorage,
        onRestartService: _restartService,
        onToast: _showToast,
        updatePrefs: _updatePrefs,
        checkingUpdate: _checkingUpdate,
        latestUpdate: _latestUpdate,
        onUpdatePrefsChanged: _handleUpdatePrefsChanged,
        onCheckUpdate: () => _checkForUpdates(manual: true),
      ),
    ];

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _openCommandPalette,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            _openCommandPalette,
      },
      child: Scaffold(
      key: const ValueKey('shell'),
      backgroundColor:
          (widget.backend.hasCustomTitleBar && micaActive) ? Colors.transparent : c.paper,
      body: Stack(
        children: [
          if (micaActive && !widget.backend.hasCustomTitleBar)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(-0.85, -0.82),
                      radius: 1.15,
                      colors: [
                        c.clay.withValues(alpha: c.isDark ? 0.30 : 0.22),
                        c.paper.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (micaActive && !widget.backend.hasCustomTitleBar)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0.88, 0.85),
                      radius: 1.10,
                      colors: [
                        const Color(0xFF0EA5E9).withValues(alpha: c.isDark ? 0.22 : 0.16),
                        c.paper.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          Column(
            children: [
              if (!useFloatingTopBar)
                AnimatedContainer(
                  duration: chromeDur,
                  curve: ClaudeMotion.editorialOut,
                  height: showTopChrome ? 46.0 : 0.0,
                  clipBehavior: Clip.hardEdge,
                  decoration: const BoxDecoration(color: Colors.transparent),
                  child: SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    child: _buildEditorialHeaderBar(
                      c,
                      winState: winState,
                      micaActive: micaActive,
                    ),
                  ),
                ),
              Expanded(
                child: Row(
                  children: [
                    if (!isMobile)
                      AnimatedBuilder(
                        animation: _sidebarCtrl,
                        builder: (ctx, _) {
                          final t = _sidebarCtrl.value.clamp(0.0, 1.0);
                          final w = lerpDouble(68, 234, t)!;
                          final showLabels = t > 0.18;
                          final labelOpacity =
                              ((t - 0.25) / 0.75).clamp(0.0, 1.0);
                          final hPad = lerpDouble(10, 13, t)!;
                          final sidebarTopOffset = useFloatingTopBar
                              ? (showTopChrome ? 46.0 + safeTop : safeTop)
                              : 0.0;

                          return AnimatedContainer(
                            duration: chromeDur,
                            curve: ClaudeMotion.editorialOut,
                            width: w + safeLeft,
                            padding: EdgeInsets.fromLTRB(
                              hPad + safeLeft,
                              sidebarTopOffset + 14.0,
                              hPad,
                              14.0,
                            ),
                            decoration: BoxDecoration(
                              color: (micaActive && widget.backend.hasCustomTitleBar)
                                  ? Colors.transparent
                                  : (micaActive ? c.glassBarTint : c.sidebar),
                              border: (micaActive && widget.backend.hasCustomTitleBar)
                                  ? null
                                  : Border(
                                      right: BorderSide(color: c.hairline.withValues(alpha: 0.45)),
                                    ),
                            ),
                            child: LayoutBuilder(
                              builder: (sbCtx, sbBox) => SingleChildScrollView(
                                physics: const ClampingScrollPhysics(),
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minHeight: sbBox.maxHeight,
                                  ),
                                  child: IntrinsicHeight(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                SizedBox(
                                  height: 34,
                                  child: Row(
                                    children: [
                                      ClaudeButton(
                                        label: '',
                                        compact: true,
                                        variant: ClaudeBtnVariant.ghost,
                                        tooltip: shouldCollapse
                                            ? '展开侧边栏'
                                            : '收起侧边栏',
                                        leading: AnimatedRotation(
                                          turns: shouldCollapse ? 0.5 : 0.0,
                                          duration: ClaudeMotion.duration(
                                            context,
                                            ClaudeMotion.base,
                                          ),
                                          curve: ClaudeMotion.editorialOut,
                                          child: const Icon(
                                            Icons.chevron_left_rounded,
                                            size: 18,
                                          ),
                                        ),
                                        onPressed: width < 960
                                            ? null
                                            : () {
                                                setState(() {
                                                  _sidebarManualCollapsed =
                                                      !_sidebarManualCollapsed;
                                                });
                                                final next =
                                                    _sidebarManualCollapsed
                                                        ? 0.0
                                                        : 1.0;
                                                unawaited(
                                                  _sidebarCtrl.animateTo(
                                                    next,
                                                    duration:
                                                        ClaudeMotion.duration(
                                                      context,
                                                      const Duration(
                                                        milliseconds: 240,
                                                      ),
                                                    ),
                                                    curve: ClaudeMotion
                                                        .editorialOut,
                                                  ),
                                                );
                                              },
                                      ),
                                      if (showLabels)
                                        Expanded(
                                          child: Opacity(
                                            opacity: labelOpacity,
                                            child: ClipRect(
                                              child: Align(
                                                alignment: Alignment.centerLeft,
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                    left: 6,
                                                  ),
                                                  child: DecoratedBox(
                                                    decoration: ShapeDecoration(
                                                      color: _isRunning
                                                          ? c.sageBg
                                                          : c.paper3,
                                                      shape: StadiumBorder(
                                                        side: BorderSide(
                                                          color: _isRunning
                                                              ? c.sage
                                                                  .withValues(
                                                                  alpha: 0.30,
                                                                )
                                                              : c.hairline,
                                                        ),
                                                      ),
                                                    ),
                                                    child: Padding(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                        horizontal: 9,
                                                        vertical: 3.5,
                                                      ),
                                                      child: Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          ClaudeStatusDot(
                                                            color: _isRunning
                                                                ? c.sage
                                                                : c.meta,
                                                            pulsing: _isRunning,
                                                            size: 6.5,
                                                          ),
                                                          const SizedBox(
                                                            width: 4,
                                                          ),
                                                          Flexible(
                                                            child: Text(
                                                              _isRunning
                                                                  ? '运行中'
                                                                  : '已停止',
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: sansStyle(
                                                                c,
                                                                size: 12,
                                                                weight:
                                                                    FontWeight
                                                                        .w600,
                                                                color:
                                                                    _isRunning
                                                                        ? c.sage
                                                                        : c.muted,
                                                                height: 1.1,
                                                              ),
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 16),
                                _SidebarNavGroup(
                                  selectedIndex: _tabIndex,
                                  expandProgress: t,
                                  enabledSubCount: enabledSubCount,
                                  activeExposeCount: activeExposeCount,
                                  onSelect: _selectTab,
                                ),
                                const Spacer(),
                                Divider(color: c.hairline.withValues(alpha: 0.45), height: 22),
                                ClaudeButton(
                                  label: t > 0.55
                                      ? (_togglingService
                                          ? (_isRunning ? '停止中...' : '启动中...')
                                          : (_isRunning ? '停止服务' : '启动服务'))
                                      : '',
                                  leading: Icon(
                                    _isRunning
                                        ? Icons.stop_rounded
                                        : Icons.play_arrow_rounded,
                                  ),
                                  expand: true,
                                  loading: _togglingService,
                                  variant: _isRunning
                                      ? ClaudeBtnVariant.neutral
                                      : ClaudeBtnVariant.clay,
                                  tooltip: _isRunning ? '停止服务' : '启动服务',
                                  onPressed: _restartingService ? null : _toggleService,
                                ),
                                const SizedBox(height: 8),
                                ClaudeButton(
                                  label: t > 0.55
                                      ? (_restartingService ? '重启中...' : '重启服务')
                                      : '',
                                  leading: const Icon(Icons.refresh_rounded),
                                  expand: true,
                                  loading: _restartingService,
                                  tooltip: '重启服务',
                                  onPressed: _togglingService ? null : _restartService,
                                ),
                                if (!widget.backend.isWebMode) ...[
                                  const SizedBox(height: 8),
                                  ClaudeButton(
                                    label: t > 0.55 ? '完全退出' : '',
                                    leading: const Icon(
                                      Icons.power_settings_new_rounded,
                                    ),
                                    expand: true,
                                    variant: ClaudeBtnVariant.ghost,
                                    tooltip: '完全退出应用',
                                    onPressed: widget.backend.quitDesktopApp,
                                  ),
                                ],
                              ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    Expanded(
                      child: Container(
                        margin: (!isMobile && micaActive && widget.backend.hasCustomTitleBar)
                            ? EdgeInsets.fromLTRB(0, showTopChrome ? 0 : 8, 8, 8)
                            : EdgeInsets.zero,
                        clipBehavior: (!isMobile && micaActive && widget.backend.hasCustomTitleBar)
                            ? Clip.antiAlias
                            : Clip.none,
                        decoration: BoxDecoration(
                          color: !micaActive
                              ? c.paper
                              : (widget.backend.hasCustomTitleBar
                                  ? c.micaCanvasTint
                                  : Colors.transparent),
                          borderRadius: (!isMobile && micaActive && widget.backend.hasCustomTitleBar)
                              ? BorderRadius.circular(14)
                              : null,
                          border: (!isMobile && micaActive && widget.backend.hasCustomTitleBar)
                              ? Border.all(
                                  color: c.isDark
                                      ? Colors.white.withValues(alpha: 0.085)
                                      : Colors.black.withValues(alpha: 0.065),
                                  width: 1,
                                )
                              : null,
                          boxShadow: (!isMobile && micaActive && widget.backend.hasCustomTitleBar)
                              ? [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: c.isDark ? 0.34 : 0.06),
                                    blurRadius: 20,
                                    offset: const Offset(0, 4),
                                  ),
                                ]
                              : null,
                        ),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1280),
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(
                                isMobile ? 14.0 + safeLeft : 28.0,
                                useFloatingTopBar
                                    ? 0.0
                                    : (isMobile ? 14.0 : 22.0),
                                (isMobile ? 14.0 : 28.0) + safeRight,
                                0.0,
                              ),
                              child: Listener(
                                behavior: HitTestBehavior.translucent,
                                onPointerSignal: _handlePointerSignal,
                                onPointerPanZoomUpdate: _handlePanZoomUpdate,
                                child: NotificationListener<ScrollNotification>(
                                  onNotification: _handleShellScroll,
                                  child: ClaudeKeepAliveTabs(
                                    index: _tabIndex,
                                    axis: isMobile
                                        ? Axis.horizontal
                                        : Axis.vertical,
                                    children: pages,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (!isMobile)
                SizedBox(
                  height: 31 + safeBottom,
                  child: ClaudeGlassBar(
                    blurSigma: (micaActive && widget.backend.hasCustomTitleBar) ? 0 : 16,
                    tintColor: (micaActive && widget.backend.hasCustomTitleBar)
                        ? Colors.transparent
                        : c.glassBarTint,
                    border: Border(top: BorderSide(color: c.hairline)),
                    padding: EdgeInsets.only(
                      left: 18 + safeLeft,
                      right: 18 + safeRight,
                      bottom: safeBottom,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
                                flex: 2,
                                child: Text(
                                  _serverName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: sansStyle(
                                    c,
                                    size: 12,
                                    weight: FontWeight.w500,
                                    color: c.inkSoft,
                                    height: 1.0,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Container(
                                width: 3,
                                height: 3,
                                decoration: BoxDecoration(
                                  color: c.meta,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Flexible(
                                flex: 3,
                                child: Text(
                                  endpointStr,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: monoStyle(
                                    c,
                                    size: 11.5,
                                    color: c.muted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_latestUpdate != null &&
                            compareSemVer(_latestUpdate!.version, widget.backend.currentAppVersion) > 0) ...[
                          const SizedBox(width: 10),
                          InkWell(
                            onTap: () => _showUpdateAvailableDialog(
                              _latestUpdate!,
                              currentVersion: widget.backend.currentAppVersion,
                            ),
                            borderRadius: BorderRadius.circular(999),
                            child: ClaudePill(
                              text: '新版本 v${_latestUpdate!.version}',
                              fg: c.clay,
                              bg: c.clay.withValues(alpha: 0.12),
                            ),
                          ),
                        ],
                        if (width >= 760) ...[
                          const SizedBox(width: 12),
                          Text(
                            'Anthropic Editorial · Dart/Flutter v$_version',
                            maxLines: 1,
                            style: sansStyle(
                              c,
                              size: 11.5,
                              color: c.meta,
                              height: 1.0,
                              tabular: true,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
          if (useFloatingTopBar && safeTop > 0)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: safeTop + 14,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  duration: chromeDur,
                  curve: ClaudeMotion.editorialOut,
                  opacity: showTopChrome ? 0.0 : 1.0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          c.paper.withValues(alpha: 0.78),
                          c.paper.withValues(alpha: 0.36),
                          c.paper.withValues(alpha: 0.0),
                        ],
                        stops: const [0.0, 0.65, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (!showTopChrome)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 12,
              child: MouseRegion(
                opaque: false,
                onEnter: (_) {
                  if (!_chromeVisible && mounted) {
                    setState(() => _chromeVisible = true);
                  }
                },
              ),
            ),
          if (useFloatingTopBar)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AnimatedSlide(
                duration: chromeDur,
                curve: ClaudeMotion.editorialOut,
                offset: showTopChrome ? Offset.zero : const Offset(0, -1.08),
                child: AnimatedOpacity(
                  duration: chromeDur,
                  curve: ClaudeMotion.editorialOut,
                  opacity: showTopChrome ? 1.0 : 0.0,
                  child: IgnorePointer(
                    ignoring: !showTopChrome,
                    child: _buildEditorialHeaderBar(
                      c,
                      winState: winState,
                      micaActive: micaActive,
                    ),
                  ),
                ),
              ),
            ),
          if (isMobile)
            Positioned(
              right: 14 + safeRight,
              bottom: 78 + safeBottom,
              child: AnimatedSlide(
                duration: chromeDur,
                curve: ClaudeMotion.editorialOut,
                offset: _chromeVisible ? Offset.zero : const Offset(0, 1.8),
                child: AnimatedOpacity(
                  duration: chromeDur,
                  curve: ClaudeMotion.editorialOut,
                  opacity: _chromeVisible ? 1.0 : 0.0,
                  child: IgnorePointer(
                    ignoring: !_chromeVisible,
                    child: _MobileFloatingServiceDock(
                      isRunning: _isRunning,
                      toggling: _togglingService,
                      restarting: _restartingService,
                      collapseTick: _dockCollapseTick,
                      onToggle: _toggleService,
                      onRestart: _restartService,
                    ),
                  ),
                ),
              ),
            ),
          if (isMobile)
            Positioned.fill(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  top: false,
                  minimum: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                  child: AnimatedSlide(
                    duration: chromeDur,
                    curve: ClaudeMotion.editorialOut,
                    offset:
                        _chromeVisible ? Offset.zero : const Offset(0, 1.35),
                    child: AnimatedOpacity(
                      duration: chromeDur,
                      curve: ClaudeMotion.editorialOut,
                      opacity: _chromeVisible ? 1.0 : 0.0,
                      child: IgnorePointer(
                        ignoring: !_chromeVisible,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: Listener(
                            behavior: HitTestBehavior.translucent,
                            onPointerSignal: _handlePointerSignal,
                            child: _MobileGlassBottomNav(
                              selectedIndex: _tabIndex,
                              enabledSubCount: enabledSubCount,
                              activeExposeCount: activeExposeCount,
                              micaActive: micaActive,
                              onSelect: _selectTab,
                              onCollapse: () => _setChromeVisibleManual(false),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (isMobile)
            Positioned.fill(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  top: false,
                  minimum: const EdgeInsets.only(bottom: 8),
                  child: AnimatedSlide(
                    duration: chromeDur,
                    curve: ClaudeMotion.editorialOut,
                    offset:
                        _chromeVisible ? const Offset(0, 1.6) : Offset.zero,
                    child: AnimatedOpacity(
                      duration: chromeDur,
                      curve: ClaudeMotion.editorialOut,
                      opacity: _chromeVisible ? 0.0 : 1.0,
                      child: IgnorePointer(
                        ignoring: _chromeVisible,
                        child: _MobileCollapsedRestorePill(
                          onRestore: () => _setChromeVisibleManual(true),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (widget.onGlobalToast == null)
            Positioned(
              right: isMobile ? 16 : 24,
              left: isMobile ? 16 : null,
              bottom: isMobile ? 82 : 44,
            child: Align(
              alignment: Alignment.bottomRight,
              child: AnimatedSwitcher(
                duration: ClaudeMotion.duration(
                  context,
                  const Duration(milliseconds: 230),
                ),
                reverseDuration: ClaudeMotion.duration(
                  context,
                  const Duration(milliseconds: 150),
                ),
                switchInCurve: ClaudeMotion.snappySpring,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, anim) {
                  return FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.24),
                        end: Offset.zero,
                      ).animate(anim),
                      child: child,
                    ),
                  );
                },
                child: _toastMessage == null
                    ? const SizedBox.shrink(key: ValueKey('no-toast'))
                    : Material(
                        key: ValueKey('toast-$_toastTick'),
                        color: Colors.transparent,
                        child: ClaudeGlassBar(
                          blurSigma: 20,
                          borderRadius: 14,
                          tintColor: c.isDark
                              ? const Color(0xDB282724)
                              : const Color(0xE01F1E1C),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10.5,
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x36000000),
                              blurRadius: 18,
                              offset: Offset(0, 6),
                            ),
                          ],
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 420),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ClaudeSparkIcon(
                                  size: 14,
                                  color: c.isDark
                                      ? c.clay
                                      : const Color(0xFF818CF8),
                                ),
                                const SizedBox(width: 9),
                                Flexible(
                                  child: Text(
                                    _toastMessage!,
                                    style: sansStyle(
                                      c,
                                      size: 13,
                                      color: const Color(0xFFFAF9F5),
                                      height: 1.25,
                                    ),
                                  ),
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
      ),
    );
  }
}

class _MobileFloatingServiceDock extends StatefulWidget {
  final bool isRunning;
  final bool toggling;
  final bool restarting;
  final int collapseTick;
  final VoidCallback onToggle;
  final VoidCallback onRestart;

  const _MobileFloatingServiceDock({
    required this.isRunning,
    required this.toggling,
    required this.restarting,
    required this.collapseTick,
    required this.onToggle,
    required this.onRestart,
  });

  @override
  State<_MobileFloatingServiceDock> createState() =>
      _MobileFloatingServiceDockState();
}

class _MobileFloatingServiceDockState extends State<_MobileFloatingServiceDock> {
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant _MobileFloatingServiceDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.collapseTick != oldWidget.collapseTick &&
        _expanded &&
        !widget.toggling &&
        !widget.restarting) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final busy = widget.toggling || widget.restarting;
    final showExpanded = _expanded || busy;

    return ClaudeGlassBar(
      blurSigma: 20,
      borderRadius: 16,
      tintColor: c.isDark
          ? const Color(0xDE181A20)
          : const Color(0xECFFFFFF),
      boxShadow: const [
        BoxShadow(
          color: Color(0x26000000),
          blurRadius: 16,
          offset: Offset(0, 4),
        ),
      ],
      padding: EdgeInsets.symmetric(
        horizontal: showExpanded ? 10 : 8,
        vertical: showExpanded ? 6 : 5,
      ),
      child: AnimatedSize(
        duration: ClaudeMotion.duration(
          context,
          const Duration(milliseconds: 220),
        ),
        curve: ClaudeMotion.snappySpring,
        alignment: Alignment.centerRight,
        child: showExpanded
            ? Row(
                key: const ValueKey('dock-expanded'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClaudeStatusDot(
                    color: widget.isRunning ? c.sage : c.meta,
                    pulsing: widget.isRunning,
                    size: 7.0,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    widget.isRunning ? '运行中' : '已停止',
                    style: sansStyle(
                      c,
                      size: 12,
                      weight: FontWeight.w600,
                      color: widget.isRunning ? c.sage : c.muted,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(width: 1, height: 16, color: c.hairline),
                  const SizedBox(width: 6),
                  ClaudeButton(
                    label: widget.isRunning ? '停止' : '启动',
                    compact: true,
                    loading: widget.toggling,
                    variant: widget.isRunning
                        ? ClaudeBtnVariant.neutral
                        : ClaudeBtnVariant.clay,
                    leading: Icon(
                      widget.isRunning
                          ? Icons.stop_rounded
                          : Icons.play_arrow_rounded,
                    ),
                    onPressed: widget.restarting ? null : widget.onToggle,
                  ),
                  const SizedBox(width: 6),
                  ClaudeButton(
                    label: '',
                    compact: true,
                    loading: widget.restarting,
                    tooltip: '重启 MCP 服务',
                    leading: const Icon(Icons.refresh_rounded),
                    onPressed: widget.toggling ? null : widget.onRestart,
                  ),
                  const SizedBox(width: 4),
                  ClaudeButton(
                    label: '',
                    compact: true,
                    variant: ClaudeBtnVariant.ghost,
                    tooltip: '收起控制坞',
                    leading: const Icon(Icons.chevron_right_rounded, size: 17),
                    onPressed:
                        busy ? null : () => setState(() => _expanded = false),
                  ),
                ],
              )
            : InkWell(
                key: const ValueKey('dock-mini'),
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() => _expanded = true),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 3,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ClaudeStatusDot(
                        color: widget.isRunning ? c.sage : c.meta,
                        pulsing: widget.isRunning,
                        size: 7.0,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        widget.isRunning ? '运行中' : '已停止',
                        style: sansStyle(
                          c,
                          size: 12,
                          weight: FontWeight.w600,
                          color: widget.isRunning ? c.sage : c.muted,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.tune_rounded,
                        size: 14,
                        color: c.muted,
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

class _ConsoleScrollBehavior extends MaterialScrollBehavior {
  const _ConsoleScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.unknown,
      };
}

class _MobileGlassBottomNav extends StatelessWidget {
  final int selectedIndex;
  final int enabledSubCount;
  final int activeExposeCount;
  final bool micaActive;
  final ValueChanged<int> onSelect;
  final VoidCallback onCollapse;

  const _MobileGlassBottomNav({
    required this.selectedIndex,
    required this.enabledSubCount,
    this.activeExposeCount = 0,
    required this.micaActive,
    required this.onSelect,
    required this.onCollapse,
  });

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final items = <(IconData, IconData, String, String?)>[
      (Icons.bolt_outlined, Icons.bolt_rounded, '调用流', null),
      (
        Icons.hub_outlined,
        Icons.hub_rounded,
        '子 MCP',
        enabledSubCount > 0 ? '$enabledSubCount' : null,
      ),
      (
        Icons.public_outlined,
        Icons.public_rounded,
        '外网',
        activeExposeCount > 0 ? '$activeExposeCount' : null,
      ),
      (Icons.tune_outlined, Icons.tune_rounded, '服务配置', null),
    ];

    final slideDur = ClaudeMotion.duration(
      context,
      const Duration(milliseconds: 280),
    );
    final glassTint = micaActive
        ? c.micaSidebarTint
        : (c.isDark ? const Color(0xD8181A20) : const Color(0xE6FFFFFF));
    final glassBorder = c.isDark
        ? Colors.white.withValues(alpha: 0.11)
        : Colors.black.withValues(alpha: 0.08);
    final glassShadow = [
      BoxShadow(
        color: Colors.black.withValues(alpha: c.isDark ? 0.45 : 0.10),
        blurRadius: 28,
        offset: const Offset(0, 10),
      ),
      BoxShadow(
        color: c.clay.withValues(alpha: c.isDark ? 0.08 : 0.05),
        blurRadius: 12,
        offset: const Offset(0, 2),
      ),
    ];

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: ClaudeGlassBar(
            blurSigma: micaActive ? 26 : 0,
            borderRadius: 999,
            tintColor: micaActive ? glassTint : c.paper2,
            border: Border.all(color: glassBorder, width: 1.0),
            boxShadow: glassShadow,
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
            child: SizedBox(
              height: 54,
              child: LayoutBuilder(
                builder: (ctx, box) {
                  final slotW = box.maxWidth / items.length;
                  const hPad = 2.0;
                  final pillW = (slotW - hPad * 2).clamp(44.0, slotW);
                  final pillLeft = selectedIndex * slotW + hPad;

                  return Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      AnimatedPositioned(
                        duration: slideDur,
                        curve: ClaudeMotion.snappySpring,
                        left: pillLeft,
                        top: 1,
                        bottom: 1,
                        width: pillW,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: c.clay.withValues(
                              alpha: c.isDark ? 0.22 : 0.11,
                            ),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: c.clay.withValues(
                                alpha: c.isDark ? 0.34 : 0.18,
                              ),
                              width: 0.8,
                            ),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          for (var i = 0; i < items.length; i++)
                            Expanded(
                              child: _MobileNavTabButton(
                                icon: selectedIndex == i
                                    ? items[i].$2
                                    : items[i].$1,
                                label: items[i].$3,
                                badge: items[i].$4,
                                active: selectedIndex == i,
                                onTap: () => onSelect(i),
                              ),
                            ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        ClaudeGlassBar(
          blurSigma: micaActive ? 26 : 0,
          borderRadius: 999,
          tintColor: micaActive ? glassTint : c.paper2,
          border: Border.all(color: glassBorder, width: 1.0),
          boxShadow: glassShadow,
          padding: const EdgeInsets.all(4),
          child: _MobileNavCollapseButton(onTap: onCollapse),
        ),
      ],
    );
  }
}

class _MobileNavCollapseButton extends StatefulWidget {
  final VoidCallback onTap;

  const _MobileNavCollapseButton({required this.onTap});

  @override
  State<_MobileNavCollapseButton> createState() =>
      _MobileNavCollapseButtonState();
}

class _MobileNavCollapseButtonState extends State<_MobileNavCollapseButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    return Tooltip(
      message: '收起底栏',
      waitDuration: const Duration(milliseconds: 420),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _pressed ? 0.90 : 1.0,
            duration: ClaudeMotion.duration(
              context,
              const Duration(milliseconds: 110),
            ),
            curve: ClaudeMotion.editorialOut,
            child: AnimatedContainer(
              duration: ClaudeMotion.duration(
                context,
                const Duration(milliseconds: 150),
              ),
              width: 54,
              height: 54,
              decoration: ShapeDecoration(
                color: _hovered
                    ? (c.isDark
                        ? Colors.white.withValues(alpha: 0.07)
                        : Colors.black.withValues(alpha: 0.05))
                    : Colors.transparent,
                shape: const CircleBorder(),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: _hovered ? c.ink : c.muted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileCollapsedRestorePill extends StatefulWidget {
  final VoidCallback onRestore;

  const _MobileCollapsedRestorePill({required this.onRestore});

  @override
  State<_MobileCollapsedRestorePill> createState() =>
      _MobileCollapsedRestorePillState();
}

class _MobileCollapsedRestorePillState
    extends State<_MobileCollapsedRestorePill> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    return Tooltip(
      message: '展开导航栏',
      waitDuration: const Duration(milliseconds: 350),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onRestore,
          child: AnimatedScale(
            scale: _pressed ? 0.92 : (_hovered ? 1.04 : 1.0),
            duration: ClaudeMotion.duration(
              context,
              const Duration(milliseconds: 130),
            ),
            curve: ClaudeMotion.editorialOut,
            child: ClaudeGlassBar(
              blurSigma: 16,
              borderRadius: 99,
              tintColor: c.isDark
                  ? const Color(0xD8181A20)
                  : const Color(0xE8FFFFFF),
              border: Border.all(
                color: _hovered ? c.ringHover : c.hairline,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: c.isDark ? 0.34 : 0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ],
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3.5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 20,
                    height: 3,
                    decoration: BoxDecoration(
                      color: _hovered ? c.clay : c.muted.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.keyboard_arrow_up_rounded,
                    size: 15,
                    color: _hovered ? c.clay : c.muted,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileNavTabButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final String? badge;
  final bool active;
  final VoidCallback onTap;

  const _MobileNavTabButton({
    required this.icon,
    required this.label,
    this.badge,
    required this.active,
    required this.onTap,
  });

  @override
  State<_MobileNavTabButton> createState() => _MobileNavTabButtonState();
}

class _MobileNavTabButtonState extends State<_MobileNavTabButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final iconColor = widget.active
        ? c.clay
        : (_hovered ? c.inkSoft : c.muted);
    final labelColor = widget.active
        ? c.clay
        : (_hovered ? c.inkSoft : c.muted);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: SizedBox.expand(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(widget.icon, size: 19.0, color: iconColor),
                  if (widget.badge != null)
                    Positioned(
                      top: -5,
                      right: -12,
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          color: c.clay,
                          shape: const StadiumBorder(),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4.5,
                            vertical: 0.5,
                          ),
                          child: Text(
                            widget.badge!,
                            style: monoStyle(
                              c,
                              size: 9.0,
                              weight: FontWeight.w700,
                              color: Colors.white,
                              height: 1.15,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  widget.label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                  style: sansStyle(
                    c,
                    size: 10.5,
                    weight: widget.active ? FontWeight.w600 : FontWeight.w500,
                    color: labelColor,
                    height: 1.1,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarNavGroup extends StatelessWidget {
  final int selectedIndex;
  final double expandProgress;
  final int enabledSubCount;
  final int activeExposeCount;
  final ValueChanged<int> onSelect;

  const _SidebarNavGroup({
    required this.selectedIndex,
    required this.expandProgress,
    required this.enabledSubCount,
    this.activeExposeCount = 0,
    required this.onSelect,
  });

  static const double _itemH = 40.0;
  static const double _gap = 5.0;

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final items = <(IconData, String, String?)>[
      (Icons.notes_rounded, '活动与调用流', null),
      (
        Icons.hub_outlined,
        '子 MCP 网关',
        enabledSubCount > 0 ? '$enabledSubCount' : null,
      ),
      (
        Icons.public_rounded,
        '外网与分享',
        activeExposeCount > 0 ? '$activeExposeCount' : null,
      ),
      (Icons.tune_rounded, '服务配置', null),
    ];

    final activeTop = selectedIndex * (_itemH + _gap);
    final slideDur = ClaudeMotion.duration(
      context,
      const Duration(milliseconds: 260),
    );

    return SizedBox(
      height: items.length * _itemH + (items.length - 1) * _gap,
      child: Stack(
        children: [
          AnimatedPositioned(
            duration: slideDur,
            curve: ClaudeMotion.snappySpring,
            top: activeTop,
            left: 0,
            right: 0,
            height: _itemH,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: c.paper2,
                shape: claudeSuperellipse(
                  12,
                  side: BorderSide(color: c.hairline),
                ),
                shadows: [
                  BoxShadow(
                    color: Colors.black
                        .withValues(alpha: c.isDark ? 0.24 : 0.04),
                    blurRadius: 6,
                    offset: const Offset(0, 1.5),
                  ),
                ],
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.only(left: 3.5),
                  width: 3,
                  height: 16,
                  decoration: BoxDecoration(
                    color: c.clay,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
            ),
          ),
          Column(
            children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const SizedBox(height: _gap),
                _SidebarNavBtn(
                  height: _itemH,
                  icon: items[i].$1,
                  label: items[i].$2,
                  badge: items[i].$3,
                  active: selectedIndex == i,
                  expandProgress: expandProgress,
                  onTap: () => onSelect(i),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _SidebarNavBtn extends StatefulWidget {
  final double height;
  final IconData icon;
  final String label;
  final String? badge;
  final bool active;
  final double expandProgress;
  final VoidCallback onTap;

  const _SidebarNavBtn({
    required this.height,
    required this.icon,
    required this.label,
    this.badge,
    required this.active,
    required this.expandProgress,
    required this.onTap,
  });

  @override
  State<_SidebarNavBtn> createState() => _SidebarNavBtnState();
}

class _SidebarNavBtnState extends State<_SidebarNavBtn> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final collapsed = widget.expandProgress < 0.35;
    final labelAlpha = ((widget.expandProgress - 0.3) / 0.7).clamp(0.0, 1.0);

    Widget row = AnimatedContainer(
      duration: ClaudeMotion.duration(context, ClaudeMotion.fast),
      height: widget.height,
      padding: EdgeInsets.symmetric(horizontal: collapsed ? 0 : 12),
      decoration: ShapeDecoration(
        color: (!widget.active && _hovered)
            ? c.paper3.withValues(alpha: 0.65)
            : c.paper3.withValues(alpha: 0.0),
        shape: claudeSuperellipse(12),
      ),
      child: Row(
        mainAxisAlignment:
            collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
        children: [
          Icon(
            widget.icon,
            size: 18,
            color: widget.active
                ? c.clay
                : (_hovered ? c.inkSoft : c.muted),
          ),
          if (!collapsed) ...[
            const SizedBox(width: 10),
            Expanded(
              child: Opacity(
                opacity: labelAlpha,
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: sansStyle(
                    c,
                    size: 13.5,
                    weight: widget.active ? FontWeight.w600 : FontWeight.w500,
                    color: widget.active
                        ? c.ink
                        : (_hovered ? c.inkSoft : c.muted),
                    height: 1.15,
                  ),
                ),
              ),
            ),
            if (widget.badge != null && labelAlpha > 0.5)
              Opacity(
                opacity: labelAlpha,
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    color: widget.active
                        ? c.clay
                        : c.clay.withValues(alpha: 0.14),
                    shape: const StadiumBorder(),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6.5,
                      vertical: 1.5,
                    ),
                    child: Text(
                      widget.badge!,
                      style: monoStyle(
                        c,
                        size: 11,
                        color: widget.active ? const Color(0xFFFAF9F5) : c.clay,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );

    if (collapsed) {
      row = Tooltip(message: widget.label, child: row);
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: row,
      ),
    );
  }
}

class _DashboardLoginScreen extends StatefulWidget {
  final String serverName;
  final String version;
  final String initialError;
  final ConsoleBackend backend;
  final VoidCallback onLoggedIn;
  final VoidCallback? onSwitchToLocal;
  final VoidCallback? onManageNodes;

  const _DashboardLoginScreen({
    super.key,
    required this.serverName,
    required this.version,
    this.initialError = '',
    required this.backend,
    required this.onLoggedIn,
    this.onSwitchToLocal,
    this.onManageNodes,
  });

  @override
  State<_DashboardLoginScreen> createState() => _DashboardLoginScreenState();
}

class _DashboardLoginScreenState extends State<_DashboardLoginScreen> {
  final _pwdCtrl = TextEditingController();
  bool _loading = false;
  late String _error = widget.initialError;

  @override
  void dispose() {
    _pwdCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_pwdCtrl.text.isEmpty) return;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final res = await widget.backend.login(_pwdCtrl.text);
      if (res['ok'] == true) {
        widget.onLoggedIn();
      } else {
        setState(() => _error = (res['error'] ?? '密码不正确').toString());
      }
    } catch (_) {
      setState(() => _error = '网络请求失败，请检查服务是否在线');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    return Scaffold(
      backgroundColor: c.paper,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ClaudeStaggeredReveal(
              index: 0,
              offsetY: 10,
              child: ClaudeCard(
                radius: 24,
                padding: const EdgeInsets.fromLTRB(28, 30, 28, 24),
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
                            shape: claudeSuperellipse(11),
                          ),
                          alignment: Alignment.center,
                          child: const ClaudeSparkIcon(size: 19),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            widget.serverName,
                            style: serifTitleStyle(c, size: 22),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '请输入本地管理密码以访问 Web 控制台（与 OAuth 2.1 本地授权密码一致）。',
                      style: sansStyle(
                        c,
                        size: 13.5,
                        color: c.muted,
                        height: 1.60,
                      ),
                    ),
                    const SizedBox(height: 22),
                    ClaudePasswordField(
                      controller: _pwdCtrl,
                      hintText: '输入管理密码...',
                      onSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: 16),
                    ClaudeButton(
                      label: _loading ? '正在验证...' : '进入控制台',
                      variant: ClaudeBtnVariant.clay,
                      expand: true,
                      onPressed: _loading ? null : _submit,
                    ),
                    ClaudeCollapsible(
                      expanded: _error.isNotEmpty,
                      builder: (_) => Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: ShapeDecoration(
                            color: c.dangerBg,
                            shape: claudeSuperellipse(
                              10,
                              side: BorderSide(
                                color: c.danger.withValues(alpha: 0.28),
                              ),
                            ),
                          ),
                          child: Text(
                            _error,
                            textAlign: TextAlign.center,
                            style: sansStyle(
                              c,
                              size: 11.8,
                              color: c.danger,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (widget.onSwitchToLocal != null ||
                        widget.onManageNodes != null) ...[
                      const SizedBox(height: 14),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (widget.onSwitchToLocal != null)
                            ClaudeButton(
                              label: '切回本机服务',
                              compact: true,
                              leading: const Icon(Icons.smartphone_rounded),
                              onPressed: widget.onSwitchToLocal,
                            ),
                          if (widget.onManageNodes != null)
                            ClaudeButton(
                              label: '管理远程节点',
                              compact: true,
                              variant: ClaudeBtnVariant.ghost,
                              leading: const Icon(Icons.hub_outlined),
                              onPressed: widget.onManageNodes,
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 18),
                    Center(
                      child: Text(
                        'Agent MCP Console · v${widget.version}',
                        style: sansStyle(
                          c,
                          size: 11.5,
                          color: c.meta,
                          tabular: true,
                        ),
                      ),
                    ),
                  ],
                ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlobalCommandPaletteDialog extends StatefulWidget {
  final String serverName;
  final bool isRunning;
  final bool isDark;
  final String activeNodeName;

  const _GlobalCommandPaletteDialog({
    required this.serverName,
    required this.isRunning,
    required this.isDark,
    required this.activeNodeName,
  });

  @override
  State<_GlobalCommandPaletteDialog> createState() =>
      _GlobalCommandPaletteDialogState();
}

class _GlobalCommandPaletteDialogState
    extends State<_GlobalCommandPaletteDialog> {
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();
  int _selectedIdx = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<({String title, String hint, IconData icon, Map<String, dynamic> payload})>
      _buildEntries() {
    final q = _ctrl.text.trim();
    final ql = q.toLowerCase();
    final items =
        <({String title, String hint, IconData icon, Map<String, dynamic> payload})>[];

    final portNum = int.tryParse(q.replaceAll(':', ''));
    if (portNum != null && portNum >= 1 && portNum <= 65535) {
      items.add((
        title: '立即转发本地端口 :$portNum（支持 WebSocket HMR）',
        hint: '回车秒享',
        icon: Icons.podcasts_rounded,
        payload: {'action': 'share_direct', 'target': '$portNum'},
      ));
    } else if (q.contains(r'\') ||
        q.contains('/') ||
        ql.endsWith('.html') ||
        ql.endsWith('.htm')) {
      items.add((
        title: '立即生成外链分享：$q',
        hint: '回车秒享',
        icon: Icons.add_link_rounded,
        payload: {'action': 'share_direct', 'target': q},
      ));
    }

    final presets = <({String title, String hint, IconData icon, Map<String, dynamic> payload})>[
      (
        title: '前往外网与分享（文件 / 文件夹 / 静态网站 / 端口）',
        hint: '外网分享',
        icon: Icons.link_rounded,
        payload: {'action': 'tab', 'index': 2},
      ),
      (
        title: '切换本机服务或远程电脑 / 手机节点（当前：${widget.activeNodeName}）',
        hint: '节点管理',
        icon: Icons.dns_rounded,
        payload: {'action': 'nodes'},
      ),
      (
        title: '平滑重启 MCP 服务',
        hint: '服务控制',
        icon: Icons.restart_alt_rounded,
        payload: {'action': 'restart'},
      ),
      (
        title: widget.isDark ? '切换至暖纸浅色主题' : '切换至深岩暗色主题',
        hint: '外观',
        icon: widget.isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
        payload: {'action': 'toggle_theme'},
      ),
      (
        title: '前往子 MCP 网关（粘贴 mcpServers JSON）',
        hint: '子网关',
        icon: Icons.layers_rounded,
        payload: {'action': 'tab', 'index': 1},
      ),
      (
        title: '前往服务配置（接入入口 / 外网隧道 / 存储清理）',
        hint: '服务配置',
        icon: Icons.tune_rounded,
        payload: {'action': 'tab', 'index': 3},
      ),
      (
        title: '前往活动与调用流',
        hint: '调用流',
        icon: Icons.bolt_rounded,
        payload: {'action': 'tab', 'index': 0},
      ),
      (
        title: '检查应用更新 (GitHub Releases)',
        hint: '更新检测 / version.json',
        icon: Icons.system_update_alt_rounded,
        payload: {'action': 'check_update'},
      ),
    ];

    if (ql.isEmpty) {
      items.addAll(presets);
    } else {
      for (final p in presets) {
        if ('${p.title} ${p.hint}'.toLowerCase().contains(ql)) {
          items.add(p);
        }
      }
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final entries = _buildEntries();
    if (_selectedIdx >= entries.length) _selectedIdx = 0;

    return Dialog(
      backgroundColor: c.paper2,
      elevation: 0,
      alignment: const Alignment(0, -0.45),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: claudeSuperellipse(18),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Focus(
          onKeyEvent: (_, KeyEvent ev) {
            if (ev is! KeyDownEvent) return KeyEventResult.ignored;
            if (ev.logicalKey == LogicalKeyboardKey.arrowDown &&
                entries.isNotEmpty) {
              setState(() {
                _selectedIdx = (_selectedIdx + 1).clamp(0, entries.length - 1);
              });
              return KeyEventResult.handled;
            }
            if (ev.logicalKey == LogicalKeyboardKey.arrowUp &&
                entries.isNotEmpty) {
              setState(() {
                _selectedIdx = (_selectedIdx - 1).clamp(0, entries.length - 1);
              });
              return KeyEventResult.handled;
            }
            if (ev.logicalKey == LogicalKeyboardKey.enter &&
                entries.isNotEmpty) {
              Navigator.of(context).pop(entries[_selectedIdx].payload);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
                child: Row(
                  children: [
                    Icon(Icons.search_rounded, size: 17, color: c.meta),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _ctrl,
                        focusNode: _focus,
                        onChanged: (_) => setState(() => _selectedIdx = 0),
                        onSubmitted: (_) {
                          if (entries.isNotEmpty) {
                            Navigator.of(context).pop(entries[_selectedIdx].payload);
                          }
                        },
                        style: sansStyle(c, size: 14, color: c.ink),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          hintText: '输入指令，或直接粘贴路径 / 端口号回车秒享…',
                          hintStyle: sansStyle(c, size: 13.5, color: c.meta),
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: c.recessed,
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: c.hairline),
                      ),
                      child: Text('ESC', style: monoStyle(c, size: 10.5, color: c.meta)),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: c.hairline),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: entries.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          '未找到匹配指令',
                          style: sansStyle(c, size: 13, color: c.muted),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.all(6),
                        itemCount: entries.length,
                        itemBuilder: (ctx, i) {
                          final it = entries[i];
                          final sel = i == _selectedIdx;
                          return Material(
                            color: sel
                                ? c.clay.withValues(alpha: c.isDark ? 0.16 : 0.10)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(9),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(9),
                              onTap: () => Navigator.of(context).pop(it.payload),
                              onHover: (h) {
                                if (h && _selectedIdx != i) {
                                  setState(() => _selectedIdx = i);
                                }
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      it.icon,
                                      size: 16,
                                      color: sel ? c.clay : c.muted,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        it.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: sansStyle(
                                          c,
                                          size: 13,
                                          weight: sel ? FontWeight.w600 : FontWeight.w500,
                                          color: sel ? c.ink : c.inkSoft,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      it.hint,
                                      style: sansStyle(c, size: 11.5, color: c.meta),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
