import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'update_service.dart';
export 'update_service.dart';

const String kLoopbackIpv4 = '127.0' '.0.1';

String generateRandomToken(String prefix, int len) {
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-';
  final rng = Random.secure();
  final body =
      List.generate(len, (_) => chars[rng.nextInt(chars.length)]).join();
  return '$prefix$body';
}

String formatBytesHuman(num? rawBytes) {
  final b = (rawBytes ?? 0).toDouble();
  if (b <= 0) return '0 B';
  if (b < 1024) return '${b.toInt()} B';
  if (b < 1048576) return '${(b / 1024).toStringAsFixed(1)} KB';
  return '${(b / 1048576).toStringAsFixed(2)} MB';
}

String normalizeRemoteBaseUrl(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return '';
  if (!s.contains('://')) {
    final lower = s.toLowerCase();
    final isLocalOrPrivate = lower.startsWith('localhost') ||
        lower.startsWith('127.') ||
        lower.startsWith('10.') ||
        lower.startsWith('192.168.') ||
        lower.startsWith('100.') ||
        RegExp(r'^172\.(1[6-9]|2\d|3[0-1])\.').hasMatch(lower) ||
        RegExp(r':\d+').hasMatch(lower);
    s = '${isLocalOrPrivate ? "http" : "https"}://$s';
  }
  try {
    final uri = Uri.parse(s);
    var path = uri.path.replaceAll(RegExp(r'/+$'), '');
    for (final suffix in const [
      '/dashboard/api',
      '/dashboard',
      '/mcp',
      '/sse',
      '/messages',
    ]) {
      if (path.toLowerCase().endsWith(suffix)) {
        path = path.substring(0, path.length - suffix.length);
        break;
      }
    }
    return Uri(
      scheme: uri.scheme.toLowerCase(),
      userInfo: uri.userInfo,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: path,
    ).toString().replaceAll(RegExp(r'/+$'), '');
  } catch (_) {
    return s.replaceAll(RegExp(r'/+$'), '');
  }
}

@immutable
class ConsoleNodeProfile {
  final String id;
  final String name;
  final String baseUrl;
  final String savedPassword;
  final bool isLocal;

  const ConsoleNodeProfile({
    required this.id,
    required this.name,
    this.baseUrl = '',
    this.savedPassword = '',
    this.isLocal = false,
  });

  String get hostLabel {
    if (isLocal) return 'LOCAL';
    try {
      final u = Uri.parse(baseUrl);
      if (u.host.isNotEmpty) {
        return u.hasPort ? '${u.host}:${u.port}' : u.host;
      }
    } catch (_) {}
    return baseUrl;
  }

  ConsoleNodeProfile copyWith({
    String? id,
    String? name,
    String? baseUrl,
    String? savedPassword,
    bool? isLocal,
  }) {
    return ConsoleNodeProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      savedPassword: savedPassword ?? this.savedPassword,
      isLocal: isLocal ?? this.isLocal,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'base_url': baseUrl,
        'saved_password': savedPassword,
      };

  factory ConsoleNodeProfile.fromJson(Map<dynamic, dynamic> raw) {
    final id = (raw['id'] ?? '').toString().trim();
    final url = normalizeRemoteBaseUrl((raw['base_url'] ?? '').toString());
    final name = (raw['name'] ?? '').toString().trim();
    return ConsoleNodeProfile(
      id: id.isEmpty ? generateRandomToken('node-', 8) : id,
      name: name.isEmpty ? (url.isEmpty ? '远程节点' : url) : name,
      baseUrl: url,
      savedPassword: (raw['saved_password'] ?? '').toString(),
      isLocal: false,
    );
  }
}

@immutable
class DesktopWindowState {
  final bool isMaximized;
  final bool isPinned;
  final bool isBackdropSupported;
  final bool windowEffect;
  final bool isVisible;

  const DesktopWindowState({
    this.isMaximized = false,
    this.isPinned = false,
    this.isBackdropSupported = false,
    this.windowEffect = false,
    this.isVisible = true,
  });

