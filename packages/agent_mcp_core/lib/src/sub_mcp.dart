import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'auth.dart';
import 'config.dart';
import 'encoding_utils.dart';
import 'logging_utils.dart';
import 'process_tools.dart';
import 'tool_types.dart';
import 'version.dart';

final RegExp _subNameRe = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$');
final RegExp _envPlaceholderRe =
    RegExp(r'\$\{(?:ENV:)?([A-Za-z_][A-Za-z0-9_]*)\}');

String sanitizeSubName(String raw) {
  final cleaned = raw
      .trim()
      .replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '-')
      .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
  return cleaned.length > 64 ? cleaned.substring(0, 64) : cleaned;
}

/// Expands `${ENV:VAR_NAME}` or `${VAR_NAME}` placeholders from `Platform.environment`
/// at runtime so secrets never have to be hardcoded in plain text inside JSON configs.
String interpolateEnvPlaceholders(String raw) {
  if (!raw.contains(r'${')) return raw;
  return raw.replaceAllMapped(_envPlaceholderRe, (m) {
    final key = m.group(1)!;
    return Platform.environment[key] ?? '';
  });
}

Map<String, String> _interpolateStringMap(Map<String, String> src) {
  final out = <String, String>{};
  for (final e in src.entries) {
    out[e.key] = interpolateEnvPlaceholders(e.value);
  }
  return out;
}

List<String> _splitCommandLineTokens(String line) {
  final tokens = <String>[];
  final buf = StringBuffer();
  String? quote;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (quote != null) {
      if (ch == quote) {
        quote = null;
      } else {
        buf.write(ch);
      }
    } else if (ch == '"' || ch == "'") {
      quote = ch;
    } else if (ch == ' ' || ch == '\t') {
      if (buf.isNotEmpty) {
        tokens.add(buf.toString());
        buf.clear();
      }
    } else {
      buf.write(ch);
    }
  }
  if (buf.isNotEmpty) tokens.add(buf.toString());
  return tokens;
}

const Set<String> kValidSubTransports = {'stdio', 'auto', 'http', 'sse', 'ws'};
const Set<String> kValidSubAuthTypes = {
  'none',
  'bearer',
  'api_key',
  'basic',
  'oauth2_pkce',
  'oauth2_client_credentials',
};

Map<String, dynamic> normalizeSubEntry(Map<String, dynamic> raw) {
  final name = sanitizeSubName((raw['name'] ?? '').toString());
  if (name.isEmpty || !_subNameRe.hasMatch(name)) {
    throw const FormatException(
      '子 MCP 名称不能为空，仅支持字母、数字、点、下划线和短横线。',
    );
  }

  var transport =
      (raw['transport'] ?? raw['type'] ?? '').toString().trim().toLowerCase();
  final command = (raw['command'] ?? '').toString().trim();
  final url = (raw['url'] ?? raw['serverUrl'] ?? '').toString().trim();

  if (transport == 'streamable-http' || transport == 'streamable_http') {
    transport = 'http';
  } else if (transport == 'websocket') {
    transport = 'ws';
  }
  if (transport.isEmpty) {
    if (command.isNotEmpty) {
      transport = 'stdio';
    } else if (url.startsWith('ws://') || url.startsWith('wss://')) {
      transport = 'ws';
    } else if (url.replaceAll(RegExp(r'/+$'), '').endsWith('/sse')) {
      transport = 'sse';
    } else {
      transport = 'http';
    }
  }
  if (!kValidSubTransports.contains(transport)) {
    throw FormatException(
      '不支持的传输协议: $transport（支持 auto / stdio / http / sse / ws）',
    );
  }
  if (transport == 'stdio' && command.isEmpty) {
    throw const FormatException('stdio 模式必须填写启动命令 (command)。');
  }
  if (transport != 'stdio' && url.isEmpty) {
    throw FormatException('$transport 模式必须填写服务地址 (url)。');
  }

  final rawArgs = raw['args'];
  final List<String> args;
  if (rawArgs is String) {
    args = rawArgs
        .split(RegExp(r'\r?\n'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  } else if (rawArgs is List) {
    args = rawArgs
        .map((e) => e.toString())
        .where((s) => s.trim().isNotEmpty)
        .toList();
  } else {
    args = <String>[];
  }

  Map<String, String> parseStringMap(dynamic src) {
    if (src is! Map) return <String, String>{};
    final out = <String, String>{};
    for (final e in src.entries) {
      final k = e.key.toString().trim();
      if (k.isNotEmpty) out[k] = e.value.toString().trim();
    }
    return out;
  }

  var authType = (raw['auth_type'] ?? 'none').toString().trim().toLowerCase();
  if (!kValidSubAuthTypes.contains(authType)) {
    authType = 'none';
  }
  var apiKeyIn = (raw['api_key_in'] ?? 'header').toString().trim().toLowerCase();
  if (apiKeyIn != 'query') apiKeyIn = 'header';
  final apiKeyName = (raw['api_key_name'] ?? '').toString().trim();

  var exposeMode =
      (raw['expose_mode'] ?? 'gateway').toString().trim().toLowerCase();
  if (exposeMode != 'direct') exposeMode = 'gateway';

  final disabledTools = ((raw['disabled_tools'] as List?) ?? const [])
      .map((e) => e.toString().trim())
      .where((s) => s.isNotEmpty)
      .toSet()
      .toList();

  final timeout =
      (int.tryParse('${raw['timeout'] ?? 30}') ?? 30).clamp(3, 300);

  return <String, dynamic>{
    'name': name,
    'description': (raw['description'] ?? '').toString().trim(),
    'transport': transport,
    'enabled': raw['enabled'] == null ? true : raw['enabled'] == true,
    'expose_mode': exposeMode,
    'disabled_tools': disabledTools,
    'command': command,
    'args': args,
    'cwd': (raw['cwd'] ?? '').toString().trim(),
    'env': parseStringMap(raw['env']),
    'url': url,
    'headers': parseStringMap(raw['headers']),
    'auth_type': authType,
    if ((raw['auth_token'] ?? '').toString().trim().isNotEmpty)
      'auth_token': raw['auth_token'].toString().trim(),
    if ((raw['api_key'] ?? '').toString().trim().isNotEmpty)
      'api_key': raw['api_key'].toString().trim(),
    if (apiKeyName.isNotEmpty) 'api_key_name': apiKeyName,
    if (authType == 'api_key') 'api_key_in': apiKeyIn,
    if ((raw['basic_username'] ?? '').toString().trim().isNotEmpty)
      'basic_username': raw['basic_username'].toString().trim(),
    if ((raw['basic_password'] ?? '').toString().trim().isNotEmpty)
      'basic_password': raw['basic_password'].toString().trim(),
    if ((raw['oauth_client_id'] ?? '').toString().trim().isNotEmpty)
      'oauth_client_id': raw['oauth_client_id'].toString().trim(),
    if ((raw['oauth_client_secret'] ?? '').toString().trim().isNotEmpty)
      'oauth_client_secret': raw['oauth_client_secret'].toString().trim(),
    if ((raw['oauth_scopes'] ?? '').toString().trim().isNotEmpty)
      'oauth_scopes': raw['oauth_scopes'].toString().trim(),
    if ((raw['oauth_auth_url'] ?? '').toString().trim().isNotEmpty)
      'oauth_auth_url': raw['oauth_auth_url'].toString().trim(),
    if ((raw['oauth_token_url'] ?? '').toString().trim().isNotEmpty)
      'oauth_token_url': raw['oauth_token_url'].toString().trim(),
    if ((raw['oauth_cimd_url'] ?? '').toString().trim().isNotEmpty)
      'oauth_cimd_url': raw['oauth_cimd_url'].toString().trim(),
    if ((raw['proxy_url'] ?? '').toString().trim().isNotEmpty)
      'proxy_url': raw['proxy_url'].toString().trim(),
    if (raw['insecure_tls'] == true) 'insecure_tls': true,
    'timeout': timeout,
  };
}

/// Parses Claude Desktop / Cursor (`mcpServers`), VS Code (`.vscode/mcp.json` `servers`),
/// single-line `npx` / `uvx` / `python` CLI invocations, or direct HTTP/WS URLs!
List<Map<String, dynamic>> parseMcpServersJson(String rawText) {
  final trimmed = rawText.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('输入内容不能为空。');
  }

  // 1. Direct URL quick import
  if (RegExp(r'^(https?|wss?)://\S+$', caseSensitive: false).hasMatch(trimmed)) {
    final uri = Uri.parse(trimmed);
    final hostLabel = sanitizeSubName(
      uri.host.replaceAll(RegExp(r'^www\.'), '').split('.').first,
    );
    final isWs = uri.scheme == 'ws' || uri.scheme == 'wss';
    return [
      normalizeSubEntry({
        'name': hostLabel.isEmpty ? 'remote-mcp' : hostLabel,
        'transport': isWs ? 'ws' : 'auto',
        'url': trimmed,
      }),
    ];
  }

  // 2. Single-line CLI command quick import (e.g. `npx -y @modelcontextprotocol/server-memory`)
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) {
    final tokens = _splitCommandLineTokens(trimmed);
    if (tokens.isNotEmpty) {
      final cmd = tokens.first;
      final args = tokens.sublist(1);
      var guessed = 'cli-mcp';
      for (final a in args.reversed) {
        if (!a.startsWith('-')) {
          final clean = a.split('/').last.replaceFirst(RegExp(r'^server-'), '');
          final cand = sanitizeSubName(clean);
          if (cand.isNotEmpty) {
            guessed = cand;
            break;
          }
        }
      }
      return [
        normalizeSubEntry({
          'name': guessed,
          'transport': 'stdio',
          'command': cmd,
          'args': args,
        }),
      ];
    }
  }

  final dynamic data;
  try {
    data = jsonDecode(trimmed);
  } on FormatException catch (e) {
    throw FormatException('JSON 格式无效: ${e.message}');
  }

  if (data is List) {
    return data
        .whereType<Map>()
        .map((m) => normalizeSubEntry(Map<String, dynamic>.from(m)))
        .toList();
  }
  if (data is! Map) {
    throw const FormatException('顶层必须是 JSON 对象、数组、URL 或命令行。');
  }

  final serversObj = data['mcpServers'] is Map
      ? Map<String, dynamic>.from(data['mcpServers'] as Map)
      : (data['servers'] is Map
          ? Map<String, dynamic>.from(data['servers'] as Map)
          : Map<String, dynamic>.from(data));
  if (serversObj.isEmpty) {
    throw const FormatException('未找到有效的 mcpServers / servers 配置项。');
  }

  if (serversObj.containsKey('command') ||
      serversObj.containsKey('url') ||
      serversObj.containsKey('serverUrl')) {
    final single = Map<String, dynamic>.from(serversObj);
    single.putIfAbsent('name', () => 'sub-mcp');
    return [normalizeSubEntry(single)];
  }

  final entries = <Map<String, dynamic>>[];
  for (final e in serversObj.entries) {
    if (e.value is! Map) continue;
    final item = Map<String, dynamic>.from(e.value as Map);
    item.putIfAbsent('name', () => e.key);
    entries.add(normalizeSubEntry(item));
  }
  if (entries.isEmpty) {
    throw const FormatException('未解析出任何有效的子 MCP 配置。');
  }
  return entries;
}

Map<String, dynamic> _mcpInitParams([String protocolVersion = '2025-11-25']) =>
    {
      'protocolVersion': protocolVersion,
      'capabilities': const <String, dynamic>{},
      'clientInfo': {
        'name': 'agent-mcp-gateway',
        'title': 'Agent MCP Gateway',
        'version': agentMcpVersion,
        'icons': buildMcpServerIcons(),
      },
    };

List<Map<String, dynamic>> _sanitizeUpstreamIcons(dynamic rawIcons) {
  if (rawIcons is! List) return const <Map<String, dynamic>>[];
  final out = <Map<String, dynamic>>[];
  for (final item in rawIcons) {
    if (item is! Map) continue;
    final src = (item['src'] ?? '').toString().trim();
    if (src.isEmpty) continue;
    final lower = src.toLowerCase();
    final safeScheme = lower.startsWith('https://') ||
        lower.startsWith('http://') ||
        lower.startsWith('data:image/');
    if (!safeScheme) continue;
    out.add(<String, dynamic>{
      'src': src,
      if (item['mimeType'] != null) 'mimeType': item['mimeType'].toString(),
      if (item['sizes'] is List)
        'sizes': (item['sizes'] as List).map((e) => e.toString()).toList(),
      if (item['theme'] != null) 'theme': item['theme'].toString(),
    });
  }
  return out;
}

String? _pickSafeUpstreamIconSrc(Map<String, dynamic> initRes) {
  Map? info = initRes['serverInfo'] as Map?;
  if (info == null) {
    final meta = initRes['_meta'];
    if (meta is Map && meta['io.modelcontextprotocol/serverInfo'] is Map) {
      info = meta['io.modelcontextprotocol/serverInfo'] as Map;
    }
  }
  if (info == null) return null;
  final icons = _sanitizeUpstreamIcons(info['icons']);
  if (icons.isEmpty) return null;
  // Prefer raster PNG/WebP/JPEG first for crisp cross-platform rendering, then SVG
  for (final ic in icons) {
    final mime = (ic['mimeType'] ?? '').toString().toLowerCase();
    final src = (ic['src'] ?? '').toString();
    if (mime.contains('png') ||
        mime.contains('webp') ||
        src.toLowerCase().startsWith('data:image/png')) {
      return src;
    }
  }
  return (icons.first['src'] ?? '').toString();
}

