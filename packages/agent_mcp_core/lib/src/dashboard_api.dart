import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_static/shelf_static.dart';

import 'auth.dart';
import 'autostart.dart';
import 'client_onboarding.dart';
import 'config.dart';
import 'exposure_tools.dart';
import 'logging_utils.dart';
import 'playit_tunnel.dart';
import 'privileged_exec.dart';
import 'sub_mcp.dart';
import 'tunnel.dart';
import 'version.dart';

const String _dashCookieName = 'mcp_dash_session';
const int _sessionTtlSec = 86400;
const int _maxFails = 5;
const int _lockoutSec = 60;

/// Mounts `/dashboard` (serving the compiled Flutter Web app) and
/// `/dashboard/api/*` management endpoints onto the main MCP HTTP port.
class DashboardHandler {
  final ServerConfig config;
  final bool Function()? isServiceRunning;
  final Future<void> Function()? onStartService;
  final Future<void> Function()? onStopService;
  final Future<void> Function()? onRestartService;
  final bool requirePassword;
  final String? localLaunchTicket;

  final Uint8List _signingSecret =
      Uint8List.fromList(utf8.encode(randomTokenUrlSafe(32)));
  final Map<String, List<int>> _failTracker = {};
  Handler? _cachedStaticHandler;
  String? _cachedStaticDir;
  final Map<String, ({int mtimeMs, Uint8List bytes})> _gzipCache = {};

  DashboardHandler({
    required this.config,
    this.isServiceRunning,
    this.onStartService,
    this.onStopService,
    this.onRestartService,
    this.requirePassword = true,
    this.localLaunchTicket,
  });

  int get _nowSec => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  String _signToken() {
    final exp = '${_nowSec + _sessionTtlSec}';
    final nonce = randomHex(12);
    final msg = ascii.encode('$exp.$nonce');
    final sig = Hmac(sha256, _signingSecret).convert(msg).toString();
    return '$exp.$nonce.$sig';
  }

  bool _checkCookie(Request req) {
    if (!requirePassword) return true;
    final rawCookie = req.headers['cookie'] ?? '';
    String tok = '';
    for (final part in rawCookie.split(';')) {
      final trimmed = part.trim();
      if (trimmed.startsWith('$_dashCookieName=')) {
        tok = trimmed.substring(_dashCookieName.length + 1);
        break;
      }
    }
    final parts = tok.split('.');
    if (parts.length != 3) return false;
    final exp = int.tryParse(parts[0]) ?? 0;
    if (exp < _nowSec) return false;
    final expected = Hmac(sha256, _signingSecret)
        .convert(ascii.encode('${parts[0]}.${parts[1]}'))
        .toString();
    return constantTimeEquals(parts[2], expected);
  }

  (bool, String?) _verifyDashboardPassword(String password) {
    final saved = loadSavedConfig(config.configFile);
    final pwdHash = (saved['oauth_local_password_hash'] ??
            config.oauthLocalPasswordHash ??
            '')
        .toString();
    if (pwdHash.isNotEmpty) {
      return (verifyPassword(password, pwdHash), null);
    }
    final apiKey = (saved['api_key'] ?? config.apiKey ?? '').toString();
    if (apiKey.isNotEmpty) {
      return (constantTimeEquals(password, apiKey), null);
    }
    return (
      false,
      '服务端尚未设置全局管理密码或 API Key，请先运行 agent-mcp setup 或在桌面端设置密码。',
    );
  }

  String _clientIp(Request req) {
    final fwd = req.headers['x-forwarded-for'];
    if (fwd != null && fwd.isNotEmpty) {
      return fwd.split(',').first.trim();
    }
    final connInfo =
        req.context['shelf.io.connection_info'] as HttpConnectionInfo?;
    return connInfo?.remoteAddress.address ?? 'local';
  }

  int _lockoutRemaining(String ip) {
    final now = _nowSec;
    final attempts = (_failTracker[ip] ?? const <int>[])
        .where((t) => now - t < _lockoutSec)
        .toList();
    _failTracker[ip] = attempts;
    if (attempts.length >= _maxFails) {
      return (_lockoutSec - (now - attempts.first)).clamp(1, _lockoutSec);
    }
    return 0;
  }

  Directory? _locateWebBundleDir() {
    final root = StoragePaths.instance.rootDir;
    final exeDir = File(Platform.resolvedExecutable).parent;
    final candidates = <String>[
      p.join(root.path, 'apps', 'agent_mcp_app', 'build', 'web'),
      p.join(root.path, 'web_dashboard'),
      p.join(exeDir.path, 'web_dashboard'),
      p.join(exeDir.path, 'data', 'web_dashboard'),
      p.join(exeDir.parent.path, 'Resources', 'web_dashboard'),
    ];
    for (final c in candidates) {
      final d = Directory(c);
      if (File(p.join(d.path, 'index.html')).existsSync()) {
        return d;
      }
    }
    return null;
  }

