import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import 'console_backend_interface.dart';

class UnauthorizedConsoleException implements Exception {
  const UnauthorizedConsoleException();
}

ConsoleBackend createPlatformConsoleBackend() => _WebConsoleBackend();

class _WebConsoleBackend extends ConsoleBackend {
  static const String _apiBase = '/dashboard/api';
  final ValueNotifier<DesktopWindowState> _windowState =
      ValueNotifier(const DesktopWindowState());

  @override
  bool get isWebMode => true;

  @override
  bool get hasCustomTitleBar => false;

  @override
  ValueListenable<DesktopWindowState> get windowState => _windowState;

  @override
  Future<void> init() async {}

  @override
  void recordUnhandledError(Object error, StackTrace stack) {
    debugPrint('Unhandled web console error: $error\n$stack');
  }

  @override
  Future<void> startWindowDrag() async {}

  @override
  Future<void> minimizeWindow() async {}

  @override
  Future<void> toggleMaximizeWindow() async {}

  @override
  Future<void> togglePinWindow() async {}

  @override
  Future<void> hideWindowToTray() async {}

  @override
  Future<void> syncNativeWindowTheme(bool isDark, {int? accentRgb}) async {}

  @override
  Future<bool> setWindowEffect(bool enabled) async {
    await saveConfig({'window_effect': enabled});
    return enabled;
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(web.window.location.href);
    return base.replace(
      path: '$_apiBase$path',
      queryParameters: (query != null && query.isNotEmpty) ? query : null,
      fragment: null,
    );
  }

  Map<String, dynamic> _decodeResp(http.Response r, {bool check401 = true}) {
    if (check401 && r.statusCode == 401) {
      throw const UnauthorizedConsoleException();
    }
    try {
      final d = jsonDecode(r.body);
      if (d is Map) return Map<String, dynamic>.from(d);
    } catch (_) {}
    return {'ok': r.statusCode >= 200 && r.statusCode < 300};
  }

  @override
  Future<Map<String, dynamic>> checkAuthState() async {
    final r = await http.get(_uri('/auth-state'));
    return _decodeResp(r, check401: false);
  }

