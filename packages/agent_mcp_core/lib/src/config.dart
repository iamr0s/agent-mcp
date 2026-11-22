import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// Resolves runtime storage layout (`config/`, `data/`, `logs/`, `bin/`).
/// Compatible with both source-tree execution and standalone `dart compile exe`.
class StoragePaths {
  final Directory rootDir;
  late final Directory configDir = Directory(p.join(rootDir.path, 'config'));
  late final Directory dataDir = Directory(p.join(rootDir.path, 'data'));
  late final Directory cacheDir = Directory(p.join(dataDir.path, 'cache'));
  late final Directory logsDir = Directory(p.join(rootDir.path, 'logs'));
  late final Directory binDir = Directory(p.join(rootDir.path, 'bin'));

  late final File defaultConfigFile =
      File(p.join(configDir.path, 'mcp_config.json'));
  late final File subMcpConfigFile =
      File(p.join(configDir.path, 'mcp_sub_servers.json'));
  late final File oauthStateFile =
      File(p.join(dataDir.path, 'oauth_state.json'));
  late final File windowStateFile =
      File(p.join(dataDir.path, 'window_state.json'));
  late final File tunnelStateFile =
      File(p.join(dataDir.path, 'tunnel_state.json'));

  StoragePaths(this.rootDir);

  static StoragePaths? _instance;

  static StoragePaths get instance {
    return _instance ??= StoragePaths(_detectProjectRoot());
  }

  static void overrideRoot(Directory dir) {
    _instance = StoragePaths(dir.absolute);
  }

  static Directory _detectProjectRoot() {
    final envRoot = Platform.environment['AGENT_MCP_HOME'];
    if (envRoot != null && envRoot.trim().isNotEmpty) {
      return Directory(p.normalize(Directory(envRoot.trim()).absolute.path));
    }

    // Check current working directory first if it looks like the workspace root
    final cwd = Directory.current.absolute;
    if (File(p.join(cwd.path, 'config', 'mcp_config.json')).existsSync() ||
        Directory(p.join(cwd.path, 'packages', 'agent_mcp_core')).existsSync()) {
      return cwd;
    }

    // Walk up from executable or script path
    final execPath = Platform.resolvedExecutable;
    final execName = p.basenameWithoutExtension(execPath).toLowerCase();
    if (execName != 'dart' &&
        execName != 'dartaotruntime' &&
        execName != 'flutter_tester') {
      final exeDir = File(execPath).parent;
      // If placed inside `<root>/bin/agent-mcp.exe`, use `<root>`
      if (p.basename(exeDir.path).toLowerCase() == 'bin') {
        return exeDir.parent;
      }
      return exeDir;
    }

    // Running via `dart run`: walk up from Platform.script
    try {
      var cur = File.fromUri(Platform.script).parent;
      for (var i = 0; i < 6; i++) {
        if (File(p.join(cur.path, 'pubspec.yaml')).existsSync() &&
            Directory(p.join(cur.path, 'packages')).existsSync()) {
          return cur;
        }
        final parent = cur.parent;
        if (parent.path == cur.path) break;
        cur = parent;
      }
    } catch (_) {}

    return cwd;
  }

  bool _migrated = false;

  void ensureLayout() {
    configDir.createSync(recursive: true);
    dataDir.createSync(recursive: true);
    cacheDir.createSync(recursive: true);
    logsDir.createSync(recursive: true);
    if (_migrated) return;
    _migrated = true;

    final migrations = <(File, File)>[
      (File(p.join(rootDir.path, 'mcp_config.json')), defaultConfigFile),
      (File(p.join(rootDir.path, 'mcp_sub_servers.json')), subMcpConfigFile),
      (File(p.join(rootDir.path, 'mcp_oauth_state.json')), oauthStateFile),
      (File(p.join(rootDir.path, 'mcp_window_state.json')), windowStateFile),
    ];
    final archiveDir =
        Directory(p.join(rootDir.path, '_legacy', 'migrated_root'));
    for (final (src, dst) in migrations) {
      try {
        if (src.existsSync() && !dst.existsSync()) {
          dst.parent.createSync(recursive: true);
          src.copySync(dst.path);
          if (dst.existsSync() && dst.lengthSync() == src.lengthSync()) {
            archiveDir.createSync(recursive: true);
            src.renameSync(p.join(archiveDir.path, p.basename(src.path)));
          }
        }
      } catch (_) {}
    }
  }
}