  Future<Response?> tryHandle(Request req) async {
    final fullPath = '/${req.url.path}';
    if (fullPath != '/dashboard' && !fullPath.startsWith('/dashboard/')) {
      return null;
    }

    if (fullPath == '/dashboard') {
      final q = req.url.query.isNotEmpty ? '?${req.url.query}' : '';
      return Response.movedPermanently('/dashboard/$q');
    }

    final ticketParam = req.url.queryParameters['ticket'];
    if (localLaunchTicket != null &&
        localLaunchTicket!.isNotEmpty &&
        ticketParam != null &&
        constantTimeEquals(ticketParam, localLaunchTicket!)) {
      final cookie =
          '$_dashCookieName=${_signToken()}; Max-Age=$_sessionTtlSec; Path=/dashboard; HttpOnly; SameSite=Lax';
      return Response.found(
        '/dashboard/',
        headers: {'set-cookie': cookie},
      );
    }

    final subPath = fullPath.substring('/dashboard'.length); // starts with `/`
    if (subPath.startsWith('/api/')) {
      return _handleApi(req, subPath.substring(4)); // e.g. `/login`, `/status`
    }

    // Serve compiled Flutter Web bundle (Flutter app handles login state via /dashboard/api/auth-state)
    final webDir = _locateWebBundleDir();
    if (webDir != null) {
      if (_cachedStaticHandler == null || _cachedStaticDir != webDir.path) {
        _cachedStaticDir = webDir.path;
        _cachedStaticHandler = createStaticHandler(
          webDir.path,
          defaultDocument: 'index.html',
        );
      }
      final strippedReq = req.change(path: 'dashboard');
      final res = await _cachedStaticHandler!(strippedReq);
      if (res.statusCode != 404) {
        return _optimizeStaticResponse(req, res, subPath);
      }
      // SPA fallback to index.html
      final indexFile = File(p.join(webDir.path, 'index.html'));
      final indexRes = Response.ok(
        indexFile.readAsBytesSync(),
        headers: const {
          'content-type': 'text/html; charset=utf-8',
          'cache-control': 'no-cache',
        },
      );
      return _optimizeStaticResponse(req, indexRes, '/index.html');
    }

    return Response.ok(
      '<!doctype html><html><meta charset="utf-8"><body style="font-family:system-ui,sans-serif;padding:40px;background:#F8FAFC;color:#0F172A">'
      '<h2>Agent MCP Dashboard (v$agentMcpVersion)</h2>'
      '<p>Web 前端静态资源尚未构建。请在工程根目录运行 <code>flutter build web --base-href /dashboard/</code>（或执行 <code>scripts/build_windows.ps1</code>）。</p>'
      '</body></html>',
      headers: const {'content-type': 'text/html; charset=utf-8'},
    );
  }

  Future<Response> _handleApi(Request req, String apiPath) async {
    if (req.method != 'GET' && req.method != 'HEAD') {
      final rawOrigin = (req.headers['origin'] ?? '').trim();
      if (rawOrigin.isNotEmpty && rawOrigin != 'null') {
        final originUri = Uri.tryParse(rawOrigin);
        final reqHost = (req.headers['x-forwarded-host'] ?? req.headers['host'] ?? '')
            .split(',')
            .first
            .trim()
            .split(':')
            .first
            .toLowerCase();
        final oHost = (originUri?.host ?? '').toLowerCase();
        final isLoopbackPair =
            (oHost == 'localhost' || oHost == '127.0.0.1' || oHost == '::1') &&
            (reqHost == 'localhost' || reqHost == '127.0.0.1' || reqHost == '::1');
        if (oHost.isEmpty || (oHost != reqHost && !isLoopbackPair)) {
          return _json(
            {'ok': false, 'error': 'Cross-origin request rejected by Origin guard'},
            status: 403,
          );
        }
      }
    }

    if (apiPath == '/auth-state' && req.method == 'GET') {
      return _json({
        'ok': true,
        'authenticated': _checkCookie(req),
        'server_name': config.serverName,
        'version': agentMcpVersion,
        'dashboard_mode': requirePassword,
      });
    }

    if (apiPath == '/login' && req.method == 'POST') {
      final ip = _clientIp(req);
      final waitSec = _lockoutRemaining(ip);
      if (waitSec > 0) {
        return _json(
          {'ok': false, 'error': '密码错误次数过多，请 $waitSec 秒后再试。'},
          status: 429,
        );
      }
      Map<String, dynamic> body = {};
      try {
        final d = jsonDecode(await req.readAsString());
        if (d is Map) body = Map<String, dynamic>.from(d);
      } catch (_) {
        return _json({'ok': false, 'error': '请求格式错误'}, status: 400);
      }

      final pwd = (body['password'] ?? '').toString();
      final (ok, setupErr) = _verifyDashboardPassword(pwd);
      if (setupErr != null) {
        return _json({'ok': false, 'error': setupErr}, status: 403);
      }
      if (!ok) {
        _failTracker.putIfAbsent(ip, () => <int>[]).add(_nowSec);
        McpLogger.instance.warning('[AUTH 401] Dashboard login failed from $ip');
        return _json({'ok': false, 'error': '密码不正确，请重试。'}, status: 401);
      }

      _failTracker.remove(ip);
      McpLogger.instance.info('[OAUTH OK] Dashboard login succeeded from $ip');
      final cookie =
          '$_dashCookieName=${_signToken()}; Max-Age=$_sessionTtlSec; Path=/dashboard; HttpOnly; SameSite=Lax';
      return Response.ok(
        jsonEncode({'ok': true}),
        headers: {
          'content-type': 'application/json; charset=utf-8',
          'set-cookie': cookie,
        },
      );
    }

    if (apiPath == '/logout' && req.method == 'POST') {
      return Response.ok(
        jsonEncode({'ok': true}),
        headers: const {
          'content-type': 'application/json; charset=utf-8',
          'set-cookie':
              '$_dashCookieName=; Max-Age=0; Path=/dashboard; HttpOnly; SameSite=Lax',
        },
      );
    }

    if (!_checkCookie(req)) {
      return _json({'ok': false, 'error': 'Unauthorized'}, status: 401);
    }

    return handleAuthenticatedApi(req, apiPath);
  }