List<Map<String, dynamic>> _extractMcpTools(Map<String, dynamic> res) {
  final raw = (res['tools'] as List?) ?? const [];
  return raw.whereType<Map>().map((t) {
    final icons = _sanitizeUpstreamIcons(t['icons']);
    return <String, dynamic>{
      'name': (t['name'] ?? '').toString(),
      if (t['title'] != null) 'title': t['title'].toString(),
      'description': (t['description'] ?? '').toString(),
      'inputSchema': t['inputSchema'] ??
          t['input_schema'] ??
          const {'type': 'object', 'properties': <String, dynamic>{}},
      if (t['annotations'] != null) 'annotations': t['annotations'],
      if (icons.isNotEmpty) 'icons': icons,
    };
  }).toList();
}

List<Map<String, dynamic>> _extractMcpResources(Map<String, dynamic> res) {
  final raw = (res['resources'] as List?) ?? const [];
  return raw.whereType<Map>().map((r) {
    return <String, dynamic>{
      'uri': (r['uri'] ?? '').toString(),
      'name': (r['name'] ?? '').toString(),
      if (r['description'] != null) 'description': r['description'].toString(),
      if (r['mimeType'] != null) 'mimeType': r['mimeType'].toString(),
    };
  }).toList();
}

List<Map<String, dynamic>> _extractMcpPrompts(Map<String, dynamic> res) {
  final raw = (res['prompts'] as List?) ?? const [];
  return raw.whereType<Map>().map((p) {
    return <String, dynamic>{
      'name': (p['name'] ?? '').toString(),
      if (p['description'] != null) 'description': p['description'].toString(),
      if (p['arguments'] is List) 'arguments': p['arguments'],
    };
  }).toList();
}

HttpClient _buildConfiguredHttpClient(Map<String, dynamic> entry) {
  final hc = HttpClient();
  if (entry['insecure_tls'] == true) {
    hc.badCertificateCallback = (_, __, ___) => true;
  }
  final proxyRaw = interpolateEnvPlaceholders(
    (entry['proxy_url'] ?? '').toString().trim(),
  );
  if (proxyRaw.isNotEmpty) {
    final pUri = Uri.tryParse(
      proxyRaw.contains('://') ? proxyRaw : 'http://$proxyRaw',
    );
    if (pUri != null && pUri.host.isNotEmpty) {
      final hp = '${pUri.host}:${pUri.hasPort ? pUri.port : 8080}';
      final directive = pUri.scheme.toLowerCase().startsWith('socks')
          ? 'SOCKS5 $hp; DIRECT'
          : 'PROXY $hp; DIRECT';
      hc.findProxy = (_) => directive;
    }
  }
  return hc;
}

http.Client _buildPkgHttpClient(Map<String, dynamic> entry) =>
    IOClient(_buildConfiguredHttpClient(entry));

Future<Process> _spawnStdioProcess(Map<String, dynamic> entry) async {
  final cmd = interpolateEnvPlaceholders((entry['command'] ?? '').toString());
  final args = ((entry['args'] as List?) ?? const [])
      .map((e) => interpolateEnvPlaceholders(e.toString()))
      .toList();
  final cwd = interpolateEnvPlaceholders((entry['cwd'] ?? '').toString().trim());
  final env = Map<String, String>.from(Platform.environment)
    ..addAll(
      _interpolateStringMap(
        Map<String, String>.from((entry['env'] as Map?) ?? const {}),
      ),
    );

  final Process proc;
  if (Platform.isWindows &&
      !cmd.toLowerCase().endsWith('.exe') &&
      !File(cmd).existsSync()) {
    proc = await Process.start(
      'cmd.exe',
      ['/c', cmd, ...args],
      workingDirectory: cwd.isEmpty ? null : cwd,
      environment: env,
    );
  } else {
    proc = await Process.start(
      cmd,
      args,
      workingDirectory: cwd.isEmpty ? null : cwd,
      environment: env,
    );
  }
  Win32ProcessJobGuard.instance.attachPid(proc.pid);
  return proc;
}

/// Persistent OAuth 2.1 Client & Token Store for remote HTTP/SSE/WS Sub-MCPs.
/// Supports RFC 9728 Protected Resource Metadata, RFC 8414 / OIDC discovery,
/// CIMD & RFC 7591 Dynamic Client Registration, S256 PKCE loopback auth,
/// `resource` audience indicators, `iss` verification, and silent refresh!
class SubMcpOAuthClientManager {
  final File? _customStoreFile;
  final Map<String, ({HttpServer server, Timer timer})> _activeLoopbacks = {};

  SubMcpOAuthClientManager([this._customStoreFile]);

  File get storeFile =>
      _customStoreFile ?? StoragePaths.instance.subMcpTokensFile;

  Map<String, Map<String, dynamic>> _loadStore() {
    if (!storeFile.existsSync()) return <String, Map<String, dynamic>>{};
    try {
      final raw = jsonDecode(storeFile.readAsStringSync());
      if (raw is Map) {
        final out = <String, Map<String, dynamic>>{};
        for (final e in raw.entries) {
          if (e.value is Map) {
            out[e.key.toString()] = Map<String, dynamic>.from(e.value as Map);
          }
        }
        return out;
      }
    } catch (_) {}
    return <String, Map<String, dynamic>>{};
  }

  void _saveStore(Map<String, Map<String, dynamic>> data) {
    storeFile.parent.createSync(recursive: true);
    const enc = JsonEncoder.withIndent('  ');
    storeFile.writeAsStringSync('${enc.convert(data)}\n', flush: true);
    if (!Platform.isWindows) {
      try {
        Process.runSync('chmod', ['600', storeFile.path]);
      } catch (_) {}
    }
  }

  Map<String, dynamic>? getRecord(String serverName) => _loadStore()[serverName];

  void saveRecord(String serverName, Map<String, dynamic> record) {
    final all = _loadStore();
    all[serverName] = record;
    _saveStore(all);
  }

  bool deleteRecord(String serverName) {
    final all = _loadStore();
    final removed = all.remove(serverName) != null;
    if (removed) _saveStore(all);
    return removed;
  }

  Map<String, dynamic> publicStatus(Map<String, dynamic> entry) {
    final authType = (entry['auth_type'] ?? 'none').toString();
    final name = (entry['name'] ?? '').toString();
    if (authType != 'oauth2_pkce' && authType != 'oauth2_client_credentials') {
      return {'enabled': false, 'auth_type': authType};
    }
    final rec = getRecord(name);
    if (rec == null || (rec['access_token'] ?? '').toString().isEmpty) {
      return {
        'enabled': true,
        'auth_type': authType,
        'authorized': false,
        'pending_loopback': _activeLoopbacks.containsKey(name),
      };
    }
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expSec = int.tryParse('${rec['expires_at'] ?? 0}') ?? 0;
    final expired = expSec > 0 && nowSec >= expSec;
    final hasRefresh = (rec['refresh_token'] ?? '').toString().isNotEmpty;
    return {
      'enabled': true,
      'auth_type': authType,
      'authorized': !expired || hasRefresh,
      'expired': expired,
      'has_refresh_token': hasRefresh,
      'expires_at': expSec > 0 ? expSec : null,
      'scope': rec['scope'] ?? '',
      'issuer': rec['issuer'] ?? '',
      'pending_loopback': _activeLoopbacks.containsKey(name),
    };
  }

  static Map<String, String> _parseWwwAuthenticateParams(String? header) {
    if (header == null || header.trim().isEmpty) return const {};
    final out = <String, String>{};
    final re = RegExp(r'([a-zA-Z0-9_-]+)\s*=\s*"([^"]*)"');
    for (final m in re.allMatches(header)) {
      out[m.group(1)!.toLowerCase()] = m.group(2)!;
    }
    return out;
  }

  Future<Map<String, dynamic>> discoverMetadata(
    Map<String, dynamic> entry,
  ) async {
    final rawUrl = interpolateEnvPlaceholders((entry['url'] ?? '').toString().trim());
    final mcpUri = Uri.parse(rawUrl);
    final origin =
        '${mcpUri.scheme}://${mcpUri.host}${mcpUri.hasPort ? ":${mcpUri.port}" : ""}';

    final manualAuth = interpolateEnvPlaceholders(
      (entry['oauth_auth_url'] ?? '').toString().trim(),
    );
    final manualToken = interpolateEnvPlaceholders(
      (entry['oauth_token_url'] ?? '').toString().trim(),
    );
    if (manualAuth.isNotEmpty && manualToken.isNotEmpty) {
      return {
        'resource': rawUrl,
        'issuer': origin,
        'authorization_endpoint': manualAuth,
        'token_endpoint': manualToken,
        'code_challenge_methods_supported': const ['S256'],
      };
    }

    final client = _buildPkgHttpClient(entry);
    try {
      String? prmUrl;
      String? challengeScope;
      // Step 1: Probe MCP URL for 401 WWW-Authenticate `resource_metadata` (RFC 9728)
      try {
        final probeResp = await client.post(
          mcpUri,
          headers: const {
            'Content-Type': 'application/json',
            'Accept': 'application/json, text/event-stream',
          },
          body: jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'initialize',
            'params': _mcpInitParams(),
          }),
        ).timeout(const Duration(seconds: 8));
        if (probeResp.statusCode == 401 || probeResp.statusCode == 403) {
          final www = probeResp.headers['www-authenticate'];
          final params = _parseWwwAuthenticateParams(www);
          prmUrl = params['resource_metadata'];
          challengeScope = params['scope'];
        }
      } catch (_) {}

      // Step 2: Fetch Protected Resource Metadata (`/.well-known/oauth-protected-resource`)
      Map<String, dynamic>? prm;
      final pathSuffix = mcpUri.path == '/' ? '' : mcpUri.path;
      final prmCandidates = <String>[
        if (prmUrl != null && prmUrl.isNotEmpty) prmUrl,
        if (pathSuffix.isNotEmpty)
          '$origin/.well-known/oauth-protected-resource$pathSuffix',
        '$origin/.well-known/oauth-protected-resource',
      ];
      for (final u in prmCandidates) {
        try {
          final r = await client
              .get(Uri.parse(u), headers: const {'Accept': 'application/json'})
              .timeout(const Duration(seconds: 6));
          if (r.statusCode == 200) {
            final d = jsonDecode(utf8.decode(r.bodyBytes));
            if (d is Map) {
              prm = Map<String, dynamic>.from(d);
              break;
            }
          }
        } catch (_) {}
      }

      final resourceUri = (prm?['resource'] ?? rawUrl).toString();
      final authServers = ((prm?['authorization_servers'] as List?) ?? const [])
          .map((e) => e.toString().trim().replaceAll(RegExp(r'/+$'), ''))
          .where((s) => s.isNotEmpty)
          .toList();
      final issuerBase = authServers.isNotEmpty ? authServers.first : origin;
      final issuerUri = Uri.parse(issuerBase);
      final issuerOrigin =
          '${issuerUri.scheme}://${issuerUri.host}${issuerUri.hasPort ? ":${issuerUri.port}" : ""}';
      final issuerPath = issuerUri.path == '/'
          ? ''
          : issuerUri.path.replaceAll(RegExp(r'/+$'), '');

      // Step 3: Fetch Authorization Server Metadata (RFC 8414 + OIDC Discovery 1.0)
      final asCandidates = <String>[
        if (issuerPath.isNotEmpty)
          '$issuerOrigin/.well-known/oauth-authorization-server$issuerPath',
        '$issuerOrigin/.well-known/oauth-authorization-server',
        if (issuerPath.isNotEmpty)
          '$issuerOrigin$issuerPath/.well-known/openid-configuration',
        '$issuerOrigin/.well-known/openid-configuration',
      ];
      Map<String, dynamic>? asMeta;
      for (final u in asCandidates) {
        try {
          final r = await client
              .get(Uri.parse(u), headers: const {'Accept': 'application/json'})
              .timeout(const Duration(seconds: 6));
          if (r.statusCode == 200) {
            final d = jsonDecode(utf8.decode(r.bodyBytes));
            if (d is Map && d['token_endpoint'] != null) {
              asMeta = Map<String, dynamic>.from(d);
              break;
            }
          }
        } catch (_) {}
      }

      asMeta ??= {
        'issuer': issuerBase,
        'authorization_endpoint':
            manualAuth.isNotEmpty ? manualAuth : '$issuerBase/authorize',
        'token_endpoint':
            manualToken.isNotEmpty ? manualToken : '$issuerBase/token',
        'registration_endpoint': '$issuerBase/register',
        'code_challenge_methods_supported': const ['S256'],
      };