const Set<String> defaultIgnoreDirs = {
  '.git',
  '.hg',
  '.svn',
  'node_modules',
  '__pycache__',
  '.pytest_cache',
  '.mypy_cache',
  '.ruff_cache',
  '.venv',
  'venv',
  '.tox',
  'dist',
  'build',
  '.dart_tool',
  '.sdk',
  '.gradle',
  '.idea',
  '.vscode',
  'target',
  'bin',
  'obj',
};

const List<String> secretFilenamePatterns = [
  '.env',
  '.env.*',
  '*.pem',
  '*.key',
  '*.p12',
  '*.pfx',
  '*.jks',
  '*.keystore',
  'id_rsa',
  'id_rsa.*',
  'id_ed25519',
  'id_ed25519.*',
  'credentials.json',
  'secrets.json',
  'secrets.yaml',
  'secrets.yml',
  '.npmrc',
  '.pypirc',
  '.netrc',
  'mcp_config.json',
  'mcp_oauth_state.json',
  'oauth_state.json',
  'mcp_sub_servers.json',
];

const Set<String> secretDirParts = {
  '.ssh',
  '.aws',
  '.gnupg',
  '.kube',
  '.local-agent-mcp',
};

class AccessPolicy {
  final String profileId;
  final String profileName;
  final String host;
  final bool readOnly;
  final bool allowSecrets;
  final bool relaxedCommandAnnotations;
  final List<String> roots;

  const AccessPolicy({
    this.profileId = 'default',
    this.profileName = '默认入口',
    this.host = '',
    this.readOnly = false,
    this.allowSecrets = false,
    this.relaxedCommandAnnotations = false,
    this.roots = const [],
  });
}

const Object _policyZoneKey = #agentMcpAccessPolicy;

/// Runs [body] inside a Dart [Zone] carrying per-request [AccessPolicy].
T runWithPolicy<T>(AccessPolicy policy, T Function() body) {
  return runZoned(body, zoneValues: {_policyZoneKey: policy});
}

AccessPolicy getEffectivePolicy(ServerConfig config) {
  final zoned = Zone.current[_policyZoneKey];
  if (zoned is AccessPolicy) return zoned;
  return AccessPolicy(
    profileId: 'global',
    profileName: config.transport == 'stdio' ? '本地 stdio' : '默认入口',
    host: '',
    readOnly: config.readOnly,
    allowSecrets: config.allowSecrets,
    relaxedCommandAnnotations: config.relaxedCommandAnnotations,
    roots: List<String>.unmodifiable(config.roots),
  );
}

List<String> parseBindHosts(dynamic rawHosts, [dynamic fallbackHost]) {
  final items = <String>[];
  void collect(dynamic src) {
    if (src == null) return;
    if (src is Iterable) {
      for (final item in src) {
        collect(item);
      }
      return;
    }
    for (final part in src.toString().split(RegExp(r'[\r\n,;]+'))) {
      final s = part.trim();
      if (s.isNotEmpty) items.add(s);
    }
  }

  collect(rawHosts);
  if (items.isEmpty) collect(fallbackHost);

  final deduped = <String>[];
  for (final h in items) {
    if (h == '0.0.0.0') return <String>['0.0.0.0'];
    if (!deduped.contains(h)) deduped.add(h);
  }
  return deduped.isEmpty ? <String>['127.0.0.1'] : deduped;
}

class ServerConfig {
  String serverName;
  String toolPrefix;
  String transport; // stdio | http | sse | dual
  String host;
  List<String> hosts;
  int port;
  String authMode; // none | bearer | oauth-local | github | google | oauth-custom
  String? apiKey;
  String? oauthClientId;
  String? oauthClientSecret;
  String? oauthBaseUrl;
  List<String> oauthBaseUrls;
  String? oauthAuthUrl;
  String? oauthTokenUrl;
  String? oauthJwksUrl;
  String? oauthLocalPasswordHash;
  List<String> oauthRedirectUris;
  List<Map<String, dynamic>> profiles;
  List<String> roots;
  bool readOnly;
  bool allowSecrets;
  bool relaxedCommandAnnotations;
  int maxReadChars;
  int maxCmdChars;
  int defaultTimeout;
  bool statelessHttp;
  String logLevel;
  String? logFile;
  bool noColor;
  File configFile;