  Future<Response> handleAuthenticatedApi(Request req, String apiPath) async {
    if (apiPath == '/status' && req.method == 'GET') {
      final saved = loadSavedConfig(config.configFile);
      saved['profiles'] = ensureProfilesInConfig(saved);
      final bindHosts = parseBindHosts(saved['hosts'], saved['host']);
      final netIfaces = await listHostNetworkInterfaces();
      final lanIps = netIfaces
          .where((e) => e['kind'] != 'loopback' && e['kind'] != 'tun_proxy')
          .map((e) => e['ip'] ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
      // Redact password hash from browser payload while indicating if set
      final sanitized = Map<String, dynamic>.from(saved)
        ..['host'] = bindHosts.first
        ..['hosts'] = bindHosts
        ..['launch_at_startup'] = Platform.isAndroid
            ? false
            : AutoStartManager.effectiveLaunchAtStartup(saved)
        ..['silent_start'] = saved['silent_start'] == true
        ..['window_effect'] = saved['window_effect'] != false
        ..['host_os'] = Platform.operatingSystem
        ..['lan_ips'] = lanIps
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
        ..['onboarding_completed'] = saved.containsKey('onboarding_completed')
            ? saved['onboarding_completed'] == true
            : true
        ..['has_password'] =
            (saved['oauth_local_password_hash'] ?? '').toString().isNotEmpty
        ..remove('oauth_local_password_hash');
      return _json({
        'running': isServiceRunning?.call() ?? true,
        'version': agentMcpVersion,
        'dashboard_mode': requirePassword,
        'config_rev': _fileMtimeMs(config.configFile),
        'sub_rev': _fileMtimeMs(SubMcpManager.instance.configFile),
        'tunnels': TunnelManager.instance.getStatuses(ensureProfilesInConfig(saved)),
        'exposures': await ExposureManager.instance.getDashboardSummary(config),
        if (Platform.isAndroid)
          'privilege': PrivilegedExecutor.instance.publicStatus,
        'config': sanitized,
      });
    }

    if (apiPath == '/privilege/status' && req.method == 'GET') {
      await PrivilegedExecutor.instance.ensureActiveIfRequested();
      return _json({
        'ok': true,
        'privilege': PrivilegedExecutor.instance.publicStatus,
      });
    }

    if (apiPath == '/privilege/apply' && req.method == 'POST') {
      final body = Map<String, dynamic>.from(
        (jsonDecode(await req.readAsString()) as Map?) ?? const {},
      );
      final mode = (body['mode'] ?? 'none').toString().trim().toLowerCase();
      final mountMaster = body['mount_master'] != false;
      final interactive = body['interactive'] == true;
      saveUpdatedConfigMap(config.configFile, {
        'android_privilege_mode': mode,
        'android_su_mount_master': mountMaster,
      });
      final cb = PrivilegedExecutor.instance.onApplyConfig;
      if (cb != null) {
        final snap = await cb(
          mode: mode,
          mountMaster: mountMaster,
          interactive: interactive,
        );
        PrivilegedExecutor.instance.updateFromNativeMap(snap);
      }
      return _json({
        'ok': true,
        'privilege': PrivilegedExecutor.instance.publicStatus,
      });
    }

    if (apiPath == '/exposures' && req.method == 'GET') {
      final forcePorts = req.url.queryParameters['scan_ports'] == '1';
      return _json({
        'ok': true,
        'exposures': await ExposureManager.instance.getDashboardSummary(
          config,
          forcePortScan: forcePorts,
        ),
      });
    }

    if (apiPath == '/tailscale/status' && req.method == 'GET') {
      final st = await ExposureManager.instance.probeTailscaleStatus(
        forceRefresh: true,
      );
      return _json({'ok': true, 'tailscale': st.toJson()});
    }

    if (apiPath == '/exposures/pick-path' && req.method == 'POST') {
      final body = Map<String, dynamic>.from(
        (jsonDecode(await req.readAsString()) as Map?) ?? const {},
      );
      final isDir = body['directory'] == true;
      final picked = await pickNativeLocalPath(
        directory: isDir,
        title: body['title']?.toString(),
        initialDirectory: body['initial_dir']?.toString(),
      );
      return _json({'ok': picked != null, 'path': picked ?? ''});
    }

    if (apiPath == '/exposures/open' && req.method == 'POST') {
      try {
        final body = Map<String, dynamic>.from(
          (jsonDecode(await req.readAsString()) as Map?) ?? const {},
        );
        final created = await ExposureManager.instance.openExposure(
          config: config,
          rawTarget: (body['target'] ?? '').toString(),
          mode: (body['mode'] ?? 'auto').toString(),
          portOverride: int.tryParse('${body['port'] ?? ''}'),
          scope: (body['scope'] ?? 'auto').toString(),
          label: body['label']?.toString(),
          ttlMinutes: int.tryParse('${body['ttl_minutes'] ?? ''}'),
          pinCode: (body['pin_code'] ?? body['pin'])?.toString(),
          maxDownloads: int.tryParse('${body['max_downloads'] ?? ''}'),
          maxUploads: int.tryParse('${body['max_uploads'] ?? ''}'),
          spa: body['spa'] == true,
          allowUpload: body['allow_upload'] == true,
          overwriteUpload: body['overwrite_upload'] == true,
          validateWithPolicy: false,
        );
        return _json({'ok': true, 'exposure': created});
      } catch (e) {
        return _json({'ok': false, 'error': '$e'}, status: 400);
      }
    }

    if (apiPath == '/exposures/close' && req.method == 'POST') {
      final body = Map<String, dynamic>.from(
        (jsonDecode(await req.readAsString()) as Map?) ?? const {},
      );
      final id = (body['id'] ?? '').toString();
      final closed = await ExposureManager.instance.closeExposure(id);
      return _json({'ok': closed, 'id': id});
    }

    if (apiPath == '/exposures/close-all' && req.method == 'POST') {
      final count = await ExposureManager.instance.closeAllExposures();
      return _json({'ok': true, 'closed_count': count});
    }
    if (apiPath == '/config' && req.method == 'POST') {
      final body = Map<String, dynamic>.from(
        (jsonDecode(await req.readAsString()) as Map?) ?? const {},
      );
      saveUpdatedConfigMap(config.configFile, body);
      return _json({'ok': true});
    }

    if (apiPath == '/service/start' && req.method == 'POST') {
      if (onStartService != null) await onStartService!();
      return _json({'ok': true});
    }
    if (apiPath == '/service/stop' && req.method == 'POST') {
      if (onStopService != null) await onStopService!();
      return _json({'ok': true});
    }
    if (apiPath == '/service/restart' && req.method == 'POST') {
      if (onRestartService != null) {
        // Return HTTP 200 before stop() closes the HTTP server socket.
        unawaited(
          Future<void>.delayed(
            const Duration(milliseconds: 120),
            () => onRestartService!(),
          ),
        );
      }
      return _json({'ok': true, 'restarting': true});
    }

    if (apiPath == '/logs' && req.method == 'GET') {
      return _json({'logs': StructuredEventBus.instance.getHistory()});
    }

    if (apiPath == '/logs/clear' && req.method == 'POST') {
      StructuredEventBus.instance.clearHistory();
      return _json({'ok': true});
    }

    if (apiPath == '/logs/stream' && req.method == 'GET') {
      final ctrl = StreamController<List<int>>();
      StreamSubscription<Map<String, dynamic>>? sub;
      Timer? pingTimer;

      void cleanup() {
        pingTimer?.cancel();
        sub?.cancel();
        if (!ctrl.isClosed) ctrl.close();
      }

      ctrl.onCancel = cleanup;
      sub = StructuredEventBus.instance.stream.listen((ev) {
        if (!ctrl.isClosed) {
          ctrl.add(utf8.encode('data: ${jsonEncode(ev)}\n\n'));
        }
      });
      pingTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        if (!ctrl.isClosed) {
          ctrl.add(utf8.encode(': ping\n\n'));
        }
      });
      // Send initial comment immediately so browser EventSource marks open
      ctrl.add(utf8.encode(': connected\n\n'));

      return Response.ok(
        ctrl.stream,
        headers: const {
          'content-type': 'text/event-stream; charset=utf-8',
          'cache-control': 'no-cache',
          'connection': 'keep-alive',
          'x-accel-buffering': 'no',
        },
        context: const {'shelf.io.buffer_output': false},
      );
    }