      return {
        ...asMeta,
        'resource': resourceUri,
        'issuer': (asMeta['issuer'] ?? issuerBase).toString(),
        if (challengeScope != null && challengeScope.isNotEmpty)
          'challenge_scope': challengeScope,
        if (prm?['scopes_supported'] is List)
          'resource_scopes': prm!['scopes_supported'],
      };
    } finally {
      client.close();
    }
  }

  /// Resolves a valid `Authorization` or API-key header/query for [entry],
  /// transparently refreshing expired OAuth 2.1 tokens or fetching M2M tokens.
  Future<({Map<String, String> headers, Map<String, String> queryParams})>
      resolveRequestAuth(
    Map<String, dynamic> entry, {
    bool forceRefresh = false,
  }) async {
    final authType = (entry['auth_type'] ?? 'none').toString();
    if (authType == 'none') {
      return (headers: const <String, String>{}, queryParams: const <String, String>{});
    }
    if (authType == 'bearer') {
      final tok = interpolateEnvPlaceholders((entry['auth_token'] ?? '').toString().trim());
      if (tok.isEmpty) {
        return (headers: const <String, String>{}, queryParams: const <String, String>{});
      }
      return (
        headers: {'Authorization': 'Bearer $tok'},
        queryParams: const <String, String>{},
      );
    }
    if (authType == 'api_key') {
      final keyVal = interpolateEnvPlaceholders((entry['api_key'] ?? '').toString().trim());
      if (keyVal.isEmpty) {
        return (headers: const <String, String>{}, queryParams: const <String, String>{});
      }
      final keyName = (entry['api_key_name'] ?? 'X-API-Key').toString().trim();
      final loc = (entry['api_key_in'] ?? 'header').toString();
      if (loc == 'query') {
        return (headers: const <String, String>{}, queryParams: {keyName: keyVal});
      }
      return (headers: {keyName: keyVal}, queryParams: const <String, String>{});
    }
    if (authType == 'basic') {
      final user = interpolateEnvPlaceholders((entry['basic_username'] ?? '').toString());
      final pass = interpolateEnvPlaceholders((entry['basic_password'] ?? '').toString());
      final b64 = base64Encode(utf8.encode('$user:$pass'));
      return (
        headers: {'Authorization': 'Basic $b64'},
        queryParams: const <String, String>{},
      );
    }
    if (authType == 'oauth2_client_credentials') {
      final token = await _acquireClientCredentialsToken(
        entry,
        forceRefresh: forceRefresh,
      );
      return (
        headers: {'Authorization': 'Bearer $token'},
        queryParams: const <String, String>{},
      );
    }
    if (authType == 'oauth2_pkce') {
      final token = await _getValidPkceAccessToken(
        entry,
        forceRefresh: forceRefresh,
      );
      return (
        headers: {'Authorization': 'Bearer $token'},
        queryParams: const <String, String>{},
      );
    }
    return (headers: const <String, String>{}, queryParams: const <String, String>{});
  }

  Future<String> _acquireClientCredentialsToken(
    Map<String, dynamic> entry, {
    bool forceRefresh = false,
  }) async {
    final name = (entry['name'] ?? '').toString();
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final rec = getRecord(name);
    if (!forceRefresh && rec != null) {
      final tok = (rec['access_token'] ?? '').toString();
      final exp = int.tryParse('${rec['expires_at'] ?? 0}') ?? 0;
      if (tok.isNotEmpty && (exp == 0 || nowSec + 30 < exp)) {
        return tok;
      }
    }

    final cid = interpolateEnvPlaceholders(
      (entry['oauth_client_id'] ?? '').toString().trim(),
    );
    final csec = interpolateEnvPlaceholders(
      (entry['oauth_client_secret'] ?? '').toString().trim(),
    );
    if (cid.isEmpty || csec.isEmpty) {
      throw StateError(
        'OAuth client_credentials 模式需要填写 Client ID 与 Client Secret。',
      );
    }

    final meta = await discoverMetadata(entry);
    final tokenEndpoint = (meta['token_endpoint'] ?? '').toString();
    if (tokenEndpoint.isEmpty) {
      throw StateError('未能发现 OAuth token_endpoint。');
    }

    final scopes = (entry['oauth_scopes'] ?? '').toString().trim();
    final resource = (meta['resource'] ?? '').toString().trim();
    final client = _buildPkgHttpClient(entry);
    try {
      final resp = await client.post(
        Uri.parse(tokenEndpoint),
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Accept': 'application/json',
          'Authorization': 'Basic ${base64Encode(utf8.encode('$cid:$csec'))}',
        },
        body: {
          'grant_type': 'client_credentials',
          if (scopes.isNotEmpty) 'scope': scopes,
          if (resource.isNotEmpty) 'resource': resource,
        },
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException(
          'OAuth client_credentials 换取令牌失败 (HTTP ${resp.statusCode}): ${resp.body}',
        );
      }
      final data = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(resp.bodyBytes)) as Map,
      );
      final accessTok = (data['access_token'] ?? '').toString();
      if (accessTok.isEmpty) {
        throw StateError('OAuth 授权服务器未返回有效的 access_token。');
      }
      final expiresIn = int.tryParse('${data['expires_in'] ?? 3600}') ?? 3600;
      saveRecord(name, {
        'auth_type': 'oauth2_client_credentials',
        'access_token': accessTok,
        'expires_at': nowSec + expiresIn,
        'scope': (data['scope'] ?? scopes).toString(),
        'token_endpoint': tokenEndpoint,
        'issuer': meta['issuer'] ?? '',
      });
      return accessTok;
    } finally {
      client.close();
    }
  }

  Future<String> _getValidPkceAccessToken(
    Map<String, dynamic> entry, {
    bool forceRefresh = false,
  }) async {
    final name = (entry['name'] ?? '').toString();
    final rec = getRecord(name);
    if (rec == null) {
      throw StateError(
        "子 MCP '$name' 需要完成 OAuth 2.1 浏览器授权（请在「子 MCP」面板点击「OAuth 授权连接」）。",
      );
    }
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final accessTok = (rec['access_token'] ?? '').toString();
    final exp = int.tryParse('${rec['expires_at'] ?? 0}') ?? 0;
    if (!forceRefresh &&
        accessTok.isNotEmpty &&
        (exp == 0 || nowSec + 45 < exp)) {
      return accessTok;
    }

    final refreshTok = (rec['refresh_token'] ?? '').toString();
    final tokenEndpoint = (rec['token_endpoint'] ?? '').toString();
    if (refreshTok.isEmpty || tokenEndpoint.isEmpty) {
      if (accessTok.isNotEmpty && (exp == 0 || nowSec < exp)) {
        return accessTok;
      }
      throw StateError(
        "子 MCP '$name' 的 OAuth 令牌已过期且无 refresh_token，请重新点击「OAuth 授权连接」。",
      );
    }

    final cid = (rec['client_id'] ?? entry['oauth_client_id'] ?? '').toString();
    final csec =
        (rec['client_secret'] ?? entry['oauth_client_secret'] ?? '').toString();
    final resource = (rec['resource'] ?? '').toString();

    final client = _buildPkgHttpClient(entry);
    try {
      final resp = await client.post(
        Uri.parse(tokenEndpoint),
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Accept': 'application/json',
          if (cid.isNotEmpty && csec.isNotEmpty)
            'Authorization': 'Basic ${base64Encode(utf8.encode('$cid:$csec'))}',
        },
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': refreshTok,
          if (cid.isNotEmpty && csec.isEmpty) 'client_id': cid,
          if (resource.isNotEmpty) 'resource': resource,
        },
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw StateError(
          "OAuth 令牌自动续期失败 (HTTP ${resp.statusCode})，请重新授权连接。",
        );
      }
      final data = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(resp.bodyBytes)) as Map,
      );
      final newAccess = (data['access_token'] ?? '').toString();
      if (newAccess.isEmpty) {
        throw StateError('OAuth 刷新未返回有效 access_token。');
      }
      final expiresIn = int.tryParse('${data['expires_in'] ?? 3600}') ?? 3600;
      final updated = <String, dynamic>{
        ...rec,
        'access_token': newAccess,
        'refresh_token':
            (data['refresh_token'] ?? refreshTok).toString(),
        'expires_at': nowSec + expiresIn,
        if (data['scope'] != null) 'scope': data['scope'].toString(),
      };
      saveRecord(name, updated);
      return newAccess;
    } finally {
      client.close();
    }
  }

  /// Starts an interactive OAuth 2.1 + PKCE (`S256`) loopback authorization session:
  /// 1. Discovers PRM (RFC 9728) + AS Metadata (RFC 8414 / OIDC).
  /// 2. Resolves Client ID via configured ID -> CIMD -> RFC 7591 Dynamic Client Registration.
  /// 3. Spawns `127.0.0.1:<ephemeral>/oauth/callback` listener, exchanges code, and persists tokens.
  Future<Map<String, dynamic>> startInteractivePkceFlow(
    Map<String, dynamic> rawEntry, {
    String? stepUpScope,
    Completer<Map<String, dynamic>>? completionSignal,
  }) async {
    final entry = normalizeSubEntry({
      ...rawEntry,
      'auth_type': 'oauth2_pkce',
      if ((rawEntry['name'] ?? '').toString().trim().isEmpty)
        'name': 'oauth-sub-mcp',
    });
    final name = entry['name'] as String;

    // Close any previous pending loopback server for this Sub-MCP
    final prev = _activeLoopbacks.remove(name);
    if (prev != null) {
      prev.timer.cancel();
      await prev.server.close(force: true);
    }

    final meta = await discoverMetadata(entry);
    final supportedMethods =
        ((meta['code_challenge_methods_supported'] as List?) ?? const ['S256'])
            .map((e) => e.toString().toUpperCase())
            .toList();
    if (supportedMethods.isNotEmpty && !supportedMethods.contains('S256')) {
      throw StateError('远端授权服务器不支持 OAuth 2.1 S256 PKCE，已安全中止。');
    }

    final authEndpoint = (meta['authorization_endpoint'] ?? '').toString();
    final tokenEndpoint = (meta['token_endpoint'] ?? '').toString();
    final regEndpoint = (meta['registration_endpoint'] ?? '').toString();
    final resourceUri = (meta['resource'] ?? entry['url'] ?? '').toString();
    final expectedIssuer = (meta['issuer'] ?? '').toString().trim();

    if (authEndpoint.isEmpty || tokenEndpoint.isEmpty) {
      throw StateError('未能从远端服务发现完整的 OAuth authorization/token 端点。');
    }

    final loopbackServer =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectUri = 'http://127.0.0.1:${loopbackServer.port}/oauth/callback';

    var clientId = interpolateEnvPlaceholders(
      (entry['oauth_client_id'] ?? '').toString().trim(),
    );
    var clientSecret = interpolateEnvPlaceholders(
      (entry['oauth_client_secret'] ?? '').toString().trim(),
    );
    final cimdUrl = interpolateEnvPlaceholders(
      (entry['oauth_cimd_url'] ?? '').toString().trim(),
    );

    // Reuse previously dynamically-registered client if same issuer & redirect allow it
    final prevRec = getRecord(name);
    if (clientId.isEmpty &&
        cimdUrl.startsWith('https://') &&
        meta['client_id_metadata_document_supported'] == true) {
      clientId = cimdUrl;
    }

    if (clientId.isEmpty && regEndpoint.isNotEmpty) {
      final client = _buildPkgHttpClient(entry);
      try {
        final regResp = await client.post(
          Uri.parse(regEndpoint),
          headers: const {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode({
            'client_name': 'Agent MCP Gateway ($name)',
            'redirect_uris': [redirectUri],
            'grant_types': ['authorization_code', 'refresh_token'],
            'response_types': ['code'],
            'token_endpoint_auth_method': 'none',
          }),
        ).timeout(const Duration(seconds: 12));
        if (regResp.statusCode == 200 || regResp.statusCode == 201) {
          final regJson = Map<String, dynamic>.from(
            jsonDecode(utf8.decode(regResp.bodyBytes)) as Map,
          );
          clientId = (regJson['client_id'] ?? '').toString().trim();
          clientSecret = (regJson['client_secret'] ?? '').toString().trim();
        }
      } catch (_) {
      } finally {
        client.close();
      }
    }

    if (clientId.isEmpty && prevRec != null) {
      clientId = (prevRec['client_id'] ?? '').toString().trim();
      clientSecret = (prevRec['client_secret'] ?? '').toString().trim();
    }
    if (clientId.isEmpty) {
      clientId = 'agent-mcp-client';
    }

    final verifier = randomTokenUrlSafe(32);
    final challenge = base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final state = randomTokenUrlSafe(20);

    final configuredScopes = (entry['oauth_scopes'] ?? '').toString().trim();
    final discoveredScopes = (meta['challenge_scope'] ?? '').toString().trim();
    final mergedScopes = <String>{
      if (configuredScopes.isNotEmpty) ...configuredScopes.split(RegExp(r'\s+')),
      if (discoveredScopes.isNotEmpty) ...discoveredScopes.split(RegExp(r'\s+')),
      if (stepUpScope != null && stepUpScope.trim().isNotEmpty)
        ...stepUpScope.trim().split(RegExp(r'\s+')),
    }..removeWhere((s) => s.isEmpty);

    final authUri = Uri.parse(authEndpoint);
    final authFullUri = authUri.replace(
      queryParameters: {
        ...authUri.queryParameters,
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
        if (mergedScopes.isNotEmpty) 'scope': mergedScopes.join(' '),
        if (resourceUri.isNotEmpty) 'resource': resourceUri,
      },
    );

    final timeoutTimer = Timer(const Duration(minutes: 5), () async {
      final active = _activeLoopbacks.remove(name);
      if (active != null) {
        await active.server.close(force: true);
      }
      if (completionSignal != null && !completionSignal.isCompleted) {
        completionSignal.complete({'ok': false, 'error': 'OAuth 授权等待超时（5 分钟）'});
      }
    });
    _activeLoopbacks[name] = (server: loopbackServer, timer: timeoutTimer);

    unawaited(() async {
      await for (final req in loopbackServer) {
        if (req.uri.path != '/oauth/callback') {
          req.response
            ..statusCode = 404
            ..write('Not Found');
          await req.response.close();
          continue;
        }
        final q = req.uri.queryParameters;
        final retState = q['state'] ?? '';
        final retIss = (q['iss'] ?? '').trim();
        final errParam = q['error'];
        final code = (q['code'] ?? '').trim();

        Future<void> replyHtml(int status, String title, String detail, bool ok) async {
          req.response.statusCode = status;
          req.response.headers.contentType = ContentType.html;
          final badgeColor = ok ? '#059669' : '#DC2626';
          req.response.write('''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>$title</title>
<style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#FAFAFB;color:#111113;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;padding:20px}@media(prefers-color-scheme:dark){body{background:#0A0A0C;color:#FAFAFA}.card{background:#121216!important;border-color:#24242C!important}}.card{max-width:400px;width:100%;background:#FFF;border:1px solid #E4E4E7;border-radius:26px;padding:28px 26px;text-align:center;box-shadow:0 18px 40px -12px rgba(0,0,0,.12)}h2{margin:12px 0 8px;font-size:18px}p{margin:0;color:#71717A;font-size:13.5px;line-height:1.6}</style></head>
<body><div class="card"><div style="width:42px;height:42px;border-radius:999px;background:${badgeColor}1F;color:$badgeColor;display:inline-flex;align-items:center;justify-content:center;font-size:20px;font-weight:700">${ok ? "✓" : "!"}</div><h2>$title</h2><p>$detail</p></div></body></html>''');
          await req.response.close();
        }

        try {
          if (retState != state) {
            await replyHtml(400, '授权校验失败', 'State 参数不匹配，请回到 Agent MCP 重新发起授权。', false);
            completionSignal?.complete({'ok': false, 'error': 'OAuth state mismatch'});
            break;
          }
          // RFC 9207 issuer validation if authorization server sent `iss`
          if (retIss.isNotEmpty &&
              expectedIssuer.isNotEmpty &&
              retIss.replaceAll(RegExp(r'/+$'), '') !=
                  expectedIssuer.replaceAll(RegExp(r'/+$'), '')) {
            await replyHtml(400, '授权来源不匹配', '返回的 issuer 与预期授权服务器不一致。', false);
            completionSignal?.complete({'ok': false, 'error': 'OAuth issuer mismatch'});
            break;
          }
          if (errParam != null && errParam.isNotEmpty) {
            final desc = q['error_description'] ?? errParam;
            await replyHtml(400, '授权被拒绝', const HtmlEscape().convert(desc), false);
            completionSignal?.complete({'ok': false, 'error': desc});
            break;
          }
          if (code.isEmpty) {
            await replyHtml(400, '缺少授权码', '回调未携带有效的 authorization code。', false);
            completionSignal?.complete({'ok': false, 'error': 'Missing code'});
            break;
          }

          final client = _buildPkgHttpClient(entry);
          try {
            final tokResp = await client.post(
              Uri.parse(tokenEndpoint),
              headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
                'Accept': 'application/json',
                if (clientSecret.isNotEmpty)
                  'Authorization':
                      'Basic ${base64Encode(utf8.encode('$clientId:$clientSecret'))}',
              },
              body: {
                'grant_type': 'authorization_code',
                'code': code,
                'redirect_uri': redirectUri,
                'code_verifier': verifier,
                if (clientSecret.isEmpty) 'client_id': clientId,
                if (resourceUri.isNotEmpty) 'resource': resourceUri,
              },
            ).timeout(const Duration(seconds: 15));

            if (tokResp.statusCode < 200 || tokResp.statusCode >= 300) {
              await replyHtml(
                400,
                '令牌交换失败',
                'HTTP ${tokResp.statusCode}: ${const HtmlEscape().convert(tokResp.body)}',
                false,
              );
              completionSignal?.complete({
                'ok': false,
                'error': 'Token exchange HTTP ${tokResp.statusCode}',
              });
              break;
            }

            final tokJson = Map<String, dynamic>.from(
              jsonDecode(utf8.decode(tokResp.bodyBytes)) as Map,
            );
            final accessTok = (tokJson['access_token'] ?? '').toString();
            final refreshTok = (tokJson['refresh_token'] ?? '').toString();
            final expiresIn =
                int.tryParse('${tokJson['expires_in'] ?? 3600}') ?? 3600;
            final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

            saveRecord(name, {
              'auth_type': 'oauth2_pkce',
              'access_token': accessTok,
              if (refreshTok.isNotEmpty) 'refresh_token': refreshTok,
              'expires_at': nowSec + expiresIn,
              'scope': (tokJson['scope'] ?? mergedScopes.join(' ')).toString(),
              'client_id': clientId,
              if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
              'token_endpoint': tokenEndpoint,
              'authorization_endpoint': authEndpoint,
              'issuer': expectedIssuer,
              'resource': resourceUri,
            });

            StructuredEventBus.instance.emit({
              'kind': 'oauth',
              'badge': '子MCP授权',
              'level': 'INFO',
              'summary': '子 MCP OAuth 2.1 授权成功: $name',
            });

            await replyHtml(
              200,
              '子 MCP 授权成功',
              '已成功连接至「${const HtmlEscape().convert(name)}」，现在可以关闭此浏览器标签页并回到 Agent MCP 控制台。',
              true,
            );
            completionSignal?.complete({'ok': true, 'server_name': name});
          } finally {
            client.close();
          }
          break;
        } catch (e) {
          await replyHtml(500, '授权处理异常', const HtmlEscape().convert('$e'), false);
          completionSignal?.complete({'ok': false, 'error': '$e'});
          break;
        }
      }

      final active = _activeLoopbacks.remove(name);
      if (active != null) {
        active.timer.cancel();
        await active.server.close(force: true);
      }
    }());

    return {
      'ok': true,
      'server_name': name,
      'authorize_url': authFullUri.toString(),
      'redirect_uri': redirectUri,
      'client_id': clientId,
      'issuer': expectedIssuer,
    };
  }
}