  ServerConfig({
    this.serverName = 'local-agent-mcp',
    this.toolPrefix = '',
    this.transport = 'stdio',
    String host = '127.0.0.1',
    List<String>? hosts,
    this.port = 8000,
    this.authMode = 'none',
    this.apiKey,
    this.oauthClientId,
    this.oauthClientSecret,
    this.oauthBaseUrl,
    List<String>? oauthBaseUrls,
    this.oauthAuthUrl,
    this.oauthTokenUrl,
    this.oauthJwksUrl,
    this.oauthLocalPasswordHash,
    List<String>? oauthRedirectUris,
    List<Map<String, dynamic>>? profiles,
    List<String>? roots,
    this.readOnly = false,
    this.allowSecrets = false,
    this.relaxedCommandAnnotations = false,
    this.maxReadChars = 60000,
    this.maxCmdChars = 15000,
    this.defaultTimeout = 60,
    this.statelessHttp = true,
    this.logLevel = 'INFO',
    this.logFile,
    this.noColor = false,
    File? configFile,
  })  : hosts = parseBindHosts(hosts, host),
        host = parseBindHosts(hosts, host).first,
        oauthBaseUrls = oauthBaseUrls ?? [],
        oauthRedirectUris = oauthRedirectUris ?? [],
        profiles = profiles ?? [],
        roots = roots ?? [],
        configFile = configFile ?? StoragePaths.instance.defaultConfigFile;

  bool get unrestricted => roots.isEmpty;