    if (apiPath == '/health-check' && req.method == 'GET') {
      final targetUrl = (req.url.queryParameters['url'] ?? '').trim();
      if (targetUrl.isNotEmpty) {
        return _json(await probeRemoteHealth(targetUrl));
      }
      return _json({
        'ok': true,
        'url': '/health',
        'scheme': 'local',
        'status_code': 200,
        'latency_ms': 0,
        'body': jsonEncode({
          'status': 'ok',
          'server_name': config.serverName,
          'version': agentMcpVersion,
          'auth_mode': config.authMode,
          'read_only': config.readOnly,
        }),
      });
    }

    if (apiPath == '/storage' && req.method == 'GET') {
      return _json({'ok': true, 'stats': getStorageStats()});
    }

    if (apiPath == '/storage/clean' && req.method == 'POST') {
      final body = Map<String, dynamic>.from(
        (jsonDecode(await req.readAsString()) as Map?) ?? const {},
      );
      final target = (body['target'] ?? '').toString().trim();
      if (target == 'logs') {
        StructuredEventBus.instance.clearHistory();
      }
      final res = cleanStorage(target);
      res['stats'] = getStorageStats();
      return _json(res);
    }

    if (apiPath == '/tunnels/install' && req.method == 'POST') {
      var force = false;
      var resume = false;
      try {
        final body = jsonDecode(await req.readAsString());
        if (body is Map) {
          force = body['force'] == true;
          resume = body['resume'] == true;
        }
      } catch (_) {}
      final res = await TunnelManager.instance.startCloudflaredDownload(
        forceUpdate: force,
        resume: resume,
      );
      return _json(res);
    }

    if (apiPath == '/tunnels/pause' && req.method == 'POST') {
      return _json(TunnelManager.instance.pauseDownload());
    }
    if (apiPath == '/tunnels/cancel' && req.method == 'POST') {
      return _json(TunnelManager.instance.cancelDownload());
    }
    if (apiPath == '/tunnels/uninstall' && req.method == 'POST') {
      return _json(await TunnelManager.instance.uninstallCloudflared());
    }
    if (apiPath == '/tunnels/import' && req.method == 'POST') {
      final rawName = req.headers['x-filename'] ??
          req.url.queryParameters['filename'] ??
          'cloudflared';
      final filename = Uri.decodeComponent(rawName);
      final bytesBuilder = BytesBuilder(copy: false);
      await for (final chunk in req.read()) {
        bytesBuilder.add(chunk);
      }
      final res = await TunnelManager.instance
          .importCloudflaredBytes(filename, bytesBuilder.takeBytes());
      return _json(res);
    }

    final tunActionMatch =
        RegExp(r'^/tunnels/([^/]+)/(start|stop)$').firstMatch(apiPath);
    if (tunActionMatch != null && req.method == 'POST') {
      final pid = Uri.decodeComponent(tunActionMatch.group(1)!);
      final act = tunActionMatch.group(2)!;
      if (act == 'stop') {
        return _json(await TunnelManager.instance.stopTunnel(pid));
      }
      final saved = loadSavedConfig(config.configFile);
      final profs = ensureProfilesInConfig(saved);
      final prof = profs.where((p) => p['id'] == pid).firstOrNull;
      if (prof == null) {
        return _json({'ok': false, 'error': '未找到该入口配置'}, status: 404);
      }
      final localPort =
          int.tryParse('${saved['port'] ?? config.port}') ?? config.port;
      return _json(await TunnelManager.instance.startTunnel(prof, localPort));
    }

    if (apiPath == '/playit/install' && req.method == 'POST') {
      var force = false;
      var resume = false;
      try {
        final body = jsonDecode(await req.readAsString());
        if (body is Map) {
          force = body['force'] == true;
          resume = body['resume'] == true;
        }
      } catch (_) {}
      final res = await PlayitManager.instance.startPlayitDownload(
        forceUpdate: force,
        resume: resume,
      );
      return _json(res);
    }

    if (apiPath == '/playit/pause' && req.method == 'POST') {
      return _json(PlayitManager.instance.pauseDownload());
    }
    if (apiPath == '/playit/cancel' && req.method == 'POST') {
      return _json(PlayitManager.instance.cancelDownload());
    }
    if (apiPath == '/playit/uninstall' && req.method == 'POST') {
      return _json(await PlayitManager.instance.uninstallPlayit());
    }
    if (apiPath == '/playit/import' && req.method == 'POST') {
      final rawName = req.headers['x-filename'] ??
          req.url.queryParameters['filename'] ??
          'playitd';
      final filename = Uri.decodeComponent(rawName);
      final bytesBuilder = BytesBuilder(copy: false);
      await for (final chunk in req.read()) {
        bytesBuilder.add(chunk);
      }
      final res = await PlayitManager.instance
          .importPlayitBytes(filename, bytesBuilder.takeBytes());
      return _json(res);
    }