  DesktopWindowState copyWith({
    bool? isMaximized,
    bool? isPinned,
    bool? isBackdropSupported,
    bool? windowEffect,
    bool? isVisible,
  }) {
    return DesktopWindowState(
      isMaximized: isMaximized ?? this.isMaximized,
      isPinned: isPinned ?? this.isPinned,
      isBackdropSupported: isBackdropSupported ?? this.isBackdropSupported,
      windowEffect: windowEffect ?? this.windowEffect,
      isVisible: isVisible ?? this.isVisible,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DesktopWindowState &&
      other.isMaximized == isMaximized &&
      other.isPinned == isPinned &&
      other.isBackdropSupported == isBackdropSupported &&
      other.windowEffect == windowEffect &&
      other.isVisible == isVisible;

  @override
  int get hashCode => Object.hash(
        isMaximized,
        isPinned,
        isBackdropSupported,
        windowEffect,
        isVisible,
      );
}

abstract class ConsoleBackend {
  bool get isWebMode;
  bool get hasCustomTitleBar;
  ValueListenable<DesktopWindowState> get windowState;

  bool get isAndroidPlatform => false;

  Future<Map<String, dynamic>> getAndroidDynamicColors() async => const {'supported': false};
  bool get isWindowsPlatform => false;
  bool get isLinuxPlatform => false;
  String get currentAppVersion => '2.6.0';
  bool get supportsInAppUpgrade => false;
  bool get supportsNodeSwitching => false;
  bool get isRemoteNodeActive => false;
  List<String> get deviceLanIps => const [];
  ValueListenable<int> get externalRefreshSignal => _defaultRefreshSignal;
  static final ValueNotifier<int> _defaultRefreshSignal = ValueNotifier<int>(0);

  final StreamController<List<String>> _droppedFilesCtrl =
      StreamController<List<String>>.broadcast();
  Stream<List<String>> get droppedFilesStream => _droppedFilesCtrl.stream;

  final StreamController<String> _trayCommandCtrl =
      StreamController<String>.broadcast();
  Stream<String> get trayCommandStream => _trayCommandCtrl.stream;

  void emitTrayCommand(String cmd) {
    final cleaned = cmd.trim();
    if (cleaned.isNotEmpty && !_trayCommandCtrl.isClosed) {
      _trayCommandCtrl.add(cleaned);
    }
  }

  void emitDroppedFiles(List<String> paths) {
    final cleaned = paths.map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    if (cleaned.isNotEmpty && !_droppedFilesCtrl.isClosed) {
      _droppedFilesCtrl.add(cleaned);
    }
  }

  ConsoleNodeProfile get activeNode => const ConsoleNodeProfile(
        id: 'local',
        name: '本机服务',
        isLocal: true,
      );

  List<ConsoleNodeProfile> get savedNodes => <ConsoleNodeProfile>[activeNode];

  Future<void> selectNode(String nodeId) async {}

  Future<ConsoleNodeProfile> upsertRemoteNode({
    String? id,
    required String name,
    required String baseUrl,
    String savedPassword = '',
  }) async =>
      activeNode;

  Future<void> deleteRemoteNode(String nodeId) async {}

  Future<void> init();
  void recordUnhandledError(Object error, StackTrace stack);

  Future<void> startWindowDrag();
  Future<void> minimizeWindow();
  Future<void> toggleMaximizeWindow();
  Future<void> togglePinWindow();
  Future<void> hideWindowToTray();
  Future<void> syncNativeWindowTheme(bool isDark);
  Future<bool> setWindowEffect(bool enabled);

  Future<Map<String, dynamic>> checkAuthState();
  Future<Map<String, dynamic>> login(String password);
  Future<void> logout();

  Future<Map<String, dynamic>> getStatus();
  Future<Map<String, dynamic>> saveConfig(Map<String, dynamic> patch);

  Future<Map<String, dynamic>> startService();
  Future<Map<String, dynamic>> stopService();
  Future<Map<String, dynamic>> restartService();

  Future<List<Map<String, dynamic>>> getLogs();
  Future<void> clearLogs();
  Stream<Map<String, dynamic>> subscribeEvents();
  Future<void> exportLogsFile(String filename, String content);

  Future<Map<String, dynamic>> checkHealth([String? targetUrl]);
  Future<Map<String, dynamic>> getStorage();
  Future<Map<String, dynamic>> cleanStorageTarget(String target);

  Future<Map<String, dynamic>> startTunnel(String profileId);
  Future<Map<String, dynamic>> stopTunnel(String profileId);
  Future<Map<String, dynamic>> installCloudflared({
    bool force = false,
    bool resume = false,
  });
  Future<Map<String, dynamic>> pauseCloudflared();
  Future<Map<String, dynamic>> cancelCloudflared();
  Future<Map<String, dynamic>> uninstallCloudflared();
  Future<Map<String, dynamic>?> pickAndImportCloudflared();

  Future<List<Map<String, dynamic>>> listSubMcps();
  Future<Map<String, dynamic>> upsertSubMcp(
    Map<String, dynamic> entry, {
    String? oldName,
  });
  Future<Map<String, dynamic>> importSubMcpsJson(String raw);
  Future<Map<String, dynamic>> probeSubMcpDraft(Map<String, dynamic> draft);
  Future<Map<String, dynamic>> toggleSubMcp(String name, bool enabled);
  Future<Map<String, dynamic>> deleteSubMcp(String name);
  Future<Map<String, dynamic>> testSubMcp(String name);

  Future<Map<String, dynamic>> getPrivilegeStatus() async =>
      const {'supported': false, 'requested_mode': 'none', 'active_mode': 'none'};

  Future<Map<String, dynamic>> applyPrivilegeConfig({
    required String mode,
    bool mountMaster = true,
    bool interactive = true,
  }) async =>
      const {'ok': false, 'supported': false};

  Future<Map<String, dynamic>> requestShizukuPermission() async =>
      const {'ok': false, 'supported': false};

  Future<bool> openPrivilegeManagerApp(String target) async => false;

  Future<Map<String, dynamic>> getExposures() async =>
      const {'ok': true, 'exposures': <String, dynamic>{'enabled': true, 'active_count': 0, 'items': <dynamic>[]}};

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
  }) async =>
      const {'ok': false, 'error': 'Unsupported'};