  @override
  Future<Map<String, dynamic>> login(String password) async {
    final r = await http.post(
      _uri('/login'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'password': password}),
    );
    return _decodeResp(r, check401: false);
  }

  @override
  Future<void> logout() async {
    await http.post(_uri('/logout'));
  }

  @override
  Future<Map<String, dynamic>> getStatus() async {
    final r = await http.get(_uri('/status'));
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> saveConfig(Map<String, dynamic> patch) async {
    final r = await http.post(
      _uri('/config'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode(patch),
    );
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> startService() async {
    final r = await http.post(_uri('/service/start'));
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> stopService() async {
    final r = await http.post(_uri('/service/stop'));
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> restartService() async {
    try {
      final r = await http.post(_uri('/service/restart'));
      await Future<void>.delayed(const Duration(milliseconds: 550));
      return _decodeResp(r);
    } catch (_) {
      // Server socket may close mid-restart; wait for rebind.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      return {'ok': true, 'restarted': true};
    }
  }

  @override
  Future<List<Map<String, dynamic>>> getLogs() async {
    final r = await http.get(_uri('/logs'));
    final d = _decodeResp(r);
    final raw = d['logs'];
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return const [];
  }

  @override
  Future<void> clearLogs() async {
    await http.post(_uri('/logs/clear'));
  }

  @override
  Stream<Map<String, dynamic>> subscribeEvents() {
    late final StreamController<Map<String, dynamic>> ctrl;
    web.EventSource? es;

    void connect() {
      es?.close();
      es = web.EventSource('$_apiBase/logs/stream');
      es!.onmessage = ((web.MessageEvent e) {
        final dataStr = (e.data as JSString?)?.toDart;
        if (dataStr == null || dataStr.isEmpty) return;
        try {
          final parsed = jsonDecode(dataStr);
          if (parsed is Map && !ctrl.isClosed) {
            ctrl.add(Map<String, dynamic>.from(parsed));
          }
        } catch (_) {}
      }).toJS;
    }

    ctrl = StreamController<Map<String, dynamic>>.broadcast(
      onListen: connect,
      onCancel: () {
        es?.close();
        es = null;
      },
    );
    return ctrl.stream;
  }

  @override
  Future<void> exportLogsFile(String filename, String content) async {
    final bytes = utf8.encode(content);
    final part = bytes.toJS;
    final blob = web.Blob(
      [part].toJS,
      web.BlobPropertyBag(type: 'text/plain;charset=utf-8'),
    );
    final url = web.URL.createObjectURL(blob);
    final anchor = web.document.createElement('a') as web.HTMLAnchorElement
      ..href = url
      ..download = filename;
    web.document.body?.appendChild(anchor);
    anchor.click();
    anchor.remove();
    web.URL.revokeObjectURL(url);
  }

  @override
  Future<Map<String, dynamic>> checkHealth([String? targetUrl]) async {
    final q = (targetUrl != null && targetUrl.trim().isNotEmpty)
        ? {'url': targetUrl.trim()}
        : null;
    final r = await http.get(_uri('/health-check', q));
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> getStorage() async {
    final r = await http.get(_uri('/storage'));
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> cleanStorageTarget(String target) async {
    final r = await http.post(
      _uri('/storage/clean'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'target': target}),
    );
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> startTunnel(String profileId) async {
    final r = await http
        .post(_uri('/tunnels/${Uri.encodeComponent(profileId)}/start'));
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> stopTunnel(String profileId) async {
    final r = await http
        .post(_uri('/tunnels/${Uri.encodeComponent(profileId)}/stop'));
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> installCloudflared({
    bool force = false,
    bool resume = false,
  }) async {
    final r = await http.post(
      _uri('/tunnels/install'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'force': force, 'resume': resume}),
    );
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> pauseCloudflared() async {
    final r = await http.post(_uri('/tunnels/pause'));
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> cancelCloudflared() async {
    final r = await http.post(_uri('/tunnels/cancel'));
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> uninstallCloudflared() async {
    final r = await http.post(_uri('/tunnels/uninstall'));
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>?> pickAndImportCloudflared() async {
    final completer = Completer<(String, Uint8List)?>();
    final input = web.document.createElement('input') as web.HTMLInputElement
      ..type = 'file';

    input.onchange = ((web.Event _) async {
      final files = input.files;
      if (files == null || files.length == 0) {
        if (!completer.isCompleted) completer.complete(null);
        return;
      }
      final file = files.item(0)!;
      final ab = await file.arrayBuffer().toDart;
      final bytes = ab.toDart.asUint8List();
      if (!completer.isCompleted) completer.complete((file.name, bytes));
    }).toJS;

    input.click();
    final picked = await completer.future;
    if (picked == null) return null;

    final r = await http.post(
      _uri('/tunnels/import', {'filename': picked.$1}),
      headers: {
        'content-type': 'application/octet-stream',
        'x-filename': Uri.encodeComponent(picked.$1),
      },
      body: picked.$2,
    );
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> installPlayit({
    bool force = false,
    bool resume = false,
  }) async {
    final r = await http.post(
      _uri('/playit/install'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'force': force, 'resume': resume}),
    );
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> pausePlayit() async {
    final r = await http.post(_uri('/playit/pause'));
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> cancelPlayit() async {
    final r = await http.post(_uri('/playit/cancel'));
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> uninstallPlayit() async {
    final r = await http.post(_uri('/playit/uninstall'));
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>?> pickAndImportPlayit() async {
    final completer = Completer<(String, Uint8List)?>();
    final input = web.document.createElement('input') as web.HTMLInputElement
      ..type = 'file';

    input.onchange = ((web.Event _) async {
      final files = input.files;
      if (files == null || files.length == 0) {
        if (!completer.isCompleted) completer.complete(null);
        return;
      }
      final file = files.item(0)!;
      final ab = await file.arrayBuffer().toDart;
      final bytes = ab.toDart.asUint8List();
      if (!completer.isCompleted) completer.complete((file.name, bytes));
    }).toJS;

    input.click();
    final picked = await completer.future;
    if (picked == null) return null;

    final r = await http.post(
      _uri('/playit/import', {'filename': picked.$1}),
      headers: {
        'content-type': 'application/octet-stream',
        'x-filename': Uri.encodeComponent(picked.$1),
      },
      body: picked.$2,
    );
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> getPlayitStatus([String? profileId]) async {
    final r = await http.get(
      _uri(
        '/playit/status',
        profileId != null && profileId.isNotEmpty
            ? {'profile_id': profileId}
            : null,
      ),
    );
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> startPlayitClaim({
    required String profileId,
    String claimMode = 'random',
    String customInput = '',
    String? secretPath,
  }) async {
    final r = await http.post(
      _uri('/playit/claim/start'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        'profile_id': profileId,
        'claim_mode': claimMode,
        'custom_input': customInput,
        if (secretPath != null && secretPath.isNotEmpty)
          'secret_path': secretPath,
      }),
    );
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> resetPlayitClaim(
    String profileId, {
    String? secretPath,
  }) async {
    final r = await http.post(
      _uri('/playit/claim/reset'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        'profile_id': profileId,
        if (secretPath != null && secretPath.isNotEmpty)
          'secret_path': secretPath,
      }),
    );
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> syncPlayitEndpoint(
    String profileId, {
    bool autoCreate = false,
  }) async {
    final r = await http.post(
      _uri('/playit/sync'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        'profile_id': profileId,
        'auto_create': autoCreate,
      }),
    );
    return _decodeResp(r);
  }

  @override
  Future<List<Map<String, dynamic>>> listSubMcps() async {
    final r = await http.get(_uri('/sub-mcps'));
    final d = _decodeResp(r);
    final raw = d['servers'];
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> upsertSubMcp(
    Map<String, dynamic> entry, {
    String? oldName,
  }) async {
    final payload = Map<String, dynamic>.from(entry);
    if (oldName != null && oldName.isNotEmpty) {
      payload['old_name'] = oldName;
    }
    final r = await http.post(
      _uri('/sub-mcps'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode(payload),
    );
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> importSubMcpsJson(String raw) async {
    final r = await http.post(
      _uri('/sub-mcps/import'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'raw': raw}),
    );
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> probeSubMcpDraft(
    Map<String, dynamic> draft,
  ) async {
    final r = await http.post(
      _uri('/sub-mcps/probe'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode(draft),
    );
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> toggleSubMcp(String name, bool enabled) async {
    final r = await http.post(
      _uri('/sub-mcps/${Uri.encodeComponent(name)}/toggle'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'enabled': enabled}),
    );
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> deleteSubMcp(String name) async {
    final r = await http.delete(_uri('/sub-mcps/${Uri.encodeComponent(name)}'));
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> testSubMcp(String name) async {
    final r =
        await http.post(_uri('/sub-mcps/${Uri.encodeComponent(name)}/test'));
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> startSubMcpOAuth(
    String name, {
    Map<String, dynamic>? draft,
    String? scope,
    bool autoOpenBrowser = true,
  }) async {
    final r = await http.post(
      _uri('/sub-mcps/${Uri.encodeComponent(name)}/oauth/start'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        if (draft != null) 'draft': draft,
        if (scope != null && scope.isNotEmpty) 'scope': scope,
      }),
    );
    final res = _decodeResp(r);
    final authUrl = (res['authorization_url'] ?? '').toString().trim();
    if (autoOpenBrowser && res['ok'] == true && authUrl.isNotEmpty) {
      web.window.open(authUrl, '_blank');
    }
    return res;
  }

  @override
  Future<Map<String, dynamic>> revokeSubMcpOAuth(String name) async {
    final r = await http
        .post(_uri('/sub-mcps/${Uri.encodeComponent(name)}/oauth/revoke'));
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> callSubMcpPlayground({
    required String name,
    String kind = 'tool',
    String toolName = '',
    String uri = '',
    Map<String, dynamic> arguments = const {},
    int? timeoutSec,
  }) async {
    final r = await http.post(
      _uri('/sub-mcps/${Uri.encodeComponent(name)}/call'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        'kind': kind,
        'tool_name': toolName,
        if (uri.isNotEmpty) 'uri': uri,
        'arguments': arguments,
        if (timeoutSec != null) 'timeout': timeoutSec,
      }),
    );
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> getClientOnboardingTargets() async {
    final r = await http.get(_uri('/clients/targets'));
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> applyClientOnboarding({
    required String clientId,
    required String serverKey,
    required String mcpUrl,
    String transport = 'http',
    String? bearerToken,
    String? customConfigPath,
  }) async {
    final r = await http.post(
      _uri('/clients/onboard'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        'client_id': clientId,
        'server_key': serverKey,
        'mcp_url': mcpUrl,
        'transport': transport,
        if (bearerToken != null && bearerToken.isNotEmpty)
          'bearer_token': bearerToken,
        if (customConfigPath != null && customConfigPath.isNotEmpty)
          'custom_config_path': customConfigPath,
      }),
    );
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> exportConfigSnapshot({
    bool includeSecrets = false,
    String? password,
  }) async {
    final r = await http.post(
      _uri('/config/snapshot/export'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        'include_secrets': includeSecrets,
        if (password != null && password.isNotEmpty) 'password': password,
      }),
    );
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> importConfigSnapshot({
    required String rawJson,
    String? password,
  }) async {
    final r = await http.post(
      _uri('/config/snapshot/import'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        'raw_json': rawJson,
        if (password != null && password.isNotEmpty) 'password': password,
      }),
    );
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> getPrivilegeStatus() async {
    final r = await http.get(_uri('/privilege/status'));
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> applyPrivilegeConfig({
    required String mode,
    bool mountMaster = true,
    bool interactive = true,
  }) async {
    final r = await http.post(
      _uri('/privilege/apply'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        'mode': mode,
        'mount_master': mountMaster,
        'interactive': interactive,
      }),
    );
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> getExposures() async {
    final r = await http.get(_uri('/exposures'));
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> getTailscaleStatus() async {
    final r = await http.get(_uri('/tailscale/status'));
    return _decodeResp(r);
  }

  @override
  Future<String?> pickLocalSharePath({required bool directory}) async {
    final r = await http.post(
      _uri('/exposures/pick-path'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'directory': directory}),
    );
    final d = _decodeResp(r);
    final pth = (d['path'] ?? '').toString().trim();
    return (d['ok'] == true && pth.isNotEmpty) ? pth : null;
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
    int? maxUploads,
    bool spa = false,
    bool allowUpload = false,
    bool overwriteUpload = false,
  }) async {
    final r = await http.post(
      _uri('/exposures/open'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        'target': target,
        'mode': mode,
        if (port != null) 'port': port,
        'scope': scope,
        if (label != null && label.isNotEmpty) 'label': label,
        if (ttlMinutes != null) 'ttl_minutes': ttlMinutes,
        if (pinCode != null && pinCode.trim().isNotEmpty)
          'pin_code': pinCode.trim(),
        if (maxDownloads != null && maxDownloads > 0)
          'max_downloads': maxDownloads,
        if (maxUploads != null && maxUploads > 0) 'max_uploads': maxUploads,
        'spa': spa,
        'allow_upload': allowUpload,
        'overwrite_upload': overwriteUpload,
      }),
    );
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> closeExposure(String id) async {
    final r = await http.post(
      _uri('/exposures/close'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'id': id}),
    );
    return _decodeResp(r);
  }

  @override
  Future<Map<String, dynamic>> closeAllExposures() async {
    final r = await http.post(_uri('/exposures/close-all'));
    return _decodeResp(r);
  }

  @override
  Future<bool> openExternalUrl(String url) async {
    web.window.open(url, '_blank');
    return true;
  }

  static const String _updatePrefsKey = 'agent_mcp_update_prefs_v1';

  @override
  Future<UpdatePreferences> loadUpdatePreferences() async {
    try {
      final raw = web.window.localStorage.getItem(_updatePrefsKey);
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return UpdatePreferences.fromJson(decoded);
      }
    } catch (_) {}
    return const UpdatePreferences();
  }

  @override
  Future<void> saveUpdatePreferences(UpdatePreferences prefs) async {
    try {
      web.window.localStorage.setItem(_updatePrefsKey, jsonEncode(prefs.toJson()));
    } catch (_) {}
  }

  @override
  void quitDesktopApp() {}
}
