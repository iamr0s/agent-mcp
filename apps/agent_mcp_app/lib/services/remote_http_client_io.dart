import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'console_backend_interface.dart';

class RemoteUnauthorizedException implements Exception {
  const RemoteUnauthorizedException();
}

class RemoteHttpNodeClient {
  ConsoleNodeProfile profile;
  String? _sessionCookie;
  bool _disposed = false;
  HttpClient _http = _createHttpClient();

  RemoteHttpNodeClient(this.profile);

  static HttpClient _createHttpClient() {
    final c = HttpClient();
    c.connectionTimeout = const Duration(seconds: 8);
    c.idleTimeout = const Duration(seconds: 25);
    return c;
  }

  void updateProfile(ConsoleNodeProfile next) {
    final urlChanged = next.baseUrl != profile.baseUrl;
    profile = next;
    if (urlChanged) {
      _sessionCookie = null;
    }
  }

  void dispose() {
    _disposed = true;
    try {
      _http.close(force: true);
    } catch (_) {}
  }

  Uri _apiUri(String subPath, [Map<String, String>? query]) {
    final base = normalizeRemoteBaseUrl(profile.baseUrl);
    final baseUri = Uri.parse(base);
    final mergedPath = '${baseUri.path}/dashboard/api$subPath'
        .replaceAll(RegExp(r'/+'), '/');
    return baseUri.replace(
      path: mergedPath,
      queryParameters: (query != null && query.isNotEmpty) ? query : null,
      fragment: null,
    );
  }

  void _captureCookies(HttpClientResponse res) {
    for (final c in res.cookies) {
      if (c.name == 'mcp_dash_session' && c.value.isNotEmpty) {
        _sessionCookie = 'mcp_dash_session=${c.value}';
        return;
      }
    }
    final rawList = res.headers[HttpHeaders.setCookieHeader];
    if (rawList != null) {
      for (final raw in rawList) {
        for (final seg in raw.split(';')) {
          final t = seg.trim();
          if (t.startsWith('mcp_dash_session=')) {
            _sessionCookie = t;
            return;
          }
        }
      }
    }
  }

