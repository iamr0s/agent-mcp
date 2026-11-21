import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import 'config.dart';
import 'logging_utils.dart';
import 'privileged_exec.dart';
import 'process_tools.dart';
import 'tool_types.dart';
import 'tunnel.dart';

final RegExp _cfTryUrlRe =
    RegExp(r'https://[a-z0-9-]+\.trycloudflare\.com', caseSensitive: false);

const Map<String, String> _mimeByExt = {
  '.html': 'text/html; charset=utf-8',
  '.htm': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/markdown; charset=utf-8',
  '.csv': 'text/csv; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.mp4': 'video/mp4',
  '.webm': 'video/webm',
  '.mov': 'video/quicktime',
  '.mkv': 'video/x-matroska',
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
  '.m4a': 'audio/mp4',
  '.ogg': 'audio/ogg',
  '.pdf': 'application/pdf',
  '.wasm': 'application/wasm',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.zip': 'application/zip',
  '.gz': 'application/gzip',
  '.apk': 'application/vnd.android.package-archive',
};

String _guessMimeType(String filePath) =>
    _mimeByExt[p.extension(filePath).toLowerCase()] ??
    'application/octet-stream';

bool _isVideoExt(String ext) =>
    const {'.mp4', '.webm', '.mov', '.mkv'}.contains(ext);
bool _isAudioExt(String ext) =>
    const {'.mp3', '.wav', '.m4a', '.ogg'}.contains(ext);
bool _isImageExt(String ext) =>
    const {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg'}.contains(ext);

String _htmlEscape(String s) => const HtmlEscape().convert(s);

String _formatHumanBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(2)} MB';
  return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
}

String _generateShareId() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
  final rng = Random.secure();
  final body = List.generate(12, (_) => chars[rng.nextInt(chars.length)]).join();
  return 'sh_$body';
}

File? findTailscaleCli() {
  if (Platform.isAndroid) return null;
  final exe = Platform.isWindows ? 'tailscale.exe' : 'tailscale';
  final pathEnv = Platform.environment['PATH'] ?? '';
  final sep = Platform.isWindows ? ';' : ':';
  for (final dir in pathEnv.split(sep)) {
    final d = dir.trim();
    if (d.isEmpty) continue;
    final cand = File(p.join(d, exe));
    if (cand.existsSync()) return cand;
  }
  if (Platform.isWindows) {
    for (final sp in const [
      r'C:\Program Files\Tailscale\tailscale.exe',
      r'C:\Program Files (x86)\Tailscale\tailscale.exe',
    ]) {
      final f = File(sp);
      if (f.existsSync()) return f;
    }
  } else if (Platform.isMacOS) {
    for (final sp in const [
      '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
      '/opt/homebrew/bin/tailscale',
      '/usr/local/bin/tailscale',
    ]) {
      final f = File(sp);
      if (f.existsSync()) return f;
    }
  } else {
    for (final sp in const ['/usr/bin/tailscale', '/usr/local/bin/tailscale']) {
      final f = File(sp);
      if (f.existsSync()) return f;
    }
  }
  return null;
}

class TailscaleRuntimeStatus {
  final bool cliInstalled;
  final String cliPath;
  final bool daemonRunning;
  final String backendState;
  final String dnsName;
  final List<String> tailscaleIps;
  final String error;

  const TailscaleRuntimeStatus({
    required this.cliInstalled,
    required this.cliPath,
    required this.daemonRunning,
    required this.backendState,
    required this.dnsName,
    required this.tailscaleIps,
    this.error = '',
  });

  bool get hasAnyTailscaleReachability =>
      daemonRunning || tailscaleIps.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'cli_installed': cliInstalled,
        'cli_path': cliPath,
        'daemon_running': daemonRunning,
        'backend_state': backendState,
        'dns_name': dnsName,
        'tailscale_ips': tailscaleIps,
        'reachable': hasAnyTailscaleReachability,
        if (error.isNotEmpty) 'error': error,
      };
}

class ExposureItem {
  final String id;
  final String kind; // 'file' | 'dir' | 'port'
  final String target;
  final int? targetPort;
  final String label;
  final String scope; // 'auto' | 'tailscale' | 'public' | 'lan'
  final bool spa;
  final int createdAtMs;
  final int? expiresAtMs;

  int hitCount = 0;
  int bytesSent = 0;
  int? lastAccessAtMs;

  String tailscaleHttpsUrl = '';
  List<String>? tailscaleCleanupArgs;

  Process? cloudflaredProc;
  String cloudflaredUrl = '';
  String cloudflaredError = '';

  ExposureItem({
    required this.id,
    required this.kind,
    required this.target,
    this.targetPort,
    required this.label,
    required this.scope,
    this.spa = false,
    required this.createdAtMs,
    this.expiresAtMs,
  });

  bool get isExpired =>
      expiresAtMs != null &&
      DateTime.now().millisecondsSinceEpoch >= expiresAtMs!;

  int? get remainingSeconds {
    if (expiresAtMs == null) return null;
    final diff = (expiresAtMs! - DateTime.now().millisecondsSinceEpoch) ~/ 1000;
    return diff < 0 ? 0 : diff;
  }
}

class ExposureManager {
  static final ExposureManager instance = ExposureManager._();
  ExposureManager._();

  final Map<String, ExposureItem> _items = {};
  Timer? _sweepTimer;

  TailscaleRuntimeStatus? _cachedTsStatus;
  int _cachedTsAtMs = 0;

  int get activeCount {
    _purgeExpiredSync();
    return _items.length;
  }

