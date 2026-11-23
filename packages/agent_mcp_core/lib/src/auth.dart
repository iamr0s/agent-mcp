import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';

import 'config.dart';
import 'logging_utils.dart';

String randomTokenUrlSafe([int byteLen = 24]) {
  final rng = Random.secure();
  final bytes =
      Uint8List.fromList(List.generate(byteLen, (_) => rng.nextInt(256)));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

String randomHex([int byteLen = 16]) {
  final rng = Random.secure();
  final bytes = List.generate(byteLen, (_) => rng.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Exact bit-for-bit compatible PBKDF2-HMAC-SHA256 (`salt$hex`, 100,000 rounds)
/// matching `hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt.encode("utf-8"), 100_000)` in Python.
Uint8List _pbkdf2HmacSha256(
  List<int> passwordBytes,
  List<int> saltBytes,
  int iterations,
) {
  final hmac = Hmac(sha256, passwordBytes);
  final saltPlusBlock = Uint8List(saltBytes.length + 4)
    ..setRange(0, saltBytes.length, saltBytes)
    ..[saltBytes.length] = 0
    ..[saltBytes.length + 1] = 0
    ..[saltBytes.length + 2] = 0
    ..[saltBytes.length + 3] = 1;

  var u = Uint8List.fromList(hmac.convert(saltPlusBlock).bytes);
  final out = Uint8List.fromList(u);
  for (var i = 1; i < iterations; i++) {
    u = Uint8List.fromList(hmac.convert(u).bytes);
    for (var j = 0; j < out.length; j++) {
      out[j] ^= u[j];
    }
  }
  return out;
}

String hashPassword(String password, [String? salt]) {
  final s = (salt != null && salt.isNotEmpty) ? salt : randomHex(16);
  final digestBytes =
      _pbkdf2HmacSha256(utf8.encode(password), utf8.encode(s), 100000);
  final hex =
      digestBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '$s\$$hex';
}

bool constantTimeEquals(String a, String b) {
  final ba = utf8.encode(a);
  final bb = utf8.encode(b);
  if (ba.length != bb.length) return false;
  var diff = 0;
  for (var i = 0; i < ba.length; i++) {
    diff |= ba[i] ^ bb[i];
  }
  return diff == 0;
}

bool verifyPassword(String password, String stored) {
  final idx = stored.indexOf(r'$');
  if (idx <= 0) return false;
  final salt = stored.substring(0, idx);
  final expected = stored.substring(idx + 1);
  final actualFull = hashPassword(password, salt);
  final actualHex = actualFull.substring(salt.length + 1);
  return constantTimeEquals(actualHex, expected);
}

String _decodeFormComponentSafe(String input) {
  try {
    return Uri.decodeQueryComponent(input);
  } catch (_) {
    try {
      return Uri.decodeComponent(input);
    } catch (_) {
      return input;
    }
  }
}

bool _isLoopbackHost(String host) {
  final h = host.toLowerCase();
  return h == 'localhost' || h == '127.0.0.1' || h == '::1' || h == '[::1]';
}

/// Normalizes OAuth redirect URIs for reliable comparison:
/// - Strips trailing slash on non-root paths
/// - Treats loopback ephemeral ports (`http://127.0.0.1:<port>/cb`) as equivalent per RFC 8252 §7.3
String normalizeOAuthRedirectUri(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme) return trimmed;

  final scheme = uri.scheme.toLowerCase();
  final rawHost = uri.host.toLowerCase();
  final isLoopback = (scheme == 'http' || scheme == 'https') &&
      _isLoopbackHost(rawHost);
  final host = isLoopback ? '127.0.0.1' : rawHost;

  var path = uri.path;
  if (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path.isEmpty) path = '/';

  final includePort = !isLoopback &&
      uri.hasPort &&
      !((scheme == 'http' && uri.port == 80) ||
          (scheme == 'https' && uri.port == 443));
  final portPart = includePort ? ':${uri.port}' : '';
  final queryPart = uri.hasQuery ? '?${uri.query}' : '';
  return '$scheme://$host$portPart$path$queryPart';
}

bool isRedirectUriAllowed(List<String> allowedUris, String candidate) {
  if (allowedUris.isEmpty) return true;
  final normCandidate = normalizeOAuthRedirectUri(candidate);
  for (final allowed in allowedUris) {
    if (allowed.trim() == '*' ||
        normalizeOAuthRedirectUri(allowed) == normCandidate) {
      return true;
    }
  }
  return false;
}

class _PendingAuthReq {
  final Map<String, dynamic> client;
  final String redirectUri;
  final String state;
  final String codeChallenge;
  final String codeChallengeMethod;
  final List<String> scopes;
  final String? profileId;
  final int expiresAtSec;

  const _PendingAuthReq({
    required this.client,
    required this.redirectUri,
    required this.state,
    required this.codeChallenge,
    required this.codeChallengeMethod,
    required this.scopes,
    required this.profileId,
    required this.expiresAtSec,
  });
}

class _AuthCodeRecord {
  final String code;
  final String clientId;
  final String redirectUri;
  final String codeChallenge;
  final String codeChallengeMethod;
  final List<String> scopes;
  final String? profileId;
  final int expiresAtSec;

  const _AuthCodeRecord({
    required this.code,
    required this.clientId,
    required this.redirectUri,
    required this.codeChallenge,
    required this.codeChallengeMethod,
    required this.scopes,
    required this.profileId,
    required this.expiresAtSec,
  });
}

/// Self-hosted OAuth 2.1 Authorization & Resource Server for Agent MCP.
/// Compatible with `data/oauth_state.json` from the Python edition.
class LocalOAuthProvider {
  String primaryBaseUrl;
  String passwordHash;
  String serverName;
  final File? stateFile;
  final File? configFile;

  final Map<String, Map<String, dynamic>> _clients = {};
  final Map<String, _PendingAuthReq> _pending = {};
  final Map<String, _AuthCodeRecord> _codes = {};
  final Map<String, Map<String, dynamic>> _accessTokens = {};
  final Map<String, Map<String, dynamic>> _refreshTokens = {};

  LocalOAuthProvider({
    required this.primaryBaseUrl,
    required this.passwordHash,
    required this.serverName,
    this.stateFile,
    this.configFile,
    String? staticClientId,
    String? staticClientSecret,
    List<String>? staticRedirectUris,
    List<Map<String, dynamic>>? extraStaticClients,
  }) {
    _loadState();
    if (staticClientId != null &&
        staticClientId.isNotEmpty &&
        staticClientSecret != null &&
        staticClientSecret.isNotEmpty) {
      _registerStaticClient(
        clientId: staticClientId,
        clientSecret: staticClientSecret,
        clientName: 'Configured OAuth Client',
        redirectUris: staticRedirectUris ?? const [],
      );
    }
    for (final sc in extraStaticClients ?? const <Map<String, dynamic>>[]) {
      final cid = (sc['client_id'] ?? '').toString().trim();
      final csec = (sc['client_secret'] ?? '').toString().trim();
      if (cid.isNotEmpty && csec.isNotEmpty) {
        final uris = ((sc['redirect_uris'] as List?) ?? const [])
            .map((e) => e.toString().trim())
            .where((s) => s.isNotEmpty)
            .toList();
        _registerStaticClient(
          clientId: cid,
          clientSecret: csec,
          clientName:
              (sc['client_name'] ?? 'Configured OAuth Client').toString(),
          redirectUris: uris,
          profileId: sc['profile_id']?.toString(),
        );
      }
    }
  }

  int get _nowSec => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  void _registerStaticClient({
    required String clientId,
    required String clientSecret,
    required String clientName,
    required List<String> redirectUris,
    String? profileId,
  }) {
    _clients[clientId] = {
      'client_id': clientId,
      'client_secret': clientSecret,
      'client_name': clientName,
      'is_static': true,
      if (profileId != null && profileId.isNotEmpty) 'profile_id': profileId,
      if (redirectUris.isNotEmpty) 'redirect_uris': redirectUris,
      'grant_types': ['authorization_code', 'refresh_token'],
      'response_types': ['code'],
      'scope': 'mcp',
    };
  }

  void _reloadPasswordHashFromDisk() {
    final cf = configFile;
    if (cf == null || !cf.existsSync()) return;
    final saved = loadSavedConfig(cf);
    if (saved.isEmpty) return;
    final diskHash = (saved['oauth_local_password_hash'] ?? '').toString().trim();
    if (diskHash.isNotEmpty) {
      passwordHash = diskHash;
    }
    final diskName = (saved['server_name'] ?? '').toString().trim();
    if (diskName.isNotEmpty) {
      serverName = diskName;
    }
  }

  void syncFromConfig(
    Map<String, dynamic> saved,
    List<Map<String, dynamic>> profiles,
  ) {
    final newHash =
        (saved['oauth_local_password_hash'] ?? '').toString().trim();
    if (newHash.isNotEmpty) {
      passwordHash = newHash;
    }
    final newName = (saved['server_name'] ?? '').toString().trim();
    if (newName.isNotEmpty) {
      serverName = newName;
    }
    for (final p in profiles) {
      if (p['enabled'] == false || p['auth_mode'] != 'oauth-local') continue;
      final cid = (p['oauth_client_id'] ?? '').toString().trim();
      final csec = (p['oauth_client_secret'] ?? '').toString().trim();
      if (cid.isNotEmpty && csec.isNotEmpty) {
        final uris = ((p['oauth_redirect_uris'] as List?) ?? const [])
            .map((e) => e.toString().trim())
            .where((s) => s.isNotEmpty)
            .toList();
        _registerStaticClient(
          clientId: cid,
          clientSecret: csec,
          clientName: (p['name'] ?? 'OAuth Profile').toString(),
          redirectUris: uris,
          profileId: p['id']?.toString(),
        );
      }
    }
  }

  Map<String, dynamic>? _resolveValidAccessTokenRecord(String token) {
    final at = _accessTokens[token];
    if (at == null) return null;
    final exp = int.tryParse('${at['expires_at'] ?? 0}') ?? 0;
    if (exp > 0 && exp < _nowSec) {
      _accessTokens.remove(token);
      return null;
    }
    return at;
  }

  String? resolveTokenClientId(String token) {
    return _resolveValidAccessTokenRecord(token)?['client_id']?.toString();
  }

  String? resolveTokenProfileId(String token) {
    final at = _resolveValidAccessTokenRecord(token);
    if (at == null) return null;
    final pid = at['profile_id']?.toString();
    if (pid != null && pid.isNotEmpty) return pid;
    final cid = at['client_id']?.toString();
    if (cid != null) {
      final cliPid = _clients[cid]?['profile_id']?.toString();
      if (cliPid != null && cliPid.isNotEmpty) return cliPid;
    }
    return null;
  }

  bool validateAccessToken(String token) => resolveTokenClientId(token) != null;

  void _loadState() {
    final f = stateFile;
    if (f == null || !f.existsSync()) return;
    try {
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is! Map) return;
      final now = _nowSec;
      final clients = raw['clients'];
      if (clients is Map) {
        for (final e in clients.entries) {
          if (e.value is Map) {
            _clients[e.key.toString()] =
                Map<String, dynamic>.from(e.value as Map);
          }
        }
      }
      final ats = raw['access_tokens'];
      if (ats is Map) {
        for (final e in ats.entries) {
          if (e.value is Map) {
            final m = Map<String, dynamic>.from(e.value as Map);
            final exp = int.tryParse('${m['expires_at'] ?? 0}') ?? 0;
            if (exp == 0 || exp > now) {
              _accessTokens[e.key.toString()] = m;
            }
          }
        }
      }
      final rts = raw['refresh_tokens'];
      if (rts is Map) {
        for (final e in rts.entries) {
          if (e.value is Map) {
            final m = Map<String, dynamic>.from(e.value as Map);
            final exp = int.tryParse('${m['expires_at'] ?? 0}') ?? 0;
            if (exp == 0 || exp > now) {
              _refreshTokens[e.key.toString()] = m;
            }
          }
        }
      }
    } catch (_) {}
  }

  void _saveState() {
    final f = stateFile;
    if (f == null) return;
    try {
      // Prune expired rotated refresh tokens before saving
      final now = _nowSec;
      _refreshTokens.removeWhere((_, v) {
        final rot = int.tryParse('${v['rotated_at'] ?? 0}') ?? 0;
        if (rot > 0 && now - rot > 90) return true;
        final exp = int.tryParse('${v['expires_at'] ?? 0}') ?? 0;
        return exp > 0 && exp < now;
      });
      f.parent.createSync(recursive: true);
      final payload = {
        'clients': _clients,
        'access_tokens': _accessTokens,
        'refresh_tokens': _refreshTokens,
      };
      f.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(payload)}\n',
        flush: true,
      );
    } catch (_) {}
  }

  bool isOAuthRoute(String path) {
    return path.startsWith('/.well-known/') ||
        path == '/register' ||
        path == '/authorize' ||
        path == '/local-login' ||
        path == '/token' ||
        path == '/revoke';
  }

  Future<Response?> tryHandle(
    Request request, {
    required String effectiveBaseUrl,
    String? targetProfileId,
  }) async {
    final path = '/${request.url.path}';
    final base = effectiveBaseUrl.replaceAll(RegExp(r'/+$'), '');

    if (path.startsWith('/.well-known/oauth-protected-resource')) {
      return _jsonResp(200, {
        'resource': '$base/mcp',
        'authorization_servers': [base],
        'scopes_supported': ['mcp'],
        'bearer_methods_supported': ['header'],
      });
    }

    if (path == '/.well-known/oauth-authorization-server' ||
        path == '/.well-known/openid-configuration') {
      return _jsonResp(200, {
        'issuer': base,
        'authorization_endpoint': '$base/authorize',
        'token_endpoint': '$base/token',
        'registration_endpoint': '$base/register',
        'revocation_endpoint': '$base/revoke',
        'scopes_supported': ['mcp'],
        'response_types_supported': ['code'],
        'grant_types_supported': ['authorization_code', 'refresh_token'],
        'token_endpoint_auth_methods_supported': [
          'client_secret_basic',
          'client_secret_post',
          'none',
        ],
        'code_challenge_methods_supported': ['S256', 'plain'],
      });
    }

    if (path == '/register' && request.method == 'POST') {
      return _handleRegister(request, targetProfileId: targetProfileId);
    }
    if (path == '/authorize' && request.method == 'GET') {
      return _handleAuthorize(request, base, targetProfileId: targetProfileId);
    }
    if (path == '/local-login' &&
        (request.method == 'GET' || request.method == 'POST')) {
      return _handleLocalLogin(request);
    }
    if (path == '/token' && request.method == 'POST') {
      return _handleToken(request, targetProfileId: targetProfileId);
    }
    if (path == '/revoke' && request.method == 'POST') {
      return _handleRevoke(request);
    }
    return null;
  }

  Future<Response> _handleRegister(
    Request request, {
    String? targetProfileId,
  }) async {
    Map<String, dynamic> body;
    try {
      final raw = await request.readAsString();
      final decoded = raw.trim().isEmpty ? const {} : jsonDecode(raw);
      body = decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      return _jsonResp(400, {'error': 'invalid_client_metadata'});
    }

    final requestedCid = (body['client_id'] ?? '').toString().trim();
    final existingStatic =
        requestedCid.isNotEmpty ? _clients[requestedCid] : null;
    if (existingStatic != null && existingStatic['is_static'] == true) {
      return _jsonResp(201, existingStatic);
    }

    final cid =
        requestedCid.isNotEmpty ? requestedCid : 'mcp-dyn-${randomHex(8)}';

    // Per RFC 7591 Section 2, default token_endpoint_auth_method is
    // "client_secret_basic", which MUST issue a client_secret unless the
    // client explicitly requests "none".
    final rawMethod =
        (body['token_endpoint_auth_method'] ?? '').toString().trim();
    final authMethod = rawMethod.isEmpty ? 'client_secret_basic' : rawMethod;
    final csec =
        authMethod == 'none' ? null : 'sec-${randomTokenUrlSafe(24)}';
    final uris = ((body['redirect_uris'] as List?) ?? const [])
        .map((e) => e.toString().trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final info = <String, dynamic>{
      'client_id': cid,
      if (csec != null) 'client_secret': csec,
      'client_id_issued_at': _nowSec,
      'client_secret_expires_at': 0,
      'client_name': (body['client_name'] ?? 'MCP Dynamic Client').toString(),
      'redirect_uris': uris,
      'grant_types':
          body['grant_types'] ?? ['authorization_code', 'refresh_token'],
      'response_types': body['response_types'] ?? ['code'],
      'token_endpoint_auth_method': authMethod,
      'scope': (body['scope'] ?? 'mcp').toString(),
      'is_dynamic': true,
      if (targetProfileId != null && targetProfileId.isNotEmpty)
        'profile_id': targetProfileId,
    };
    _clients[cid] = info;
    _saveState();
    McpLogger.instance.info(
      '[OAUTH REGISTER] client_id=$cid auth=$authMethod name=${info['client_name']}',
    );
    StructuredEventBus.instance.emit({
      'kind': 'oauth',
      'badge': '注册',
      'level': 'INFO',
      'summary': 'OAuth 动态注册客户端: ${info['client_name']} ($cid)',
    });
    return _jsonResp(201, info);
  }

  Future<Response> _handleAuthorize(
    Request request,
    String base, {
    String? targetProfileId,
  }) async {
    final q = request.url.queryParameters;
    final clientId = (q['client_id'] ?? '').trim();
    final redirectUri = (q['redirect_uri'] ?? '').trim();
    final state = q['state'] ?? '';
    final codeChallenge = q['code_challenge'] ?? '';
    final codeChallengeMethod = q['code_challenge_method'] ?? 'S256';
    final scopeRaw = (q['scope'] ?? 'mcp').trim();
    final scopes = scopeRaw.isEmpty
        ? <String>['mcp']
        : scopeRaw.split(RegExp(r'\s+'));

    var client = _clients[clientId];
    if (client == null && clientId.isNotEmpty) {
      // Auto-accept unknown public/PKCE clients when redirect_uri is provided
      client = {
        'client_id': clientId,
        'client_name': clientId,
        'redirect_uris': [if (redirectUri.isNotEmpty) redirectUri],
        'is_dynamic': true,
        if (targetProfileId != null && targetProfileId.isNotEmpty)
          'profile_id': targetProfileId,
      };
      _clients[clientId] = client;
      _saveState();
    } else if (client != null &&
        targetProfileId != null &&
        targetProfileId.isNotEmpty &&
        (client['profile_id'] ?? '').toString().isEmpty) {
      client['profile_id'] = targetProfileId;
    }

    if (client == null || redirectUri.isEmpty) {
      return _htmlResp(
        400,
        '<h3>OAuth 授权请求缺少 client_id 或 redirect_uri 参数。</h3>',
      );
    }

    final allowedUris = ((client['redirect_uris'] as List?) ?? const [])
        .map((e) => e.toString().trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (!isRedirectUriAllowed(allowedUris, redirectUri)) {
      return _htmlResp(
        400,
        '<h3>回调地址 (Redirect URI) 不匹配</h3>'
        '<p>客户端 <code>${_esc(clientId)}</code> 请求的回调地址为：<br><code>${_esc(redirectUri)}</code></p>'
        '<p>当前白名单配置为：<br><code>${_esc(allowedUris.join(', '))}</code></p>'
        '<p>请在 Agent MCP 控制台「服务配置 -> 对应入口编辑 -> 允许的回调 URI」中添加上述地址（或留空以允许动态匹配）。</p>',
      );
    }

    final resolvedProfileId =
        targetProfileId ?? client['profile_id']?.toString();
    final reqId = randomTokenUrlSafe(24);
    _pending[reqId] = _PendingAuthReq(
      client: client,
      redirectUri: redirectUri,
      state: state,
      codeChallenge: codeChallenge,
      codeChallengeMethod: codeChallengeMethod,
      scopes: scopes,
      profileId: resolvedProfileId,
      expiresAtSec: _nowSec + 600,
    );
    McpLogger.instance.info(
      '[OAUTH AUTHORIZE] client_id=$clientId redirect_uri=$redirectUri',
    );
    return Response.found('$base/local-login?req=$reqId');
  }

  Future<Response> _handleLocalLogin(Request request) async {
    final reqId = request.url.queryParameters['req'] ?? '';
    final entry = _pending[reqId];
    if (entry == null || entry.expiresAtSec < _nowSec) {
      _pending.remove(reqId);
      return _htmlResp(
        400,
        '<h3>该授权会话已过期或已完成，请回到 MCP 客户端重新发起连接。</h3>',
      );
    }

    // Always pull latest password hash from disk so newly saved passwords
    // in the desktop/web console take effect immediately without restart.
    _reloadPasswordHashFromDisk();

    var errorMsg = '';
    if (passwordHash.isEmpty) {
      errorMsg =
          '<p style="color:#b45309;background:#fef3c7;padding:11px 14px;border-radius:14px;font-size:13px">'
          '尚未设置「OAuth 本地授权密码」。请先打开 Agent MCP 控制台「服务配置 &rarr; OAuth 2.1 本地密码」设置并保存后，直接在此输入即可（无需重启）。</p>';
    }

    if (request.method == 'POST') {
      final formBody = await request.readAsString();
      final form = Uri.splitQueryString(formBody);
      final pwd = form['password'] ?? '';
      if (passwordHash.isEmpty) {
        errorMsg =
            '<p style="color:#dc2626;font-size:13.5px">控制台尚未配置 OAuth 本地密码，请先在「服务配置」页面保存密码后再试。</p>';
      } else if (verifyPassword(pwd, passwordHash)) {
        _pending.remove(reqId);
        final codeStr = randomTokenUrlSafe(32);
        final cid = (entry.client['client_id'] ?? 'local-client').toString();
        _codes[codeStr] = _AuthCodeRecord(
          code: codeStr,
          clientId: cid,
          redirectUri: entry.redirectUri,
          codeChallenge: entry.codeChallenge,
          codeChallengeMethod: entry.codeChallengeMethod,
          scopes: entry.scopes,
          profileId: entry.profileId,
          expiresAtSec: _nowSec + 300,
        );

        final target = Uri.parse(entry.redirectUri);
        final mergedQp = <String, String>{
          ...target.queryParameters,
          'code': codeStr,
          if (entry.state.isNotEmpty) 'state': entry.state,
        };
        final redirectTarget = target.replace(queryParameters: mergedQp);
        McpLogger.instance.info('[OAUTH LOGIN OK] client_id=$cid');
        StructuredEventBus.instance.emit({
          'kind': 'oauth',
          'badge': '已授权',
          'level': 'INFO',
          'summary': '本地 OAuth 授权通过: $cid',
        });
        return Response.found(redirectTarget.toString());
      } else {
        final cid = (entry.client['client_id'] ?? 'unknown').toString();
        McpLogger.instance
            .warning('[OAUTH LOGIN FAIL] wrong password for client_id=$cid');
        StructuredEventBus.instance.emit({
          'kind': 'err',
          'badge': '鉴权失败',
          'level': 'WARNING',
          'summary': 'OAuth 授权密码输入错误 ($cid)',
        });
        errorMsg = '<p style="color:#dc2626;font-size:13.5px">密码错误，请确认输入的是控制台设置的「OAuth 本地授权密码」。</p>';
      }
    }

    final cname = _esc(
      (entry.client['client_name'] ?? entry.client['client_id'] ?? 'MCP Client')
          .toString(),
    );
    final sname = _esc(serverName);
    final page = '''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>$sname - 授权确认</title>
<style>
:root{--bg:#FAFAFB;--card:#FFFFFF;--elev:#F4F4F6;--border:#E6E6EA;--ink:#111113;--muted:#71717A;--clay:#141416;--clay-h:#27272A;--on-clay:#FFFFFF;--clay-bg:rgba(20,20,22,.075);--dot:rgba(17,17,19,.05);--sh:inset 0 1px 0 rgba(255,255,255,.96),0 18px 42px -12px rgba(9,9,11,.09),0 2px 6px rgba(9,9,11,.035)}
@media (prefers-color-scheme: dark){:root{--bg:#0A0A0C;--card:#121216;--elev:#0E0E12;--border:#222228;--ink:#FAFAFA;--muted:#8E8E98;--clay:#F4F4F6;--clay-h:#FFFFFF;--on-clay:#0A0A0C;--clay-bg:rgba(244,244,246,.10);--dot:rgba(250,250,250,.04);--sh:inset 0 1px 0 rgba(255,255,255,.14),0 22px 48px -10px rgba(0,0,0,.72),0 2px 8px rgba(0,0,0,.44)}}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:18px;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Inter","PingFang SC","Microsoft YaHei UI",sans-serif;background-color:var(--bg);background-image:radial-gradient(560px 340px at 50% 25%,var(--clay-bg),transparent 70%),radial-gradient(circle,var(--dot) 1px,transparent 1px);background-size:100% 100%,22px 22px;color:var(--ink)}
.card{width:100%;max-width:404px;background:var(--card);border:1px solid var(--border);border-radius:28px;padding:28px 26px;box-shadow:var(--sh);animation:rise .22s cubic-bezier(.16,1,.3,1) both}
.head-row{display:flex;align-items:center;gap:11px;margin-bottom:11px}
.ico{width:40px;height:40px;border-radius:13.5px;background:var(--clay-bg);color:var(--clay);display:inline-flex;align-items:center;justify-content:center;flex-shrink:0}
.client-pill{display:inline-block;padding:2.5px 10px;border-radius:999px;background:var(--elev);border:1px solid var(--border);font-family:ui-monospace,Consolas,monospace;font-size:12px;color:var(--ink)}
.pw-box{position:relative;margin:10px 0 15px}
input{width:100%;padding:11px 40px 11px 14px;background:var(--elev);color:var(--ink);border:1px solid var(--border);border-radius:14px;font-size:14px;outline:none;transition:border-color .15s}
input:focus{border-color:var(--clay)}
.eye{position:absolute;right:10px;top:50%;transform:translateY(-50%);border:0;background:transparent;color:var(--muted);cursor:pointer;padding:4px;display:inline-flex}
.eye:hover{color:var(--ink)}
.submit{width:100%;padding:11px 18px;background:var(--clay);color:var(--on-clay);border:0;border-radius:999px;font-size:13.8px;font-weight:600;cursor:pointer;display:inline-flex;align-items:center;justify-content:center;gap:7px;transition:background .15s}
.submit:hover{background:var(--clay-h)}
.spin{width:13px;height:13px;border-radius:99px;border:2px solid rgba(128,128,136,.35);border-top-color:var(--on-clay);display:none;animation:sp .75s linear infinite}
@keyframes sp{to{transform:rotate(360deg)}}
@keyframes rise{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:translateY(0)}}
</style>
</head><body><div class="card">
<div class="head-row"><span class="ico"><svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg></span><h2 style="margin:0;font-size:17px;font-weight:600">$sname 授权确认</h2></div>
<p style="margin:0 0 14px;color:var(--muted);font-size:13.2px;line-height:1.58">客户端 <span class="client-pill">$cname</span> 请求接入你的本地 MCP 控制节点。</p>
$errorMsg
<form method="post" onsubmit="document.getElementById('authSpin').style.display='inline-block'">
<label style="font-size:12.5px;color:var(--muted);font-weight:500">本地 OAuth 2.1 授权密码</label>
<div class="pw-box">
<input id="pwd" type="password" name="password" autofocus required />
<button type="button" class="eye" onclick="const i=document.getElementById('pwd');i.type=i.type==='password'?'text':'password'" title="显示 / 隐藏密码">
<svg width="16" height="16" viewBox="0 0 20 20" fill="none"><path d="M2 10s3-5.5 8-5.5S18 10 18 10s-3 5.5-8 5.5S2 10 2 10z" stroke="currentColor" stroke-width="1.5"/><circle cx="10" cy="10" r="2.3" stroke="currentColor" stroke-width="1.5"/></svg>
</button>
</div>
<button class="submit" type="submit"><span class="spin" id="authSpin"></span><span>确认并授权连接</span></button>
</form></div></body></html>''';
    return _htmlResp(200, page);
  }

  Future<Response> _handleToken(
    Request request, {
    String? targetProfileId,
  }) async {
    final ctype = (request.headers['content-type'] ?? '').toLowerCase();
    final rawBody = await request.readAsString();
    Map<String, String> params = {};
    if (ctype.contains('application/json')) {
      try {
        final d = jsonDecode(rawBody);
        if (d is Map) {
          params = d.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
        }
      } catch (_) {}
    } else {
      params = Uri.splitQueryString(rawBody);
    }

    // Parse client credentials from HTTP Basic header per RFC 6749 §2.3.1
    // (form-urlencoded prior to base64: '+' represents space)
    var clientId = (params['client_id'] ?? '').trim();
    var clientSecret = (params['client_secret'] ?? '').trim();
    final authHdr = request.headers['authorization'] ?? '';
    if (authHdr.toLowerCase().startsWith('basic ')) {
      try {
        final decoded =
            utf8.decode(base64Decode(authHdr.substring(6).trim()));
        final colon = decoded.indexOf(':');
        if (colon != -1) {
          final basicId =
              _decodeFormComponentSafe(decoded.substring(0, colon)).trim();
          final basicSec =
              _decodeFormComponentSafe(decoded.substring(colon + 1)).trim();
          if (clientId.isEmpty) clientId = basicId;
          if (clientSecret.isEmpty) clientSecret = basicSec;
        }
      } catch (_) {}
    }

    final grantType = params['grant_type'] ?? '';
    if (grantType == 'authorization_code') {
      final codeStr = params['code'] ?? '';
      final codeRec = _codes.remove(codeStr);
      if (codeRec == null || codeRec.expiresAtSec < _nowSec) {
        return _jsonResp(400, {'error': 'invalid_grant'});
      }

      // Validate redirect_uri if sent on /token
      final tokenRedirect = (params['redirect_uri'] ?? '').trim();
      if (tokenRedirect.isNotEmpty &&
          codeRec.redirectUri.isNotEmpty &&
          normalizeOAuthRedirectUri(tokenRedirect) !=
              normalizeOAuthRedirectUri(codeRec.redirectUri)) {
        return _jsonResp(400, {
          'error': 'invalid_grant',
          'error_description': 'redirect_uri mismatch',
        });
      }

      // Verify PKCE first if code_challenge was supplied on /authorize
      var pkceVerified = false;
      if (codeRec.codeChallenge.isNotEmpty) {
        final verifier = params['code_verifier'] ?? '';
        if (verifier.isEmpty) {
          return _jsonResp(400, {
            'error': 'invalid_grant',
            'error_description': 'Missing code_verifier',
          });
        }
        final computed = codeRec.codeChallengeMethod.toUpperCase() == 'PLAIN'
            ? verifier
            : base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes)
                .replaceAll('=', '');
        if (!constantTimeEquals(computed, codeRec.codeChallenge)) {
          return _jsonResp(400, {
            'error': 'invalid_grant',
            'error_description': 'PKCE verification failed',
          });
        }
        pkceVerified = true;
      }

      final effectiveCid = clientId.isNotEmpty ? clientId : codeRec.clientId;
      final client = _clients[effectiveCid] ?? _clients[codeRec.clientId];
      final isStatic = client?['is_static'] == true;
      final expectedSec = (client?['client_secret'] ?? '').toString();

      if (isStatic && expectedSec.isNotEmpty) {
        // Static confidential client: if client_secret is provided, it must match;
        // if omitted, allow only when S256 PKCE verified possession of the auth code.
        if (clientSecret.isNotEmpty &&
            !constantTimeEquals(clientSecret, expectedSec)) {
          McpLogger.instance.warning(
            '[OAUTH TOKEN 401] Static client secret mismatch for $effectiveCid',
          );
          return _jsonResp(401, {'error': 'invalid_client'});
        }
        if (clientSecret.isEmpty && !pkceVerified) {
          McpLogger.instance.warning(
            '[OAUTH TOKEN 401] Missing client_secret and no PKCE for $effectiveCid',
          );
          return _jsonResp(401, {'error': 'invalid_client'});
        }
      } else if (!isStatic &&
          expectedSec.isNotEmpty &&
          clientSecret.isNotEmpty &&
          !constantTimeEquals(clientSecret, expectedSec) &&
          !pkceVerified) {
        return _jsonResp(401, {'error': 'invalid_client'});
      }

      final resolvedProfileId = codeRec.profileId ??
          client?['profile_id']?.toString() ??
          targetProfileId;
      return _issueTokenPair(
        effectiveCid,
        codeRec.scopes,
        profileId: resolvedProfileId,
      );
    }

    if (grantType == 'refresh_token') {
      final rtStr = params['refresh_token'] ?? '';
      final rt = _refreshTokens[rtStr];
      if (rt == null) {
        return _jsonResp(400, {'error': 'invalid_grant'});
      }
      final exp = int.tryParse('${rt['expires_at'] ?? 0}') ?? 0;
      if (exp > 0 && exp < _nowSec) {
        _refreshTokens.remove(rtStr);
        return _jsonResp(400, {'error': 'invalid_grant'});
      }

      // 60-second grace window so concurrent refresh calls from cloud MCP
      // clients never race and invalidate each other.
      final rotatedAt = int.tryParse('${rt['rotated_at'] ?? 0}') ?? 0;
      if (rotatedAt > 0) {
        if (_nowSec - rotatedAt <= 60 && rt['grace_payload'] is Map) {
          return _jsonResp(
            200,
            Map<String, dynamic>.from(rt['grace_payload'] as Map),
          );
        }
        _refreshTokens.remove(rtStr);
        return _jsonResp(400, {'error': 'invalid_grant'});
      }

      final effectiveCid = clientId.isNotEmpty
          ? clientId
          : (rt['client_id'] ?? 'local-client').toString();
      final scopes = ((rt['scopes'] as List?) ?? const ['mcp'])
          .map((e) => e.toString())
          .toList();
      final resolvedProfileId =
          rt['profile_id']?.toString() ?? targetProfileId;

      final payload = _createTokenPairPayload(
        effectiveCid,
        scopes,
        profileId: resolvedProfileId,
      );
      rt['rotated_at'] = _nowSec;
      rt['grace_payload'] = payload;
      _saveState();
      McpLogger.instance.info(
        '[OAUTH REFRESH] rotated access+refresh token for client_id=$effectiveCid',
      );
      return _jsonResp(200, payload);
    }

    return _jsonResp(400, {'error': 'unsupported_grant_type'});
  }

  Map<String, dynamic> _createTokenPairPayload(
    String clientId,
    List<String> scopes, {
    String? profileId,
  }) {
    final accessStr = randomTokenUrlSafe(32);
    final refreshStr = randomTokenUrlSafe(32);
    // 30-day access token + 90-day refresh token prevents mid-session drops
    const expiresIn = 3600 * 24 * 30;
    final finalScopes = scopes.isEmpty ? <String>['mcp'] : scopes;

    _accessTokens[accessStr] = {
      'token': accessStr,
      'client_id': clientId,
      'scopes': finalScopes,
      if (profileId != null && profileId.isNotEmpty) 'profile_id': profileId,
      'expires_at': _nowSec + expiresIn,
    };
    _refreshTokens[refreshStr] = {
      'token': refreshStr,
      'client_id': clientId,
      'scopes': finalScopes,
      if (profileId != null && profileId.isNotEmpty) 'profile_id': profileId,
      'expires_at': _nowSec + 3600 * 24 * 90,
    };
    return {
      'access_token': accessStr,
      'token_type': 'Bearer',
      'expires_in': expiresIn,
      'refresh_token': refreshStr,
      'scope': finalScopes.join(' '),
    };
  }

  Response _issueTokenPair(
    String clientId,
    List<String> scopes, {
    String? profileId,
  }) {
    final payload = _createTokenPairPayload(
      clientId,
      scopes,
      profileId: profileId,
    );
    _saveState();
    McpLogger.instance.info(
      '[OAUTH TOKEN] issued access+refresh token for client_id=$clientId',
    );
    return _jsonResp(200, payload);
  }

  Future<Response> _handleRevoke(Request request) async {
    final form = Uri.splitQueryString(await request.readAsString());
    final tok = form['token'] ?? '';
    if (tok.isNotEmpty) {
      _accessTokens.remove(tok);
      _refreshTokens.remove(tok);
      _saveState();
    }
    return _jsonResp(200, {'ok': true});
  }
}