/// Persistent initialized stdio session kept warm across consecutive Sub-MCP
/// tool calls (`call_sub_mcp` / `inspect_sub_mcp`) to eliminate 1–2.5s cold
/// starts from `npx` / `uvx` / `python` subprocesses.
class _PooledStdioSession {
  final String serverName;
  final String fingerprint;
  final Process proc;
  final void Function() _onClosed;

  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  String _stderrTail = '';
  int _nextId = 1;
  bool _closed = false;
  Timer? _idleTimer;
  late final StreamSubscription<String> _outSub;
  late final StreamSubscription<String> _errSub;
  Map<String, dynamic> initResult = const {};

  _PooledStdioSession._({
    required this.serverName,
    required this.fingerprint,
    required this.proc,
    required void Function() onClosed,
  }) : _onClosed = onClosed {
    _errSub = proc.stderr.transform(utf8.decoder).listen(
      (chunk) {
        _stderrTail += chunk;
        if (_stderrTail.length > 2400) {
          _stderrTail = _stderrTail.substring(_stderrTail.length - 2400);
        }
      },
      onError: (_) {},
    );

    _outSub = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) return;
        try {
          final msg = jsonDecode(trimmed);
          if (msg is Map && msg['id'] != null) {
            final id = int.tryParse('${msg['id']}');
            final comp = id != null ? _pending.remove(id) : null;
            if (comp != null && !comp.isCompleted) {
              if (msg['error'] != null) {
                comp.completeError(
                  StateError('RPC Error: ${jsonEncode(msg['error'])}'),
                );
              } else {
                comp.complete(
                  Map<String, dynamic>.from(
                    (msg['result'] as Map?) ?? const {},
                  ),
                );
              }
            }
          }
        } catch (_) {}
      },
      onDone: _handleStdoutClosed,
      onError: (_) => _handleStdoutClosed(),
    );

    proc.exitCode.then((_) => _handleStdoutClosed());
  }

  bool get isAlive => !_closed;

  int get pid => proc.pid;

  void _handleStdoutClosed() {
    if (_closed) return;
    _closed = true;
    _idleTimer?.cancel();
    final errMsg = _stderrTail.trim();
    final ex = StateError(
      'Sub-MCP stdio process ($serverName) closed unexpectedly'
      '${errMsg.isNotEmpty ? ': $errMsg' : ''}',
    );
    final waiters = _pending.values.toList();
    _pending.clear();
    for (final c in waiters) {
      if (!c.isCompleted) c.completeError(ex);
    }
    _onClosed();
  }

  void touchIdleTimer(Duration ttl) {
    _idleTimer?.cancel();
    if (_closed) return;
    _idleTimer = Timer(ttl, () {
      unawaited(close());
    });
  }

  Future<Map<String, dynamic>> sendRpc(
    String method,
    Map<String, dynamic>? params, {
    bool isNotification = false,
    required Duration timeout,
  }) async {
    if (_closed) {
      throw StateError('Sub-MCP stdio session ($serverName) is closed.');
    }
    if (isNotification) {
      final payload = <String, dynamic>{
        'jsonrpc': '2.0',
        'method': method,
        if (params != null) 'params': params,
      };
      proc.stdin.writeln(jsonEncode(payload));
      await proc.stdin.flush();
      return const <String, dynamic>{};
    }

    final id = _nextId++;
    final comp = Completer<Map<String, dynamic>>();
    _pending[id] = comp;
    final payload = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params ?? const <String, dynamic>{},
    };
    try {
      proc.stdin.writeln(jsonEncode(payload));
      await proc.stdin.flush();
    } catch (e) {
      _pending.remove(id);
      await close();
      throw StateError('Failed writing to Sub-MCP ($serverName) stdin: $e');
    }

    return comp.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        final errTxt = _stderrTail.trim();
        throw TimeoutException(
          'Sub-MCP stdio timeout ($serverName/$method)'
          '${errTxt.isNotEmpty ? ': $errTxt' : ''}',
        );
      },
    );
  }

  static Future<_PooledStdioSession> spawnAndInitialize(
    Map<String, dynamic> entry, {
    required String fingerprint,
    required Duration timeout,
    required Duration idleTtl,
    required void Function() onClosed,
  }) async {
    final proc = await _spawnStdioProcess(entry);
    final session = _PooledStdioSession._(
      serverName: (entry['name'] ?? 'sub-mcp').toString(),
      fingerprint: fingerprint,
      proc: proc,
      onClosed: onClosed,
    );
    try {
      session.initResult = await session.sendRpc(
        'initialize',
        _mcpInitParams(),
        timeout: timeout,
      );
      await session.sendRpc(
        'notifications/initialized',
        null,
        isNotification: true,
        timeout: timeout,
      );
      session.touchIdleTimer(idleTtl);
      return session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _idleTimer?.cancel();
    await _outSub.cancel();
    await _errSub.cancel();
    try {
      await proc.stdin.close();
    } catch (_) {}
    try {
      proc.kill();
    } catch (_) {}
    final waiters = _pending.values.toList();
    _pending.clear();
    for (final c in waiters) {
      if (!c.isCompleted) {
        c.completeError(StateError('Sub-MCP session ($serverName) closed.'));
      }
    }
    _onClosed();
  }
}

class _WarmStdioSessionPool {
  final Duration idleTtl;
  final Map<String, _PooledStdioSession> _sessions = {};
  final Map<String, Future<_PooledStdioSession>> _inflightSpawns = {};

  _WarmStdioSessionPool({this.idleTtl = const Duration(minutes: 5)});

  int get activeCount => _sessions.values.where((s) => s.isAlive).length;

  int? serverPid(String name) {
    final s = _sessions[name];
    return (s != null && s.isAlive) ? s.pid : null;
  }

  bool isServerWarm(String name) => _sessions[name]?.isAlive ?? false;

  static String _fingerprint(Map<String, dynamic> entry) => jsonEncode({
        'command': entry['command'],
        'args': entry['args'],
        'cwd': entry['cwd'],
        'env': entry['env'],
      });

  Future<_PooledStdioSession> acquire(
    Map<String, dynamic> entry, {
    required Duration timeout,
  }) async {
    final name = (entry['name'] ?? '').toString();
    final fp = _fingerprint(entry);
    final existing = _sessions[name];
    if (existing != null) {
      if (existing.isAlive && existing.fingerprint == fp) {
        existing.touchIdleTimer(idleTtl);
        return existing;
      }
      await existing.close();
      _sessions.remove(name);
    }

    final pendingSpawn = _inflightSpawns[name];
    if (pendingSpawn != null) {
      final spawned = await pendingSpawn;
      if (spawned.isAlive && spawned.fingerprint == fp) {
        spawned.touchIdleTimer(idleTtl);
        return spawned;
      }
    }

    final fut = _PooledStdioSession.spawnAndInitialize(
      entry,
      fingerprint: fp,
      timeout: timeout,
      idleTtl: idleTtl,
      onClosed: () {
        final cur = _sessions[name];
        if (cur != null && !cur.isAlive) {
          _sessions.remove(name);
        }
      },
    );
    _inflightSpawns[name] = fut;
    try {
      final session = await fut;
      _sessions[name] = session;
      return session;
    } finally {
      if (identical(_inflightSpawns[name], fut)) {
        final _ = _inflightSpawns.remove(name);
      }
    }
  }

  Future<T> runWithWarmSession<T>(
    Map<String, dynamic> entry, {
    required Duration timeout,
    required Future<T> Function(_PooledStdioSession session) action,
  }) async {
    var session = await acquire(entry, timeout: timeout);
    try {
      final out = await action(session);
      session.touchIdleTimer(idleTtl);
      return out;
    } on StateError catch (e) {
      if (e.message.startsWith('RPC Error:')) rethrow;
      await evict((entry['name'] ?? '').toString());
      session = await acquire(entry, timeout: timeout);
      final out = await action(session);
      session.touchIdleTimer(idleTtl);
      return out;
    }
  }

  Future<void> evict(String name) async {
    final s = _sessions.remove(name);
    if (s != null) {
      await s.close();
    }
  }

  Future<void> closeAll() async {
    final all = _sessions.values.toList();
    _sessions.clear();
    _inflightSpawns.clear();
    for (final s in all) {
      await s.close();
    }
  }
}

typedef _RpcSenderFn = Future<Map<String, dynamic>> Function(
  String method,
  Map<String, dynamic>? params, {
  bool isNotification,
});

class _HttpStatusSignalException implements Exception {
  final int statusCode;
  final String body;
  final String? wwwAuthenticate;
  const _HttpStatusSignalException(
    this.statusCode,
    this.body, {
    this.wwwAuthenticate,
  });

  @override
  String toString() => 'HTTP $statusCode: $body';
}

class _McpClientSession {
  final Map<String, dynamic> entry;
  final Duration timeout;
  final _WarmStdioSessionPool? stdioPool;
  final SubMcpOAuthClientManager oauthManager;

  _McpClientSession(
    this.entry, {
    this.stdioPool,
    SubMcpOAuthClientManager? oauth,
  })  : timeout = Duration(seconds: (entry['timeout'] as int?) ?? 30),
        oauthManager = oauth ?? SubMcpManager.instance.oauthManager;