  factory ServerConfig.fromSavedMap(
    Map<String, dynamic> saved, {
    File? configFile,
  }) {
    final profs = ensureProfilesInConfig(saved);
    final rawRoots = (saved['roots'] as List?) ?? const [];
    final resolvedRoots = rawRoots
        .map((e) => e.toString().trim())
        .where((s) => s.isNotEmpty)
        .map(expandAndResolvePath)
        .toList();

    final bindHosts = parseBindHosts(saved['hosts'], saved['host']);

    return ServerConfig(
      serverName: (saved['server_name'] ?? 'mcp-${Platform.localHostname}')
          .toString()
          .trim(),
      toolPrefix: (saved['tool_prefix'] ?? '').toString(),
      transport: (saved['transport'] ?? 'dual').toString().toLowerCase(),
      host: bindHosts.first,
      hosts: bindHosts,
      port: int.tryParse('${saved['port'] ?? 8000}') ?? 8000,
      authMode: (saved['auth_mode'] ?? 'bearer').toString().toLowerCase(),
      apiKey: _nonEmptyOrNull(saved['api_key']),
      oauthClientId: _nonEmptyOrNull(saved['oauth_client_id']),
      oauthClientSecret: _nonEmptyOrNull(saved['oauth_client_secret']),
      oauthBaseUrl: _nonEmptyOrNull(saved['oauth_base_url']),
      oauthBaseUrls: ((saved['oauth_base_urls'] as List?) ?? const [])
          .map((e) => e.toString().trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      oauthAuthUrl: _nonEmptyOrNull(saved['oauth_auth_url']),
      oauthTokenUrl: _nonEmptyOrNull(saved['oauth_token_url']),
      oauthJwksUrl: _nonEmptyOrNull(saved['oauth_jwks_url']),
      oauthLocalPasswordHash:
          _nonEmptyOrNull(saved['oauth_local_password_hash']),
      oauthRedirectUris: ((saved['oauth_redirect_uris'] as List?) ?? const [])
          .map((e) => e.toString().trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      profiles: profs,
      roots: resolvedRoots,
      readOnly: saved['read_only'] == true,
      allowSecrets: saved['allow_secrets'] == true,
      relaxedCommandAnnotations: saved['relaxed_command_annotations'] == true,
      defaultTimeout:
          (int.tryParse('${saved['default_timeout'] ?? 60}') ?? 60).clamp(1, 600),
      logLevel: (saved['log_level'] ?? 'INFO').toString().toUpperCase(),
      logFile: _nonEmptyOrNull(saved['log_file']),
      configFile: configFile,
    );
  }
}

String? _nonEmptyOrNull(dynamic val) {
  if (val == null) return null;
  final s = val.toString().trim();
  return s.isEmpty ? null : s;
}

String _randomHex(int length) {
  const chars = '0123456789abcdef';
  final rng = Random.secure();
  return List.generate(length, (_) => chars[rng.nextInt(chars.length)]).join();
}

String normalizeDirectBaseUrl(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return '';
  if (!s.contains('://')) {
    final lower = s.toLowerCase();
    final isLocalOrPrivate = lower.startsWith('localhost') ||
        lower.startsWith('127.') ||
        lower.startsWith('10.') ||
        lower.startsWith('192.168.') ||
        lower.startsWith('100.') ||
        lower.startsWith('198.18.') ||
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

List<String> resolveProfileBaseUrls(
  Map<String, dynamic> prof, {
  required int port,
  String fallbackHost = '127.0.0.1',
  String? liveQuickUrl,
}) {
  final tmode = (prof['tunnel_mode'] ?? 'none').toString().trim().toLowerCase();
  if (tmode == 'quick') {
    final q = (liveQuickUrl ?? '').trim().replaceAll(RegExp(r'/+$'), '');
    return q.isNotEmpty ? <String>[q] : const <String>[];
  }
  if (tmode == 'token') {
    final b = normalizeDirectBaseUrl((prof['base_url'] ?? '').toString());
    return b.isNotEmpty ? <String>[b] : const <String>[];
  }

  final urls = <String>[];
  void addUnique(String raw) {
    final clean = normalizeDirectBaseUrl(raw);
    if (clean.isNotEmpty && !urls.contains(clean)) {
      urls.add(clean);
    }
  }

  final rawDirectIps = prof['direct_ips'];
  if (rawDirectIps is List) {
    for (final item in rawDirectIps) {
      final ip = item.toString().trim();
      if (ip.isEmpty) continue;
      if (ip.contains('://') || ip.contains(':')) {
        addUnique(ip);
      } else {
        addUnique('http://$ip:$port');
      }
    }
  }

  final rawManual = prof['manual_urls'];
  if (rawManual is List) {
    for (final item in rawManual) {
      addUnique(item.toString());
    }
  }

  if (urls.isEmpty) {
    final legacyBase = (prof['base_url'] ?? '').toString().trim();
    if (legacyBase.isNotEmpty) {
      addUnique(legacyBase);
    }
  }

  if (urls.isEmpty) {
    final cleanHost = (fallbackHost == '0.0.0.0' ||
            fallbackHost == '::' ||
            fallbackHost.trim().isEmpty)
        ? '127.0.0.1'
        : fallbackHost.trim();
    urls.add('http://$cleanHost:$port');
  }
  return urls;
}

Future<List<Map<String, String>>> listHostNetworkInterfaces() async {
  final out = <Map<String, String>>[
    const {
      'ip': '127.0.0.1',
      'iface': 'lo',
      'kind': 'loopback',
      'label': '本机回环',
    },
  ];
  final seen = <String>{'127.0.0.1'};

  (String, String, int) classify(String ip, String ifName) {
    final lower = ifName.toLowerCase();
    if (ip.startsWith('198.18.') ||
        lower.contains('clash') ||
        lower.contains('mihomo') ||
        lower.contains('sing-box')) {
      return ('tun_proxy', '代理 TUN', 4);
    }
    final parts = ip.split('.');
    final p0 = parts.isNotEmpty ? (int.tryParse(parts[0]) ?? -1) : -1;
    final p1 = parts.length > 1 ? (int.tryParse(parts[1]) ?? -1) : -1;
    final isCgnat = p0 == 100 && p1 >= 64 && p1 <= 127;
    if (isCgnat ||
        lower.contains('tailscale') ||
        lower.contains('zerotier') ||
        lower.startsWith('wg') ||
        lower.startsWith('tun')) {
      return ('vpn', '组网 / Tailscale', 2);
    }
    final isLan = p0 == 10 ||
        (p0 == 172 && p1 >= 16 && p1 <= 31) ||
        (p0 == 192 && p1 == 168);
    if (isLan) {
      return ('lan', '局域网', 1);
    }
    return ('public', '网卡地址', 3);
  }

  final collected = <(int, Map<String, String>)>[];
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        final ip = addr.address.trim();
        if (ip.isEmpty || ip.startsWith('169.254.') || !seen.add(ip)) continue;
        final (kind, label, rank) = classify(ip, iface.name);
        collected.add((
          rank,
          {
            'ip': ip,
            'iface': iface.name,
            'kind': kind,
            'label': label,
          },
        ));
      }
    }
  } catch (_) {}

  collected.sort((a, b) => a.$1.compareTo(b.$1));
  for (final item in collected) {
    out.add(item.$2);
  }
  return out;
}

Map<String, dynamic> normalizeProfile(
  Map<String, dynamic> raw, [
  int idx = 0,
  int? serverPort,
]) {
  final rawId = (raw['id'] ?? '').toString().trim();
  final pid = rawId.isEmpty ? 'prof-${_randomHex(8)}' : rawId;
  final rawName = (raw['name'] ?? '').toString().trim();
  final name = rawName.isEmpty ? '入口 #${idx + 1}' : rawName;

  var transport = (raw['transport'] ?? 'dual').toString().trim().toLowerCase();
  if (transport != 'dual' && transport != 'http' && transport != 'sse') {
    transport = 'dual';
  }

  var authMode =
      (raw['auth_mode'] ?? 'oauth-local').toString().trim().toLowerCase();
  const validAuth = {
    'none',
    'bearer',
    'oauth-local',
    'github',
    'google',
    'oauth-custom',
  };
  if (!validAuth.contains(authMode)) {
    authMode = 'oauth-local';
  }

  final rawBaseUrl = (raw['base_url'] ?? '')
      .toString()
      .trim()
      .replaceAll(RegExp(r'/+$'), '');

  List<String> parseStringList(dynamic v) {
    if (v is String) {
      return v
          .split(RegExp(r'[\r\n,;]+'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    if (v is List) {
      return v
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return <String>[];
  }

  var tunnelMode =
      (raw['tunnel_mode'] ?? 'none').toString().trim().toLowerCase();
  if (tunnelMode != 'none' && tunnelMode != 'token' && tunnelMode != 'quick') {
    tunnelMode = 'none';
  }

  final directIps = <String>[];
  for (final ip in parseStringList(raw['direct_ips'])) {
    final cleaned = ip
        .replaceFirst(RegExp(r'^https?://', caseSensitive: false), '')
        .split('/')
        .first
        .split(':')
        .first
        .trim();
    if (cleaned.isNotEmpty && !directIps.contains(cleaned)) {
      directIps.add(cleaned);
    }
  }

  final manualUrls = <String>[];
  for (final u in parseStringList(raw['manual_urls'])) {
    final norm = normalizeDirectBaseUrl(u);
    if (norm.isNotEmpty && !manualUrls.contains(norm)) {
      manualUrls.add(norm);
    }
  }

  final hasExplicitDirectConfig =
      raw.containsKey('direct_ips') || raw.containsKey('manual_urls');
  if (tunnelMode == 'none' &&
      !hasExplicitDirectConfig &&
      directIps.isEmpty &&
      manualUrls.isEmpty &&
      rawBaseUrl.isNotEmpty) {
    final migrated = normalizeDirectBaseUrl(rawBaseUrl);
    if (migrated.isNotEmpty) {
      manualUrls.add(migrated);
    }
  }

  final effectivePort = (serverPort != null && serverPort > 0) ? serverPort : 8000;
  final baseUrls = <String>[];
  String primaryBaseUrl = rawBaseUrl;

  if (tunnelMode == 'quick') {
    primaryBaseUrl = '';
  } else if (tunnelMode == 'token') {
    primaryBaseUrl = rawBaseUrl.isEmpty ? '' : normalizeDirectBaseUrl(rawBaseUrl);
    if (primaryBaseUrl.isNotEmpty) {
      baseUrls.add(primaryBaseUrl);
    }
  } else {
    for (final ip in directIps) {
      final u = 'http://$ip:$effectivePort';
      if (!baseUrls.contains(u)) baseUrls.add(u);
    }
    for (final u in manualUrls) {
      if (!baseUrls.contains(u)) baseUrls.add(u);
    }
    primaryBaseUrl = baseUrls.isNotEmpty ? baseUrls.first : '';
  }

  return <String, dynamic>{
    'id': pid,
    'name': name,
    'enabled': raw['enabled'] == null ? true : raw['enabled'] == true,
    'transport': transport,
    'base_url': primaryBaseUrl,
    'base_urls': baseUrls,
    'direct_ips': tunnelMode == 'none' ? directIps : const <String>[],
    'manual_urls': tunnelMode == 'none' ? manualUrls : const <String>[],
    'auth_mode': authMode,
    'api_key': _nonEmptyOrNull(raw['api_key']),
    'oauth_client_id': _nonEmptyOrNull(raw['oauth_client_id']),
    'oauth_client_secret': _nonEmptyOrNull(raw['oauth_client_secret']),
    'oauth_redirect_uris': parseStringList(raw['oauth_redirect_uris']),
    'tunnel_mode': tunnelMode,
    'tunnel_token': _nonEmptyOrNull(raw['tunnel_token']),
    'tunnel_auto_start': raw['tunnel_auto_start'] == null
        ? true
        : raw['tunnel_auto_start'] == true,
    'inherit_permissions': raw['inherit_permissions'] == null
        ? true
        : raw['inherit_permissions'] == true,
    'read_only': raw['read_only'] == true,
    'allow_secrets': raw['allow_secrets'] == true,
    'relaxed_command_annotations': raw['relaxed_command_annotations'] == true,
    'roots': parseStringList(raw['roots']),
  };
}

List<Map<String, dynamic>> ensureProfilesInConfig(Map<String, dynamic> data) {
  final cfgPort = int.tryParse('${data['port'] ?? 8000}') ?? 8000;
  final rawProfiles = data['profiles'];
  if (rawProfiles is List && rawProfiles.isNotEmpty) {
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < rawProfiles.length; i++) {
      final item = rawProfiles[i];
      if (item is Map) {
        out.add(normalizeProfile(Map<String, dynamic>.from(item), i, cfgPort));
      }
    }
    if (out.isNotEmpty) return out;
  }

  final bases = <String>[];
  final b0 = (data['oauth_base_url'] ?? '')
      .toString()
      .trim()
      .replaceAll(RegExp(r'/+$'), '');
  if (b0.isNotEmpty) bases.add(b0);
  final extraBases = data['oauth_base_urls'];
  if (extraBases is List) {
    for (final u in extraBases) {
      final s = u.toString().trim().replaceAll(RegExp(r'/+$'), '');
      if (s.isNotEmpty && !bases.contains(s)) bases.add(s);
    }
  }
  if (bases.isEmpty) bases.add('');

  var tr = (data['transport'] ?? 'dual').toString().toLowerCase();
  if (tr != 'dual' && tr != 'http' && tr != 'sse') tr = 'dual';
  final am = (data['auth_mode'] ?? 'oauth-local').toString().toLowerCase();

  final out = <Map<String, dynamic>>[];
  for (var idx = 0; idx < bases.length; idx++) {
    out.add(
      normalizeProfile(
        {
          'id': idx == 0 ? 'default' : 'prof-${idx + 1}',
          'name': idx == 0 ? '主入口' : '备用入口 #$idx',
          'enabled': true,
          'transport': tr,
          'base_url': bases[idx],
          'auth_mode': am,
          'api_key': data['api_key'],
          'oauth_client_id': data['oauth_client_id'],
          'oauth_client_secret': data['oauth_client_secret'],
          'oauth_redirect_uris': data['oauth_redirect_uris'] ?? const [],
          'inherit_permissions': true,
          'read_only': data['read_only'] == true,
          'allow_secrets': data['allow_secrets'] == true,
          'relaxed_command_annotations':
              data['relaxed_command_annotations'] == true,
          'roots': data['roots'] ?? const [],
        },
        idx,
        cfgPort,
      ),
    );
  }
  return out;
}

String sanitizePrefix(String raw) {
  final cleaned = raw
      .trim()
      .replaceAll(RegExp(r'[^a-zA-Z0-9_]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return cleaned.isEmpty ? '' : '${cleaned}_';
}

String expandUserPath(String rawPath) {
  var s = rawPath.trim();
  if (s.startsWith('~')) {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    if (home.isNotEmpty) {
      if (s == '~') {
        s = home;
      } else if (s.startsWith('~/') || s.startsWith(r'~\')) {
        s = p.join(home, s.substring(2));
      }
    }
  }
  return s;
}

String expandAndResolvePath(String rawPath) {
  final expanded = expandUserPath(rawPath);
  final abs = p.isAbsolute(expanded)
      ? expanded
      : p.join(Directory.current.path, expanded);
  try {
    final f = File(abs);
    if (f.existsSync()) return f.resolveSymbolicLinksSync();
    final d = Directory(abs);
    if (d.existsSync()) return d.resolveSymbolicLinksSync();
  } catch (_) {}
  return p.normalize(p.absolute(abs));
}

bool isWithin(String targetPath, String rootPath) {
  final normTarget = p.normalize(p.absolute(targetPath));
  final normRoot = p.normalize(p.absolute(rootPath));
  if (Platform.isWindows) {
    final tl = normTarget.toLowerCase();
    final rl = normRoot.toLowerCase();
    if (tl == rl) return true;
    final prefix = rl.endsWith(r'\') ? rl : '$rl\\';
    return tl.startsWith(prefix);
  } else {
    if (normTarget == normRoot) return true;
    final prefix = normRoot.endsWith('/') ? normRoot : '$normRoot/';
    return normTarget.startsWith(prefix);
  }
}

String normalizePath(String rawPath, List<String> roots) {
  final expanded = expandUserPath(rawPath);
  String candidate;
  if (p.isAbsolute(expanded)) {
    candidate = expanded;
  } else {
    var base = Directory.current.absolute.path;
    if (roots.isNotEmpty && !roots.any((r) => isWithin(base, r))) {
      base = roots.first;
    }
    candidate = p.join(base, expanded);
  }
  return expandAndResolvePath(candidate);
}

bool wildcardMatch(String text, String pattern, {bool caseSensitive = true}) {
  final t = caseSensitive ? text : text.toLowerCase();
  final pat = caseSensitive ? pattern : pattern.toLowerCase();
  final buf = StringBuffer('^');
  for (var i = 0; i < pat.length; i++) {
    final ch = pat[i];
    if (ch == '*') {
      if (i + 1 < pat.length && pat[i + 1] == '*') {
        buf.write('.*');
        i++;
      } else {
        buf.write('[^/\\\\]*');
      }
    } else if (ch == '?') {
      buf.write('[^/\\\\]');
    } else if (r'.+^$()[]{}|\'.contains(ch)) {
      buf.write('\\$ch');
    } else {
      buf.write(ch);
    }
  }
  buf.write(r'$');
  return RegExp(buf.toString()).hasMatch(t);
}


/// Checks whether [targetPath] points to a protected credential file, secret
/// directory (`.ssh`, `.aws`, `.gnupg`, `.kube`, `.local-agent-mcp`), or MCP
/// internal config/data file. Shared by both MCP tools and `/share/<id>`.
String? blockedSecretReason(
  String targetPath, {
  String? rawLabel,
  ServerConfig? config,
}) {
  final resolved = expandAndResolvePath(targetPath);
  final label = rawLabel ?? targetPath;
  final storage = StoragePaths.instance;
  final cfgDirResolved = expandAndResolvePath(storage.configDir.path);
  final dataDirResolved = expandAndResolvePath(storage.dataDir.path);
  final cfgResolved =
      config != null ? expandAndResolvePath(config.configFile.path) : null;

  if ((cfgResolved != null && _samePath(resolved, cfgResolved)) ||
      isWithin(resolved, cfgDirResolved) ||
      isWithin(resolved, dataDirResolved)) {
    return "Access blocked for protected MCP config/data file '$label'. "
        'Enable allow_secrets on this profile if you intentionally need access.';
  }

  final baseLower = p.basename(resolved).toLowerCase();
  if (baseLower != '.env.example') {
    for (final pat in secretFilenamePatterns) {
      if (wildcardMatch(baseLower, pat.toLowerCase(), caseSensitive: false)) {
        return "Access blocked for secret file '${p.basename(resolved)}'. "
            'Enable allow_secrets on this profile if you intentionally need access.';
      }
    }
  }

  final parts = p.split(resolved);
  if (parts.any((part) => secretDirParts.contains(part.toLowerCase()))) {
    return "Access blocked inside sensitive directory '$label'. "
        'Enable allow_secrets on this profile if you intentionally need access.';
  }
  return null;
}

bool isBlockedSecretPath(String targetPath, {ServerConfig? config}) =>
    blockedSecretReason(targetPath, config: config) != null;

String? checkAccess(String targetPath, ServerConfig config) {
  final policy = getEffectivePolicy(config);
  final resolved = expandAndResolvePath(targetPath);
  final roots = policy.roots.map(expandAndResolvePath).toList();

  if (roots.isNotEmpty && !roots.any((r) => isWithin(resolved, r))) {
    final allowed = roots.join(', ');
    return "Access denied: '$resolved' is outside allowed roots [$allowed] for profile '${policy.profileName}'.";
  }

  if (!policy.allowSecrets) {
    final reason = blockedSecretReason(resolved, rawLabel: targetPath, config: config);
    if (reason != null) return reason;
  }
  return null;
}

bool _samePath(String a, String b) {
  final na = p.normalize(p.absolute(a));
  final nb = p.normalize(p.absolute(b));
  return Platform.isWindows ? na.toLowerCase() == nb.toLowerCase() : na == nb;
}

Map<String, dynamic> loadSavedConfig([File? configFile]) {
  final storage = StoragePaths.instance..ensureLayout();
  final file = configFile ?? storage.defaultConfigFile;
  if (!file.existsSync()) return <String, dynamic>{};
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {}
  return <String, dynamic>{};
}

void saveConfigFile(File configFile, Map<String, dynamic> data) {
  StoragePaths.instance.ensureLayout();
  configFile.parent.createSync(recursive: true);
  const encoder = JsonEncoder.withIndent('  ');
  configFile.writeAsStringSync('${encoder.convert(data)}\n', flush: true);
  if (!Platform.isWindows) {
    try {
      Process.runSync('chmod', ['600', configFile.path]);
    } catch (_) {}
  }
}

Map<String, dynamic> _dirStats(Directory dir) {
  var totalBytes = 0;
  var fileCount = 0;
  if (dir.existsSync()) {
    try {
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is File) {
          fileCount++;
          try {
            totalBytes += entity.lengthSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
  return {
    'path': dir.path,
    'files': fileCount,
    'bytes': totalBytes,
  };
}

Map<String, dynamic> getStorageStats() {
  final s = StoragePaths.instance..ensureLayout();
  return {
    'config': _dirStats(s.configDir),
    'data': _dirStats(s.dataDir),
    'cache': _dirStats(s.cacheDir),
    'logs': _dirStats(s.logsDir),
  };
}

Map<String, dynamic> cleanStorage(String target) {
  final s = StoragePaths.instance..ensureLayout();
  var removed = 0;
  if (target == 'cache') {
    if (s.cacheDir.existsSync()) {
      for (final item in s.cacheDir.listSync(followLinks: false)) {
        try {
          item.deleteSync(recursive: true);
          removed++;
        } catch (_) {}
      }
    }
    return {
      'ok': true,
      'target': target,
      'removed': removed,
      'message': '缓存已清理',
    };
  }

  if (target == 'logs') {
    if (s.logsDir.existsSync()) {
      for (final f in s.logsDir.listSync(recursive: true, followLinks: false)) {
        if (f is File) {
          try {
            f.deleteSync();
            removed++;
          } catch (_) {}
        }
      }
    }
    return {
      'ok': true,
      'target': target,
      'removed': removed,
      'message': '已清理 $removed 个日志文件',
    };
  }

  if (target == 'window') {
    if (s.windowStateFile.existsSync()) {
      try {
        s.windowStateFile.deleteSync();
        removed = 1;
      } catch (_) {}
    }
    return {
      'ok': true,
      'target': target,
      'removed': removed,
      'message': '窗口位置与尺寸已重置，下次启动生效',
    };
  }

  if (target == 'oauth') {
    if (s.oauthStateFile.existsSync()) {
      try {
        s.oauthStateFile.deleteSync();
        removed = 1;
      } catch (_) {}
    }
    return {
      'ok': true,
      'target': target,
      'removed': removed,
      'message': 'OAuth 持久化会话已清空，重启服务后生效',
    };
  }

  return {'ok': false, 'error': '未知清理目标: $target'};
}