    if (apiPath == '/playit/status' && req.method == 'GET') {
      final pid = req.url.queryParameters['profile_id']?.trim();
      final saved = loadSavedConfig(config.configFile);
      final profs = ensureProfilesInConfig(saved);
      if (pid != null && pid.isNotEmpty) {
        final prof = profs.where((p) => p['id'] == pid).firstOrNull;
        return _json({
          'ok': true,
          'component': PlayitManager.instance.getComponentStatus(profs),
          'profile': PlayitManager.instance.getProfilePlayitStatus(
            pid,
            customSecretPath: prof?['playit_secret_path']?.toString(),
          ),
        });
      }
      return _json({
        'ok': true,
        'component': PlayitManager.instance.getComponentStatus(profs),
      });
    }

    if (apiPath == '/playit/claim/start' && req.method == 'POST') {
      final body = Map<String, dynamic>.from(
        (jsonDecode(await req.readAsString()) as Map?) ?? const {},
      );
      final pid = (body['profile_id'] ?? 'default').toString().trim();
      final claimMode = (body['claim_mode'] ?? 'random').toString().trim();
      final customInput = (body['custom_input'] ?? '').toString().trim();
      final secretPath = body['secret_path']?.toString();
      final saved = loadSavedConfig(config.configFile);
      final profs = ensureProfilesInConfig(saved);
      final prof = profs.where((p) => p['id'] == pid).firstOrNull;
      final localPort =
          int.tryParse('${saved['port'] ?? config.port}') ?? config.port;
      final res = await PlayitManager.instance.startClaim(
        profileId: pid,
        claimMode: claimMode,
        customInput: customInput,
        customSecretPath: secretPath ?? prof?['playit_secret_path']?.toString(),
        localPort: localPort,
        profile: prof,
      );
      return _json(res);
    }

    if (apiPath == '/playit/claim/reset' && req.method == 'POST') {
      final body = Map<String, dynamic>.from(
        (jsonDecode(await req.readAsString()) as Map?) ?? const {},
      );
      final pid = (body['profile_id'] ?? 'default').toString().trim();
      final secretPath = body['secret_path']?.toString();
      final saved = loadSavedConfig(config.configFile);
      final profs = ensureProfilesInConfig(saved);
      final prof = profs.where((p) => p['id'] == pid).firstOrNull;
      final res = await PlayitManager.instance.resetProfileSecret(
        pid,
        customSecretPath: secretPath ?? prof?['playit_secret_path']?.toString(),
      );
      return _json(res);
    }

    if (apiPath == '/playit/sync' && req.method == 'POST') {
      final body = Map<String, dynamic>.from(
        (jsonDecode(await req.readAsString()) as Map?) ?? const {},
      );
      final pid = (body['profile_id'] ?? 'default').toString().trim();
      final saved = loadSavedConfig(config.configFile);
      final profs = ensureProfilesInConfig(saved);
      final prof = profs.where((p) => p['id'] == pid).firstOrNull;
      final secFile = resolvePlayitSecretFile(
        pid,
        body['secret_path']?.toString() ??
            prof?['playit_secret_path']?.toString(),
      );
      final secKey = readPlayitSecretKey(secFile);
      if (secKey == null || secKey.isEmpty) {
        return _json({'ok': false, 'error': '该入口尚未完成 Playit 认领'});
      }
      final localPort =
          int.tryParse('${saved['port'] ?? config.port}') ?? config.port;
      final res = await PlayitManager.instance.syncProfileEndpointFromApi(
        profileId: pid,
        secretKey: secKey,
        localPort: localPort,
        profile: prof,
        allowAutoCreate: body['auto_create'] == true,
      );
      return _json(res);
    }

    if (apiPath == '/sub-mcps' && req.method == 'GET') {
      return _json({'ok': true, 'servers': SubMcpManager.instance.listWithStatus()});
    }

    if (apiPath == '/sub-mcps' && req.method == 'POST') {
      try {
        final body = Map<String, dynamic>.from(
          (jsonDecode(await req.readAsString()) as Map?) ?? const {},
        );
        final oldName = body.remove('old_name')?.toString();
        final entry =
            SubMcpManager.instance.upsertEntry(body, oldName: oldName);
        return _json({'ok': true, 'entry': entry});
      } catch (e) {
        return _json({'ok': false, 'error': '$e'}, status: 400);
      }
    }

    if (apiPath == '/sub-mcps/import' && req.method == 'POST') {
      try {
        final body = Map<String, dynamic>.from(
          (jsonDecode(await req.readAsString()) as Map?) ?? const {},
        );
        final imported =
            SubMcpManager.instance.importJson((body['raw'] ?? '').toString());
        return _json({
          'ok': true,
          'count': imported.length,
          'entries': imported,
        });
      } catch (e) {
        return _json({'ok': false, 'error': '$e'}, status: 400);
      }
    }

    if (apiPath == '/sub-mcps/probe' && req.method == 'POST') {
      try {
        final body = Map<String, dynamic>.from(
          (jsonDecode(await req.readAsString()) as Map?) ?? const {},
        );
        return _json(await SubMcpManager.instance.probeDraft(body));
      } catch (e) {
        return _json({'ok': false, 'error': '$e'}, status: 400);
      }
    }

    final subToggleMatch =
        RegExp(r'^/sub-mcps/([^/]+)/toggle$').firstMatch(apiPath);
    if (subToggleMatch != null && req.method == 'POST') {
      final name = Uri.decodeComponent(subToggleMatch.group(1)!);
      try {
        final body = Map<String, dynamic>.from(
          (jsonDecode(await req.readAsString()) as Map?) ?? const {},
        );
        final entry = SubMcpManager.instance
            .toggleEntry(name, body['enabled'] != false);
        return _json({'ok': true, 'entry': entry});
      } catch (e) {
        return _json({'ok': false, 'error': '$e'}, status: 404);
      }
    }

    final subTestMatch =
        RegExp(r'^/sub-mcps/([^/]+)/test$').firstMatch(apiPath);
    if (subTestMatch != null && req.method == 'POST') {
      final name = Uri.decodeComponent(subTestMatch.group(1)!);
      return _json(
        await SubMcpManager.instance.discoverTools(name, refresh: true),
      );
    }