/// Always returns a hot-reloadable [LocalOAuthProvider] instance so switching
/// any profile to `oauth-local` in the UI works immediately without restarting.
LocalOAuthProvider buildOAuthProvider(ServerConfig config) {
  final enabledProfiles =
      config.profiles.where((p) => p['enabled'] != false).toList();
  final oauthLocalProfiles =
      enabledProfiles.where((p) => p['auth_mode'] == 'oauth-local').toList();

  final primaryBase = (oauthLocalProfiles.isNotEmpty
          ? oauthLocalProfiles.first['base_url']?.toString()
          : null) ??
      config.oauthBaseUrl ??
      'http://${config.host}:${config.port}';

  final hash = config.oauthLocalPasswordHash ?? '';
  final extraClients = oauthLocalProfiles
      .where((p) =>
          (p['oauth_client_id'] ?? '').toString().isNotEmpty &&
          (p['oauth_client_secret'] ?? '').toString().isNotEmpty)
      .map((p) => <String, dynamic>{
            'client_id': p['oauth_client_id'],
            'client_secret': p['oauth_client_secret'],
            'redirect_uris': p['oauth_redirect_uris'] ?? const [],
            'client_name': p['name'] ?? 'OAuth Profile',
            'profile_id': p['id'],
          })
      .toList();

  return LocalOAuthProvider(
    primaryBaseUrl: primaryBase,
    passwordHash: hash,
    serverName: config.serverName,
    stateFile: StoragePaths.instance.oauthStateFile,
    configFile: config.configFile,
    staticClientId: config.oauthClientId,
    staticClientSecret: config.oauthClientSecret,
    staticRedirectUris: config.oauthRedirectUris,
    extraStaticClients: extraClients,
  );
}

String _esc(String s) => const HtmlEscape().convert(s);

Response _jsonResp(int status, Map<String, dynamic> body) {
  return Response(
    status,
    body: jsonEncode(body),
    headers: const {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  );
}

Response _htmlResp(int status, String htmlBody) {
  return Response(
    status,
    body: htmlBody,
    headers: const {'content-type': 'text/html; charset=utf-8'},
  );
}