  void _ensureSweepTimer() {
    _sweepTimer ??= Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(purgeExpired());
    });
  }

  void _purgeExpiredSync() {
    final expiredIds =
        _items.values.where((e) => e.isExpired).map((e) => e.id).toList();
    for (final id in expiredIds) {
      unawaited(closeExposure(id, reason: 'expired'));
    }
  }

  Future<void> purgeExpired() async {
    final expiredIds =
        _items.values.where((e) => e.isExpired).map((e) => e.id).toList();
    for (final id in expiredIds) {
      await closeExposure(id, reason: 'expired');
    }
  }

  static bool isExposureEnabledInSaved(Map<String, dynamic> saved) =>
      saved['expose_enabled'] != false;

  static bool isTailscaleEnabledInSaved(Map<String, dynamic> saved) =>
      saved['expose_tailscale_enabled'] != false;

  static String tailscaleModeInSaved(Map<String, dynamic> saved) {
    final v = (saved['expose_tailscale_mode'] ?? 'funnel')
        .toString()
        .trim()
        .toLowerCase();
    return v == 'serve' || v == 'tailnet' ? 'tailnet' : 'funnel';
  }

  static bool isCloudflaredFallbackInSaved(Map<String, dynamic> saved) =>
      saved['expose_cloudflared_fallback'] != false;

  static int defaultTtlMinutesInSaved(Map<String, dynamic> saved) {
    final raw = saved['expose_default_ttl_minutes'];
    if (raw is int) return raw.clamp(0, 10080);
    final parsed = int.tryParse('${raw ?? ''}');
    return (parsed ?? 120).clamp(0, 10080);
  }

  Future<TailscaleRuntimeStatus> probeTailscaleStatus({
    bool forceRefresh = false,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!forceRefresh &&
        _cachedTsStatus != null &&
        (now - _cachedTsAtMs) < 6000) {
      return _cachedTsStatus!;
    }

    final netIfaces = await listHostNetworkInterfaces();
    final nicTsIps = <String>[];
    for (final iface in netIfaces) {
      final ip = (iface['ip'] ?? '').toString().trim();
      final kind = (iface['kind'] ?? '').toString();
      if (ip.startsWith('100.') && kind != 'tun_proxy') {
        if (!nicTsIps.contains(ip)) nicTsIps.add(ip);
      }
    }

    final cli = findTailscaleCli();
    if (cli == null) {
      final st = TailscaleRuntimeStatus(
        cliInstalled: false,
        cliPath: '',
        daemonRunning: nicTsIps.isNotEmpty,
        backendState: nicTsIps.isNotEmpty ? 'InterfaceActive' : 'NotInstalled',
        dnsName: '',
        tailscaleIps: nicTsIps,
      );
      _cachedTsStatus = st;
      _cachedTsAtMs = now;
      return st;
    }

    try {
      final res = await Process.run(
        cli.path,
        const ['status', '--json'],
      ).timeout(const Duration(seconds: 4));

      if (res.exitCode == 0) {
        final decoded = jsonDecode(res.stdout.toString());
        if (decoded is Map) {
          final backendState =
              (decoded['BackendState'] ?? '').toString().trim();
          final selfMap = decoded['Self'] is Map
              ? Map<String, dynamic>.from(decoded['Self'] as Map)
              : const <String, dynamic>{};
          var dns = (selfMap['DNSName'] ?? '').toString().trim();
          if (dns.endsWith('.')) dns = dns.substring(0, dns.length - 1);
          final ips = <String>[...nicTsIps];
          final rawTsIps = selfMap['TailscaleIPs'];
          if (rawTsIps is List) {
            for (final rawIp in rawTsIps) {
              final s = rawIp.toString().trim();
              if (s.isNotEmpty && !s.contains(':') && !ips.contains(s)) {
                ips.add(s);
              }
            }
          }
          final running = backendState.toLowerCase() == 'running';
          final st = TailscaleRuntimeStatus(
            cliInstalled: true,
            cliPath: cli.path,
            daemonRunning: running || ips.isNotEmpty,
            backendState: backendState.isEmpty ? 'Unknown' : backendState,
            dnsName: dns,
            tailscaleIps: ips,
          );
          _cachedTsStatus = st;
          _cachedTsAtMs = now;
          return st;
        }
      }

      final errOut = '${res.stderr}\n${res.stdout}'.trim();
      final st = TailscaleRuntimeStatus(
        cliInstalled: true,
        cliPath: cli.path,
        daemonRunning: nicTsIps.isNotEmpty,
        backendState: nicTsIps.isNotEmpty ? 'InterfaceOnly' : 'Stopped',
        dnsName: '',
        tailscaleIps: nicTsIps,
        error: errOut.split(RegExp(r'\r?\n')).first,
      );
      _cachedTsStatus = st;
      _cachedTsAtMs = now;
      return st;
    } catch (e) {
      final st = TailscaleRuntimeStatus(
        cliInstalled: true,
        cliPath: cli.path,
        daemonRunning: nicTsIps.isNotEmpty,
        backendState: nicTsIps.isNotEmpty ? 'InterfaceOnly' : 'Stopped',
        dnsName: '',
        tailscaleIps: nicTsIps,
        error: '$e',
      );
      _cachedTsStatus = st;
      _cachedTsAtMs = now;
      return st;
    }
  }

  Future<(String url, List<String>? cleanupArgs)> _tryMountTailscale({
    required TailscaleRuntimeStatus tsStatus,
    required String shareId,
    required int mcpPort,
    required bool allowPublicFunnel,
  }) async {
    if (!tsStatus.cliInstalled ||
        tsStatus.backendState.toLowerCase() != 'running' ||
        tsStatus.dnsName.isEmpty) {
      return ('', null);
    }

    final cliPath = tsStatus.cliPath;
    final mountPath = '/share/$shareId';
    final localTarget = 'http://127.0.0.1:$mcpPort$mountPath';

    if (allowPublicFunnel) {
      try {
        final r = await Process.run(cliPath, [
          'funnel',
          '--bg',
          '--yes',
          '--https=443',
          '--set-path=$mountPath',
          localTarget,
        ]).timeout(const Duration(seconds: 6));
        if (r.exitCode == 0) {
          return (
            'https://${tsStatus.dnsName}$mountPath',
            ['funnel', '--https=443', '--set-path=$mountPath', 'off'],
          );
        }
      } catch (_) {}
    }

    try {
      final r = await Process.run(cliPath, [
        'serve',
        '--bg',
        '--yes',
        '--https=443',
        '--set-path=$mountPath',
        localTarget,
      ]).timeout(const Duration(seconds: 6));
      if (r.exitCode == 0) {
        return (
          'https://${tsStatus.dnsName}$mountPath',
          ['serve', '--https=443', '--set-path=$mountPath', 'off'],
        );
      }
    } catch (_) {}

    return ('', null);
  }

  Future<(Process? proc, String url, String error)> _startQuickCloudflared({
    required String targetLocalUrl,
  }) async {
    final cf = findCloudflared();
    if (cf == null) {
      return (null, '', '未安装 cloudflared，已跳过临时公网域名');
    }
    try {
      final proc = await Process.start(
        cf.path,
        ['tunnel', '--url', targetLocalUrl, '--no-autoupdate'],
      );
      Win32ProcessJobGuard.instance.attachPid(proc.pid);

      final completer = Completer<String>();
      void scanLine(String line) {
        final m = _cfTryUrlRe.firstMatch(line);
        if (m != null && !completer.isCompleted) {
          completer.complete(m.group(0)!);
        }
      }

      proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(scanLine, onError: (_) {});
      proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(scanLine, onError: (_) {});
      unawaited(proc.exitCode.then((_) {
        if (!completer.isCompleted) completer.complete('');
      }));

      final url = await completer.future.timeout(
        const Duration(seconds: 12),
        onTimeout: () => '',
      );
      if (url.isEmpty) {
        try {
          proc.kill();
        } catch (_) {}
        return (null, '', '申请临时公网隧道超时');
      }
      return (proc, url, '');
    } catch (e) {
      return (null, '', '启动临时公网隧道失败: $e');
    }
  }
  List<String> _discoverActivePublicGatewayBases(Map<String, dynamic> saved) {
    final out = <String>[];
    final tunnelStatuses = TunnelManager.instance.getStatuses();
    final profiles = ensureProfilesInConfig(saved);

    for (final p in profiles) {
      if (p['enabled'] == false) continue;
      final pid = (p['id'] ?? '').toString();
      final tmode = (p['tunnel_mode'] ?? 'none').toString().toLowerCase();
      final tst = tunnelStatuses[pid];
      final tunnelRunning = tst is Map && tst['running'] == true;

      if (tmode == 'quick' && tunnelRunning) {
        final liveUrl = (tst['url'] ?? '').toString().trim();
        if (liveUrl.startsWith('https://') && !out.contains(liveUrl)) {
          out.add(liveUrl.replaceAll(RegExp(r'/+$'), ''));
        }
      } else if (tmode == 'token' && tunnelRunning) {
        final base = (p['base_url'] ?? '').toString().trim();
        if (base.startsWith('https://') && !out.contains(base)) {
          out.add(base.replaceAll(RegExp(r'/+$'), ''));
        }
      } else if (tmode == 'none') {
        final manuals = p['manual_urls'];
        if (manuals is List) {
          for (final raw in manuals) {
            final u = raw.toString().trim().replaceAll(RegExp(r'/+$'), '');
            if (u.startsWith('https://') && !out.contains(u)) {
              out.add(u);
            }
          }
        }
      }
    }
    return out;
  }

  Future<Map<String, dynamic>> serializeItem(
    ExposureItem item,
    ServerConfig config, {
    Map<String, dynamic>? savedOverride,
    TailscaleRuntimeStatus? tsOverride,
    List<Map<String, String>>? ifacesOverride,
  }) async {
    final saved = savedOverride ?? loadSavedConfig(config.configFile);
    final livePort =
        int.tryParse('${saved['port'] ?? config.port}') ?? config.port;
    final tsEnabled = isTailscaleEnabledInSaved(saved);
    final ts = tsOverride ?? await probeTailscaleStatus();
    final ifaces = ifacesOverride ?? await listHostNetworkInterfaces();
    final bindHosts = parseBindHosts(saved['hosts'], saved['host']);
    final bindsAll = bindHosts.contains('0.0.0.0') || bindHosts.contains('::');

    final shareSuffix =
        item.kind == 'dir' ? '/share/${item.id}/' : '/share/${item.id}';
    final rawFileSuffix = item.kind == 'file'
        ? '/share/${item.id}/${Uri.encodeComponent(p.basename(item.target))}'
        : shareSuffix;

    final publicUrls = <String>[];
    final tailscaleUrls = <String>[];
    final lanUrls = <String>[];

    if (item.cloudflaredUrl.isNotEmpty) {
      final cfFull = item.kind == 'port'
          ? item.cloudflaredUrl
          : '${item.cloudflaredUrl}$shareSuffix';
      if (!publicUrls.contains(cfFull)) publicUrls.add(cfFull);
    }

    if (tsEnabled && item.tailscaleHttpsUrl.isNotEmpty) {
      final u = item.kind == 'dir' && !item.tailscaleHttpsUrl.endsWith('/')
          ? '${item.tailscaleHttpsUrl}/'
          : item.tailscaleHttpsUrl;
      if (item.tailscaleCleanupArgs != null &&
          item.tailscaleCleanupArgs!.isNotEmpty &&
          item.tailscaleCleanupArgs!.first == 'funnel') {
        if (!publicUrls.contains(u)) publicUrls.add(u);
      }
      if (!tailscaleUrls.contains(u)) tailscaleUrls.add(u);
    }

    if (item.scope != 'tailscale' && item.scope != 'lan') {
      for (final base in _discoverActivePublicGatewayBases(saved)) {
        final u = '$base$shareSuffix';
        if (!publicUrls.contains(u)) publicUrls.add(u);
      }
    }

    if (tsEnabled) {
      for (final ip in ts.tailscaleIps) {
        if (bindsAll || bindHosts.contains(ip)) {
          final u = 'http://$ip:$livePort$shareSuffix';
          if (!tailscaleUrls.contains(u)) tailscaleUrls.add(u);
        }
        if (item.kind == 'port' && item.targetPort != null) {
          final directPortUrl = 'http://$ip:${item.targetPort}';
          if (!tailscaleUrls.contains(directPortUrl)) {
            tailscaleUrls.add(directPortUrl);
          }
        }
      }
    }

    for (final iface in ifaces) {
      final ip = (iface['ip'] ?? '').toString().trim();
      final kind = (iface['kind'] ?? '').toString();
      if (kind == 'lan' && ip.isNotEmpty) {
        if (bindsAll || bindHosts.contains(ip)) {
          final u = 'http://$ip:$livePort$shareSuffix';
          if (!lanUrls.contains(u)) lanUrls.add(u);
        }
      }
    }

    final loopbackUrl = 'http://127.0.0.1:$livePort$shareSuffix';

    String primaryUrl = loopbackUrl;
    if (item.scope == 'tailscale') {
      primaryUrl = tailscaleUrls.isNotEmpty
          ? tailscaleUrls.first
          : (lanUrls.isNotEmpty ? lanUrls.first : loopbackUrl);
    } else if (item.scope == 'lan') {
      primaryUrl = lanUrls.isNotEmpty
          ? lanUrls.first
          : (tailscaleUrls.isNotEmpty ? tailscaleUrls.first : loopbackUrl);
    } else {
      if (publicUrls.isNotEmpty) {
        primaryUrl = publicUrls.first;
      } else if (tailscaleUrls.isNotEmpty) {
        primaryUrl = tailscaleUrls.first;
      } else if (lanUrls.isNotEmpty) {
        primaryUrl = lanUrls.first;
      }
    }

    String? directMediaUrl;
    if (item.kind == 'file') {
      if (primaryUrl.endsWith('/share/${item.id}')) {
        final basePrefix = primaryUrl.substring(
          0,
          primaryUrl.length - '/share/${item.id}'.length,
        );
        directMediaUrl = '$basePrefix$rawFileSuffix';
      } else {
        directMediaUrl = 'http://127.0.0.1:$livePort$rawFileSuffix';
      }
    }

    final allUrls = <String>[
      ...publicUrls,
      ...tailscaleUrls.where((u) => !publicUrls.contains(u)),
      ...lanUrls,
      loopbackUrl,
    ];

    return {
      'id': item.id,
      'kind': item.kind,
      'label': item.label,
      'target': item.target,
      if (item.targetPort != null) 'port': item.targetPort,
      'scope': item.scope,
      'spa': item.spa,
      'primary_url': primaryUrl,
      if (directMediaUrl != null) 'direct_file_url': directMediaUrl,
      'public_urls': publicUrls,
      'tailscale_urls': tailscaleUrls,
      'lan_urls': lanUrls,
      'loopback_url': loopbackUrl,
      'all_urls': allUrls,
      'hit_count': item.hitCount,
      'bytes_sent': item.bytesSent,
      'bytes_sent_human': _formatHumanBytes(item.bytesSent),
      'created_at_ms': item.createdAtMs,
      'expires_at_ms': item.expiresAtMs,
      'remaining_seconds': item.remainingSeconds,
      if (item.cloudflaredError.isNotEmpty)
        'tunnel_note': item.cloudflaredError,
    };
  }

  Future<Map<String, dynamic>> openExposure({
    required ServerConfig config,
    required String rawTarget,
    int? portOverride,
    String scope = 'auto',
    String? label,
    int? ttlMinutes,
    bool spa = false,
    bool validateWithPolicy = true,
  }) async {
    _ensureSweepTimer();
    await purgeExpired();

    final saved = loadSavedConfig(config.configFile);
    if (!isExposureEnabledInSaved(saved)) {
      throw StateError('外网分享功能已在控制台「服务配置」中关闭，请先开启后再创建分享。');
    }

    final normScope = scope.trim().toLowerCase();
    final effectiveScope =
        const {'auto', 'tailscale', 'public', 'lan'}.contains(normScope)
            ? normScope
            : 'auto';

    final effTtl = ttlMinutes ?? defaultTtlMinutesInSaved(saved);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final expMs = effTtl > 0 ? nowMs + effTtl * 60 * 1000 : null;

    String kind;
    String resolvedTarget;
    int? targetPort = portOverride;
    String defaultLabel;

    final trimmed = rawTarget.trim();
    final portOnly = targetPort ?? int.tryParse(trimmed);
    if (portOnly != null && portOnly >= 1 && portOnly <= 65535) {
      kind = 'port';
      targetPort = portOnly;
      resolvedTarget = 'http://127.0.0.1:$portOnly';
      defaultLabel = '本地端口 :$portOnly';
    } else if (trimmed.startsWith('http://127.0.0.1:') ||
        trimmed.startsWith('http://localhost:')) {
      final uri = Uri.parse(trimmed);
      kind = 'port';
      targetPort = uri.hasPort ? uri.port : 80;
      resolvedTarget = 'http://127.0.0.1:$targetPort';
      defaultLabel = '本地服务 :$targetPort';
    } else {
      if (trimmed.isEmpty) {
        throw ArgumentError('请填写要分享的本地文件路径、网页文件夹或本地端口号（如 3000）。');
      }
      final policy = getEffectivePolicy(config);
      final checkedPath = normalizePath(trimmed, policy.roots);
      if (validateWithPolicy) {
        final deny = checkAccess(checkedPath, config);
        if (deny != null) throw FileSystemException(deny, checkedPath);
      }
      final st = await PrivFs.stat(checkedPath);
      if (!st.exists) {
        throw FileSystemException('找不到目标文件或目录', checkedPath);
      }
      if (st.isDirectory) {
        kind = 'dir';
        resolvedTarget = checkedPath;
        defaultLabel = '网页目录 ${p.basename(checkedPath)}';
      } else {
        kind = 'file';
        resolvedTarget = checkedPath;
        defaultLabel = p.basename(checkedPath);
      }
    }

    final id = _generateShareId();
    final item = ExposureItem(
      id: id,
      kind: kind,
      target: resolvedTarget,
      targetPort: targetPort,
      label:
          (label != null && label.trim().isNotEmpty) ? label.trim() : defaultLabel,
      scope: effectiveScope,
      spa: spa,
      createdAtMs: nowMs,
      expiresAtMs: expMs,
    );

    final livePort =
        int.tryParse('${saved['port'] ?? config.port}') ?? config.port;
    final tsEnabled = isTailscaleEnabledInSaved(saved);
    final tsMode = tailscaleModeInSaved(saved);
    final tsStatus = await probeTailscaleStatus(forceRefresh: true);

    if (tsEnabled && effectiveScope != 'lan') {
      final allowFunnel = effectiveScope != 'tailscale' && tsMode == 'funnel';
      final (tsUrl, cleanupArgs) = await _tryMountTailscale(
        tsStatus: tsStatus,
        shareId: id,
        mcpPort: livePort,
        allowPublicFunnel: allowFunnel,
      );
      if (tsUrl.isNotEmpty) {
        item.tailscaleHttpsUrl = tsUrl;
        item.tailscaleCleanupArgs = cleanupArgs;
      }
    }

    final existingPubBases = _discoverActivePublicGatewayBases(saved);
    final hasFunnelPublic = item.tailscaleHttpsUrl.isNotEmpty &&
        item.tailscaleCleanupArgs != null &&
        item.tailscaleCleanupArgs!.isNotEmpty &&
        item.tailscaleCleanupArgs!.first == 'funnel';

    final cfAllowed = isCloudflaredFallbackInSaved(saved);
    final wantPublic =
        effectiveScope == 'public' || (effectiveScope == 'auto' && cfAllowed);
    final needCf = wantPublic &&
        ((kind == 'port' && !hasFunnelPublic) ||
            (existingPubBases.isEmpty && !hasFunnelPublic));

    if (needCf) {
      final localUrlForCf =
          kind == 'port' ? resolvedTarget : 'http://127.0.0.1:$livePort';
      final (proc, cfUrl, cfErr) = await _startQuickCloudflared(
        targetLocalUrl: localUrlForCf,
      );
      item.cloudflaredProc = proc;
      item.cloudflaredUrl = cfUrl;
      if (cfUrl.isEmpty && cfErr.isNotEmpty && existingPubBases.isEmpty) {
        item.cloudflaredError = cfErr;
      }
    }

    _items[id] = item;

    final serialized = await serializeItem(
      item,
      config,
      savedOverride: saved,
      tsOverride: tsStatus,
    );

    StructuredEventBus.instance.emit({
      'kind': 'info',
      'badge': '外网分享',
      'level': 'INFO',
      'summary': '已开启外网分享 [${item.label}] -> ${serialized['primary_url']}',
    });

    return serialized;
  }

  Future<bool> closeExposure(String id, {String reason = 'manual'}) async {
    final item = _items.remove(id.trim());
    if (item == null) return false;

    if (item.cloudflaredProc != null) {
      try {
        item.cloudflaredProc!.kill();
      } catch (_) {}
      item.cloudflaredProc = null;
    }

    if (item.tailscaleCleanupArgs != null &&
        item.tailscaleCleanupArgs!.isNotEmpty) {
      final cli = findTailscaleCli();
      if (cli != null) {
        try {
          await Process.run(cli.path, item.tailscaleCleanupArgs!)
              .timeout(const Duration(seconds: 4));
        } catch (_) {}
      }
    }

    StructuredEventBus.instance.emit({
      'kind': 'info',
      'badge': '外网分享',
      'level': 'INFO',
      'summary':
          '已关闭外网分享 [${item.label}] (${reason == 'expired' ? '到期自动回收' : '手动关闭'})',
    });
    return true;
  }

  Future<int> closeAllExposures() async {
    final ids = _items.keys.toList();
    var count = 0;
    for (final id in ids) {
      if (await closeExposure(id)) count++;
    }
    return count;
  }

  Future<Map<String, dynamic>> getDashboardSummary(ServerConfig config) async {
    await purgeExpired();
    final saved = loadSavedConfig(config.configFile);
    final ts = await probeTailscaleStatus();
    final ifaces = await listHostNetworkInterfaces();
    final pubBases = _discoverActivePublicGatewayBases(saved);
    final cfInstalled = findCloudflared() != null;

    final list = <Map<String, dynamic>>[];
    final sorted = _items.values.toList()
      ..sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
    for (final item in sorted) {
      list.add(
        await serializeItem(
          item,
          config,
          savedOverride: saved,
          tsOverride: ts,
          ifacesOverride: ifaces,
        ),
      );
    }

    return {
      'enabled': isExposureEnabledInSaved(saved),
      'tailscale_enabled': isTailscaleEnabledInSaved(saved),
      'tailscale_mode': tailscaleModeInSaved(saved),
      'cloudflared_fallback': isCloudflaredFallbackInSaved(saved),
      'default_ttl_minutes': defaultTtlMinutesInSaved(saved),
      'tailscale_status': ts.toJson(),
      'public_gateway_bases': pubBases,
      'cloudflared_installed': cfInstalled,
      'active_count': list.length,
      'items': list,
    };
  }
  Future<Response?> tryHandleShareRequest(
    Request req, {
    required ServerConfig config,
  }) async {
    final path = req.url.path;
    if (path != 'share' && !path.startsWith('share/')) {
      return null;
    }

    final saved = loadSavedConfig(config.configFile);
    if (!isExposureEnabledInSaved(saved)) {
      return Response.forbidden(
        '外网分享功能已在控制台设置中关闭。',
        headers: const {'content-type': 'text/plain; charset=utf-8'},
      );
    }

    final segments = req.url.pathSegments;
    if (segments.length < 2) {
      return Response.notFound('Share ID missing.');
    }

    final id = segments[1];
    final item = _items[id];
    if (item == null || item.isExpired) {
      if (item != null && item.isExpired) {
        unawaited(closeExposure(id, reason: 'expired'));
      }
      return Response.notFound(
        _renderExpiredHtml(),
        headers: const {'content-type': 'text/html; charset=utf-8'},
      );
    }

    if (item.scope == 'tailscale' || item.scope == 'lan') {
      final cfIp = req.headers['cf-connecting-ip'] ?? '';
      final fwdHost = (req.headers['x-forwarded-host'] ??
              req.headers['host'] ??
              '')
          .toLowerCase();
      if (cfIp.isNotEmpty || fwdHost.endsWith('.trycloudflare.com')) {
        return Response.forbidden(
          '该链接仅限局域网或 Tailscale 组网内设备访问。',
          headers: const {'content-type': 'text/plain; charset=utf-8'},
        );
      }
    }

    item.hitCount++;
    item.lastAccessAtMs = DateTime.now().millisecondsSinceEpoch;

    final subSegments = segments.sublist(2);

    if (item.kind == 'file') {
      return _serveSingleFile(req, item, subSegments);
    }
    if (item.kind == 'dir') {
      final rawReqPath = req.requestedUri.path;
      if (subSegments.isEmpty && !rawReqPath.endsWith('/')) {
        final q = req.requestedUri.hasQuery ? '?${req.requestedUri.query}' : '';
        return Response.found('$rawReqPath/$q');
      }
      return _serveDirectory(req, item, subSegments);
    }
    if (item.kind == 'port' && item.targetPort != null) {
      return _proxyLocalPort(req, item, subSegments);
    }

    return Response.notFound('Unsupported share item.');
  }

  Future<Response> _serveSingleFile(
    Request req,
    ExposureItem item,
    List<String> subSegments,
  ) async {
    final fileName = p.basename(item.target);
    final ext = p.extension(fileName).toLowerCase();
    final wantRaw = req.url.queryParameters['raw'] == '1' ||
        req.url.queryParameters['download'] == '1' ||
        subSegments.isNotEmpty ||
        !(req.headers['accept'] ?? '').contains('text/html') ||
        ext == '.html' ||
        ext == '.htm';

    final forceDownload = req.url.queryParameters['download'] == '1';

    if (!wantRaw &&
        (_isVideoExt(ext) || _isAudioExt(ext) || _isImageExt(ext))) {
      final stat = await PrivFs.stat(item.target);
      final rawHref =
          '/share/${item.id}/${Uri.encodeComponent(fileName)}?raw=1';
      final dlHref =
          '/share/${item.id}/${Uri.encodeComponent(fileName)}?download=1';
      final html = _renderMediaLandingHtml(
        title: item.label,
        fileName: fileName,
        sizeHuman: _formatHumanBytes(stat.size),
        ext: ext,
        rawHref: rawHref,
        dlHref: dlHref,
      );
      final bytes = utf8.encode(html);
      item.bytesSent += bytes.length;
      return Response.ok(
        bytes,
        headers: const {
          'content-type': 'text/html; charset=utf-8',
          'cache-control': 'no-store',
        },
      );
    }

    return _streamFileWithRange(
      req,
      item,
      item.target,
      forceDownload: forceDownload,
    );
  }

  Future<Response> _serveDirectory(
    Request req,
    ExposureItem item,
    List<String> subSegments,
  ) async {
    final rootPath = p.canonicalize(item.target);
    final relParts = subSegments.where((s) => s.isNotEmpty).toList();
    final candidatePath = relParts.isEmpty
        ? rootPath
        : p.normalize(p.joinAll([rootPath, ...relParts]));

    if (candidatePath != rootPath && !p.isWithin(rootPath, candidatePath)) {
      return Response.forbidden('Forbidden path traversal.');
    }

    final candStat = await PrivFs.stat(candidatePath);
    if (candStat.isDirectory) {
      final indexHtml = p.join(candidatePath, 'index.html');
      if ((await PrivFs.stat(indexHtml)).isFile) {
        return _streamFileWithRange(req, item, indexHtml);
      }
      return _renderDirectoryListing(item, candidatePath, relParts);
    }

    if (!candStat.exists && item.spa) {
      final spaIndex = p.join(rootPath, 'index.html');
      if ((await PrivFs.stat(spaIndex)).isFile) {
        return _streamFileWithRange(req, item, spaIndex);
      }
    }

    if (!candStat.isFile) {
      return Response.notFound('File not found.');
    }

    return _streamFileWithRange(req, item, candidatePath);
  }

  Future<Response> _renderDirectoryListing(
    ExposureItem item,
    String dirPath,
    List<String> relParts,
  ) async {
    final entries = await PrivFs.listDir(dirPath);
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    final rows = StringBuffer();
    if (relParts.isNotEmpty) {
      rows.writeln('<li><a href="../">📁 .. (返回上级)</a><span></span></li>');
    }
    for (final e in entries) {
      final slash = e.isDirectory ? '/' : '';
      final href = '${Uri.encodeComponent(e.name)}$slash';
      final icon = e.isDirectory ? '📁' : '📄';
      final meta = e.isDirectory ? '目录' : _formatHumanBytes(e.size);
      rows.writeln(
        '<li><a href="$href">$icon ${_htmlEscape(e.name)}$slash</a><span>$meta</span></li>',
      );
    }

    final relDisplay = relParts.isEmpty ? '/' : '/${relParts.join('/')}/';
    final html = '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>${_htmlEscape(item.label)} · 文件浏览</title>'
        '<style>body{margin:0;padding:28px 16px;background:#FAF9F5;color:#141413;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}'
        '.wrap{max-width:760px;margin:0 auto;background:#FFF;border:1px solid #E6E3DA;border-radius:18px;padding:22px 24px;box-shadow:0 6px 24px rgba(20,20,19,.05)}'
        'h1{margin:0 0 4px;font-size:19px}.sub{color:#737068;font-size:13px;font-family:monospace;margin-bottom:16px}'
        'ul{list-style:none;padding:0;margin:0}li{display:flex;justify-content:space-between;align-items:center;padding:10px 8px;border-top:1px solid #F0EEE6;font-size:14px}'
        'a{color:#141413;text-decoration:none;word-break:break-all}a:hover{color:#D97757}span{color:#87847B;font-size:12px;font-family:monospace;margin-left:12px;white-space:nowrap}</style>'
        '</head><body><div class="wrap"><h1>${_htmlEscape(item.label)}</h1>'
        '<div class="sub">${_htmlEscape(relDisplay)}</div><ul>$rows</ul></div></body></html>';
    final bytes = utf8.encode(html);
    item.bytesSent += bytes.length;
    return Response.ok(
      bytes,
      headers: const {'content-type': 'text/html; charset=utf-8'},
    );
  }

  Future<Response> _streamFileWithRange(
    Request req,
    ExposureItem item,
    String filePath, {
    bool forceDownload = false,
  }) async {
    final mime = _guessMimeType(filePath);
    final fileName = p.basename(filePath);
    final encodedName = Uri.encodeComponent(fileName);
    final dispType = forceDownload ? 'attachment' : 'inline';

    final localFile = File(filePath);
    var directReadable = false;
    int totalLen = 0;
    try {
      if (await localFile.exists()) {
        totalLen = await localFile.length();
        directReadable = true;
      }
    } catch (_) {
      directReadable = false;
    }

    if (!directReadable) {
      final bytes = await PrivFs.readBytes(filePath);
      totalLen = bytes.length;
      item.bytesSent += totalLen;
      return Response.ok(
        bytes,
        headers: {
          'content-type': mime,
          'content-length': '$totalLen',
          'accept-ranges': 'bytes',
          'content-disposition': "$dispType; filename*=UTF-8''$encodedName",
          'access-control-allow-origin': '*',
        },
      );
    }

    final baseHeaders = <String, String>{
      'content-type': mime,
      'accept-ranges': 'bytes',
      'content-disposition': "$dispType; filename*=UTF-8''$encodedName",
      'access-control-allow-origin': '*',
    };

    if (req.method == 'HEAD') {
      return Response.ok(
        const <int>[],
        headers: {...baseHeaders, 'content-length': '$totalLen'},
      );
    }

    final rangeHdr = req.headers['range'];
    if (rangeHdr != null && rangeHdr.startsWith('bytes=') && totalLen > 0) {
      final spec = rangeHdr.substring(6).split(',').first.trim();
      final dash = spec.indexOf('-');
      if (dash >= 0) {
        final startStr = spec.substring(0, dash).trim();
        final endStr = spec.substring(dash + 1).trim();
        int start;
        int end;
        if (startStr.isEmpty) {
          final suffixLen = int.tryParse(endStr) ?? 0;
          start = (totalLen - suffixLen).clamp(0, totalLen - 1);
          end = totalLen - 1;
        } else {
          start = int.tryParse(startStr) ?? 0;
          end = endStr.isEmpty
              ? totalLen - 1
              : (int.tryParse(endStr) ?? (totalLen - 1));
        }

        if (start < 0 || start >= totalLen || end < start) {
          return Response(
            416,
            headers: {...baseHeaders, 'content-range': 'bytes */$totalLen'},
          );
        }
        if (end >= totalLen) end = totalLen - 1;
        final chunkLen = end - start + 1;
        item.bytesSent += chunkLen;

        return Response(
          206,
          body: localFile.openRead(start, end + 1),
          headers: {
            ...baseHeaders,
            'content-range': 'bytes $start-$end/$totalLen',
            'content-length': '$chunkLen',
          },
          context: const {'shelf.io.buffer_output': false},
        );
      }
    }

    item.bytesSent += totalLen;
    return Response.ok(
      localFile.openRead(),
      headers: {...baseHeaders, 'content-length': '$totalLen'},
      context: const {'shelf.io.buffer_output': false},
    );
  }

  Future<Response> _proxyLocalPort(
    Request req,
    ExposureItem item,
    List<String> subSegments,
  ) async {
    final port = item.targetPort!;
    final subPath = '/${subSegments.join('/')}';
    final query = req.requestedUri.hasQuery ? '?${req.requestedUri.query}' : '';
    final upstreamUri = Uri.parse('http://127.0.0.1:$port$subPath$query');

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..findProxy = (_) => 'DIRECT';
    try {
      final upReq = await client.openUrl(req.method, upstreamUri);
      upReq.followRedirects = false;
      req.headers.forEach((k, v) {
        final lower = k.toLowerCase();
        if (lower == 'host' ||
            lower == 'connection' ||
            lower == 'content-length' ||
            lower == 'transfer-encoding') {
          return;
        }
        upReq.headers.set(k, v);
      });
      upReq.headers.set('x-forwarded-prefix', '/share/${item.id}');

      if (req.method != 'GET' && req.method != 'HEAD') {
        await upReq.addStream(req.read());
      }
      final upRes = await upReq.close();

      final outHeaders = <String, String>{};
      upRes.headers.forEach((name, values) {
        final lower = name.toLowerCase();
        if (lower == 'transfer-encoding' || lower == 'connection') return;
        outHeaders[name] = values.join(', ');
      });

      final controller = StreamController<List<int>>();
      upRes.listen(
        (chunk) {
          item.bytesSent += chunk.length;
          controller.add(chunk);
        },
        onDone: () {
          controller.close();
          client.close(force: false);
        },
        onError: (Object e) {
          controller.addError(e);
          controller.close();
          client.close(force: true);
        },
        cancelOnError: true,
      );

      return Response(
        upRes.statusCode,
        body: controller.stream,
        headers: outHeaders,
        context: const {'shelf.io.buffer_output': false},
      );
    } catch (e) {
      client.close(force: true);
      return Response(
        502,
        body: '无法连接本地端口 127.0.0.1:$port — 请确认本地服务已启动 ($e)',
        headers: const {'content-type': 'text/plain; charset=utf-8'},
      );
    }
  }

  String _renderMediaLandingHtml({
    required String title,
    required String fileName,
    required String sizeHuman,
    required String ext,
    required String rawHref,
    required String dlHref,
  }) {
    String playerBlock;
    if (_isVideoExt(ext)) {
      playerBlock =
          '<video controls playsinline preload="metadata" src="$rawHref"></video>';
    } else if (_isAudioExt(ext)) {
      playerBlock = '<audio controls preload="metadata" src="$rawHref"></audio>';
    } else {
      playerBlock = '<img src="$rawHref" alt="${_htmlEscape(fileName)}">';
    }

    return '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>${_htmlEscape(title)} · 在线预览</title>'
        '<style>body{margin:0;padding:24px 14px;background:#141413;color:#FAF9F5;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;display:flex;justify-content:center}'
        '.card{width:100%;max-width:940px;background:#1E1D1B;border:1px solid #33312C;border-radius:20px;padding:20px;box-sizing:border-box;box-shadow:0 16px 48px rgba(0,0,0,.45)}'
        '.top{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:center;gap:12px;margin-bottom:16px}'
        '.title{font-size:17px;font-weight:600;word-break:break-all}.meta{font-size:12.5px;color:#9C988E;margin-top:3px;font-family:monospace}'
        '.btns{display:flex;gap:8px}.btn{padding:8px 15px;border-radius:11px;text-decoration:none;font-size:13px;font-weight:600;background:#D97757;color:#FAF9F5}'
        '.btn.sec{background:#2B2925;color:#E8E5DC;border:1px solid #3D3A34}'
        'video,img{width:100%;max-height:74vh;border-radius:13px;background:#000;display:block}audio{width:100%;margin:18px 0}</style>'
        '</head><body><div class="card"><div class="top"><div>'
        '<div class="title">${_htmlEscape(title)}</div>'
        '<div class="meta">${_htmlEscape(fileName)} · $sizeHuman · 支持拖动进度条在线播放</div>'
        '</div><div class="btns">'
        '<a class="btn sec" href="$rawHref" target="_blank">直链</a>'
        '<a class="btn" href="$dlHref">下载文件</a>'
        '</div></div>$playerBlock</div></body></html>';
  }

  String _renderExpiredHtml() =>
      '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<title>分享已关闭或已过期</title>'
      '<style>body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;background:#FAF9F5;color:#141413;font-family:-apple-system,sans-serif;text-align:center}'
      '.box{padding:28px 32px;background:#FFF;border:1px solid #E5E2D9;border-radius:18px;max-width:400px}'
      'h2{margin:0 0 8px;font-size:18px}p{margin:0;color:#737068;font-size:13.5px;line-height:1.5}</style>'
      '</head><body><div class="box"><h2>该分享链接已关闭或到期</h2>'
      '<p>如需继续访问，请在控制台「外网分享」页重新开启，或直接告诉 AI 重新生成链接。</p></div></body></html>';
}

