import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
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
  '.yaml': 'text/yaml; charset=utf-8',
  '.yml': 'text/yaml; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/markdown; charset=utf-8',
  '.csv': 'text/csv; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
  '.py': 'text/plain; charset=utf-8',
  '.dart': 'text/plain; charset=utf-8',
  '.ts': 'text/plain; charset=utf-8',
  '.tsx': 'text/plain; charset=utf-8',
  '.jsx': 'text/plain; charset=utf-8',
  '.sh': 'text/plain; charset=utf-8',
  '.ps1': 'text/plain; charset=utf-8',
  '.log': 'text/plain; charset=utf-8',
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
bool _isPdfExt(String ext) => ext == '.pdf';
bool _isTextPreviewExt(String ext) => const {
      '.txt',
      '.md',
      '.json',
      '.yaml',
      '.yml',
      '.csv',
      '.xml',
      '.py',
      '.dart',
      '.js',
      '.mjs',
      '.ts',
      '.tsx',
      '.jsx',
      '.sh',
      '.ps1',
      '.log',
      '.html',
      '.htm',
      '.css',
    }.contains(ext);

bool _isSensitiveShareFile(String filePath) {
  final base = p.basename(filePath).toLowerCase();
  if (base == '.env' ||
      (base.startsWith('.env.') && base != '.env.example') ||
      base == 'id_rsa' ||
      base == 'id_ed25519' ||
      base == 'mcp_config.json' ||
      base == 'oauth_state.json' ||
      base.endsWith('.pem') ||
      base.endsWith('.key')) {
    return true;
  }
  return false;
}

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

/// Probes common local web/dev ports on loopback to power 1-click port chips.
Future<List<int>> scanActiveLocalDevPorts({int? excludePort}) async {
  const candidates = <int>[3000, 4173, 5000, 5173, 7860, 8000, 8080, 8888];
  final checks = candidates.where((pt) => pt != excludePort).map((pt) async {
    try {
      final sock = await Socket.connect(
        InternetAddress.loopbackIPv4,
        pt,
        timeout: const Duration(milliseconds: 110),
      );
      await sock.close();
      return pt;
    } catch (_) {
      return null;
    }
  });
  final resolved = await Future.wait(checks);
  return resolved.whereType<int>().toList();
}

