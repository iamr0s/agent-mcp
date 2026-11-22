import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_mcp_core/agent_mcp_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'console_backend_interface.dart';
import 'remote_http_client_io.dart';

class UnauthorizedConsoleException implements Exception {
  const UnauthorizedConsoleException();
}

ConsoleBackend createPlatformConsoleBackend() => _IoConsoleBackend();

class _IoConsoleBackend extends ConsoleBackend {
  static const MethodChannel _winChannel = MethodChannel('agent_mcp/window');
  static const MethodChannel _androidChannel =
      MethodChannel('agent_mcp/android');

  late final McpServiceController _ctrl;
  final ValueNotifier<DesktopWindowState> _windowState =
      ValueNotifier(const DesktopWindowState());
  final ValueNotifier<int> _refreshSignal = ValueNotifier<int>(0);

  bool _initialized = false;
  bool? _lastSyncedDark;
  String _lastTraySig = '';
  String _lastAndroidFgsSig = '';

  List<String> _lanIps = const [];
  final List<ConsoleNodeProfile> _remoteNodes = [];
  String _activeNodeId = 'local';
  RemoteHttpNodeClient? _remoteClient;

  @override
  bool get isWebMode => false;

  @override
  bool get isAndroidPlatform => Platform.isAndroid;

  @override
  bool get supportsNodeSwitching => true;

  @override
  bool get isRemoteNodeActive =>
      _activeNodeId != 'local' && _remoteClient != null;

  @override
  List<String> get deviceLanIps => List.unmodifiable(_lanIps);

  @override
  ValueListenable<int> get externalRefreshSignal => _refreshSignal;

  @override
  bool get hasCustomTitleBar => Platform.isWindows;

  @override
  ValueListenable<DesktopWindowState> get windowState => _windowState;

  ConsoleNodeProfile get _localNodeProfile => ConsoleNodeProfile(
        id: 'local',
        name: Platform.isAndroid ? '本机 Android 服务' : '本机桌面服务',
        isLocal: true,
      );

  @override
  ConsoleNodeProfile get activeNode {
    if (_activeNodeId == 'local') return _localNodeProfile;
    for (final n in _remoteNodes) {
      if (n.id == _activeNodeId) return n;
    }
    return _localNodeProfile;
  }

  @override
  List<ConsoleNodeProfile> get savedNodes => <ConsoleNodeProfile>[
        _localNodeProfile,
        ..._remoteNodes,
      ];

  File get _remoteNodesFile =>
      File(p.join(StoragePaths.instance.dataDir.path, 'remote_nodes.json'));