    final subOAuthStartMatch =
        RegExp(r'^/sub-mcps/([^/]+)/oauth/start$').firstMatch(apiPath);
    if (subOAuthStartMatch != null && req.method == 'POST') {
      final name = Uri.decodeComponent(subOAuthStartMatch.group(1)!);
      try {
        final rawText = await req.readAsString();
        final body = rawText.trim().isEmpty
            ? const <String, dynamic>{}
            : Map<String, dynamic>.from((jsonDecode(rawText) as Map?) ?? const {});
        final draft = body['draft'] is Map
            ? Map<String, dynamic>.from(body['draft'] as Map)
            : null;
        final started = await SubMcpManager.instance.startOAuthFlow(
          name,
          draftOverride: draft,
          stepUpScope: body['scope']?.toString(),
        );
        return _json(started);
      } catch (e) {
        return _json({'ok': false, 'error': '$e'}, status: 400);
      }
    }

    final subOAuthRevokeMatch =
        RegExp(r'^/sub-mcps/([^/]+)/oauth/revoke$').firstMatch(apiPath);
    if (subOAuthRevokeMatch != null && req.method == 'POST') {
      final name = Uri.decodeComponent(subOAuthRevokeMatch.group(1)!);
      return _json({'ok': SubMcpManager.instance.revokeOAuth(name)});
    }

    final subCallMatch =
        RegExp(r'^/sub-mcps/([^/]+)/call$').firstMatch(apiPath);
    if (subCallMatch != null && req.method == 'POST') {
      final name = Uri.decodeComponent(subCallMatch.group(1)!);
      try {
        final body = Map<String, dynamic>.from(
          (jsonDecode(await req.readAsString()) as Map?) ?? const {},
        );
        final kind = (body['kind'] ?? 'tool').toString().toLowerCase();
        final sw = Stopwatch()..start();
        String output;
        if (kind == 'resource') {
          output = await SubMcpManager.instance.readResource(
            name,
            (body['uri'] ?? body['tool_name'] ?? '').toString(),
          );
        } else if (kind == 'prompt') {
          output = await SubMcpManager.instance.getPrompt(
            name,
            (body['tool_name'] ?? '').toString(),
            arguments: body['arguments'] is Map
                ? Map<String, dynamic>.from(body['arguments'] as Map)
                : const <String, dynamic>{},
          );
        } else {
          output = await SubMcpManager.instance.callTool(
            name,
            (body['tool_name'] ?? '').toString(),
            arguments: body['arguments'] is Map
                ? Map<String, dynamic>.from(body['arguments'] as Map)
                : const <String, dynamic>{},
            timeoutSec: int.tryParse('${body['timeout'] ?? ''}'),
          );
        }
        sw.stop();
        return _json({
          'ok': !output.startsWith('Error:'),
          'output': output,
          'ms': double.parse((sw.elapsedMicroseconds / 1000.0).toStringAsFixed(1)),
        });
      } catch (e) {
        return _json({'ok': false, 'error': '$e'}, status: 400);
      }
    }

    if (apiPath == '/clients/targets' && req.method == 'GET') {
      return _json({
        'ok': true,
        'targets':
            ClientOnboardingManager.detectTargets().map((t) => t.toJson()).toList(),
      });
    }

    if (apiPath == '/clients/onboard' && req.method == 'POST') {
      try {
        final body = Map<String, dynamic>.from(
          (jsonDecode(await req.readAsString()) as Map?) ?? const {},
        );
        final res = ClientOnboardingManager.applyClientOnboarding(
          clientId: (body['client_id'] ?? '').toString(),
          serverKey: (body['server_key'] ?? '').toString(),
          mcpUrl: (body['mcp_url'] ?? '').toString(),
          transport: (body['transport'] ?? 'http').toString(),
          bearerToken: body['bearer_token']?.toString(),
          customConfigPath: body['custom_config_path']?.toString(),
        );
        return _json(res);
      } catch (e) {
        return _json({'ok': false, 'error': '$e'}, status: 400);
      }
    }

    if (apiPath == '/config/snapshot/export' && req.method == 'POST') {
      try {
        final rawText = await req.readAsString();
        final body = rawText.trim().isEmpty
            ? const <String, dynamic>{}
            : Map<String, dynamic>.from((jsonDecode(rawText) as Map?) ?? const {});
        final snap = ConfigSnapshotManager.exportSnapshot(
          configFile: config.configFile,
          includeSecrets: body['include_secrets'] == true,
          password: body['password']?.toString(),
        );
        return _json({'ok': true, 'snapshot': snap});
      } catch (e) {
        return _json({'ok': false, 'error': '$e'}, status: 400);
      }
    }

    if (apiPath == '/config/snapshot/import' && req.method == 'POST') {
      try {
        final body = Map<String, dynamic>.from(
          (jsonDecode(await req.readAsString()) as Map?) ?? const {},
        );
        final res = ConfigSnapshotManager.importSnapshot(
          rawJson: (body['raw_json'] ?? '').toString(),
          password: body['password']?.toString(),
          configFile: config.configFile,
        );
        return _json(res);
      } catch (e) {
        return _json({'ok': false, 'error': '$e'}, status: 400);
      }
    }

    final subDelMatch = RegExp(r'^/sub-mcps/([^/]+)$').firstMatch(apiPath);
    if (subDelMatch != null && req.method == 'DELETE') {
      final name = Uri.decodeComponent(subDelMatch.group(1)!);
      return _json({'ok': SubMcpManager.instance.deleteEntry(name)});
    }