  Future<Map<String, dynamic>> _handshakeOrDiscover(_RpcSenderFn send) async {
    try {
      final initRes = await send('initialize', _mcpInitParams());
      await send('notifications/initialized', null, isNotification: true);
      return initRes;
    } on StateError catch (e) {
      if (e.message.contains('-32601')) {
        // Pure MCP 2026-07-28 stateless server without legacy `initialize`: fallback to `server/discover`!
        final disc = await send('server/discover', const <String, dynamic>{});
        final supported = (disc['supportedVersions'] as List?)
                ?.map((v) => v.toString())
                .toList() ??
            const <String>[];
        final meta = disc['_meta'];
        final metaInfo = (meta is Map &&
                meta['io.modelcontextprotocol/serverInfo'] is Map)
            ? Map<String, dynamic>.from(
                meta['io.modelcontextprotocol/serverInfo'] as Map,
              )
            : null;
        return <String, dynamic>{
          ...disc,
          'protocolVersion':
              supported.contains('2026-07-28') ? '2026-07-28' : '2025-11-25',
          if (metaInfo != null && disc['serverInfo'] == null)
            'serverInfo': metaInfo,
        };
      }
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> _collectPaginatedList(
    _RpcSenderFn send,
    String method,
    List<Map<String, dynamic>> Function(Map<String, dynamic>) extractor,
  ) async {
    final all = <Map<String, dynamic>>[];
    String? cursor;
    final seenCursors = <String>{};
    for (var page = 0; page < 20; page++) {
      final params = <String, dynamic>{
        if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      };
      final res = await send(method, params);
      all.addAll(extractor(res));
      final next = (res['nextCursor'] ?? '').toString().trim();
      if (next.isEmpty || !seenCursors.add(next)) break;
      cursor = next;
    }
    return all;
  }

  Future<
      ({
        Map<String, dynamic> initResult,
        List<Map<String, dynamic>> tools,
        List<Map<String, dynamic>> resources,
        List<Map<String, dynamic>> prompts,
      })> initializeAndDiscoverAll() async {
    Future<
        ({
          Map<String, dynamic> initResult,
          List<Map<String, dynamic>> tools,
          List<Map<String, dynamic>> resources,
          List<Map<String, dynamic>> prompts,
        })> discoverBody(_RpcSenderFn send, {Map<String, dynamic>? preInit}) async {
      final initRes = preInit ?? await _handshakeOrDiscover(send);
      final caps = (initRes['capabilities'] as Map?) ?? const {};
      final tools = await _collectPaginatedList(
        send,
        'tools/list',
        _extractMcpTools,
      );
      var resources = <Map<String, dynamic>>[];
      var prompts = <Map<String, dynamic>>[];
      if (caps.containsKey('resources')) {
        try {
          resources = await _collectPaginatedList(
            send,
            'resources/list',
            _extractMcpResources,
          );
        } catch (_) {}
      }
      if (caps.containsKey('prompts')) {
        try {
          prompts = await _collectPaginatedList(
            send,
            'prompts/list',
            _extractMcpPrompts,
          );
        } catch (_) {}
      }
      return (
        initResult: initRes,
        tools: tools,
        resources: resources,
        prompts: prompts,
      );
    }

    final tr = entry['transport'] as String;
    if (tr == 'stdio' && stdioPool != null) {
      return stdioPool!.runWithWarmSession(
        entry,
        timeout: timeout,
        action: (session) => discoverBody(
          (m, p, {isNotification = false}) => session.sendRpc(
            m,
            p,
            isNotification: isNotification,
            timeout: timeout,
          ),
          preInit: session.initResult,
        ),
      );
    }
    return _executeAcrossTransport((send) => discoverBody(send));
  }

  Future<(Map<String, dynamic>, List<Map<String, dynamic>>)>
      initializeAndListTools() async {
    final bundle = await initializeAndDiscoverAll();
    return (bundle.initResult, bundle.tools);
  }

  Future<String> callTool(
    String toolName,
    Map<String, dynamic> arguments, {
    Duration? overrideTimeout,
  }) async {
    final effTimeout = overrideTimeout ?? timeout;
    final tr = entry['transport'] as String;
    final Map<String, dynamic> res;
    if (tr == 'stdio' && stdioPool != null) {
      res = await stdioPool!.runWithWarmSession(
        entry,
        timeout: effTimeout,
        action: (session) => session.sendRpc(
          'tools/call',
          {'name': toolName, 'arguments': arguments},
          timeout: effTimeout,
        ),
      );
    } else {
      res = await _executeAcrossTransport(
        (send) async {
          await _handshakeOrDiscover(send);
          return send('tools/call', {'name': toolName, 'arguments': arguments});
        },
        overrideTimeout: effTimeout,
      );
    }
    return _formatCallToolResult(res);
  }

  Future<String> readResource(String uri, {Duration? overrideTimeout}) async {
    final effTimeout = overrideTimeout ?? timeout;
    final tr = entry['transport'] as String;
    final Map<String, dynamic> res;
    if (tr == 'stdio' && stdioPool != null) {
      res = await stdioPool!.runWithWarmSession(
        entry,
        timeout: effTimeout,
        action: (session) =>
            session.sendRpc('resources/read', {'uri': uri}, timeout: effTimeout),
      );
    } else {
      res = await _executeAcrossTransport(
        (send) async {
          await _handshakeOrDiscover(send);
          return send('resources/read', {'uri': uri});
        },
        overrideTimeout: effTimeout,
      );
    }
    return const JsonEncoder.withIndent('  ').convert(res);
  }

  Future<String> getPrompt(
    String promptName,
    Map<String, dynamic> arguments, {
    Duration? overrideTimeout,
  }) async {
    final effTimeout = overrideTimeout ?? timeout;
    final tr = entry['transport'] as String;
    final Map<String, dynamic> res;
    if (tr == 'stdio' && stdioPool != null) {
      res = await stdioPool!.runWithWarmSession(
        entry,
        timeout: effTimeout,
        action: (session) => session.sendRpc(
          'prompts/get',
          {'name': promptName, 'arguments': arguments},
          timeout: effTimeout,
        ),
      );
    } else {
      res = await _executeAcrossTransport(
        (send) async {
          await _handshakeOrDiscover(send);
          return send(
            'prompts/get',
            {'name': promptName, 'arguments': arguments},
          );
        },
        overrideTimeout: effTimeout,
      );
    }
    return const JsonEncoder.withIndent('  ').convert(res);
  }

  Future<T> _executeAcrossTransport<T>(
    Future<T> Function(_RpcSenderFn send) action, {
    Duration? overrideTimeout,
  }) async {
    final tr = entry['transport'] as String;
    if (tr == 'stdio') {
      return _runEphemeralStdio(action, overrideTimeout: overrideTimeout);
    }
    if (tr == 'ws') {
      return _runWebSocket(action, overrideTimeout: overrideTimeout);
    }
    if (tr == 'sse') {
      return _runWithOAuthRetry(
        (auth) => _runSse(action, auth: auth, overrideTimeout: overrideTimeout),
      );
    }
    if (tr == 'auto') {
      return _runWithOAuthRetry((auth) async {
        try {
          return await _runHttp(
            action,
            auth: auth,
            overrideTimeout: overrideTimeout,
          );
        } on _HttpStatusSignalException catch (e) {
          if (e.statusCode == 404 || e.statusCode == 405) {
            return _runSse(
              action,
              auth: auth,
              overrideTimeout: overrideTimeout,
            );
          }
          rethrow;
        }
      });
    }
    return _runWithOAuthRetry(
      (auth) => _runHttp(action, auth: auth, overrideTimeout: overrideTimeout),
    );
  }

  Future<T> _runWithOAuthRetry<T>(
    Future<T> Function(
      ({Map<String, String> headers, Map<String, String> queryParams}) auth,
    ) runner,
  ) async {
    final authType = (entry['auth_type'] ?? 'none').toString();
    var auth = await oauthManager.resolveRequestAuth(entry);
    try {
      return await runner(auth);
    } on _HttpStatusSignalException catch (e) {
      if (e.statusCode == 401 &&
          (authType == 'oauth2_pkce' ||
              authType == 'oauth2_client_credentials')) {
        auth = await oauthManager.resolveRequestAuth(entry, forceRefresh: true);
        return runner(auth);
      }
      if (e.statusCode == 401 && authType == 'none') {
        throw const HttpException(
          'HTTP 401 未授权：该远程 MCP 服务要求鉴权（建议在编辑弹窗将鉴权方式切为「OAuth 2.1 授权」或填写 Bearer Token）。',
        );
      }
      if (e.statusCode == 403 && e.wwwAuthenticate != null) {
        final p = SubMcpOAuthClientManager._parseWwwAuthenticateParams(
          e.wwwAuthenticate,
        );
        if (p['error'] == 'insufficient_scope') {
          throw HttpException(
            "HTTP 403 权限范围不足 (insufficient_scope: ${p['scope'] ?? ''})，请在子 MCP 面板重新点击 OAuth 授权升级权限。",
          );
        }
      }
      throw HttpException('HTTP ${e.statusCode}: ${e.body}');
    }
  }

  Uri _buildAuthenticatedUri(
    String rawUrl,
    Map<String, String> extraQuery,
  ) {
    final base = Uri.parse(interpolateEnvPlaceholders(rawUrl));
    if (extraQuery.isEmpty) return base;
    return base.replace(
      queryParameters: {...base.queryParameters, ...extraQuery},
    );
  }

  Future<T> _runEphemeralStdio<T>(
    Future<T> Function(_RpcSenderFn send) action, {
    Duration? overrideTimeout,
  }) async {
    final effTimeout = overrideTimeout ?? timeout;
    final proc = await _spawnStdioProcess(entry);

    final pending = <int, Completer<Map<String, dynamic>>>{};
    var nextId = 1;
    final stderrBuf = StringBuffer();

    final errSub = proc.stderr
        .transform(utf8.decoder)
        .listen((chunk) => stderrBuf.write(chunk), onError: (_) {});

    final outSub = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) return;
      try {
        final msg = jsonDecode(trimmed);
        if (msg is Map && msg['id'] != null) {
          final id = int.tryParse('${msg['id']}');
          final comp = id != null ? pending.remove(id) : null;
          if (comp != null && !comp.isCompleted) {
            if (msg['error'] != null) {
              comp.completeError(
                StateError('RPC Error: ${jsonEncode(msg['error'])}'),
              );
            } else {
              comp.complete(
                Map<String, dynamic>.from((msg['result'] as Map?) ?? const {}),
              );
            }
          }
        }
      } catch (_) {}
    });