void registerExposureTools(
  void Function({
    required String name,
    required String description,
    required Map<String, dynamic> inputSchema,
    required ToolAnnotations annotations,
    required ToolHandler handler,
  }) registerTool,
  ServerConfig config,
) {
  final cmdAnn = config.relaxedCommandAnnotations
      ? readOnlyAnn
      : const ToolAnnotations(
          readOnlyHint: false,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: true,
        );

  registerTool(
    name: 'manage_expose',
    description:
        'Expose or close external access to a local file (MP4 video, HTML, APK, PDF), static website folder, or local web port (e.g. 3000) '
        'combining Tailscale (Funnel/Serve/Tailnet IP), active public gateway domain, and temporary Cloudflare tunnel. '
        'Actions: "open" (returns ready-to-open URLs immediately), "close" (by id), "close_all", "list".',
    annotations: cmdAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['open', 'close', 'close_all', 'list'],
          'description':
              '"open" to generate live external links, "close" to stop an active link by id, "close_all" to stop all active links, or "list" to inspect active links and Tailscale status.',
        },
        'target': {
          'type': 'string',
          'description':
              'For action="open": local file path (e.g. D:\\videos\\demo.mp4), website folder path, or local port/URL (e.g. "3000" or "http://127.0.0.1:3000").',
        },
        'port': {
          'type': 'integer',
          'description':
              'Optional numeric local port to expose (e.g. 3000, 5173, 8080).',
        },
        'id': {
          'type': 'string',
          'description': 'For action="close": exposure ID (e.g. "sh_...") to close.',
        },
        'scope': {
          'type': 'string',
          'enum': ['auto', 'tailscale', 'public', 'lan'],
          'default': 'auto',
          'description':
              '"auto" (best available public + Tailscale + LAN URLs), "tailscale" (Tailnet devices only), "public" (internet HTTPS), or "lan".',
        },
        'label': {
          'type': 'string',
          'description': 'Optional friendly title shown in the preview page and console.',
        },
        'ttl_minutes': {
          'type': 'integer',
          'description':
              'Auto-expire time in minutes (0 = keep open until manually closed). Defaults to server setting.',
        },
        'spa': {
          'type': 'boolean',
          'default': false,
          'description':
              'Set true for single-page web app folders so unknown routes fall back to index.html.',
        },
      },
      'required': ['action'],
    },
    handler: (args) async {
      final policy = getEffectivePolicy(config);
      final action = (args['action'] ?? 'list').toString().trim().toLowerCase();

      if (action == 'list') {
        final summary =
            await ExposureManager.instance.getDashboardSummary(config);
        return const JsonEncoder.withIndent('  ').convert(summary);
      }

      if (policy.readOnly) {
        throw const FileSystemException('当前入口为只读模式，不允许创建或关闭外网分享。');
      }

      if (action == 'open') {
        final rawTarget = (args['target'] ?? '').toString();
        final portVal = args['port'] is int
            ? args['port'] as int
            : int.tryParse('${args['port'] ?? ''}');
        final scope = (args['scope'] ?? 'auto').toString();
        final label = args['label']?.toString();
        final ttl = args['ttl_minutes'] is int
            ? args['ttl_minutes'] as int
            : int.tryParse('${args['ttl_minutes'] ?? ''}');
        final spa = args['spa'] == true;

        final created = await ExposureManager.instance.openExposure(
          config: config,
          rawTarget: rawTarget,
          portOverride: portVal,
          scope: scope,
          label: label,
          ttlMinutes: ttl,
          spa: spa,
          validateWithPolicy: true,
        );
        return const JsonEncoder.withIndent('  ').convert({
          'ok': true,
          'exposure': created,
        });
      }

      if (action == 'close') {
        final id = (args['id'] ?? '').toString().trim();
        if (id.isEmpty) {
          throw ArgumentError('关闭分享时请传入 id（可先调用 action="list" 查询）。');
        }
        final closed = await ExposureManager.instance.closeExposure(id);
        return const JsonEncoder.withIndent('  ').convert({
          'ok': closed,
          'id': id,
          'message': closed ? '已关闭该分享链接' : '未找到该活跃分享（可能已关闭或已到期）',
        });
      }

      if (action == 'close_all') {
        final count = await ExposureManager.instance.closeAllExposures();
        return const JsonEncoder.withIndent('  ').convert({
          'ok': true,
          'closed_count': count,
        });
      }

      throw ArgumentError('不支持的 action: $action（可选 open / close / close_all / list）');
    },
  );
}