    return _json({'ok': false, 'error': 'Unknown endpoint: $apiPath'}, status: 404);
  }

  Future<Response> _optimizeStaticResponse(
    Request req,
    Response res,
    String subPath,
  ) async {
    final norm = subPath.split('?').first.toLowerCase();
    final isIndex = norm == '/' || norm.isEmpty || norm == '/index.html';
    final isBootstrap = isIndex ||
        norm.endsWith('flutter_bootstrap.js') ||
        norm.endsWith('flutter_service_worker.js') ||
        norm.endsWith('version.json') ||
        norm.endsWith('main.dart.js') ||
        norm.endsWith('main.dart.mjs') ||
        norm.endsWith('main.dart.wasm');
    final cacheControl = isBootstrap
        ? 'no-cache, must-revalidate'
        : (norm.startsWith('/canvaskit/') || norm.startsWith('/assets/fonts/'))
            ? 'public, max-age=31536000, immutable'
            : 'public, max-age=3600';

    final headers = Map<String, Object>.from(res.headers);
    headers['cache-control'] = cacheControl;

    final acceptEnc = (req.headers['accept-encoding'] ?? '').toLowerCase();
    final alreadyEncoded = headers.containsKey('content-encoding');
    final compressible = norm.endsWith('.js') ||
        norm.endsWith('.wasm') ||
        norm.endsWith('.json') ||
        norm.endsWith('.html') ||
        norm.endsWith('.css') ||
        norm.endsWith('.svg') ||
        norm.endsWith('.ttf') ||
        norm.endsWith('.otf') ||
        norm.endsWith('.txt') ||
        isIndex;

    if (res.statusCode == 200 &&
        !alreadyEncoded &&
        compressible &&
        acceptEnc.contains('gzip')) {
      final cacheKey = '${_cachedStaticDir ?? ''}$norm';
      final file = _cachedStaticDir == null
          ? null
          : File(
              p.join(
                _cachedStaticDir!,
                isIndex ? 'index.html' : norm.replaceFirst(RegExp(r'^/+'), ''),
              ),
            );
      final mtime = file != null ? _fileMtimeMs(file) : 0;
      final cached = _gzipCache[cacheKey];
      Uint8List gzBytes;
      if (cached != null && mtime > 0 && cached.mtimeMs == mtime) {
        gzBytes = cached.bytes;
      } else {
        final rawBytes = await res.read().expand((b) => b).toList();
        if (rawBytes.length < 1024) {
          return Response(res.statusCode, body: rawBytes, headers: headers);
        }
        gzBytes = Uint8List.fromList(gzip.encode(rawBytes));
        if (mtime > 0) {
          _gzipCache[cacheKey] = (mtimeMs: mtime, bytes: gzBytes);
        }
      }
      headers['content-encoding'] = 'gzip';
      headers['vary'] = 'Accept-Encoding';
      headers['content-length'] = '${gzBytes.length}';
      return Response.ok(gzBytes, headers: headers);
    }

    return res.change(headers: headers);
  }
}

({String short, String detail}) _classifyProbeError(Object err) {
  if (err is TimeoutException) {
    return (short: '连接超时 (>6s)', detail: '请求超过 6 秒未响应');
  }
  if (err is HandshakeException || err is TlsException) {
    return (
      short: 'TLS 未开启 / 证书异常',
      detail: 'TLS 握手失败（该端口可能仅提供明文 HTTP，或证书无效）',
    );
  }
  if (err is SocketException) {
    final msg = err.message;
    final full = err.toString();
    if (full.contains('Failed host lookup') ||
        full.contains('11001') ||
        full.contains('No address associated')) {
      return (short: 'DNS 解析失败', detail: '域名无法解析，请检查域名拼写或 DNS 记录');
    }
    if (full.contains('Connection refused') ||
        full.contains('10061') ||
        full.contains('errno = 111')) {
      return (short: '拒绝连接', detail: '目标端口未监听或防火墙已拦截');
    }
    if (full.contains('Connection reset') || full.contains('10054')) {
      return (short: '连接被重置', detail: '远端重置了连接 ($msg)');
    }
    return (short: '网络不可达', detail: msg.isNotEmpty ? msg : full);
  }
  if (err is FormatException) {
    return (short: '地址格式错误', detail: err.message);
  }
  final s = '$err';
  return (
    short: '连接异常',
    detail: s.length > 140 ? '${s.substring(0, 140)}...' : s,
  );
}

String _extractHostAndBasePath(String rawInput) {
  var s = rawInput
      .trim()
      .replaceFirst(RegExp(r'^https?://', caseSensitive: false), '')
      .replaceAll(RegExp(r'/+$'), '');
  if (s.toLowerCase().endsWith('/health')) {
    s = s.substring(0, s.length - '/health'.length).replaceAll(RegExp(r'/+$'), '');
  }
  return s;
}