    Future<Map<String, dynamic>> send(
      String method,
      Map<String, dynamic>? params, {
      bool isNotification = false,
    }) async {
      if (isNotification) {
        final payload = <String, dynamic>{
          'jsonrpc': '2.0',
          'method': method,
          if (params != null) 'params': params,
        };
        proc.stdin.writeln(jsonEncode(payload));
        await proc.stdin.flush();
        return const <String, dynamic>{};
      }
      final id = nextId++;
      final comp = Completer<Map<String, dynamic>>();
      pending[id] = comp;
      final payload = <String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params ?? const <String, dynamic>{},
      };
      proc.stdin.writeln(jsonEncode(payload));
      await proc.stdin.flush();
      return comp.future.timeout(
        effTimeout,
        onTimeout: () {
          final errTxt = stderrBuf.toString().trim();
          throw TimeoutException(
            'Sub-MCP stdio timeout ($method)${errTxt.isNotEmpty ? ': $errTxt' : ''}',
          );
        },
      );
    }

    try {
      return await action(send);
    } finally {
      await outSub.cancel();
      await errSub.cancel();
      try {
        await proc.stdin.close();
      } catch (_) {}
      proc.kill();
    }
  }

  Future<T> _runHttp<T>(
    Future<T> Function(_RpcSenderFn send) action, {
    required ({Map<String, String> headers, Map<String, String> queryParams}) auth,
    Duration? overrideTimeout,
  }) async {
    final effTimeout = overrideTimeout ?? timeout;
    final uri = _buildAuthenticatedUri(entry['url'] as String, auth.queryParams);
    final customHeaders = _interpolateStringMap(
      Map<String, String>.from((entry['headers'] as Map?) ?? const {}),
    );
    final baseHeaders = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
      ...customHeaders,
      ...auth.headers,
    };
    final client = _buildPkgHttpClient(entry);
    String? sessionId;
    String? negotiatedProtocolVersion;
    var nextId = 1;

    Future<Map<String, dynamic>> send(
      String method,
      Map<String, dynamic>? params, {
      bool isNotification = false,
    }) async {
      final headers = <String, String>{
        ...baseHeaders,
        if (sessionId != null) 'Mcp-Session-Id': sessionId!,
        if (negotiatedProtocolVersion != null &&
            method != 'initialize' &&
            method != 'server/discover')
          'MCP-Protocol-Version': negotiatedProtocolVersion!,
      };
      final bodyObj = <String, dynamic>{
        'jsonrpc': '2.0',
        if (!isNotification) 'id': nextId++,
        'method': method,
        if (params != null) 'params': params,
      };
      var resp = await client
          .post(uri, headers: headers, body: jsonEncode(bodyObj))
          .timeout(effTimeout);

      // Streamable HTTP session-expired recovery: if server invalidated sessionId (404), re-handshake cleanly!
      if (resp.statusCode == 404 && sessionId != null && method != 'initialize') {
        sessionId = null;
        final reInitResp = await client
            .post(
              uri,
              headers: baseHeaders,
              body: jsonEncode({
                'jsonrpc': '2.0',
                'id': nextId++,
                'method': 'initialize',
                'params': _mcpInitParams(),
              }),
            )
            .timeout(effTimeout);
        final newSid = reInitResp.headers['mcp-session-id'] ??
            reInitResp.headers['Mcp-Session-Id'];
        if (newSid != null && newSid.isNotEmpty) {
          sessionId = newSid;
          await client
              .post(
                uri,
                headers: {...baseHeaders, 'Mcp-Session-Id': sessionId!},
                body: jsonEncode({
                  'jsonrpc': '2.0',
                  'method': 'notifications/initialized',
                }),
              )
              .timeout(effTimeout);
          resp = await client
              .post(
                uri,
                headers: {...baseHeaders, 'Mcp-Session-Id': sessionId!},
                body: jsonEncode(bodyObj),
              )
              .timeout(effTimeout);
        }
      }

      final sid =
          resp.headers['mcp-session-id'] ?? resp.headers['Mcp-Session-Id'];
      if (sid != null && sid.isNotEmpty) sessionId = sid;

      if (isNotification && resp.statusCode < 400) {
        return const <String, dynamic>{};
      }
      if (resp.statusCode >= 400) {
        throw _HttpStatusSignalException(
          resp.statusCode,
          resp.body,
          wwwAuthenticate: resp.headers['www-authenticate'],
        );
      }
      if (resp.statusCode == 202 || resp.body.trim().isEmpty) {
        return const <String, dynamic>{};
      }

      final ctype = (resp.headers['content-type'] ?? '').toLowerCase();
      Map<String, dynamic>? rpcMsg;
      if (ctype.contains('text/event-stream')) {
        for (final line in utf8.decode(resp.bodyBytes).split(RegExp(r'\r?\n'))) {
          if (line.startsWith('data:')) {
            final dataStr = line.substring(5).trim();
            if (dataStr.isEmpty) continue;
            final decoded = jsonDecode(dataStr);
            if (decoded is Map && decoded.containsKey('jsonrpc')) {
              rpcMsg = Map<String, dynamic>.from(decoded);
              if (rpcMsg['id'] != null) break;
            }
          }
        }
      } else {
        final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
        if (decoded is Map) rpcMsg = Map<String, dynamic>.from(decoded);
      }

      if (rpcMsg == null) {
        throw const FormatException('Invalid JSON-RPC response from Sub-MCP.');
      }
      if (rpcMsg['error'] != null) {
        throw StateError('RPC Error: ${jsonEncode(rpcMsg['error'])}');
      }
      final resMap =
          Map<String, dynamic>.from((rpcMsg['result'] as Map?) ?? const {});
      if (method == 'initialize' && resMap['protocolVersion'] != null) {
        negotiatedProtocolVersion = resMap['protocolVersion'].toString();
      } else if (method == 'server/discover') {
        final sv = (resMap['supportedVersions'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const <String>[];
        negotiatedProtocolVersion =
            sv.contains('2026-07-28') ? '2026-07-28' : '2025-11-25';
      }
      return resMap;
    }

    try {
      return await action(send);
    } finally {
      client.close();
    }
  }

  Future<T> _runSse<T>(
    Future<T> Function(_RpcSenderFn send) action, {
    required ({Map<String, String> headers, Map<String, String> queryParams}) auth,
    Duration? overrideTimeout,
  }) async {
    final effTimeout = overrideTimeout ?? timeout;
    final sseUri = _buildAuthenticatedUri(entry['url'] as String, auth.queryParams);
    final customHeaders = <String, String>{
      ..._interpolateStringMap(
        Map<String, String>.from((entry['headers'] as Map?) ?? const {}),
      ),
      ...auth.headers,
    };
    final httpClient = _buildConfiguredHttpClient(entry);
    final endpointCompleter = Completer<Uri>();
    final pending = <int, Completer<Map<String, dynamic>>>{};
    var nextId = 1;

    try {
      final req = await httpClient.getUrl(sseUri).timeout(effTimeout);
      req.headers.set('Accept', 'text/event-stream');
      customHeaders.forEach(req.headers.set);
      final resp = await req.close().timeout(effTimeout);
      if (resp.statusCode >= 400) {
        throw _HttpStatusSignalException(
          resp.statusCode,
          'SSE HTTP ${resp.statusCode}',
          wwwAuthenticate: resp.headers.value('www-authenticate'),
        );
      }

      var currentEvent = 'message';
      final dataLines = <String>[];

      final sub = resp
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line.isEmpty) {
          final payload = dataLines.join('\n').trim();
          dataLines.clear();
          final ev = currentEvent;
          currentEvent = 'message';
          if (payload.isEmpty) return;
          if (ev == 'endpoint') {
            if (!endpointCompleter.isCompleted) {
              endpointCompleter.complete(sseUri.resolve(payload));
            }
          } else {
            try {
              final msg = jsonDecode(payload);
              if (msg is Map && msg['id'] != null) {
                final id = int.tryParse('${msg['id']}');
                final comp = id != null ? pending.remove(id) : null;
                if (comp != null && !comp.isCompleted) {
                  if (msg['error'] != null) {
                    comp.completeError(
                      StateError('RPC Error: ${jsonEncode(msg['error'])}'),
                    );
                  } else {
                    comp.complete(
                      Map<String, dynamic>.from(
                        (msg['result'] as Map?) ?? const {},
                      ),
                    );
                  }
                }
              }
            } catch (_) {}
          }
          return;
        }
        if (line.startsWith('event:')) {
          currentEvent = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          dataLines.add(line.substring(5).trimLeft());
        }
      });

      final rawPostUri = await endpointCompleter.future.timeout(effTimeout);
      final postUri = auth.queryParams.isEmpty
          ? rawPostUri
          : rawPostUri.replace(
              queryParameters: {...rawPostUri.queryParameters, ...auth.queryParams},
            );
      final postClient = _buildPkgHttpClient(entry);

      Future<Map<String, dynamic>> send(
        String method,
        Map<String, dynamic>? params, {
        bool isNotification = false,
      }) async {
        final headers = <String, String>{
          'Content-Type': 'application/json',
          ...customHeaders,
        };
        if (isNotification) {
          await postClient
              .post(
                postUri,
                headers: headers,
                body: jsonEncode({
                  'jsonrpc': '2.0',
                  'method': method,
                  if (params != null) 'params': params,
                }),
              )
              .timeout(effTimeout);
          return const <String, dynamic>{};
        }
        final id = nextId++;
        final comp = Completer<Map<String, dynamic>>();
        pending[id] = comp;
        await postClient
            .post(
              postUri,
              headers: headers,
              body: jsonEncode({
                'jsonrpc': '2.0',
                'id': id,
                'method': method,
                'params': params ?? const <String, dynamic>{},
              }),
            )
            .timeout(effTimeout);
        return comp.future.timeout(effTimeout);
      }

      try {
        return await action(send);
      } finally {
        postClient.close();
        await sub.cancel();
      }
    } finally {
      httpClient.close(force: true);
    }
  }

  Future<T> _runWebSocket<T>(
    Future<T> Function(_RpcSenderFn send) action, {
    Duration? overrideTimeout,
  }) async {
    final effTimeout = overrideTimeout ?? timeout;
    final auth = await oauthManager.resolveRequestAuth(entry);
    final wsUri = _buildAuthenticatedUri(entry['url'] as String, auth.queryParams);
    final headers = <String, dynamic>{
      ..._interpolateStringMap(
        Map<String, String>.from((entry['headers'] as Map?) ?? const {}),
      ),
      ...auth.headers,
    };
    final customHc = _buildConfiguredHttpClient(entry);
    final ws = await WebSocket.connect(
      wsUri.toString(),
      headers: headers,
      protocols: const ['mcp'],
      customClient: customHc,
    ).timeout(effTimeout);

    final pending = <int, Completer<Map<String, dynamic>>>{};
    var nextId = 1;
    final sub = ws.listen((rawMsg) {
      try {
        final text = rawMsg is String ? rawMsg : utf8.decode(rawMsg as List<int>);
        final msg = jsonDecode(text);
        if (msg is Map && msg['id'] != null) {
          final id = int.tryParse('${msg['id']}');
          final comp = id != null ? pending.remove(id) : null;
          if (comp != null && !comp.isCompleted) {
            if (msg['error'] != null) {
              comp.completeError(
                StateError('RPC Error: ${jsonEncode(msg['error'])}'),
              );
            } else {
              comp.complete(
                Map<String, dynamic>.from((msg['result'] as Map?) ?? const {}),
              );
            }
          }
        }
      } catch (_) {}
    });

    Future<Map<String, dynamic>> send(
      String method,
      Map<String, dynamic>? params, {
      bool isNotification = false,
    }) async {
      if (isNotification) {
        ws.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': method,
            if (params != null) 'params': params,
          }),
        );
        return const <String, dynamic>{};
      }
      final id = nextId++;
      final comp = Completer<Map<String, dynamic>>();
      pending[id] = comp;
      ws.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': params ?? const <String, dynamic>{},
        }),
      );
      return comp.future.timeout(effTimeout);
    }

    try {
      return await action(send);
    } finally {
      await sub.cancel();
      await ws.close();
      customHc.close(force: true);
    }
  }
}