  void _loadSavedNodesFromDisk() {
    _remoteNodes.clear();
    _activeNodeId = 'local';
    try {
      final f = _remoteNodesFile;
      if (!f.existsSync()) return;
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is Map) {
        final rawList = decoded['nodes'];
        if (rawList is List) {
          for (final item in rawList) {
            if (item is Map) {
              final prof = ConsoleNodeProfile.fromJson(item);
              if (prof.baseUrl.isNotEmpty) {
                _remoteNodes.add(prof);
              }
            }
          }
        }
        final wantedId = (decoded['active_node_id'] ?? 'local').toString();
        if (wantedId != 'local' &&
            _remoteNodes.any((n) => n.id == wantedId)) {
          _activeNodeId = wantedId;
        }
      }
    } catch (_) {}
    _rebuildRemoteClient();
  }

  void _saveNodesToDisk() {
    try {
      StoragePaths.instance.ensureLayout();
      final payload = {
        'version': 1,
        'active_node_id': _activeNodeId,
        'nodes': _remoteNodes.map((n) => n.toJson()).toList(),
      };
      const enc = JsonEncoder.withIndent('  ');
      _remoteNodesFile.writeAsStringSync('${enc.convert(payload)}\n',
          flush: true);
    } catch (_) {}
  }

  void _rebuildRemoteClient() {
    _remoteClient?.dispose();
    _remoteClient = null;
    if (_activeNodeId != 'local') {
      final match =
          _remoteNodes.where((n) => n.id == _activeNodeId).firstOrNull;
      if (match != null) {
        _remoteClient = RemoteHttpNodeClient(match);
      } else {
        _activeNodeId = 'local';
      }
    }
  }

  @override
  Future<void> selectNode(String nodeId) async {
    final targetId =
        (nodeId == 'local' || _remoteNodes.any((n) => n.id == nodeId))
            ? nodeId
            : 'local';
    if (_activeNodeId == targetId &&
        (targetId == 'local' || _remoteClient != null)) {
      return;
    }
    _activeNodeId = targetId;
    _rebuildRemoteClient();
    _saveNodesToDisk();
    _refreshSignal.value++;
  }

  @override
  Future<ConsoleNodeProfile> upsertRemoteNode({
    String? id,
    required String name,
    required String baseUrl,
    String savedPassword = '',
  }) async {
    final cleanUrl = normalizeRemoteBaseUrl(baseUrl);
    final cleanName = name.trim().isEmpty ? cleanUrl : name.trim();
    final idx = (id != null && id.isNotEmpty)
        ? _remoteNodes.indexWhere((n) => n.id == id)
        : -1;
    late final ConsoleNodeProfile entry;
    if (idx >= 0) {
      entry = _remoteNodes[idx].copyWith(
        name: cleanName,
        baseUrl: cleanUrl,
        savedPassword: savedPassword,
      );
      _remoteNodes[idx] = entry;
      if (_activeNodeId == entry.id) {
        _remoteClient?.updateProfile(entry);
      }
    } else {
      entry = ConsoleNodeProfile(
        id: generateRandomToken('node-', 8),
        name: cleanName,
        baseUrl: cleanUrl,
        savedPassword: savedPassword,
      );
      _remoteNodes.add(entry);
    }
    _saveNodesToDisk();
    _refreshSignal.value++;
    return entry;
  }

  @override
  Future<void> deleteRemoteNode(String nodeId) async {
    _remoteNodes.removeWhere((n) => n.id == nodeId);
    if (_activeNodeId == nodeId) {
      _activeNodeId = 'local';
      _rebuildRemoteClient();
    }
    _saveNodesToDisk();
    _refreshSignal.value++;
  }

  Future<T> _guardRemote<T>(Future<T> Function(RemoteHttpNodeClient c) fn) async {
    final client = _remoteClient;
    if (client == null) {
      throw StateError('Remote node client is not active');
    }
    try {
      return await fn(client);
    } on RemoteUnauthorizedException {
      throw const UnauthorizedConsoleException();
    }
  }

  @override
  void recordUnhandledError(Object error, StackTrace stack) {
    try {
      StoragePaths.instance.ensureLayout();
      final crashFile =
          File(p.join(StoragePaths.instance.logsDir.path, 'crash.log'));
      crashFile.parent.createSync(recursive: true);
      final ts = DateTime.now().toIso8601String();
      crashFile.writeAsStringSync(
        '[$ts] UNCAUGHT ERROR: $error\n$stack\n\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  Future<void> _initAndroidStorageAndChannel() async {
    _androidChannel.setMethodCallHandler(_handleAndroidEvent);
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (_) {}
    try {
      final raw = await _androidChannel.invokeMethod<dynamic>('getPaths');
      if (raw is Map) {
        final extDir = (raw['externalFilesDir'] ?? '').toString().trim();
        final intDir = (raw['filesDir'] ?? '').toString().trim();
        if (intDir.isNotEmpty) {
          PrivilegedExecutor.instance.appInternalDir = intDir;
        }
        final chosenRoot = extDir.isNotEmpty ? extDir : intDir;
        if (chosenRoot.isNotEmpty) {
          final rootDir = Directory(chosenRoot)..createSync(recursive: true);
          StoragePaths.overrideRoot(rootDir);
          final workspaceDir = Directory(p.join(rootDir.path, 'workspace'))
            ..createSync(recursive: true);
          try {
            Directory.current = workspaceDir;
          } catch (_) {}
        }
        if (raw['lanIps'] is List) {
          _lanIps = (raw['lanIps'] as List)
              .map((e) => e.toString().trim())
              .where((s) => s.isNotEmpty)
              .toList();
        }
        if (raw['privilege'] is Map) {
          PrivilegedExecutor.instance
              .updateFromNativeMap(raw['privilege'] as Map);
        }
      }
    } catch (_) {}
    PrivilegedExecutor.instance.onEnsureReady = () async {
      final res =
          await _androidChannel.invokeMethod<dynamic>('ensurePrivilegeReady');
      if (res is Map) {
        return Map<String, dynamic>.from(res);
      }
      return const <String, dynamic>{};
    };
    PrivilegedExecutor.instance.onApplyConfig = ({
      required String mode,
      required bool mountMaster,
      required bool interactive,
    }) async {
      final res = await _androidChannel.invokeMethod<dynamic>(
        'applyPrivilegeConfig',
        <String, Object>{
          'mode': mode,
          'mountMaster': mountMaster,
          'interactive': interactive,
        },
      );
      if (res is Map) {
        return Map<String, dynamic>.from(res);
      }
      return const <String, dynamic>{};
    };
    await _refreshDeviceLanIpsFallback();
  }

  Future<void> _refreshDeviceLanIpsFallback() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final ips = <String>[];
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address.trim();
          if (ip.isNotEmpty && !ips.contains(ip)) {
            ips.add(ip);
          }
        }
      }
      if (ips.isNotEmpty) {
        _lanIps = ips;
      }
    } catch (_) {}
  }

  Future<dynamic> _handleAndroidEvent(MethodCall call) async {
    if (call.method == 'onPrivilegeChanged' && call.arguments is Map) {
      PrivilegedExecutor.instance
          .updateFromNativeMap(call.arguments as Map);
      unawaited(_syncAndroidForegroundService());
      _refreshSignal.value++;
      return null;
    }
    if (call.method == 'onNotificationAction') {
      final act = (call.arguments ?? '').toString();
      try {
        switch (act) {
          case 'stop':
            await _ctrl.stop();
            await _syncAndroidForegroundService();
            _refreshSignal.value++;
          case 'start':
            await _ctrl.start();
            await _syncAndroidForegroundService();
            _refreshSignal.value++;
          case 'restart':
            await _ctrl.restart();
            await _syncAndroidForegroundService();
            _refreshSignal.value++;
        }
      } catch (e, st) {
        recordUnhandledError(e, st);
      }
    }
    return null;
  }

  Future<void> _syncAndroidForegroundService() async {
    if (!Platform.isAndroid || !_initialized) return;
    try {
      final cfg = _ctrl.loadCurrentServerConfig();
      final running = _ctrl.isRunning;
      await _refreshDeviceLanIpsFallback();
      final primaryIp = _lanIps.isNotEmpty ? _lanIps.first : kLoopbackIpv4;
      final privBadge = PrivilegedExecutor.instance.shortBadge;
      final sig =
          '${cfg.serverName}|$running|${cfg.port}|$primaryIp|$privBadge';
      if (sig == _lastAndroidFgsSig) return;
      _lastAndroidFgsSig = sig;
      await _androidChannel.invokeMethod<void>(
        'syncForegroundService',
        <String, Object>{
          'running': running,
          'serverName': cfg.serverName,
          'port': cfg.port,
          'lanIp': primaryIp,
          'privilegeBadge': privBadge,
        },
      );
    } catch (_) {}
  }

  @override
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    if (Platform.isAndroid) {
      await _initAndroidStorageAndChannel();
    } else {
      await _refreshDeviceLanIpsFallback();
    }

    StoragePaths.instance.ensureLayout();
    _ctrl = McpServiceController();

    if (Platform.isAndroid && !_ctrl.configFile.existsSync()) {
      saveConfigFile(_ctrl.configFile, {
        'server_name': 'Android MCP',
        'host': '0.0.0.0',
        'hosts': ['0.0.0.0'],
        'port': 8000,
        'auto_start': true,
        'auth_mode': 'none',
        'relaxed_command_annotations': true,
      });
    }

    _loadSavedNodesFromDisk();
    final saved = loadSavedConfig(_ctrl.configFile);

    if (Platform.isAndroid) {
      final savedPrivMode =
          (saved['android_privilege_mode'] ?? 'none').toString();
      final savedMountMaster = saved['android_su_mount_master'] != false;
      if (savedPrivMode != 'none') {
        unawaited(() async {
          try {
            final res = await _androidChannel.invokeMethod<dynamic>(
              'applyPrivilegeConfig',
              <String, Object>{
                'mode': savedPrivMode,
                'mountMaster': savedMountMaster,
                'interactive': false,
              },
            );
            if (res is Map) {
              PrivilegedExecutor.instance.updateFromNativeMap(res);
              await _syncAndroidForegroundService();
              _refreshSignal.value++;
            }
          } catch (_) {}
        }());
      }
    }

    if (Platform.isWindows) {
      _winChannel.setMethodCallHandler(_handleNativeWindowEvent);
      await _syncInitialWindowState();
      final wantMica = saved['window_effect'] != false;
      await setWindowEffect(wantMica);
      final sname = (saved['server_name'] ?? 'Agent MCP').toString();
      unawaited(_updateNativeTrayTooltip(sname));
    }

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      if (saved['launch_at_startup'] == true) {
        AutoStartManager.syncFromConfigMap(saved);
      }
    }
    if (saved['auto_start'] != false) {
      try {
        await _ctrl.start();
      } catch (e, st) {
        recordUnhandledError(e, st);
      }
    }
    unawaited(_syncNativeTrayState());
    unawaited(_syncAndroidForegroundService());
  }

  Future<void> _syncNativeTrayState() async {
    if (!Platform.isWindows || !_initialized) return;
    try {
      final cfg = _ctrl.loadCurrentServerConfig();
      final running = _ctrl.isRunning;
      final dark = _lastSyncedDark ?? false;
      final sig = '${cfg.serverName}|$running|${cfg.port}|$dark';
      if (sig == _lastTraySig) return;
      _lastTraySig = sig;
      await _winChannel.invokeMethod<void>('setTrayState', <String, Object>{
        'serverName': cfg.serverName,
        'running': running,
        'port': cfg.port,
        'dark': dark,
      });
    } catch (_) {}
  }

  Future<void> _openWebDashboardInBrowser() async {
    try {
      final cfg = _ctrl.loadCurrentServerConfig();
      final url = 'http://127.0.0.1:${cfg.port}/dashboard/';
      if (Platform.isWindows) {
        await Process.run(
          'rundll32',
          ['url.dll,FileProtocolHandler', url],
          runInShell: false,
        );
      } else if (Platform.isAndroid) {
        await _androidChannel.invokeMethod<void>('openExternalUrl', url);
      }
    } catch (e, st) {
      recordUnhandledError(e, st);
    }
  }

  Future<void> _updateNativeTrayTooltip(String serverName) async {
    if (!Platform.isWindows) return;
    try {
      await _winChannel.invokeMethod<void>(
        'setTrayTooltip',
        '$serverName Console (v$agentMcpVersion)',
      );
    } catch (_) {}
  }

  DesktopWindowState _parseWindowStateMap(Map<dynamic, dynamic> raw) {
    return DesktopWindowState(
      isMaximized: raw['isMaximized'] == true,
      isPinned: raw['isPinned'] == true,
      isBackdropSupported: raw['isBackdropSupported'] == true,
      windowEffect: raw['windowEffect'] == true,
      isVisible: raw['isVisible'] != false,
    );
  }

  Future<dynamic> _handleNativeWindowEvent(MethodCall call) async {
    if (call.method == 'onStateChanged' && call.arguments is Map) {
      _windowState.value = _parseWindowStateMap(call.arguments as Map);
      return null;
    }
    if (call.method == 'onFilesDropped' && call.arguments is List) {
      final paths = (call.arguments as List)
          .map((e) => e.toString().trim())
          .where((s) => s.isNotEmpty)
          .toList();
      emitDroppedFiles(paths);
      return null;
    }
    if (call.method == 'onTrayAction') {
      final act = (call.arguments ?? '').toString();
      try {
        switch (act) {
          case 'open':
            await _restoreAndFocusConsole();
          case 'open_web':
            if (!_ctrl.isRunning) {
              await _ctrl.start();
              await _syncNativeTrayState();
            }
            await _openWebDashboardInBrowser();
          case 'start':
            await _ctrl.start();
            await _syncNativeTrayState();
            _refreshSignal.value++;
          case 'stop':
            await _ctrl.stop();
            await _syncNativeTrayState();
            _refreshSignal.value++;
          case 'restart':
            await _ctrl.restart();
            await _syncNativeTrayState();
            _refreshSignal.value++;
          case 'quit':
            quitDesktopApp();
        }
      } catch (e, st) {
        recordUnhandledError(e, st);
      }
    }
    return null;
  }

  Future<void> _syncInitialWindowState() async {
    try {
      final raw = await _winChannel.invokeMethod<dynamic>('getState');
      if (raw is Map) {
        _windowState.value = _parseWindowStateMap(raw);
      }
    } catch (_) {}
  }

  Future<void> _restoreAndFocusConsole() async {
    try {
      await _winChannel.invokeMethod<void>('showAndFocus');
      return;
    } catch (_) {}
  }

  @override
  Future<void> startWindowDrag() async {
    if (!Platform.isWindows) return;
    try {
      await _winChannel.invokeMethod<void>('startDragging');
    } catch (_) {}
  }

  @override
  Future<void> minimizeWindow() async {
    if (!Platform.isWindows) return;
    try {
      await _winChannel.invokeMethod<void>('minimize');
    } catch (_) {}
  }

  @override
  Future<void> toggleMaximizeWindow() async {
    if (!Platform.isWindows) return;
    try {
      final res = await _winChannel.invokeMethod<bool>('toggleMaximize');
      if (res != null) {
        _windowState.value = _windowState.value.copyWith(isMaximized: res);
      }
    } catch (_) {}
  }

  @override
  Future<void> togglePinWindow() async {
    if (!Platform.isWindows) return;
    try {
      final res = await _winChannel.invokeMethod<bool>('togglePin');
      if (res != null) {
        _windowState.value = _windowState.value.copyWith(isPinned: res);
      }
    } catch (_) {}
  }

  @override
  Future<void> hideWindowToTray() async {
    if (!Platform.isWindows) return;
    try {
      await _winChannel.invokeMethod<void>('hideToTray');
    } catch (_) {}
  }

  @override
  Future<void> syncNativeWindowTheme(bool isDark) async {
    if (_lastSyncedDark == isDark) return;
    _lastSyncedDark = isDark;
    if (Platform.isAndroid) {
      SystemChrome.setSystemUIOverlayStyle(
        SystemUiOverlayStyle(
          statusBarColor: const Color(0x00000000),
          systemNavigationBarColor: const Color(0x00000000),
          systemNavigationBarDividerColor: const Color(0x00000000),
          statusBarIconBrightness:
              isDark ? Brightness.light : Brightness.dark,
          systemNavigationBarIconBrightness:
              isDark ? Brightness.light : Brightness.dark,
        ),
      );
      try {
        await _androidChannel.invokeMethod<void>('setSystemBarsDark', isDark);
      } catch (_) {}
      return;
    }
    if (!Platform.isWindows) return;
    try {
      await _winChannel.invokeMethod<void>('setDarkTheme', isDark);
    } catch (_) {}
    unawaited(_syncNativeTrayState());
  }

  @override
  Future<bool> setWindowEffect(bool enabled) async {
    if (!Platform.isWindows) return false;
    try {
      final applied =
          await _winChannel.invokeMethod<bool>('setWindowEffect', enabled) ??
              false;
      _windowState.value = _windowState.value.copyWith(windowEffect: applied);
      return applied;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Map<String, dynamic>> checkAuthState() async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.checkAuthState());
    }
    final cfg = _ctrl.loadCurrentServerConfig();
    return {
      'ok': true,
      'authenticated': true,
      'server_name': cfg.serverName,
      'version': agentMcpVersion,
      'dashboard_mode': false,
    };
  }

  @override
  Future<Map<String, dynamic>> login(String password) async {
    if (isRemoteNodeActive) {
      final res = await _guardRemote((c) => c.login(password));
      if (res['ok'] == true) {
        final cur = activeNode;
        if (!cur.isLocal && cur.savedPassword != password) {
          await upsertRemoteNode(
            id: cur.id,
            name: cur.name,
            baseUrl: cur.baseUrl,
            savedPassword: password,
          );
        }
      }
      return res;
    }
    return {'ok': true};
  }

  @override
  Future<void> logout() async {
    if (isRemoteNodeActive) {
      final cur = activeNode;
      if (!cur.isLocal && cur.savedPassword.isNotEmpty) {
        await upsertRemoteNode(
          id: cur.id,
          name: cur.name,
          baseUrl: cur.baseUrl,
          savedPassword: '',
        );
      }
      await _guardRemote((c) => c.logout());
    }
  }

  @override
  Future<Map<String, dynamic>> getStatus() async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.getStatus());
    }
    final saved = loadSavedConfig(_ctrl.configFile);
    saved['profiles'] = ensureProfilesInConfig(saved);
    final bindHosts = parseBindHosts(saved['hosts'], saved['host']);
    final netIfaces = await listHostNetworkInterfaces();
    final cleanLanIps = netIfaces
        .where((e) => e['kind'] != 'loopback' && e['kind'] != 'tun_proxy')
        .map((e) => e['ip'] ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    if (cleanLanIps.isNotEmpty) {
      _lanIps = cleanLanIps;
    }
    if (Platform.isAndroid) {
      try {
        final rawPriv =
            await _androidChannel.invokeMethod<dynamic>('getPrivilegeStatus');
        if (rawPriv is Map) {
          PrivilegedExecutor.instance.updateFromNativeMap(rawPriv);
        }
      } catch (_) {}
    }
    final sanitized = Map<String, dynamic>.from(saved)
      ..['host'] = bindHosts.first
      ..['hosts'] = bindHosts
      ..['launch_at_startup'] = Platform.isAndroid
          ? false
          : AutoStartManager.effectiveLaunchAtStartup(saved)
      ..['silent_start'] = saved['silent_start'] == true
      ..['window_effect'] = saved['window_effect'] != false
      ..['backdrop_supported'] = _windowState.value.isBackdropSupported
      ..['host_os'] = Platform.operatingSystem
      ..['lan_ips'] = _lanIps
      ..['network_interfaces'] = netIfaces
      ..['android_privilege_mode'] =
          (saved['android_privilege_mode'] ?? 'none').toString()
      ..['android_su_mount_master'] =
          saved['android_su_mount_master'] != false
      ..['expose_enabled'] = ExposureManager.isExposureEnabledInSaved(saved)
      ..['expose_tailscale_enabled'] = ExposureManager.isTailscaleEnabledInSaved(saved)
      ..['expose_tailscale_mode'] = ExposureManager.tailscaleModeInSaved(saved)
      ..['expose_cloudflared_fallback'] = ExposureManager.isCloudflaredFallbackInSaved(saved)
      ..['expose_default_ttl_minutes'] = ExposureManager.defaultTtlMinutesInSaved(saved)
      ..['privilege_status'] = PrivilegedExecutor.instance.publicStatus
      ..['has_password'] =
          (saved['oauth_local_password_hash'] ?? '').toString().isNotEmpty
      ..remove('oauth_local_password_hash');
    unawaited(_syncNativeTrayState());
    unawaited(_syncAndroidForegroundService());
    return {
      'running': _ctrl.isRunning,
      'version': agentMcpVersion,
      'dashboard_mode': false,
      'tunnels': TunnelManager.instance.getStatuses(),
      'exposures': await ExposureManager.instance.getDashboardSummary(_ctrl.loadCurrentServerConfig()),
      'config': sanitized,
    };
  }

  @override
  Future<Map<String, dynamic>> saveConfig(Map<String, dynamic> patch) async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.saveConfig(patch));
    }
    saveUpdatedConfigMap(_ctrl.configFile, patch);
    if (patch.containsKey('window_effect') && Platform.isWindows) {
      await setWindowEffect(patch['window_effect'] != false);
    }
    if (patch.containsKey('server_name') && Platform.isWindows) {
      unawaited(
        _updateNativeTrayTooltip(
          (patch['server_name'] ?? 'Agent MCP').toString(),
        ),
      );
    }
    unawaited(_syncNativeTrayState());
    unawaited(_syncAndroidForegroundService());
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> startService() async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.startService());
    }
    await _ctrl.start();
    unawaited(_syncNativeTrayState());
    unawaited(_syncAndroidForegroundService());
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> stopService() async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.stopService());
    }
    await _ctrl.stop();
    unawaited(_syncNativeTrayState());
    unawaited(_syncAndroidForegroundService());
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> restartService() async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.restartService());
    }
    await _ctrl.restart();
    unawaited(_syncNativeTrayState());
    unawaited(_syncAndroidForegroundService());
    return {'ok': true};
  }

  @override
  Future<List<Map<String, dynamic>>> getLogs() async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.getLogs());
    }
    return StructuredEventBus.instance.getHistory();
  }

  @override
  Future<void> clearLogs() async {
    if (isRemoteNodeActive) {
      await _guardRemote((c) => c.clearLogs());
      return;
    }
    StructuredEventBus.instance.clearHistory();
  }

  @override
  Stream<Map<String, dynamic>> subscribeEvents() {
    if (isRemoteNodeActive) {
      final client = _remoteClient;
      if (client != null) {
        return client.subscribeEvents();
      }
    }
    return StructuredEventBus.instance.stream;
  }

  @override
  Future<void> exportLogsFile(String filename, String content) async {
    final outFile = File(p.join(StoragePaths.instance.logsDir.path, filename));
    outFile.parent.createSync(recursive: true);
    outFile.writeAsStringSync(content, flush: true);
  }

  @override
  Future<Map<String, dynamic>> checkHealth([String? targetUrl]) async {
    if (targetUrl != null && targetUrl.trim().isNotEmpty) {
      return probeRemoteHealth(targetUrl);
    }
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.checkHealth(targetUrl));
    }
    final cfg = _ctrl.loadCurrentServerConfig();
    return {
      'ok': _ctrl.isRunning,
      'url': '/health',
      'scheme': 'local',
      'status_code': _ctrl.isRunning ? 200 : 503,
      'latency_ms': 0,
      'body': jsonEncode({
        'status': _ctrl.isRunning ? 'ok' : 'stopped',
        'server_name': cfg.serverName,
        'version': agentMcpVersion,
      }),
    };
  }

  @override
  Future<Map<String, dynamic>> getStorage() async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.getStorage());
    }
    return {'ok': true, 'stats': getStorageStats()};
  }

  @override
  Future<Map<String, dynamic>> cleanStorageTarget(String target) async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.cleanStorageTarget(target));
    }
    if (target == 'logs') StructuredEventBus.instance.clearHistory();
    final res = cleanStorage(target);
    res['stats'] = getStorageStats();
    return res;
  }

  @override
  Future<Map<String, dynamic>> startTunnel(String profileId) async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.startTunnel(profileId));
    }
    final saved = loadSavedConfig(_ctrl.configFile);
    final profs = ensureProfilesInConfig(saved);
    final prof = profs.where((e) => e['id'] == profileId).firstOrNull;
    if (prof == null) return {'ok': false, 'error': '未找到该入口配置'};
    final port = int.tryParse('${saved['port'] ?? 8000}') ?? 8000;
    return TunnelManager.instance.startTunnel(prof, port);
  }

  @override
  Future<Map<String, dynamic>> stopTunnel(String profileId) async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.stopTunnel(profileId));
    }
    return TunnelManager.instance.stopTunnel(profileId);
  }

  @override
  Future<Map<String, dynamic>> installCloudflared({
    bool force = false,
    bool resume = false,
  }) async {
    if (isRemoteNodeActive) {
      return _guardRemote(
        (c) => c.installCloudflared(force: force, resume: resume),
      );
    }
    return TunnelManager.instance.startCloudflaredDownload(
      forceUpdate: force,
      resume: resume,
    );
  }

  @override
  Future<Map<String, dynamic>> pauseCloudflared() async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.pauseCloudflared());
    }
    return TunnelManager.instance.pauseDownload();
  }

  @override
  Future<Map<String, dynamic>> cancelCloudflared() async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.cancelCloudflared());
    }
    return TunnelManager.instance.cancelDownload();
  }

  @override
  Future<Map<String, dynamic>> uninstallCloudflared() async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.uninstallCloudflared());
    }
    return TunnelManager.instance.uninstallCloudflared();
  }

  @override
  Future<Map<String, dynamic>?> pickAndImportCloudflared() async {
    String? path;
    if (Platform.isWindows) {
      path = await _pickFileWindowsPowerShell();
    }
    if (path == null || path.isEmpty) return null;
    final f = File(path);
    if (!f.existsSync()) return null;
    final bytes = await f.readAsBytes();
    if (isRemoteNodeActive) {
      return _guardRemote(
        (c) => c.importCloudflaredBytes(p.basename(path!), bytes),
      );
    }
    return TunnelManager.instance.importCloudflaredBytes(
      p.basename(path),
      bytes,
    );
  }

  Future<String?> _pickFileWindowsPowerShell() async {
    try {
      final r = await Process.run(
        'powershell.exe',
        const [
          '-NoProfile',
          '-STA',
          '-Command',
          "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; "
              "Add-Type -AssemblyName System.Windows.Forms; "
              "\$d = New-Object System.Windows.Forms.OpenFileDialog; "
              "\$d.Title = '选择官方下载的 cloudflared 可执行文件或压缩包'; "
              "if (\$d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Write-Output \$d.FileName }",
        ],
        runInShell: false,
      );
      final out = '${r.stdout}'.trim();
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> listSubMcps() async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.listSubMcps());
    }
    return SubMcpManager.instance.listWithStatus();
  }

  @override
  Future<Map<String, dynamic>> upsertSubMcp(
    Map<String, dynamic> entry, {
    String? oldName,
  }) async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.upsertSubMcp(entry, oldName: oldName));
    }
    try {
      final res = SubMcpManager.instance.upsertEntry(entry, oldName: oldName);
      return {'ok': true, 'entry': res};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  @override
  Future<Map<String, dynamic>> importSubMcpsJson(String raw) async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.importSubMcpsJson(raw));
    }
    try {
      final list = SubMcpManager.instance.importJson(raw);
      return {'ok': true, 'count': list.length, 'entries': list};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  @override
  Future<Map<String, dynamic>> probeSubMcpDraft(
    Map<String, dynamic> draft,
  ) async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.probeSubMcpDraft(draft));
    }
    return SubMcpManager.instance.probeDraft(draft);
  }

  @override
  Future<Map<String, dynamic>> toggleSubMcp(String name, bool enabled) async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.toggleSubMcp(name, enabled));
    }
    try {
      final e = SubMcpManager.instance.toggleEntry(name, enabled);
      return {'ok': true, 'entry': e};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  @override
  Future<Map<String, dynamic>> deleteSubMcp(String name) async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.deleteSubMcp(name));
    }
    return {'ok': SubMcpManager.instance.deleteEntry(name)};
  }

  @override
  Future<Map<String, dynamic>> testSubMcp(String name) async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.testSubMcp(name));
    }
    return SubMcpManager.instance.discoverTools(name, refresh: true);
  }

  @override
  Future<Map<String, dynamic>> getPrivilegeStatus() async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.getPrivilegeStatus());
    }
    if (!Platform.isAndroid) {
      return const {
        'ok': true,
        'privilege': {'supported': false},
      };
    }
    try {
      final raw =
          await _androidChannel.invokeMethod<dynamic>('getPrivilegeStatus');
      if (raw is Map) {
        PrivilegedExecutor.instance.updateFromNativeMap(raw);
      }
    } catch (_) {}
    return {
      'ok': true,
      'privilege': PrivilegedExecutor.instance.publicStatus,
    };
  }

  @override
  Future<Map<String, dynamic>> applyPrivilegeConfig({
    required String mode,
    bool mountMaster = true,
    bool interactive = true,
  }) async {
    if (isRemoteNodeActive) {
      return _guardRemote(
        (c) => c.applyPrivilegeConfig(
          mode: mode,
          mountMaster: mountMaster,
          interactive: interactive,
        ),
      );
    }
    saveUpdatedConfigMap(_ctrl.configFile, {
      'android_privilege_mode': mode,
      'android_su_mount_master': mountMaster,
    });
    if (Platform.isAndroid) {
      try {
        final raw = await _androidChannel.invokeMethod<dynamic>(
          'applyPrivilegeConfig',
          <String, Object>{
            'mode': mode,
            'mountMaster': mountMaster,
            'interactive': interactive,
          },
        );
        if (raw is Map) {
          PrivilegedExecutor.instance.updateFromNativeMap(raw);
        }
      } catch (e) {
        return {'ok': false, 'error': '$e'};
      }
      await _syncAndroidForegroundService();
      _refreshSignal.value++;
    }
    return {
      'ok': true,
      'privilege': PrivilegedExecutor.instance.publicStatus,
    };
  }

  @override
  Future<Map<String, dynamic>> requestShizukuPermission() async {
    if (!Platform.isAndroid || isRemoteNodeActive) {
      return const {'ok': false, 'supported': false};
    }
    try {
      final raw = await _androidChannel
          .invokeMethod<dynamic>('requestShizukuPermission');
      if (raw is Map) {
        PrivilegedExecutor.instance.updateFromNativeMap(raw);
      }
      await _syncAndroidForegroundService();
      _refreshSignal.value++;
      return {
        'ok': true,
        'privilege': PrivilegedExecutor.instance.publicStatus,
      };
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  @override
  Future<bool> openPrivilegeManagerApp(String target) async {
    if (!Platform.isAndroid || isRemoteNodeActive) return false;
    try {
      final ok = await _androidChannel.invokeMethod<bool>(
        'openPrivilegeManagerApp',
        target,
      );
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Map<String, dynamic>> getExposures() async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.getExposures());
    }
    return {
      'ok': true,
      'exposures': await ExposureManager.instance
          .getDashboardSummary(_ctrl.loadCurrentServerConfig()),
    };
  }

  @override
  Future<Map<String, dynamic>> getTailscaleStatus() async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.getTailscaleStatus());
    }
    final st =
        await ExposureManager.instance.probeTailscaleStatus(forceRefresh: true);
    return {'ok': true, 'tailscale': st.toJson()};
  }

  @override
  Future<String?> pickLocalSharePath({required bool directory}) async {
    if (isRemoteNodeActive) {
      try {
        return await _remoteClient?.pickLocalSharePath(directory: directory);
      } catch (_) {
        return null;
      }
    }
    return pickNativeLocalPath(directory: directory);
  }

  @override
  Future<Map<String, dynamic>> openExposure({
    required String target,
    String mode = 'auto',
    int? port,
    String scope = 'auto',
    String? label,
    int? ttlMinutes,
    String? pinCode,
    int? maxDownloads,
    bool spa = false,
  }) async {
    if (isRemoteNodeActive) {
      return _guardRemote(
        (c) => c.openExposure(
          target: target,
          mode: mode,
          port: port,
          scope: scope,
          label: label,
          ttlMinutes: ttlMinutes,
          pinCode: pinCode,
          maxDownloads: maxDownloads,
          spa: spa,
        ),
      );
    }
    try {
      if (!_ctrl.isRunning) {
        await _ctrl.start();
      }
      final created = await ExposureManager.instance.openExposure(
        config: _ctrl.loadCurrentServerConfig(),
        rawTarget: target,
        mode: mode,
        portOverride: port,
        scope: scope,
        label: label,
        ttlMinutes: ttlMinutes,
        pinCode: pinCode,
        maxDownloads: maxDownloads,
        spa: spa,
        validateWithPolicy: false,
      );
      _refreshSignal.value++;
      return {'ok': true, 'exposure': created};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  @override
  Future<Map<String, dynamic>> closeExposure(String id) async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.closeExposure(id));
    }
    final closed = await ExposureManager.instance.closeExposure(id);
    _refreshSignal.value++;
    return {'ok': closed, 'id': id};
  }

  @override
  Future<Map<String, dynamic>> closeAllExposures() async {
    if (isRemoteNodeActive) {
      return _guardRemote((c) => c.closeAllExposures());
    }
    final count = await ExposureManager.instance.closeAllExposures();
    _refreshSignal.value++;
    return {'ok': true, 'closed_count': count};
  }

  @override
  Future<bool> openExternalUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return false;
    if (Platform.isAndroid) {
      try {
        final ok = await _androidChannel.invokeMethod<bool>(
          'openExternalUrl',
          trimmed,
        );
        return ok == true;
      } catch (_) {
        return false;
      }
    }
    try {
      if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', trimmed]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [trimmed]);
      } else {
        await Process.start('xdg-open', [trimmed]);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void quitDesktopApp() {
    unawaited(() async {
      try {
        _remoteClient?.dispose();
        await _ctrl.dispose();
      } catch (_) {}
      if (Platform.isAndroid) {
        try {
          await _androidChannel.invokeMethod<void>(
            'syncForegroundService',
            const <String, Object>{'running': false},
          );
        } catch (_) {}
        await SystemNavigator.pop();
        return;
      }
      if (Platform.isWindows) {
        try {
          await _winChannel.invokeMethod<void>('forceClose');
        } catch (_) {}
      }
      exit(0);
    }());
  }
}