  Future<(int, String)> _sendRaw(
    String method,
    String subPath, {
    Map<String, String>? query,
    Object? jsonBody,
    Uint8List? rawBytes,
    Map<String, String>? extraHeaders,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (_disposed) {
      _http = _createHttpClient();
      _disposed = false;
    }
    final uri = _apiUri(subPath, query);
    final req = await _http.openUrl(method, uri).timeout(timeout);
    req.followRedirects = true;
    if (_sessionCookie != null && _sessionCookie!.isNotEmpty) {
      req.headers.set(HttpHeaders.cookieHeader, _sessionCookie!);
    }
    if (extraHeaders != null) {
      extraHeaders.forEach(req.headers.set);
    }
    if (jsonBody != null) {
      final encoded = utf8.encode(jsonEncode(jsonBody));
      req.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      );
      req.contentLength = encoded.length;
      req.add(encoded);
    } else if (rawBytes != null) {
      req.contentLength = rawBytes.length;
      req.add(rawBytes);
    }
    final res = await req.close().timeout(timeout);
    _captureCookies(res);
    final body = await utf8.decodeStream(res).timeout(timeout);
    return (res.statusCode, body);
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String subPath, {
    Map<String, String>? query,
    Object? jsonBody,
    Uint8List? rawBytes,
    Map<String, String>? extraHeaders,
    bool check401 = true,
    bool allowAutoRelogin = true,
  }) async {
    var (code, body) = await _sendRaw(
      method,
      subPath,
      query: query,
      jsonBody: jsonBody,
      rawBytes: rawBytes,
      extraHeaders: extraHeaders,
    );
    if (check401 &&
        code == 401 &&
        allowAutoRelogin &&
        profile.savedPassword.isNotEmpty) {
      final loginRes = await login(profile.savedPassword);
      if (loginRes['ok'] == true) {
        (code, body) = await _sendRaw(
          method,
          subPath,
          query: query,
          jsonBody: jsonBody,
          rawBytes: rawBytes,
          extraHeaders: extraHeaders,
        );
      }
    }
    if (check401 && code == 401) {
      throw const RemoteUnauthorizedException();
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return {
      'ok': code >= 200 && code < 300,
      'status_code': code,
    };
  }

  Future<Map<String, dynamic>> checkAuthState() async {
    final res = await _requestJson(
      'GET',
      '/auth-state',
      check401: false,
      allowAutoRelogin: false,
    );
    if (res['authenticated'] != true && profile.savedPassword.isNotEmpty) {
      final lr = await login(profile.savedPassword);
      if (lr['ok'] == true) {
        return _requestJson(
          'GET',
          '/auth-state',
          check401: false,
          allowAutoRelogin: false,
        );
      }
    }
    return res;
  }

  Future<Map<String, dynamic>> login(String password) => _requestJson(
        'POST',
        '/login',
        jsonBody: {'password': password},
        check401: false,
        allowAutoRelogin: false,
      );

  Future<void> logout() async {
    try {
      await _requestJson('POST', '/logout', check401: false);
    } catch (_) {}
    _sessionCookie = null;
  }

  Future<Map<String, dynamic>> getStatus() => _requestJson('GET', '/status');

  Future<Map<String, dynamic>> saveConfig(Map<String, dynamic> patch) =>
      _requestJson('POST', '/config', jsonBody: patch);

  Future<Map<String, dynamic>> startService() =>
      _requestJson('POST', '/service/start');

  Future<Map<String, dynamic>> stopService() =>
      _requestJson('POST', '/service/stop');

  Future<Map<String, dynamic>> restartService() async {
    try {
      final r = await _requestJson('POST', '/service/restart');
      await Future<void>.delayed(const Duration(milliseconds: 550));
      return r;
    } on RemoteUnauthorizedException {
      rethrow;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      return {'ok': true, 'restarted': true};
    }
  }

  Future<List<Map<String, dynamic>>> getLogs() async {
    final d = await _requestJson('GET', '/logs');
    final raw = d['logs'];
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return const [];
  }

  Future<void> clearLogs() async {
    await _requestJson('POST', '/logs/clear');
  }

  Stream<Map<String, dynamic>> subscribeEvents() {
    late final StreamController<Map<String, dynamic>> ctrl;
    var active = false;
    HttpClient? sseHttp;

    Future<void> pumpLoop() async {
      while (active && !_disposed && !ctrl.isClosed) {
        try {
          sseHttp?.close(force: true);
          sseHttp = HttpClient()
            ..connectionTimeout = const Duration(seconds: 8)
            ..idleTimeout = const Duration(minutes: 10);
          final req = await sseHttp!.getUrl(_apiUri('/logs/stream'));
          req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
          req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
          if (_sessionCookie != null && _sessionCookie!.isNotEmpty) {
            req.headers.set(HttpHeaders.cookieHeader, _sessionCookie!);
          }
          final res = await req.close();
          _captureCookies(res);
          if (res.statusCode == 401 && profile.savedPassword.isNotEmpty) {
            await login(profile.savedPassword);
            await Future<void>.delayed(const Duration(seconds: 1));
            continue;
          }
          if (res.statusCode != 200) {
            await Future<void>.delayed(const Duration(seconds: 3));
            continue;
          }
          await for (final line
              in res.transform(utf8.decoder).transform(const LineSplitter())) {
            if (!active || ctrl.isClosed) break;
            if (line.startsWith('data:')) {
              final data = line.substring(5).trim();
              if (data.isEmpty) continue;
              try {
                final parsed = jsonDecode(data);
                if (parsed is Map && !ctrl.isClosed) {
                  ctrl.add(Map<String, dynamic>.from(parsed));
                }
              } catch (_) {}
            }
          }
        } catch (_) {}
        if (active && !ctrl.isClosed) {
          await Future<void>.delayed(const Duration(milliseconds: 2400));
        }
      }
    }

    ctrl = StreamController<Map<String, dynamic>>.broadcast(
      onListen: () {
        active = true;
        unawaited(pumpLoop());
      },
      onCancel: () {
        active = false;
        try {
          sseHttp?.close(force: true);
        } catch (_) {}
        sseHttp = null;
      },
    );
    return ctrl.stream;
  }

  Future<Map<String, dynamic>> checkHealth([String? targetUrl]) {
    final q = (targetUrl != null && targetUrl.trim().isNotEmpty)
        ? {'url': targetUrl.trim()}
        : null;
    return _requestJson('GET', '/health-check', query: q);
  }

  Future<Map<String, dynamic>> getStorage() => _requestJson('GET', '/storage');

  Future<Map<String, dynamic>> cleanStorageTarget(String target) =>
      _requestJson('POST', '/storage/clean', jsonBody: {'target': target});

  Future<Map<String, dynamic>> startTunnel(String profileId) =>
      _requestJson('POST', '/tunnels/${Uri.encodeComponent(profileId)}/start');

  Future<Map<String, dynamic>> stopTunnel(String profileId) =>
      _requestJson('POST', '/tunnels/${Uri.encodeComponent(profileId)}/stop');

  Future<Map<String, dynamic>> installCloudflared({
    bool force = false,
    bool resume = false,
  }) =>
      _requestJson(
        'POST',
        '/tunnels/install',
        jsonBody: {'force': force, 'resume': resume},
      );

  Future<Map<String, dynamic>> pauseCloudflared() =>
      _requestJson('POST', '/tunnels/pause');

  Future<Map<String, dynamic>> cancelCloudflared() =>
      _requestJson('POST', '/tunnels/cancel');

  Future<Map<String, dynamic>> uninstallCloudflared() =>
      _requestJson('POST', '/tunnels/uninstall');

  Future<Map<String, dynamic>> importCloudflaredBytes(
    String filename,
    Uint8List bytes,
  ) =>
      _requestJson(
        'POST',
        '/tunnels/import',
        query: {'filename': filename},
        rawBytes: bytes,
        extraHeaders: {
          'content-type': 'application/octet-stream',
          'x-filename': Uri.encodeComponent(filename),
        },
      );

  Future<List<Map<String, dynamic>>> listSubMcps() async {
    final d = await _requestJson('GET', '/sub-mcps');
    final raw = d['servers'];
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return const [];
  }

  Future<Map<String, dynamic>> upsertSubMcp(
    Map<String, dynamic> entry, {
    String? oldName,
  }) {
    final payload = Map<String, dynamic>.from(entry);
    if (oldName != null && oldName.isNotEmpty) {
      payload['old_name'] = oldName;
    }
    return _requestJson('POST', '/sub-mcps', jsonBody: payload);
  }

  Future<Map<String, dynamic>> importSubMcpsJson(String raw) =>
      _requestJson('POST', '/sub-mcps/import', jsonBody: {'raw': raw});

  Future<Map<String, dynamic>> probeSubMcpDraft(Map<String, dynamic> draft) =>
      _requestJson('POST', '/sub-mcps/probe', jsonBody: draft);

  Future<Map<String, dynamic>> toggleSubMcp(String name, bool enabled) =>
      _requestJson(
        'POST',
        '/sub-mcps/${Uri.encodeComponent(name)}/toggle',
        jsonBody: {'enabled': enabled},
      );

  Future<Map<String, dynamic>> deleteSubMcp(String name) =>
      _requestJson('DELETE', '/sub-mcps/${Uri.encodeComponent(name)}');

  Future<Map<String, dynamic>> testSubMcp(String name) =>
      _requestJson('POST', '/sub-mcps/${Uri.encodeComponent(name)}/test');

  Future<Map<String, dynamic>> getPrivilegeStatus() =>
      _requestJson('GET', '/privilege/status');

  Future<Map<String, dynamic>> applyPrivilegeConfig({
    required String mode,
    required bool mountMaster,
    required bool interactive,
  }) =>
      _requestJson(
        'POST',
        '/privilege/apply',
        jsonBody: {
          'mode': mode,
          'mount_master': mountMaster,
          'interactive': interactive,
        },
      );

  Future<Map<String, dynamic>> getExposures() =>
      _requestJson('GET', '/exposures');

  Future<Map<String, dynamic>> getTailscaleStatus() =>
      _requestJson('GET', '/tailscale/status');

  Future<Map<String, dynamic>> openExposure({
    required String target,
    int? port,
    String scope = 'auto',
    String? label,
    int? ttlMinutes,
    bool spa = false,
  }) =>
      _requestJson(
        'POST',
        '/exposures/open',
        jsonBody: {
          'target': target,
          if (port != null) 'port': port,
          'scope': scope,
          if (label != null && label.isNotEmpty) 'label': label,
          if (ttlMinutes != null) 'ttl_minutes': ttlMinutes,
          'spa': spa,
        },
      );

  Future<Map<String, dynamic>> closeExposure(String id) =>
      _requestJson('POST', '/exposures/close', jsonBody: {'id': id});

  Future<Map<String, dynamic>> closeAllExposures() =>
      _requestJson('POST', '/exposures/close-all');
}