String _formatCallToolResult(Map<String, dynamic> res) {
  final isError = res['isError'] == true || res['is_error'] == true;
  final structured = res['structuredContent'] ?? res['structured_content'];
  final content = (res['content'] as List?) ?? const [];

  final hasRichBlocks = content.any((b) {
    if (b is! Map) return false;
    final t = b['type']?.toString();
    return t == 'image' ||
        t == 'audio' ||
        t == 'resource' ||
        t == 'resource_link';
  });
  if (!isError && (hasRichBlocks || structured != null)) {
    final cleanBlocks = content
        .whereType<Map>()
        .map((b) => Map<String, dynamic>.from(b))
        .toList();
    return '$kMcpStructuredCallResultPrefix${jsonEncode({
      'content': cleanBlocks,
      if (structured != null) 'structuredContent': structured,
      'isError': false,
    })}';
  }

  final parts = <String>[];
  for (final block in content) {
    if (block is! Map) {
      parts.add('$block');
      continue;
    }
    final btype = block['type'];
    if (btype == 'text' && block['text'] != null) {
      parts.add(block['text'].toString());
    } else if (btype == 'image') {
      parts.add('[Image content: ${block['mimeType'] ?? 'image/*'}]');
    } else if (btype == 'audio') {
      parts.add('[Audio content: ${block['mimeType'] ?? 'audio/*'}]');
    } else if (btype == 'resource') {
      final resObj = block['resource'];
      if (resObj is Map) {
        final uri = resObj['uri'] ?? '';
        final txt = resObj['text'] ?? '';
        parts.add(
          txt.toString().isNotEmpty ? '[Resource $uri]\n$txt' : '[Resource $uri]',
        );
      }
    } else {
      parts.add(jsonEncode(block));
    }
  }

  if (parts.isEmpty && structured != null) {
    parts.add(const JsonEncoder.withIndent('  ').convert(structured));
  }

  final body = parts.join('\n').trim();
  final finalBody = body.isEmpty ? '(empty result)' : body;
  if (isError && !finalBody.startsWith('Error:')) {
    return 'Error: $finalBody';
  }
  return finalBody;
}

class SubMcpManager {
  static final SubMcpManager instance = SubMcpManager();

  final File? _customConfigFile;
  final SubMcpOAuthClientManager oauthManager;
  final Map<String, Map<String, dynamic>> _cache = {};
  final _WarmStdioSessionPool _stdioPool;

  SubMcpManager([
    this._customConfigFile,
    Duration stdioIdleTtl = const Duration(minutes: 5),
    File? customOAuthStoreFile,
  ])  : _stdioPool = _WarmStdioSessionPool(idleTtl: stdioIdleTtl),
        oauthManager = SubMcpOAuthClientManager(customOAuthStoreFile);

  File get configFile =>
      _customConfigFile ?? StoragePaths.instance.subMcpConfigFile;

  int get warmSessionCount => _stdioPool.activeCount;

  int? warmSessionPid(String serverName) => _stdioPool.serverPid(serverName);

  Future<void> closeAllSessions() => _stdioPool.closeAll();

  List<Map<String, dynamic>> loadEntries() {
    StoragePaths.instance.ensureLayout();
    if (!configFile.existsSync()) return <Map<String, dynamic>>[];
    try {
      final raw = jsonDecode(configFile.readAsStringSync());
      final items = raw is Map
          ? ((raw['servers'] as List?) ?? const [])
          : (raw is List ? raw : const []);
      final out = <Map<String, dynamic>>[];
      for (final it in items) {
        if (it is Map) {
          try {
            out.add(normalizeSubEntry(Map<String, dynamic>.from(it)));
          } catch (_) {}
        }
      }
      return out;
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  void saveEntries(List<Map<String, dynamic>> entries) {
    configFile.parent.createSync(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    final payload = {'version': 2, 'servers': entries};
    configFile.writeAsStringSync('${encoder.convert(payload)}\n', flush: true);
    if (!Platform.isWindows) {
      try {
        Process.runSync('chmod', ['600', configFile.path]);
      } catch (_) {}
    }
  }

  Map<String, dynamic>? getEntry(String name) {
    for (final e in loadEntries()) {
      if (e['name'] == name) return e;
    }
    return null;
  }

  List<Map<String, dynamic>> listWithStatus() {
    final entries = loadEntries();
    return entries.map((e) {
      final name = e['name'] as String;
      final c = _cache[name] ?? const <String, dynamic>{};
      final disabledSet = ((e['disabled_tools'] as List?) ?? const [])
          .map((t) => t.toString())
          .toSet();
      final tools = (c['tools'] as List?) ?? const [];
      final resources = (c['resources'] as List?) ?? const [];
      final prompts = (c['prompts'] as List?) ?? const [];
      return <String, dynamic>{
        ...e,
        'status': c['status'] ?? 'idle',
        'warm': _stdioPool.isServerWarm(name),
        if (_stdioPool.serverPid(name) != null)
          'warm_pid': _stdioPool.serverPid(name),
        'oauth_status': oauthManager.publicStatus(e),
        'tool_count': c.containsKey('tools') ? tools.length : null,
        'resource_count': c.containsKey('resources') ? resources.length : null,
        'prompt_count': c.containsKey('prompts') ? prompts.length : null,
        'tools': tools.whereType<Map>().map((t) {
          final tname = (t['name'] ?? '').toString();
          return {
            'name': tname,
            'description': t['description'] ?? '',
            'inputSchema': t['inputSchema'] ??
                const {'type': 'object', 'properties': <String, dynamic>{}},
            'enabled': !disabledSet.contains(tname),
          };
        }).toList(),
        'resources': resources,
        'prompts': prompts,
        if (c['icon_src'] != null) 'icon_src': c['icon_src'],
        if (c['server_title'] != null) 'server_title': c['server_title'],
        'last_error': c['error'],
        'last_ms': c['ms'],
      };
    }).toList();
  }

  /// Warms any cold `expose_mode == 'direct'` Sub-MCPs and returns their mounted tool specs.
  Future<List<McpToolSpec>> resolveDirectMountedToolSpecs({
    String globalPrefix = '',
    Set<String>? existingToolNames,
  }) async {
    final coldDirect = <String>[];
    for (final entry in loadEntries()) {
      if (entry['enabled'] == false || entry['expose_mode'] != 'direct') {
        continue;
      }
      final sname = entry['name'] as String;
      final cached = _cache[sname];
      if (cached == null || cached['tools'] is! List) {
        coldDirect.add(sname);
      }
    }
    if (coldDirect.isNotEmpty) {
      await Future.wait(
        coldDirect.map(
          (sname) => discoverTools(sname)
              .timeout(const Duration(seconds: 4), onTimeout: () => const {}),
        ),
      );
    }
    return buildDirectMountedToolSpecs(
      globalPrefix: globalPrefix,
      existingToolNames: existingToolNames,
    );
  }

  /// Aggregates discovered MCP resources across enabled Sub-MCPs (`submcp://<server>/<uri>`).
  List<Map<String, dynamic>> collectBridgedResources() {
    final out = <Map<String, dynamic>>[];
    for (final entry in loadEntries()) {
      if (entry['enabled'] == false) continue;
      final sname = entry['name'] as String;
      final resList = (_cache[sname]?['resources'] as List?) ?? const [];
      for (final r in resList.whereType<Map>()) {
        final rawUri = (r['uri'] ?? '').toString().trim();
        if (rawUri.isEmpty) continue;
        out.add(<String, dynamic>{
          'uri': 'submcp://$sname/${Uri.encodeComponent(rawUri)}',
          'name': '[$sname] ${r['name'] ?? rawUri}',
          if (r['description'] != null) 'description': r['description'],
          if (r['mimeType'] != null) 'mimeType': r['mimeType'],
        });
      }
    }
    return out;
  }

  Future<Map<String, dynamic>?> readBridgedResource(String requestedUri) async {
    if (!requestedUri.startsWith('submcp://')) return null;
    final rest = requestedUri.substring('submcp://'.length);
    final slash = rest.indexOf('/');
    if (slash <= 0) return null;
    final sname = rest.substring(0, slash);
    final origUri = Uri.decodeComponent(rest.substring(slash + 1));
    final entry = getEntry(sname);
    if (entry == null || entry['enabled'] == false) return null;
    final rawJson = await _McpClientSession(
      entry,
      stdioPool: _stdioPool,
      oauth: oauthManager,
    ).readResource(origUri);
    final decoded = jsonDecode(rawJson);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  }

  /// Aggregates discovered MCP prompts across enabled Sub-MCPs (`<subPrefix>_<prompt>`).
  List<Map<String, dynamic>> collectBridgedPrompts() {
    final out = <Map<String, dynamic>>[];
    final used = <String>{};
    for (final entry in loadEntries()) {
      if (entry['enabled'] == false) continue;
      final sname = entry['name'] as String;
      final pList = (_cache[sname]?['prompts'] as List?) ?? const [];
      for (final p in pList.whereType<Map>()) {
        final rawName = (p['name'] ?? '').toString().trim();
        if (rawName.isEmpty) continue;
        final safeName = buildSafeMcpToolName(
          globalPrefix: '',
          subPrefix: sanitizePrefix(sname),
          rawToolName: rawName,
          usedNames: used,
        );
        out.add(<String, dynamic>{
          'name': safeName,
          'description': p['description'] != null
              ? '[$sname] ${p['description']}'
              : '[$sname] $rawName',
          if (p['arguments'] is List) 'arguments': p['arguments'],
          '_sub_server': sname,
          '_orig_prompt': rawName,
        });
      }
    }
    return out;
  }

  Future<Map<String, dynamic>?> getBridgedPrompt(
    String requestedName,
    Map<String, dynamic> arguments,
  ) async {
    final bridged = collectBridgedPrompts();
    final hit =
        bridged.where((p) => p['name'] == requestedName).firstOrNull;
    if (hit == null) return null;
    final sname = hit['_sub_server'] as String;
    final origName = hit['_orig_prompt'] as String;
    final entry = getEntry(sname);
    if (entry == null || entry['enabled'] == false) return null;
    final rawJson = await _McpClientSession(
      entry,
      stdioPool: _stdioPool,
      oauth: oauthManager,
    ).getPrompt(origName, arguments);
    final decoded = jsonDecode(rawJson);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  }

  /// Returns MCP tool definitions for Sub-MCPs configured with `expose_mode == 'direct'`
  /// so they appear directly in the main server's `tools/list` (`<subname>__<tool>`).
  List<McpToolSpec> buildDirectMountedToolSpecs({
    String globalPrefix = '',
    Set<String>? existingToolNames,
  }) {
    final specs = <McpToolSpec>[];
    final usedMountedNames = <String>{...?existingToolNames};
    for (final entry in loadEntries()) {
      if (entry['enabled'] == false || entry['expose_mode'] != 'direct') {
        continue;
      }
      final sname = entry['name'] as String;
      final cached = _cache[sname];
      if (cached == null || cached['tools'] is! List) {
        // Trigger background warm discovery so next tools/list includes it
        unawaited(discoverTools(sname));
        continue;
      }
      final disabled = ((entry['disabled_tools'] as List?) ?? const [])
          .map((e) => e.toString())
          .toSet();
      final subPrefix = sanitizePrefix(sname);
      final serverIconSrc = cached['icon_src']?.toString();
      final fallbackSubIcons = (serverIconSrc != null && serverIconSrc.isNotEmpty)
          ? <Map<String, dynamic>>[
              {'src': serverIconSrc},
            ]
          : null;
      for (final rawTool in cached['tools'] as List) {
        if (rawTool is! Map) continue;
        final tName = (rawTool['name'] ?? '').toString().trim();
        if (tName.isEmpty || disabled.contains(tName)) continue;
        final fullName = buildSafeMcpToolName(
          globalPrefix: globalPrefix,
          subPrefix: subPrefix,
          rawToolName: tName,
          usedNames: usedMountedNames,
        );
        final mountedBase = buildSafeMcpToolName(
          globalPrefix: '',
          subPrefix: subPrefix,
          rawToolName: tName,
        );
        final desc = (rawTool['description'] ?? '').toString().trim();
        final rawTitle = (rawTool['title'] ?? '').toString().trim();
        final toolIcons = rawTool['icons'] is List
            ? (rawTool['icons'] as List)
                .whereType<Map>()
                .map((m) => Map<String, dynamic>.from(m))
                .toList()
            : fallbackSubIcons;
        final schema = rawTool['inputSchema'] is Map
            ? Map<String, dynamic>.from(rawTool['inputSchema'] as Map)
            : const <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{},
              };
        specs.add(
          McpToolSpec(
            baseName: mountedBase,
            name: fullName,
            title: rawTitle.isNotEmpty ? '[$sname] $rawTitle' : '[$sname] $tName',
            description: desc.isEmpty ? '[$sname] $tName' : '[$sname] $desc',
            inputSchema: schema,
            annotations: subCallAnn,
            icons: toolIcons,
            handler: (args) => callTool(sname, tName, arguments: args),
          ),
        );
      }
    }
    return specs;
  }

  Map<String, dynamic> upsertEntry(
    Map<String, dynamic> raw, {
    String? oldName,
  }) {
    final entry = normalizeSubEntry(raw);
    final entries = loadEntries();
    final targetOld = (oldName != null && oldName.isNotEmpty)
        ? oldName
        : (entry['name'] as String);
    if (oldName != null &&
        oldName.isNotEmpty &&
        oldName != entry['name'] &&
        entries.any((e) => e['name'] == entry['name'])) {
      throw FormatException("已存在名为 '${entry['name']}' 的子 MCP。");
    }

    var updated = false;
    final next = <Map<String, dynamic>>[];
    for (final e in entries) {
      if (e['name'] == targetOld) {
        next.add(entry);
        updated = true;
      } else {
        next.add(e);
      }
    }
    if (!updated) next.add(entry);
    saveEntries(next);
    if (oldName != null && oldName != entry['name']) {
      _cache.remove(oldName);
      unawaited(_stdioPool.evict(oldName));
      final oldTok = oauthManager.getRecord(oldName);
      if (oldTok != null) {
        oauthManager.saveRecord(entry['name'] as String, oldTok);
        oauthManager.deleteRecord(oldName);
      }
    }
    final newName = entry['name'] as String;
    _cache.remove(newName);
    unawaited(_stdioPool.evict(newName));
    if (entry['enabled'] != false && entry['expose_mode'] == 'direct') {
      unawaited(discoverTools(newName, refresh: true));
    }
    return entry;
  }

  List<Map<String, dynamic>> importJson(String rawText) {
    final parsed = parseMcpServersJson(rawText);
    final entries = loadEntries();
    final byName = <String, Map<String, dynamic>>{
      for (final e in entries) e['name'] as String: e,
    };
    final order = entries.map((e) => e['name'] as String).toList();
    for (final item in parsed) {
      final n = item['name'] as String;
      if (!byName.containsKey(n)) order.add(n);
      byName[n] = item;
      _cache.remove(n);
      unawaited(_stdioPool.evict(n));
    }
    saveEntries([for (final n in order) byName[n]!]);
    return parsed;
  }

  Map<String, dynamic> toggleEntry(String name, bool enabled) {
    final entries = loadEntries();
    for (final e in entries) {
      if (e['name'] == name) {
        e['enabled'] = enabled;
        saveEntries(entries);
        if (!enabled) {
          unawaited(_stdioPool.evict(name));
        } else if (e['expose_mode'] == 'direct') {
          unawaited(discoverTools(name, refresh: true));
        }
        return e;
      }
    }
    throw StateError('未找到子 MCP: $name');
  }

  bool deleteEntry(String name) {
    final entries = loadEntries();
    final next = entries.where((e) => e['name'] != name).toList();
    if (next.length == entries.length) return false;
    saveEntries(next);
    _cache.remove(name);
    oauthManager.deleteRecord(name);
    unawaited(_stdioPool.evict(name));
    return true;
  }

  Future<Map<String, dynamic>> startOAuthFlow(
    String serverName, {
    Map<String, dynamic>? draftOverride,
    String? stepUpScope,
    Completer<Map<String, dynamic>>? completionSignal,
  }) async {
    final target = draftOverride ?? getEntry(serverName);
    if (target == null) {
      throw StateError("未找到子 MCP '$serverName'");
    }
    return oauthManager.startInteractivePkceFlow(
      {...target, 'name': serverName},
      stepUpScope: stepUpScope,
      completionSignal: completionSignal,
    );
  }

  bool revokeOAuth(String serverName) {
    _cache.remove(serverName);
    return oauthManager.deleteRecord(serverName);
  }

  Future<Map<String, dynamic>> probeDraft(Map<String, dynamic> raw) async {
    final draft = Map<String, dynamic>.from(raw);
    if ((draft['name'] ?? '').toString().trim().isEmpty) {
      draft['name'] = 'probe-temp';
    }
    final Map<String, dynamic> entry;
    try {
      entry = normalizeSubEntry(draft);
    } on FormatException catch (e) {
      return {'ok': false, 'error': e.message};
    }

    final sw = Stopwatch()..start();
    try {
      final bundle = await _McpClientSession(
        entry,
        oauth: oauthManager,
      ).initializeAndDiscoverAll();
      sw.stop();
      final elapsed =
          double.parse((sw.elapsedMicroseconds / 1000.0).toStringAsFixed(1));
      final serverInfo = (bundle.initResult['serverInfo'] as Map?) ?? const {};
      final rawName = (serverInfo['name'] ?? '').toString().trim();
      final version = (serverInfo['version'] ?? '').toString().trim();
      final instructions =
          (bundle.initResult['instructions'] ?? '').toString().trim();
      final suggestedName = rawName.isNotEmpty ? sanitizeSubName(rawName) : '';

      String desc;
      if (instructions.isNotEmpty) {
        final firstPara = instructions.split(RegExp(r'\r?\n')).first.trim();
        desc = firstPara.length > 180
            ? '${firstPara.substring(0, 180)}...'
            : firstPara;
      } else if (bundle.tools.isNotEmpty) {
        final sample = bundle.tools.take(5).map((t) => t['name']).join(', ');
        final suffix = bundle.tools.length > 5 ? ' 等' : '';
        final verTag = version.isNotEmpty ? 'v$version · ' : '';
        desc = '$verTag提供 ${bundle.tools.length} 个工具（$sample$suffix）';
      } else {
        desc = '$rawName $version'.trim();
      }

      final iconSrc = _pickSafeUpstreamIconSrc(bundle.initResult);
      return {
        'ok': true,
        'name': suggestedName,
        'raw_name': rawName,
        'version': version,
        'description': desc,
        if (iconSrc != null) 'icon_src': iconSrc,
        'tool_count': bundle.tools.length,
        'resource_count': bundle.resources.length,
        'prompt_count': bundle.prompts.length,
        'ms': elapsed,
      };
    } catch (e) {
      sw.stop();
      final elapsed =
          double.parse((sw.elapsedMicroseconds / 1000.0).toStringAsFixed(1));
      final msg = '$e';
      final needsOAuth = msg.contains('401') || msg.contains('OAuth');
      return {
        'ok': false,
        'error': msg,
        'needs_oauth': needsOAuth,
        'ms': elapsed,
      };
    }
  }

  Future<Map<String, dynamic>> discoverTools(
    String name, {
    bool refresh = false,
  }) async {
    final entry = getEntry(name);
    if (entry == null) {
      return {'ok': false, 'error': "Sub-MCP '$name' not found."};
    }
    final cached = _cache[name];
    if (!refresh &&
        cached != null &&
        cached['status'] == 'ok' &&
        cached['tools'] != null) {
      return {
        'ok': true,
        'tools': cached['tools'],
        'resources': cached['resources'] ?? const <Map<String, dynamic>>[],
        'prompts': cached['prompts'] ?? const <Map<String, dynamic>>[],
        'ms': cached['ms'] ?? 0.0,
        'cached': true,
      };
    }

    final sw = Stopwatch()..start();
    try {
      final usePool = entry['enabled'] != false ? _stdioPool : null;
      final bundle = await _McpClientSession(
        entry,
        stdioPool: usePool,
        oauth: oauthManager,
      ).initializeAndDiscoverAll();
      sw.stop();
      final elapsed =
          double.parse((sw.elapsedMicroseconds / 1000.0).toStringAsFixed(1));
      final iconSrc = _pickSafeUpstreamIconSrc(bundle.initResult);
      final sInfo = (bundle.initResult['serverInfo'] as Map?) ?? const {};
      _cache[name] = {
        'status': 'ok',
        'tools': bundle.tools,
        'resources': bundle.resources,
        'prompts': bundle.prompts,
        if (iconSrc != null) 'icon_src': iconSrc,
        if (sInfo['title'] != null) 'server_title': sInfo['title'].toString(),
        'error': null,
        'ms': elapsed,
      };
      return {
        'ok': true,
        'tools': bundle.tools,
        'resources': bundle.resources,
        'prompts': bundle.prompts,
        'ms': elapsed,
        'cached': false,
      };
    } catch (e) {
      sw.stop();
      final elapsed =
          double.parse((sw.elapsedMicroseconds / 1000.0).toStringAsFixed(1));
      final errMsg = '$e';
      _cache[name] = {
        'status': 'error',
        'tools': const <Map<String, dynamic>>[],
        'resources': const <Map<String, dynamic>>[],
        'prompts': const <Map<String, dynamic>>[],
        'error': errMsg,
        'ms': elapsed,
      };
      return {'ok': false, 'error': errMsg, 'ms': elapsed};
    }
  }

  Future<String> callTool(
    String serverName,
    String toolName, {
    Map<String, dynamic>? arguments,
    int? timeoutSec,
  }) async {
    final entry = getEntry(serverName);
    if (entry == null) {
      final avail = loadEntries()
          .where((e) => e['enabled'] != false)
          .map((e) => e['name'])
          .toList();
      return "Error: Sub-MCP '$serverName' not found. Available enabled sub-MCPs: $avail";
    }
    if (entry['enabled'] == false) {
      return "Error: Sub-MCP '$serverName' is currently disabled.";
    }
    final disabled = ((entry['disabled_tools'] as List?) ?? const [])
        .map((e) => e.toString())
        .toSet();
    if (disabled.contains(toolName)) {
      return "Error: Tool '$toolName' is disabled on Sub-MCP '$serverName'.";
    }
    try {
      final res = await _McpClientSession(
        entry,
        stdioPool: _stdioPool,
        oauth: oauthManager,
      ).callTool(
        toolName,
        arguments ?? const <String, dynamic>{},
        overrideTimeout:
            timeoutSec != null ? Duration(seconds: timeoutSec) : null,
      );
      if (res.startsWith('Error:')) {
        final hint = _cachedSchemaHint(serverName, toolName);
        if (hint != null) {
          return '$res\n\n[Hint: expected inputSchema for $serverName/$toolName]\n$hint';
        }
      }
      return res;
    } catch (e) {
      final hint = _cachedSchemaHint(serverName, toolName);
      var msg = "Error: Sub-MCP call '$serverName/$toolName' failed: $e";
      if (hint != null) {
        msg += '\n\n[Hint: expected inputSchema for $serverName/$toolName]\n$hint';
      }
      return msg;
    }
  }

  Future<String> readResource(String serverName, String uri) async {
    final entry = getEntry(serverName);
    if (entry == null) return "Error: Sub-MCP '$serverName' not found.";
    if (entry['enabled'] == false) {
      return "Error: Sub-MCP '$serverName' is currently disabled.";
    }
    try {
      return await _McpClientSession(
        entry,
        stdioPool: _stdioPool,
        oauth: oauthManager,
      ).readResource(uri);
    } catch (e) {
      return "Error: Sub-MCP resource read '$serverName ($uri)' failed: $e";
    }
  }

  Future<String> getPrompt(
    String serverName,
    String promptName, {
    Map<String, dynamic>? arguments,
  }) async {
    final entry = getEntry(serverName);
    if (entry == null) return "Error: Sub-MCP '$serverName' not found.";
    if (entry['enabled'] == false) {
      return "Error: Sub-MCP '$serverName' is currently disabled.";
    }
    try {
      return await _McpClientSession(
        entry,
        stdioPool: _stdioPool,
        oauth: oauthManager,
      ).getPrompt(promptName, arguments ?? const <String, dynamic>{});
    } catch (e) {
      return "Error: Sub-MCP prompt '$serverName/$promptName' failed: $e";
    }
  }

  String? _cachedSchemaHint(String serverName, String toolName) {
    final tools = (_cache[serverName]?['tools'] as List?) ?? const [];
    for (final t in tools) {
      if (t is Map && t['name'] == toolName) {
        return const JsonEncoder.withIndent('  ')
            .convert(t['inputSchema'] ?? const <String, dynamic>{});
      }
    }
    return null;
  }
}

void registerSubMcpTools(
  RegisterToolFn registerTool,
  ServerConfig config, {
  SubMcpManager? manager,
}) {
  final mgr = manager ?? SubMcpManager.instance;
  const jsonEncoder = JsonEncoder.withIndent('  ');

  registerTool(
    name: 'list_sub_mcps',
    description:
        'List all configured and enabled nested Sub-MCP servers (stdio, Streamable HTTP, SSE, WebSocket, OAuth 2.1) without polluting the main toolset.\n'
        'Call this first to discover available Sub-MCP servers, then use inspect_sub_mcp() and call_sub_mcp().',
    annotations: readOnlyAnn,
    inputSchema: {'type': 'object', 'properties': <String, dynamic>{}},
    handler: (_) {
      final items = mgr.listWithStatus();
      final enabledItems = items
          .where((it) => it['enabled'] != false)
          .map((it) => {
                'name': it['name'],
                'description':
                    (it['description'] ?? '').toString().trim().isEmpty
                        ? '(no description)'
                        : it['description'],
                'transport': it['transport'],
                'auth_type': it['auth_type'] ?? 'none',
                'expose_mode': it['expose_mode'] ?? 'gateway',
                'status': it['status'] ?? 'idle',
                'warm': it['warm'] == true,
                'cached_tool_count': it['tool_count'],
                'cached_resource_count': it['resource_count'],
                'cached_prompt_count': it['prompt_count'],
              })
          .toList();
      return jsonEncoder.convert({
        'count': enabledItems.length,
        'sub_mcps': enabledItems,
        'usage':
            '1) Call inspect_sub_mcp(server_name, kind="tools"|"resources"|"prompts") to list items. '
                '2) Call inspect_sub_mcp(server_name, tool_name) to inspect exact inputSchema before calling. '
                '3) Call call_sub_mcp(server_name, tool_name, arguments={...}) (or kind="resource"|"prompt") to execute.',
      });
    },
  );

  registerTool(
    name: 'inspect_sub_mcp',
    description:
        'Inspect tools, resources, or prompts exposed by a nested Sub-MCP server.\n'
        'Omit tool_name to get a compact list; pass tool_name to get its full inputSchema.',
    annotations: readOnlyAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'server_name': {'type': 'string'},
        'tool_name': {'type': 'string'},
        'kind': {
          'type': 'string',
          'enum': ['tools', 'resources', 'prompts', 'all'],
          'default': 'tools',
        },
        'refresh': {'type': 'boolean', 'default': false},
      },
      'required': ['server_name'],
    },
    handler: (args) async {
      final serverName = (args['server_name'] ?? '').toString();
      final toolName = args['tool_name']?.toString();
      final kind = (args['kind'] ?? 'tools').toString().toLowerCase();
      final refresh = args['refresh'] == true;

      final entry = mgr.getEntry(serverName);
      if (entry == null) {
        final avail = mgr
            .loadEntries()
            .where((e) => e['enabled'] != false)
            .map((e) => e['name'])
            .toList();
        return "Error: Sub-MCP '$serverName' not found. Available enabled sub-MCPs: $avail";
      }
      if (entry['enabled'] == false) {
        return "Error: Sub-MCP '$serverName' is disabled.";
      }

      final res = await mgr.discoverTools(serverName, refresh: refresh);
      if (res['ok'] != true) {
        return "Error: Failed to connect to Sub-MCP '$serverName': ${res['error']}";
      }

      final disabled = ((entry['disabled_tools'] as List?) ?? const [])
          .map((e) => e.toString())
          .toSet();
      final tools = ((res['tools'] as List?) ?? const [])
          .whereType<Map>()
          .where((t) => !disabled.contains((t['name'] ?? '').toString()))
          .toList();
      final resources =
          ((res['resources'] as List?) ?? const []).whereType<Map>().toList();
      final prompts =
          ((res['prompts'] as List?) ?? const []).whereType<Map>().toList();

      if (toolName != null && toolName.isNotEmpty) {
        for (final t in tools) {
          if (t['name'] == toolName) {
            return jsonEncoder.convert({
              'server_name': serverName,
              'tool': t,
            });
          }
        }
        final names = tools.map((t) => t['name'].toString()).toList();
        final close = findClosestLines(toolName, names, limit: 5, cutoff: 0.4)
            .map((e) => e.$2)
            .toList();
        return "Error: Tool '$toolName' not found in Sub-MCP '$serverName'. "
            'Close matches: ${close.isNotEmpty ? close : names.take(10).toList()}';
      }

      if (kind == 'resources') {
        return jsonEncoder.convert({
          'server_name': serverName,
          'resource_count': resources.length,
          'resources': resources,
        });
      }
      if (kind == 'prompts') {
        return jsonEncoder.convert({
          'server_name': serverName,
          'prompt_count': prompts.length,
          'prompts': prompts,
        });
      }

      final compact = tools.map((t) {
        final rawDesc = (t['description'] ?? '').toString().trim();
        final firstLine =
            rawDesc.isEmpty ? '' : rawDesc.split(RegExp(r'\r?\n')).first;
        return {
          'name': t['name'],
          'description': firstLine.length > 200
              ? firstLine.substring(0, 200)
              : firstLine,
        };
      }).toList();

      return jsonEncoder.convert({
        'server_name': serverName,
        'description': entry['description'] ?? '',
        'transport': entry['transport'],
        'tool_count': compact.length,
        'tools': compact,
        if (kind == 'all') 'resources': resources,
        if (kind == 'all') 'prompts': prompts,
        'hint':
            'Call inspect_sub_mcp(server_name, tool_name) to view full parameter schema before calling.',
      });
    },
  );

  registerTool(
    name: 'call_sub_mcp',
    description:
        'Invoke a tool, read a resource (kind="resource", uri=...), or render a prompt (kind="prompt") on a nested Sub-MCP server.',
    annotations: subCallAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'server_name': {'type': 'string'},
        'tool_name': {
          'type': 'string',
          'description': 'Tool name (or prompt name when kind="prompt", or resource URI when kind="resource").',
        },
        'kind': {
          'type': 'string',
          'enum': ['tool', 'resource', 'prompt'],
          'default': 'tool',
        },
        'uri': {
          'type': 'string',
          'description': 'Resource URI when kind="resource".',
        },
        'arguments': {'type': 'object'},
        'timeout': {'type': 'integer'},
      },
      'required': ['server_name'],
    },
    handler: (args) async {
      final serverName = (args['server_name'] ?? '').toString();
      final kind = (args['kind'] ?? 'tool').toString().toLowerCase();
      final rawArgs = args['arguments'];
      final callArgs = rawArgs is Map
          ? Map<String, dynamic>.from(rawArgs)
          : <String, dynamic>{};

      if (kind == 'resource') {
        final uri = (args['uri'] ?? args['tool_name'] ?? '').toString().trim();
        if (uri.isEmpty) {
          return "Error: 'uri' is required when kind='resource'.";
        }
        return mgr.readResource(serverName, uri);
      }
      if (kind == 'prompt') {
        final pname = (args['tool_name'] ?? '').toString().trim();
        if (pname.isEmpty) {
          return "Error: 'tool_name' (prompt name) is required when kind='prompt'.";
        }
        return mgr.getPrompt(serverName, pname, arguments: callArgs);
      }

      final toolName = (args['tool_name'] ?? '').toString();
      if (toolName.isEmpty) {
        return "Error: 'tool_name' is required when kind='tool'.";
      }
      final timeoutSec =
          args['timeout'] != null ? int.tryParse('${args['timeout']}') : null;
      return mgr.callTool(
        serverName,
        toolName,
        arguments: callArgs,
        timeoutSec: timeoutSec,
      );
    },
  );
}