/// Opens a native OS file or folder dialog on Desktop (Windows/macOS/Linux)
/// without requiring any third-party native Flutter plugin dependencies.
Future<String?> pickNativeLocalPath({required bool directory}) async {
  if (Platform.isAndroid || Platform.isIOS) return null;
  try {
    if (Platform.isWindows) {
      final script = directory
          ? r'Add-Type -AssemblyName System.Windows.Forms; $f = New-Object System.Windows.Forms.FolderBrowserDialog; $f.Description = "选择要分享的文件夹"; if ($f.ShowDialog() -eq "OK") { [Console]::Out.Write($f.SelectedPath) }'
          : r'Add-Type -AssemblyName System.Windows.Forms; $f = New-Object System.Windows.Forms.OpenFileDialog; $f.Title = "选择要分享的文件或网页"; if ($f.ShowDialog() -eq "OK") { [Console]::Out.Write($f.FileName) }';
      final res = await Process.run(
        'powershell',
        ['-NoProfile', '-STA', '-Command', script],
      ).timeout(const Duration(minutes: 3));
      final picked = res.stdout.toString().trim();
      return picked.isEmpty ? null : picked;
    } else if (Platform.isMacOS) {
      final prompt = directory
          ? 'POSIX path of (choose folder with prompt "选择要分享的文件夹")'
          : 'POSIX path of (choose file with prompt "选择要分享的文件")';
      final res = await Process.run('osascript', ['-e', prompt])
          .timeout(const Duration(minutes: 3));
      final picked = res.stdout.toString().trim();
      return (res.exitCode == 0 && picked.isNotEmpty) ? picked : null;
    } else if (Platform.isLinux) {
      final args = directory
          ? ['--file-selection', '--directory', '--title=选择要分享的文件夹']
          : ['--file-selection', '--title=选择要分享的文件'];
      final res = await Process.run('zenity', args)
          .timeout(const Duration(minutes: 3));
      final picked = res.stdout.toString().trim();
      return (res.exitCode == 0 && picked.isNotEmpty) ? picked : null;
    }
  } catch (_) {}
  return null;
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

  /// One of the 4 user-facing share archetypes:
  /// - `'file'`   : Single File Share (opens rich single-file preview/download card)
  /// - `'folder'` : Folder Directory Explorer (breadcrumbs + subfolders + click file -> single-file preview)
  /// - `'site'`   : Static Website / HTML Share (renders single `.html` or static website folder directly)
  /// - `'port'`   : Local Port Forwarding (`127.0.0.1:<port>` reverse proxy)
  final String kind;
  final String target;
  final bool targetIsDirectory;
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
    this.targetIsDirectory = false,
    this.targetPort,
    required this.label,
    required this.scope,
    this.spa = false,
    required this.createdAtMs,
    this.expiresAtMs,
  });

  bool get needsTrailingSlash => kind == 'folder' || kind == 'site';

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
        item.needsTrailingSlash ? '/share/${item.id}/' : '/share/${item.id}';
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
      final u =
          item.needsTrailingSlash && !item.tailscaleHttpsUrl.endsWith('/')
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
      'target_is_dir': item.targetIsDirectory,
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
    String mode = 'auto',
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
      throw StateError('外链分享功能已在偏好设置中关闭，请先开启后再创建分享。');
    }

    final normScope = scope.trim().toLowerCase();
    final effectiveScope =
        const {'auto', 'tailscale', 'public', 'lan'}.contains(normScope)
            ? normScope
            : 'auto';

    final reqMode = mode.trim().toLowerCase();
    final effTtl = ttlMinutes ?? defaultTtlMinutesInSaved(saved);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final expMs = effTtl > 0 ? nowMs + effTtl * 60 * 1000 : null;

    String kind;
    String resolvedTarget;
    var targetIsDir = false;
    int? targetPort = portOverride;
    String defaultLabel;

    final trimmed = rawTarget.trim().replaceAll(RegExp(r'^:+'), '');
    final portOnly = targetPort ??
        ((reqMode == 'port' || reqMode == 'auto') ? int.tryParse(trimmed) : null);

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
      final rawPath = rawTarget.trim();
      if (rawPath.isEmpty) {
        throw ArgumentError('请选择或拖入要分享的文件、文件夹、静态网页或本地端口号（如 5173）。');
      }
      final policy = getEffectivePolicy(config);
      final checkedPath = normalizePath(rawPath, policy.roots);
      if (validateWithPolicy) {
        final deny = checkAccess(checkedPath, config);
        if (deny != null) throw FileSystemException(deny, checkedPath);
      }
      final st = await PrivFs.stat(checkedPath);
      if (!st.exists) {
        throw FileSystemException('找不到目标文件或文件夹', checkedPath);
      }
      resolvedTarget = checkedPath;
      targetIsDir = st.isDirectory;

      if (st.isDirectory) {
        final hasIndex =
            (await PrivFs.stat(p.join(checkedPath, 'index.html'))).isFile;
        if (reqMode == 'folder') {
          kind = 'folder';
        } else if (reqMode == 'site' || reqMode == 'dir' && (spa || hasIndex)) {
          kind = 'site';
        } else if (reqMode == 'dir') {
          kind = 'folder';
        } else {
          // auto: directory with index.html -> static website, otherwise folder explorer
          kind = (spa || hasIndex) ? 'site' : 'folder';
        }
        defaultLabel = kind == 'site'
            ? '静态网站 ${p.basename(checkedPath)}'
            : '文件夹 ${p.basename(checkedPath)}';
      } else {
        final ext = p.extension(checkedPath).toLowerCase();
        final isHtmlFile = ext == '.html' || ext == '.htm';
        if (reqMode == 'site' || (reqMode == 'auto' && isHtmlFile)) {
          kind = 'site';
          defaultLabel = '静态网页 ${p.basename(checkedPath)}';
        } else {
          kind = 'file';
          defaultLabel = p.basename(checkedPath);
        }
      }
    }

    final id = _generateShareId();
    final item = ExposureItem(
      id: id,
      kind: kind,
      target: resolvedTarget,
      targetIsDirectory: targetIsDir,
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
      'badge': '随手分享',
      'level': 'INFO',
      'summary': '已开启分享 [${item.label}] -> ${serialized['primary_url']}',
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
      'badge': '随手分享',
      'level': 'INFO',
      'summary':
          '已收起分享 [${item.label}] (${reason == 'expired' ? '到期自动收起' : '手动收起'})',
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
    final livePort =
        int.tryParse('${saved['port'] ?? config.port}') ?? config.port;
    final ts = await probeTailscaleStatus();
    final ifaces = await listHostNetworkInterfaces();
    final pubBases = _discoverActivePublicGatewayBases(saved);
    final cfInstalled = findCloudflared() != null;
    final activePorts = await scanActiveLocalDevPorts(excludePort: livePort);

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
      'active_local_ports': activePorts,
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
        '外链分享功能已在偏好设置中关闭。',
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
    if (item.kind == 'folder') {
      final rawReqPath = req.requestedUri.path;
      if (subSegments.isEmpty && !rawReqPath.endsWith('/')) {
        final q = req.requestedUri.hasQuery ? '?${req.requestedUri.query}' : '';
        return Response.found('$rawReqPath/$q');
      }
      return _serveFolderExplorer(req, item, subSegments);
    }
    if (item.kind == 'site') {
      final rawReqPath = req.requestedUri.path;
      if (subSegments.isEmpty && !rawReqPath.endsWith('/')) {
        final q = req.requestedUri.hasQuery ? '?${req.requestedUri.query}' : '';
        return Response.found('$rawReqPath/$q');
      }
      return _serveStaticWebsite(req, item, subSegments);
    }
    if (item.kind == 'port' && item.targetPort != null) {
      return _proxyLocalPort(req, item, subSegments);
    }

    return Response.notFound('Unsupported share item.');
  }

  /// Mode 1: Single File Share -> Rich Unified Single-File Preview Card
  Future<Response> _serveSingleFile(
    Request req,
    ExposureItem item,
    List<String> subSegments,
  ) async {
    final fileName = p.basename(item.target);
    final forceDownload = req.url.queryParameters['download'] == '1';
    final wantRaw = req.url.queryParameters['raw'] == '1' ||
        forceDownload ||
        subSegments.isNotEmpty ||
        !(req.headers['accept'] ?? '').contains('text/html');

    if (!wantRaw) {
      final rawHref =
          '/share/${item.id}/${Uri.encodeComponent(fileName)}?raw=1';
      final dlHref =
          '/share/${item.id}/${Uri.encodeComponent(fileName)}?download=1';
      return _renderUnifiedSingleFilePage(
        item: item,
        filePath: item.target,
        displayTitle: item.label,
        rawHref: rawHref,
        dlHref: dlHref,
        backToFolderHref: null,
      );
    }

    return _streamFileWithRange(
      req,
      item,
      item.target,
      forceDownload: forceDownload,
    );
  }

  /// Mode 2: Folder Directory Explorer -> Subfolder Navigation -> Click File = Unified Single-File Preview!
  Future<Response> _serveFolderExplorer(
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
    if (_isSensitiveShareFile(candidatePath)) {
      return Response.forbidden('Sensitive file hidden.');
    }

    final candStat = await PrivFs.stat(candidatePath);
    if (candStat.isDirectory) {
      final rawReqPath = req.requestedUri.path;
      if (!rawReqPath.endsWith('/')) {
        final q = req.requestedUri.hasQuery ? '?${req.requestedUri.query}' : '';
        return Response.found('$rawReqPath/$q');
      }
      if (req.url.queryParameters['zip'] == '1') {
        return _serveDirectoryAsZip(item, candidatePath, relParts);
      }
      return _renderDirectoryListing(item, candidatePath, relParts);
    }

    if (!candStat.isFile) {
      return Response.notFound('File not found.');
    }

    final forceDownload = req.url.queryParameters['download'] == '1';
    final wantRaw = req.url.queryParameters['raw'] == '1' ||
        forceDownload ||
        !(req.headers['accept'] ?? '').contains('text/html');

    if (!wantRaw) {
      final encodedRel = relParts.map(Uri.encodeComponent).join('/');
      final baseFileHref = '/share/${item.id}/$encodedRel';
      final parentHref = relParts.length <= 1
          ? '/share/${item.id}/'
          : '/share/${item.id}/${relParts.sublist(0, relParts.length - 1).map(Uri.encodeComponent).join('/')}/';
      return _renderUnifiedSingleFilePage(
        item: item,
        filePath: candidatePath,
        displayTitle: p.basename(candidatePath),
        rawHref: '$baseFileHref?raw=1',
        dlHref: '$baseFileHref?download=1',
        backToFolderHref: parentHref,
      );
    }

    return _streamFileWithRange(
      req,
      item,
      candidatePath,
      forceDownload: forceDownload,
    );
  }

  /// Mode 3: Static Website / Single-Page HTML Share (renders website directly, never exposes directory list)
  Future<Response> _serveStaticWebsite(
    Request req,
    ExposureItem item,
    List<String> subSegments,
  ) async {
    final relParts = subSegments.where((s) => s.isNotEmpty).toList();

    // Case 3A: Single `.html` file shared as a live webpage (+ safe sibling asset resolution)
    if (!item.targetIsDirectory) {
      if (relParts.isEmpty) {
        return _streamFileWithRange(req, item, item.target);
      }
      final parentRoot = p.canonicalize(p.dirname(item.target));
      final assetPath = p.normalize(p.joinAll([parentRoot, ...relParts]));
      if (assetPath == parentRoot ||
          !p.isWithin(parentRoot, assetPath) ||
          _isSensitiveShareFile(assetPath)) {
        return Response.forbidden('Forbidden asset path.');
      }
      final assetStat = await PrivFs.stat(assetPath);
      if (assetStat.isFile) {
        return _streamFileWithRange(req, item, assetPath);
      }
      return Response.notFound('Static asset not found.');
    }

    // Case 3B: Website Directory (`index.html` + static assets + optional SPA fallback)
    final rootPath = p.canonicalize(item.target);
    final candidatePath = relParts.isEmpty
        ? rootPath
        : p.normalize(p.joinAll([rootPath, ...relParts]));

    if (candidatePath != rootPath && !p.isWithin(rootPath, candidatePath)) {
      return Response.forbidden('Forbidden path traversal.');
    }
    if (_isSensitiveShareFile(candidatePath)) {
      return Response.forbidden('Forbidden.');
    }

    final candStat = await PrivFs.stat(candidatePath);
    if (candStat.isDirectory) {
      for (final idxName in const ['index.html', 'index.htm']) {
        final idxFile = p.join(candidatePath, idxName);
        if ((await PrivFs.stat(idxFile)).isFile) {
          return _streamFileWithRange(req, item, idxFile);
        }
      }
      if (item.spa) {
        final spaIndex = p.join(rootPath, 'index.html');
        if ((await PrivFs.stat(spaIndex)).isFile) {
          return _streamFileWithRange(req, item, spaIndex);
        }
      }
      return Response.notFound(
        '<!DOCTYPE html><html lang="zh-CN"><meta charset="utf-8">'
        '<body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;background:#F6F4EC;color:#1F1E1B;font-family:sans-serif">'
        '<div style="background:#FFF;padding:28px 32px;border-radius:20px;max-width:440px;text-align:center;box-shadow:0 10px 30px rgba(0,0,0,.06)">'
        '<h3 style="margin:0 0 8px">未找到网页入口 index.html</h3>'
        '<p style="margin:0;color:#6E6A61;font-size:14px;line-height:1.6">当前为「静态网站分享」模式（不会暴露目录文件列表）。如果你想展示文件夹目录，请在分享页切换为「文件夹目录」模式。</p>'
        '</div></body></html>',
        headers: const {'content-type': 'text/html; charset=utf-8'},
      );
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

  Future<Response> _serveDirectoryAsZip(
    ExposureItem item,
    String dirPath,
    List<String> relParts,
  ) async {
    final archive = Archive();
    var accumulatedBytes = 0;
    const maxZipBytes = 120 * 1024 * 1024; // 120 MB safety cap

    Future<void> walk(String currentDir, String relPrefix) async {
      final entries = await PrivFs.listDir(currentDir);
      for (final e in entries) {
        if (e.name.startsWith('.') || defaultIgnoreDirs.contains(e.name)) {
          continue;
        }
        final full = p.join(currentDir, e.name);
        if (_isSensitiveShareFile(full)) continue;
        final nextRel = relPrefix.isEmpty ? e.name : '$relPrefix/${e.name}';
        if (e.isDirectory) {
          await walk(full, nextRel);
        } else if (!e.isDirectory) {
          if (accumulatedBytes + e.size > maxZipBytes) continue;
          final data = await PrivFs.readBytes(full);
          accumulatedBytes += data.length;
          archive.addFile(ArchiveFile(nextRel, data.length, data));
        }
      }
    }

    await walk(dirPath, '');
    final zipped = ZipEncoder().encode(archive);
    final zipName = relParts.isEmpty ? item.label : relParts.last;
    final encodedZip = Uri.encodeComponent('$zipName.zip');
    item.bytesSent += zipped.length;
    return Response.ok(
      zipped,
      headers: {
        'content-type': 'application/zip',
        'content-length': '${zipped.length}',
        'content-disposition': "attachment; filename*=UTF-8''$encodedZip",
      },
    );
  }

  Future<Response> _renderDirectoryListing(
    ExposureItem item,
    String dirPath,
    List<String> relParts,
  ) async {
    final rawEntries = await PrivFs.listDir(dirPath);
    final entries = rawEntries
        .where((e) => !e.name.startsWith('.') && !_isSensitiveShareFile(p.join(dirPath, e.name)))
        .toList()
      ..sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    final crumbs = StringBuffer(
      '<a href="/share/${item.id}/">全部文件</a>',
    );
    for (var i = 0; i < relParts.length; i++) {
      final href =
          '/share/${item.id}/${relParts.sublist(0, i + 1).map(Uri.encodeComponent).join('/')}/';
      crumbs.write(
        ' <span class="sep">/</span> <a href="$href">${_htmlEscape(relParts[i])}</a>',
      );
    }

    final rows = StringBuffer();
    if (relParts.isNotEmpty) {
      rows.writeln(
        '<a class="item" data-name=".." href="../">'
        '<span class="left"><span class="ico dir">↩</span><span class="nm">返回上一级目录</span></span>'
        '<span class="meta">上级</span></a>',
      );
    }
    for (final e in entries) {
      final slash = e.isDirectory ? '/' : '';
      final href = '${Uri.encodeComponent(e.name)}$slash';
      final ico = e.isDirectory ? '📁' : '📄';
      final meta = e.isDirectory
          ? '进入子目录 →'
          : '${_formatHumanBytes(e.size)} · 点开预览';
      rows.writeln(
        '<a class="item" data-name="${_htmlEscape(e.name.toLowerCase())}" href="$href">'
        '<span class="left"><span class="ico">$ico</span><span class="nm">${_htmlEscape(e.name)}$slash</span></span>'
        '<span class="meta">$meta</span></a>',
      );
    }

    final html = '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>${_htmlEscape(item.label)} · 文件夹分享</title>'
        '<style>'
        ':root{--bg:#F6F4EC;--card:#FFFFFF;--soft:#EFECE2;--hover:#E7E3D6;--ink:#1F1E1B;--muted:#6E6A61;--accent:#C96442}'
        '@media(prefers-color-scheme:dark){:root{--bg:#161513;--card:#22211D;--soft:#2C2A25;--hover:#35332D;--ink:#F3F1E9;--muted:#A6A298;--accent:#E07A56}}'
        '*{box-sizing:border-box}body{margin:0;padding:28px 16px;background:var(--bg);color:var(--ink);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei UI",sans-serif}'
        '.wrap{max-width:820px;margin:0 auto;background:var(--card);border-radius:24px;padding:26px;box-shadow:0 12px 36px rgba(0,0,0,.06)}'
        '.head{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:center;gap:12px;margin-bottom:16px}'
        'h1{margin:0;font-size:20px;font-weight:700}.crumbs{font-size:13.5px;color:var(--muted);margin-top:5px}'
        '.crumbs a{color:var(--accent);text-decoration:none;font-weight:600}.sep{margin:0 4px;opacity:.5}'
        '.tools{display:flex;gap:8px;align-items:center;flex-wrap:wrap}'
        'input{background:var(--soft);border:none;border-radius:99px;padding:8px 14px;color:var(--ink);font-size:13px;outline:none;width:180px}'
        '.zbtn{background:var(--soft);color:var(--ink);text-decoration:none;padding:8px 14px;border-radius:99px;font-size:12.5px;font-weight:600}'
        '.zbtn:hover{background:var(--hover)}'
        '.list{display:flex;flex-direction:column;gap:8px;margin-top:8px}'
        '.item{display:flex;justify-content:space-between;align-items:center;gap:12px;padding:12px 16px;border-radius:15px;background:var(--soft);color:var(--ink);text-decoration:none;transition:background .15s}'
        '.item:hover{background:var(--hover)}.left{display:flex;align-items:center;gap:10px;min-width:0}'
        '.nm{font-size:14.5px;font-weight:500;word-break:break-all}.meta{font-size:12.5px;color:var(--muted);font-family:ui-monospace,monospace;white-space:nowrap}'
        '.empty{padding:32px;text-align:center;color:var(--muted);font-size:14px}'
        '</style></head><body><div class="wrap">'
        '<div class="head"><div><h1>${_htmlEscape(item.label)}</h1><div class="crumbs">$crumbs</div></div>'
        '<div class="tools"><input id="q" type="search" placeholder="搜索文件名..." oninput="flt(this.value)">'
        '<a class="zbtn" href="?zip=1">打包下载 (.zip)</a></div></div>'
        '<div class="list" id="lst">${entries.isEmpty && relParts.isEmpty ? '<div class="empty">这个文件夹目前是空的</div>' : rows.toString()}</div>'
        '</div><script>function flt(v){v=v.toLowerCase().trim();document.querySelectorAll(".item").forEach(el=>{const n=el.getAttribute("data-name")||"";el.style.display=(!v||n===".."||n.includes(v))?"flex":"none";});}</script>'
        '</body></html>';
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

  /// Unified Single-File Preview Page shared by BOTH Mode 1 (Single File Share)
  /// AND clicking any file inside Mode 2 (Folder Explorer Share)!
  Future<Response> _renderUnifiedSingleFilePage({
    required ExposureItem item,
    required String filePath,
    required String displayTitle,
    required String rawHref,
    required String dlHref,
    required String? backToFolderHref,
  }) async {
    final fileName = p.basename(filePath);
    final ext = p.extension(fileName).toLowerCase();
    final stat = await PrivFs.stat(filePath);
    final sizeHuman = _formatHumanBytes(stat.size);

    String stageHtml;
    if (_isVideoExt(ext)) {
      stageHtml =
          '<video controls playsinline preload="metadata" src="$rawHref"></video>';
    } else if (_isAudioExt(ext)) {
      stageHtml =
          '<div class="pad-box"><audio controls preload="metadata" src="$rawHref"></audio></div>';
    } else if (_isImageExt(ext)) {
      stageHtml =
          '<div class="img-box"><img src="$rawHref" alt="${_htmlEscape(fileName)}"></div>';
    } else if (_isPdfExt(ext)) {
      stageHtml =
          '<iframe class="pdf-frame" src="$rawHref" title="${_htmlEscape(fileName)}"></iframe>';
    } else if (_isTextPreviewExt(ext) && stat.size <= 131072) {
      String snippet = '';
      try {
        final rawBytes = await PrivFs.readBytes(filePath);
        snippet = utf8.decode(rawBytes, allowMalformed: true);
      } catch (_) {}
      stageHtml = '<pre class="code-box">${_htmlEscape(snippet)}</pre>';
    } else {
      stageHtml = '<div class="dl-stage">'
          '<div class="dl-name">${_htmlEscape(fileName)}</div>'
          '<div class="dl-sub">文件大小 $sizeHuman · 点击下方按钮即可原速下载</div>'
          '<a class="btn pri big" href="$dlHref">直接下载文件 ($sizeHuman)</a>'
          '</div>';
    }

    final backLink = backToFolderHref != null
        ? '<a class="btn ghost" href="$backToFolderHref">← 返回所在文件夹</a>'
        : '';

    final html = '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>${_htmlEscape(displayTitle)} · 在线预览</title>'
        '<style>'
        ':root{--bg:#F6F4EC;--card:#FFFFFF;--soft:#EFECE2;--ink:#1F1E1B;--muted:#6E6A61;--accent:#C96442}'
        '@media(prefers-color-scheme:dark){:root{--bg:#141413;--card:#1F1E1B;--soft:#2B2924;--ink:#FAF9F5;--muted:#A4A096;--accent:#D97757}}'
        '*{box-sizing:border-box}body{margin:0;padding:24px 14px;background:var(--bg);color:var(--ink);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei UI",sans-serif;display:flex;justify-content:center}'
        '.card{width:100%;max-width:940px;background:var(--card);border-radius:24px;padding:22px 24px;box-shadow:0 14px 44px rgba(0,0,0,.08)}'
        '.top{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:center;gap:12px;margin-bottom:16px}'
        '.title{font-size:18px;font-weight:700;word-break:break-all}.meta{font-size:12.5px;color:var(--muted);margin-top:4px;font-family:ui-monospace,monospace}'
        '.btns{display:flex;flex-wrap:wrap;gap:8px;align-items:center}'
        '.btn{padding:8px 15px;border-radius:99px;text-decoration:none;font-size:13px;font-weight:600;background:var(--soft);color:var(--ink)}'
        '.btn.pri{background:var(--accent);color:#FFF}.btn.big{padding:11px 22px;font-size:14px;margin-top:8px;display:inline-block}'
        '.btn.ghost{color:var(--accent)}'
        'video{width:100%;max-height:74vh;border-radius:16px;background:#000;display:block}'
        '.img-box{background:var(--soft);border-radius:16px;padding:16px;text-align:center}img{max-width:100%;max-height:72vh;border-radius:10px}'
        '.pad-box{background:var(--soft);border-radius:16px;padding:28px}audio{width:100%}'
        '.pdf-frame{width:100%;height:74vh;border:none;border-radius:16px;background:var(--soft)}'
        '.code-box{margin:0;padding:18px;border-radius:16px;background:#191816;color:#EDEAE2;font-family:ui-monospace,Consolas,monospace;font-size:13px;line-height:1.6;overflow:auto;max-height:70vh;white-space:pre-wrap;word-break:break-word}'
        '.dl-stage{background:var(--soft);border-radius:18px;padding:42px 20px;text-align:center;display:flex;flex-direction:column;align-items:center;gap:8px}'
        '.dl-name{font-size:17px;font-weight:700}.dl-sub{font-size:13.5px;color:var(--muted)}'
        '</style></head><body><div class="card"><div class="top"><div>'
        '<div class="title">${_htmlEscape(displayTitle)}</div>'
        '<div class="meta">${_htmlEscape(fileName)} · $sizeHuman</div>'
        '</div><div class="btns">$backLink'
        '<a class="btn" href="$rawHref" target="_blank">原始直链</a>'
        '<a class="btn pri" href="$dlHref">下载文件</a>'
        '</div></div>$stageHtml</div></body></html>';

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
      if ((req.headers['accept'] ?? '').contains('text/html')) {
        return Response(
          502,
          body: '<!DOCTYPE html><html lang="zh-CN"><meta charset="utf-8">'
              '<meta http-equiv="refresh" content="4">'
              '<body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;background:#F6F4EC;color:#1F1E1B;font-family:sans-serif">'
              '<div style="background:#FFF;padding:28px 32px;border-radius:22px;max-width:420px;text-align:center;box-shadow:0 10px 30px rgba(0,0,0,.06)">'
              '<h3 style="margin:0 0 8px">正在等待本机端口 :$port 启动...</h3>'
              '<p style="margin:0;color:#6E6A61;font-size:13.5px;line-height:1.6">当前尚未检测到 127.0.0.1:$port 的响应，本页面每 4 秒会自动刷新一次。</p>'
              '</div></body></html>',
          headers: const {'content-type': 'text/html; charset=utf-8'},
        );
      }
      return Response(
        502,
        body: '无法连接本地端口 127.0.0.1:$port — 请确认本地服务已启动 ($e)',
        headers: const {'content-type': 'text/plain; charset=utf-8'},
      );
    }
  }

  String _renderExpiredHtml() =>
      '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<title>分享链接已收起</title>'
      '<style>body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;background:#F6F4EC;color:#1F1E1B;font-family:-apple-system,sans-serif;text-align:center}'
      '.box{padding:28px 32px;background:#FFF;border-radius:22px;max-width:400px;box-shadow:0 10px 30px rgba(0,0,0,.06)}'
      'h2{margin:0 0 8px;font-size:18px}p{margin:0;color:#6E6A61;font-size:13.5px;line-height:1.55}</style>'
      '</head><body><div class="box"><h2>这条分享链接已经收起或到期</h2>'
      '<p>如果还需要查看，可以在「随手分享」页重新开启，或让 AI 再发一次。</p></div></body></html>';
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
        'Share a local single file (streaming video/PDF/APK preview), folder directory explorer (browse subfolders and click files to preview), '
        'static website / single HTML page (renders directly as a live webpage), or local port (e.g. 3000/5173) via Tailscale, gateway domain, or temporary tunnel. '
        'Actions: "open", "close", "close_all", "list".',
    annotations: cmdAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['open', 'close', 'close_all', 'list'],
          'description':
              '"open" to generate live external links, "close" to stop an active link by id, "close_all" to stop all active links, or "list" to inspect active links.',
        },
        'target': {
          'type': 'string',
          'description':
              'For action="open": local file path (e.g. demo.mp4 or page.html), folder path, or local port/URL (e.g. "5173").',
        },
        'mode': {
          'type': 'string',
          'enum': ['auto', 'file', 'folder', 'site', 'port'],
          'default': 'auto',
          'description':
              '"file" (single file preview/download), "folder" (directory browser with subfolder navigation -> single file preview), "site" (render single .html or website folder directly as live site), "port" (reverse proxy local port), or "auto".',
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
        throw const FileSystemException('当前入口为只读模式，不允许创建或关闭外链分享。');
      }

      if (action == 'open') {
        final rawTarget = (args['target'] ?? '').toString();
        final mode = (args['mode'] ?? 'auto').toString();
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
          mode: mode,
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
          'message': closed ? '已收起该分享链接' : '未找到该活跃分享（可能已收起或到期）',
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