Future<Map<String, dynamic>> _probeSingleProtocol(
  String proto,
  String hurl,
) async {
  final sw = Stopwatch()..start();
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..idleTimeout = const Duration(seconds: 5);
  try {
    final uri = Uri.parse(hurl);
    final req = await client.getUrl(uri).timeout(const Duration(seconds: 6));
    req.headers.set(
      HttpHeaders.acceptHeader,
      'application/json, text/plain, */*',
    );
    final res = await req.close().timeout(const Duration(seconds: 6));
    final body = await res
        .transform(const Utf8Decoder(allowMalformed: true))
        .join()
        .timeout(const Duration(seconds: 5));
    sw.stop();

    final code = res.statusCode;
    final redirected = res.redirects.isNotEmpty;
    final finalScheme = redirected
        ? res.redirects.last.location.scheme.toUpperCase()
        : proto;
    final ok = code == 200;
    final statusText = ok
        ? (redirected && finalScheme != proto
            ? '↪ 跳转 $finalScheme (200)'
            : 'HTTP 200 正常')
        : 'HTTP $code';

    return {
      'protocol': proto,
      'url': hurl,
      'ok': ok,
      'redirected': redirected,
      'status_code': code,
      'status_text': statusText,
      'latency_ms': sw.elapsedMilliseconds,
      'body': body,
      if (!ok) 'error': 'HTTP 状态码 $code',
    };
  } catch (e) {
    sw.stop();
    final info = _classifyProbeError(e);
    return {
      'protocol': proto,
      'url': hurl,
      'ok': false,
      'redirected': false,
      'status_code': null,
      'status_text': info.short,
      'latency_ms': sw.elapsedMilliseconds,
      'error': info.detail,
    };
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>> probeRemoteHealth(String targetUrl) async {
  final hostAndPath = _extractHostAndBasePath(targetUrl);
  if (hostAndPath.isEmpty) {
    return {
      'ok': false,
      'url': targetUrl,
      'status_text': '地址为空',
      'error': '无效的服务地址格式，请输入域名或完整 URL',
      'probes': const [],
    };
  }

  final httpsParsed = Uri.tryParse('https://$hostAndPath');
  final httpParsed = Uri.tryParse('http://$hostAndPath');
  if (httpsParsed == null ||
      httpsParsed.host.isEmpty ||
      httpParsed == null ||
      httpParsed.host.isEmpty) {
    return {
      'ok': false,
      'url': targetUrl,
      'status_text': '格式错误',
      'error': '无效的服务地址格式，请输入域名或完整 URL',
      'probes': const [],
    };
  }

  String withHealth(Uri u) {
    final pth = '${u.path.replaceAll(RegExp(r'/+$'), '')}/health';
    return u.replace(path: pth, query: null, fragment: null).toString();
  }

  final httpsUrl = withHealth(httpsParsed);
  final httpUrl = withHealth(httpParsed);

  final probes = await Future.wait([
    _probeSingleProtocol('HTTPS', httpsUrl),
    _probeSingleProtocol('HTTP', httpUrl),
  ]);

  final httpsRes = probes[0];
  final httpRes = probes[1];
  final anyOk = httpsRes['ok'] == true || httpRes['ok'] == true;
  final primary = httpsRes['ok'] == true
      ? httpsRes
      : (httpRes['ok'] == true ? httpRes : httpsRes);

  return {
    'ok': anyOk,
    'url': primary['url'],
    'scheme': (primary['protocol'] ?? '').toString().toLowerCase(),
    'status_code': primary['status_code'],
    'status_text': primary['status_text'],
    'latency_ms': primary['latency_ms'],
    'body': primary['body'],
    if (!anyOk) 'error': primary['error'] ?? httpRes['error'],
    'probes': probes,
  };
}

void saveUpdatedConfigMap(File configFile, Map<String, dynamic> patch) {
  final cur = loadSavedConfig(configFile);
  final body = Map<String, dynamic>.from(patch);
  final newPwd = body.remove('oauth_local_password')?.toString().trim();
  if (newPwd != null && newPwd.isNotEmpty) {
    cur['oauth_local_password_hash'] = hashPassword(newPwd);
  }
  final effectivePort =
      int.tryParse('${body['port'] ?? cur['port'] ?? 8000}') ?? 8000;

  void syncProfilesDerivedFields(List<Map<String, dynamic>> profs) {
    cur['profiles'] = profs;
    final enabled = profs.where((p) => p['enabled'] != false).toList();
    final activeList = enabled.isNotEmpty ? enabled : profs;
    if (activeList.isNotEmpty) {
      final p0 = activeList.first;
      cur['transport'] = p0['transport'];
      cur['auth_mode'] = p0['auth_mode'];
      final bases = <String>[];
      for (final p in activeList) {
        final multi = p['base_urls'];
        if (multi is List) {
          for (final u in multi) {
            final s = u.toString().trim();
            if (s.isNotEmpty && !bases.contains(s)) bases.add(s);
          }
        }
        final b = (p['base_url'] ?? '').toString().trim();
        if (b.isNotEmpty && !bases.contains(b)) bases.add(b);
      }
      if (bases.isNotEmpty) {
        cur['oauth_base_url'] = bases.first;
        cur['oauth_base_urls'] = bases;
      } else {
        cur.remove('oauth_base_url');
        cur['oauth_base_urls'] = const <String>[];
      }
      if (p0['oauth_client_id'] != null) {
        cur['oauth_client_id'] = p0['oauth_client_id'];
      }
      if (p0['oauth_client_secret'] != null) {
        cur['oauth_client_secret'] = p0['oauth_client_secret'];
      }
      if (p0['oauth_redirect_uris'] != null) {
        cur['oauth_redirect_uris'] = p0['oauth_redirect_uris'];
      }
      if (p0['oauth_allow_all_redirects'] != null) {
        cur['oauth_allow_all_redirects'] = p0['oauth_allow_all_redirects'];
      }
      if (p0['api_key'] != null) {
        cur['api_key'] = p0['api_key'];
      }
    }
  }

  if (body['profiles'] is List) {
    final rawList = body.remove('profiles') as List;
    final profs = <Map<String, dynamic>>[];
    for (var i = 0; i < rawList.length; i++) {
      if (rawList[i] is Map) {
        profs.add(
          normalizeProfile(
            Map<String, dynamic>.from(rawList[i] as Map),
            i,
            effectivePort,
          ),
        );
      }
    }
    syncProfilesDerivedFields(profs);
  } else if (body.containsKey('port') && cur['profiles'] is List) {
    final existingList = cur['profiles'] as List;
    final profs = <Map<String, dynamic>>[];
    for (var i = 0; i < existingList.length; i++) {
      if (existingList[i] is Map) {
        profs.add(
          normalizeProfile(
            Map<String, dynamic>.from(existingList[i] as Map),
            i,
            effectivePort,
          ),
        );
      }
    }
    if (profs.isNotEmpty) {
      syncProfilesDerivedFields(profs);
    }
  }
  if (body.containsKey('hosts') || body.containsKey('host')) {
    final normalizedHosts = parseBindHosts(
      body.remove('hosts'),
      body.remove('host') ?? cur['host'],
    );
    cur['hosts'] = normalizedHosts;
    cur['host'] = normalizedHosts.first;
  }
  for (final e in body.entries) {
    if (e.key == 'tool_prefix') {
      cur[e.key] =
          sanitizePrefix(e.value.toString()).replaceAll(RegExp(r'_+$'), '');
    } else {
      cur[e.key] = e.value;
    }
  }
  final shouldSyncAutoStart = patch.containsKey('launch_at_startup') ||
      patch.containsKey('silent_start');
  saveConfigFile(configFile, cur);
  if (shouldSyncAutoStart) {
    unawaited(AutoStartManager.syncFromConfigMapAsync(cur));
  }
}

int _fileMtimeMs(File f) {
  try {
    return f.existsSync() ? f.lastModifiedSync().millisecondsSinceEpoch : 0;
  } catch (_) {
    return 0;
  }
}

Response _json(Map<String, dynamic> data, {int status = 200}) {
  return Response(
    status,
    body: jsonEncode(data),
    headers: const {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  );
}