  Future<String?> pickLocalSharePath({required bool directory}) async => null;

  Future<Map<String, dynamic>> closeExposure(String id) async =>
      const {'ok': false};

  Future<Map<String, dynamic>> closeAllExposures() async =>
      const {'ok': false};

  Future<Map<String, dynamic>> getTailscaleStatus() async =>
      const {'ok': true, 'tailscale': <String, dynamic>{}};

  Future<bool> openExternalUrl(String url) async => false;

  Future<UpdatePreferences> loadUpdatePreferences() async =>
      const UpdatePreferences();

  Future<void> saveUpdatePreferences(UpdatePreferences prefs) async {}

  Future<UpdateCheckResult> checkForUpdates({bool manual = false}) async {
    final prefs = await loadUpdatePreferences();
    final res = await UpdateService.checkLatest(
      currentVersion: currentAppVersion,
      mirrorPrefix: prefs.mirrorPrefix,
      skippedVersion: prefs.skippedVersion,
      manual: manual,
    );
    if (res.ok) {
      await saveUpdatePreferences(
        prefs.copyWith(
          lastCheckedAtIso: DateTime.now().toUtc().toIso8601String(),
        ),
      );
    }
    return res;
  }

  Future<UpdateDownloadResult> downloadUpdatePackage(
    UpdateAsset asset, {
    void Function(int received, int total)? onProgress,
    String mirrorPrefix = '',
  }) async =>
      const UpdateDownloadResult(ok: false, error: '当前平台暂不支持应用内下载');

  Future<Map<String, dynamic>> launchDownloadedInstaller(
    String filePath, {
    bool silent = false,
    String after = 'gui',
  }) async =>
      const {'ok': false, 'error': '当前平台暂不支持应用内启动安装'};

  void quitDesktopApp();
}