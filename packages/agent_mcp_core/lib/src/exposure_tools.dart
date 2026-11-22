import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:stream_channel/stream_channel.dart';

import 'auth.dart';
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

/// Unified sensitive file & directory check shared with `config.dart` (`isBlockedSecretPath`).
bool _isSensitiveShareFile(String filePath, {ServerConfig? config}) {
  return isBlockedSecretPath(filePath, config: config);
}

/// Resolves real physical paths (following filesystem symlinks) and verifies
/// that [relSegments] remains strictly inside [rootDir] with no symlink escape.
/// Returns `null` if traversal/symlink escape or secret path is detected.
Future<String?> _resolveSafeSharePath(
  String rootDir,
  List<String> relSegments, {
  ServerConfig? config,
  bool allowMissingLeaf = false,
}) async {
  for (final seg in relSegments) {
    if (seg == '..' || seg.contains('/') || seg.contains(r'\')) {
      return null;
    }
  }

  final useBridge = await PrivFs.useBridgeForPath(rootDir);
  String rootReal;
  if (!useBridge) {
    try {
      final d = Directory(rootDir);
      rootReal = d.existsSync()
          ? d.resolveSymbolicLinksSync()
          : p.canonicalize(rootDir);
    } catch (_) {
      rootReal = p.canonicalize(rootDir);
    }
  } else {
    rootReal = p.normalize(p.absolute(rootDir));
  }

  final candidateLexical = relSegments.isEmpty
      ? rootReal
      : p.normalize(p.joinAll([rootReal, ...relSegments]));

  if (!isWithin(candidateLexical, rootReal)) {
    return null;
  }
  if (_isSensitiveShareFile(candidateLexical, config: config)) {
    return null;
  }

  if (!useBridge) {
    // Check every ancestor segment for symlinks escaping rootReal
    var cur = rootReal;
    for (var i = 0; i < relSegments.length; i++) {
      cur = p.join(cur, relSegments[i]);
      final linkType = FileSystemEntity.typeSync(cur, followLinks: false);
      if (linkType == FileSystemEntityType.notFound) {
        if (allowMissingLeaf && i == relSegments.length - 1) {
          return candidateLexical;
        }
        return candidateLexical;
      }
      try {
        final resolvedStep = linkType == FileSystemEntityType.directory
            ? Directory(cur).resolveSymbolicLinksSync()
            : (linkType == FileSystemEntityType.file
                ? File(cur).resolveSymbolicLinksSync()
                : FileSystemEntity.typeSync(cur, followLinks: true) ==
                        FileSystemEntityType.directory
                    ? Directory(cur).resolveSymbolicLinksSync()
                    : File(cur).resolveSymbolicLinksSync());
        if (!isWithin(resolvedStep, rootReal)) {
          return null; // Symlink points outside shared root!
        }
        if (_isSensitiveShareFile(resolvedStep, config: config)) {
          return null;
        }
        if (i == relSegments.length - 1) {
          return resolvedStep;
        }
      } catch (_) {
        // Broken symlink or unreadable target -> block safely
        if (linkType == FileSystemEntityType.link) return null;
      }
    }
  }

  return candidateLexical;
}

final Uint32List _crc32Table = (() {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[i] = c;
  }
  return table;
})();

int _updateCrc32(int crc, List<int> chunk) {
  var c = crc;
  for (var i = 0; i < chunk.length; i++) {
    c = _crc32Table[(c ^ chunk[i]) & 0xFF] ^ (c >>> 8);
  }
  return c;
}

class _ZipCdEntry {
  final Uint8List nameBytes;
  final int dosTime;
  final int dosDate;
  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;

  const _ZipCdEntry({
    required this.nameBytes,
    required this.dosTime,
    required this.dosDate,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
  });
}

/// Streams a PKZIP archive (DEFLATE + Data Descriptor + UTF-8 flags) in 64KB
/// chunks directly over HTTP with <2MB constant memory footprint.
Stream<List<int>> _streamPkZipEntries(
  List<({String fullPath, String relPath, DateTime modified})> files, {
  required void Function(int deltaBytes) onBytesEmitted,
}) async* {
  final cdEntries = <_ZipCdEntry>[];
  var offset = 0;

  Uint8List emitBytes(Uint8List b) {
    offset += b.length;
    onBytesEmitted(b.length);
    return b;
  }

  for (final f in files) {
    final nameBytes = Uint8List.fromList(utf8.encode(f.relPath));
    final dt = f.modified.toLocal();
    final dosTime = ((dt.hour & 0x1F) << 11) |
        ((dt.minute & 0x3F) << 5) |
        ((dt.second ~/ 2) & 0x1F);
    final year = dt.year < 1980 ? 1980 : (dt.year > 2107 ? 2107 : dt.year);
    final dosDate =
        (((year - 1980) & 0x7F) << 9) | ((dt.month & 0x0F) << 5) | (dt.day & 0x1F);

    final localHeaderOffset = offset;
    final lfh = ByteData(30 + nameBytes.length);
    lfh.setUint32(0, 0x04034b50, Endian.little);
    lfh.setUint16(4, 20, Endian.little); // version 2.0
    lfh.setUint16(6, 0x0808, Endian.little); // data descriptor + UTF-8
    lfh.setUint16(8, 8, Endian.little); // DEFLATE
    lfh.setUint16(10, dosTime, Endian.little);
    lfh.setUint16(12, dosDate, Endian.little);
    lfh.setUint32(14, 0, Endian.little);
    lfh.setUint32(18, 0, Endian.little);
    lfh.setUint32(22, 0, Endian.little);
    lfh.setUint16(26, nameBytes.length, Endian.little);
    lfh.setUint16(28, 0, Endian.little);
    final lfhBytes = lfh.buffer.asUint8List();
    lfhBytes.setRange(30, 30 + nameBytes.length, nameBytes);
    yield emitBytes(lfhBytes);

    var crc = 0xFFFFFFFF;
    var uncompSize = 0;
    var compSize = 0;

    final rawStream = await PrivFs.openRead(f.fullPath);
    final trackedRaw = rawStream.map((chunk) {
      crc = _updateCrc32(crc, chunk);
      uncompSize += chunk.length;
      return chunk;
    });

    final deflatedStream = ZLibCodec(raw: true, level: 6).encoder.bind(trackedRaw);
    await for (final compChunk in deflatedStream) {
      if (compChunk.isNotEmpty) {
        compSize += compChunk.length;
        offset += compChunk.length;
        onBytesEmitted(compChunk.length);
        yield compChunk;
      }
    }

    final finalCrc = (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
    final dd = ByteData(16);
    dd.setUint32(0, 0x08074b50, Endian.little);
    dd.setUint32(4, finalCrc, Endian.little);
    dd.setUint32(8, compSize, Endian.little);
    dd.setUint32(12, uncompSize, Endian.little);
    yield emitBytes(dd.buffer.asUint8List());

    cdEntries.add(
      _ZipCdEntry(
        nameBytes: nameBytes,
        dosTime: dosTime,
        dosDate: dosDate,
        crc32: finalCrc,
        compressedSize: compSize,
        uncompressedSize: uncompSize,
        localHeaderOffset: localHeaderOffset,
      ),
    );
  }

  final cdStartOffset = offset;
  for (final e in cdEntries) {
    final cdh = ByteData(46 + e.nameBytes.length);
    cdh.setUint32(0, 0x02014b50, Endian.little);
    cdh.setUint16(4, 20, Endian.little);
    cdh.setUint16(6, 20, Endian.little);
    cdh.setUint16(8, 0x0808, Endian.little);
    cdh.setUint16(10, 8, Endian.little);
    cdh.setUint16(12, e.dosTime, Endian.little);
    cdh.setUint16(14, e.dosDate, Endian.little);
    cdh.setUint32(16, e.crc32, Endian.little);
    cdh.setUint32(20, e.compressedSize, Endian.little);
    cdh.setUint32(24, e.uncompressedSize, Endian.little);
    cdh.setUint16(28, e.nameBytes.length, Endian.little);
    cdh.setUint16(30, 0, Endian.little);
    cdh.setUint16(32, 0, Endian.little);
    cdh.setUint16(34, 0, Endian.little);
    cdh.setUint16(36, 0, Endian.little);
    cdh.setUint32(38, 0, Endian.little);
    cdh.setUint32(42, e.localHeaderOffset, Endian.little);
    final cdhBytes = cdh.buffer.asUint8List();
    cdhBytes.setRange(46, 46 + e.nameBytes.length, e.nameBytes);
    yield emitBytes(cdhBytes);
  }

  final cdByteLen = offset - cdStartOffset;
  final eocd = ByteData(22);
  eocd.setUint32(0, 0x06054b50, Endian.little);
  eocd.setUint16(4, 0, Endian.little);
  eocd.setUint16(6, 0, Endian.little);
  eocd.setUint16(8, cdEntries.length, Endian.little);
  eocd.setUint16(10, cdEntries.length, Endian.little);
  eocd.setUint32(12, cdByteLen, Endian.little);
  eocd.setUint32(16, cdStartOffset, Endian.little);
  eocd.setUint16(20, 0, Endian.little);
  yield emitBytes(eocd.buffer.asUint8List());
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

final String _sharePinHmacSecret = randomHex(32);

String _computeSharePinToken(ExposureItem item) {
  final mac = Hmac(sha256, utf8.encode(_sharePinHmacSecret));
  return mac
      .convert(utf8.encode('${item.id}|${item.createdAtMs}|${item.pinCode ?? ''}'))
      .toString()
      .substring(0, 32);
}

String? _extractCookieValue(Request req, String name) {
  final raw = req.headers['cookie'] ?? '';
  if (raw.isEmpty) return null;
  for (final part in raw.split(';')) {
    final idx = part.indexOf('=');
    if (idx <= 0) continue;
    final k = part.substring(0, idx).trim();
    if (k == name) {
      return part.substring(idx + 1).trim();
    }
  }
  return null;
}

List<int> _cachedDevPorts = const [];
int _cachedDevPortsAtMs = 0;
int? _cachedDevPortsExclude;

/// Probes common local web/dev ports on loopback to power 1-click port chips,
/// with a 15-second cache so status polling never causes background socket churn.
Future<List<int>> scanActiveLocalDevPorts({
  int? excludePort,
  bool forceRefresh = false,
}) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  if (!forceRefresh &&
      _cachedDevPortsAtMs > 0 &&
      _cachedDevPortsExclude == excludePort &&
      (now - _cachedDevPortsAtMs) < 15000) {
    return _cachedDevPorts;
  }
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
  final resolved = (await Future.wait(checks)).whereType<int>().toList();
  _cachedDevPorts = resolved;
  _cachedDevPortsAtMs = now;
  _cachedDevPortsExclude = excludePort;
  return resolved;
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
  /// - `'port'`   : Local Port Forwarding (`127.0.0.1:<port>` reverse proxy + WebSocket HMR)
  final String kind;
  final String target;
  final bool targetIsDirectory;
  final int? targetPort;
  final String label;
  final String scope; // 'auto' | 'tailscale' | 'public' | 'lan'
  final bool spa;
  final String? pinCode;
  final int? maxDownloads;
  final int createdAtMs;
  final int? expiresAtMs;

  int hitCount = 0;
  int downloadCount = 0;
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
    this.pinCode,
    this.maxDownloads,
    required this.createdAtMs,
    this.expiresAtMs,
  });

  bool get needsTrailingSlash => kind == 'folder' || kind == 'site';

  bool get hasPin => pinCode != null && pinCode!.isNotEmpty;

  bool get isDownloadExhausted =>
      maxDownloads != null && maxDownloads! > 0 && downloadCount >= maxDownloads!;

  int? get remainingDownloads {
    if (maxDownloads == null || maxDownloads! <= 0) return null;
    final rem = maxDownloads! - downloadCount;
    return rem < 0 ? 0 : rem;
  }

  bool get isExpired =>
      (expiresAtMs != null &&
          DateTime.now().millisecondsSinceEpoch >= expiresAtMs!) ||
      isDownloadExhausted;

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
      'has_pin': item.hasPin,
      if (item.hasPin) 'pin_code': item.pinCode,
      if (item.maxDownloads != null && item.maxDownloads! > 0) ...{
        'max_downloads': item.maxDownloads,
        'download_count': item.downloadCount,
        'remaining_downloads': item.remainingDownloads,
      },
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
    String? pinCode,
    int? maxDownloads,
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

    final cleanPin = pinCode?.trim() ?? '';
    if (cleanPin.isNotEmpty && (cleanPin.length < 4 || cleanPin.length > 16)) {
      throw ArgumentError('提取码长度需在 4 到 16 位之间（留空则免密直接打开）。');
    }
    final effMaxDl =
        (maxDownloads != null && maxDownloads > 0) ? maxDownloads.clamp(1, 100000) : null;

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
      } else if (_isSensitiveShareFile(checkedPath, config: config)) {
        throw FileSystemException('出于安全保护，禁止直接外链分享敏感密钥或系统配置文件', checkedPath);
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
        } else if (reqMode == 'site' || (reqMode == 'dir' && (spa || hasIndex))) {
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
      pinCode: cleanPin.isEmpty ? null : cleanPin,
      maxDownloads: effMaxDl,
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
      'summary':
          '已开启分享 [${item.label}]${item.hasPin ? " (已设提取码)" : ""} -> ${serialized['primary_url']}',
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

    final reasonText = switch (reason) {
      'expired' => '到期自动收起',
      'max_downloads' => '达到下载次数上限自动收起',
      _ => '手动收起',
    };

    StructuredEventBus.instance.emit({
      'kind': 'info',
      'badge': '随手分享',
      'level': 'INFO',
      'summary': '已收起分享 [${item.label}] ($reasonText)',
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

  Future<Map<String, dynamic>> getDashboardSummary(
    ServerConfig config, {
    bool forcePortScan = false,
  }) async {
    await purgeExpired();
    final saved = loadSavedConfig(config.configFile);
    final livePort =
        int.tryParse('${saved['port'] ?? config.port}') ?? config.port;
    final ts = await probeTailscaleStatus();
    final ifaces = await listHostNetworkInterfaces();
    final pubBases = _discoverActivePublicGatewayBases(saved);
    final cfInstalled = findCloudflared() != null;
    final activePorts = await scanActiveLocalDevPorts(
      excludePort: livePort,
      forceRefresh: forcePortScan,
    );

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
        unawaited(
          closeExposure(
            id,
            reason: item.isDownloadExhausted ? 'max_downloads' : 'expired',
          ),
        );
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

    // Optional PIN lock enforcement (supports HTML form POST, HttpOnly cookie,
    // ?pin=<code> query param, and X-Share-Pin header for CLI/SDK tools)
    String? setPinCookieHeader;
    if (item.hasPin) {
      final expectedToken = _computeSharePinToken(item);
      final cookieName = 'mcp_share_${item.id}';
      final cookieVal = _extractCookieValue(req, cookieName) ?? '';
      final headerPin = (req.headers['x-share-pin'] ?? '').trim();
      final queryPin = (req.url.queryParameters['pin'] ?? '').trim();

      if (req.method == 'POST' &&
          req.url.queryParameters['__pin_unlock'] == '1') {
        final formBody = await req.readAsString();
        var submittedPin = '';
        for (final pair in formBody.split('&')) {
          final kv = pair.split('=');
          if (kv.isNotEmpty && kv[0] == 'pin' && kv.length > 1) {
            submittedPin = Uri.decodeQueryComponent(kv[1]).trim();
          }
        }
        if (constantTimeEquals(submittedPin, item.pinCode!)) {
          final redirectTarget = req.requestedUri.path;
          return Response.seeOther(
            redirectTarget,
            headers: {
              'set-cookie':
                  '$cookieName=$expectedToken; Path=/share/${item.id}; HttpOnly; SameSite=Lax; Max-Age=86400',
            },
          );
        }
        return Response(
          401,
          body: _renderPinPromptHtml(item, req.requestedUri.path, error: '提取码不正确，请重新输入'),
          headers: const {
            'content-type': 'text/html; charset=utf-8',
            'cache-control': 'no-store',
          },
        );
      }

      var authorized = false;
      if (cookieVal.isNotEmpty &&
          constantTimeEquals(cookieVal, expectedToken)) {
        authorized = true;
      } else if (headerPin.isNotEmpty &&
          constantTimeEquals(headerPin, item.pinCode!)) {
        authorized = true;
      } else if (queryPin.isNotEmpty &&
          constantTimeEquals(queryPin, item.pinCode!)) {
        authorized = true;
        setPinCookieHeader =
            '$cookieName=$expectedToken; Path=/share/${item.id}; HttpOnly; SameSite=Lax; Max-Age=86400';
      }

      if (!authorized) {
        final acceptsHtml = (req.headers['accept'] ?? '').contains('text/html');
        if (acceptsHtml) {
          return Response(
            401,
            body: _renderPinPromptHtml(item, req.requestedUri.path),
            headers: const {
              'content-type': 'text/html; charset=utf-8',
              'cache-control': 'no-store',
            },
          );
        }
        return Response(
          401,
          body: 'Share PIN required. Pass ?pin=<code> or X-Share-Pin header.',
          headers: const {'content-type': 'text/plain; charset=utf-8'},
        );
      }
    }

    item.hitCount++;
    item.lastAccessAtMs = DateTime.now().millisecondsSinceEpoch;

    final subSegments = segments.sublist(2);

    Response attachPinCookie(Response res) {
      if (setPinCookieHeader == null) return res;
      return res.change(headers: {'set-cookie': setPinCookieHeader});
    }

    if (item.kind == 'file') {
      return attachPinCookie(await _serveSingleFile(req, item, subSegments));
    }
    if (item.kind == 'folder') {
      final rawReqPath = req.requestedUri.path;
      if (subSegments.isEmpty && !rawReqPath.endsWith('/')) {
        final q = req.requestedUri.hasQuery ? '?${req.requestedUri.query}' : '';
        return attachPinCookie(Response.found('$rawReqPath/$q'));
      }
      return attachPinCookie(
        await _serveFolderExplorer(req, item, subSegments, config: config),
      );
    }
    if (item.kind == 'site') {
      final rawReqPath = req.requestedUri.path;
      if (subSegments.isEmpty && !rawReqPath.endsWith('/')) {
        final q = req.requestedUri.hasQuery ? '?${req.requestedUri.query}' : '';
        return attachPinCookie(Response.found('$rawReqPath/$q'));
      }
      return attachPinCookie(
        await _serveStaticWebsite(req, item, subSegments, config: config),
      );
    }
    if (item.kind == 'port' && item.targetPort != null) {
      return attachPinCookie(await _proxyLocalPort(req, item, subSegments));
    }

    return Response.notFound('Unsupported share item.');
  }

  bool _consumeDownloadQuotaOrReject(ExposureItem item, Request req) {
    if (item.maxDownloads == null || item.maxDownloads! <= 0) return true;
    if (req.method == 'HEAD') return !item.isDownloadExhausted;
    // Do not charge multiple downloads when an HTML5 <video>/<audio> player scrubs non-zero byte ranges
    final rangeHdr = req.headers['range'] ?? '';
    final isMidStreamSeek =
        rangeHdr.startsWith('bytes=') && !rangeHdr.startsWith('bytes=0-');
    if (isMidStreamSeek) {
      return item.downloadCount <= item.maxDownloads!;
    }
    if (item.downloadCount >= item.maxDownloads!) {
      unawaited(closeExposure(item.id, reason: 'max_downloads'));
      return false;
    }
    item.downloadCount++;
    if (item.downloadCount >= item.maxDownloads!) {
      // Schedule graceful cleanup once the final allowed download finishes starting
      Future<void>.delayed(const Duration(seconds: 3), () {
        if (_items.containsKey(item.id) && item.isDownloadExhausted) {
          unawaited(closeExposure(item.id, reason: 'max_downloads'));
        }
      });
    }
    return true;
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

    if (!_consumeDownloadQuotaOrReject(item, req)) {
      return Response.notFound(
        _renderExpiredHtml(),
        headers: const {'content-type': 'text/html; charset=utf-8'},
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
    List<String> subSegments, {
    required ServerConfig config,
  }) async {
    final relParts = subSegments.where((s) => s.isNotEmpty).toList();
    final safePath = await _resolveSafeSharePath(
      item.target,
      relParts,
      config: config,
    );
    if (safePath == null) {
      return Response.forbidden('Forbidden path or symlink traversal.');
    }

    final candStat = await PrivFs.stat(safePath);
    if (candStat.isDirectory) {
      final rawReqPath = req.requestedUri.path;
      if (!rawReqPath.endsWith('/')) {
        final q = req.requestedUri.hasQuery ? '?${req.requestedUri.query}' : '';
        return Response.found('$rawReqPath/$q');
      }
      if (req.url.queryParameters['zip'] == '1') {
        if (!_consumeDownloadQuotaOrReject(item, req)) {
          return Response.notFound(
            _renderExpiredHtml(),
            headers: const {'content-type': 'text/html; charset=utf-8'},
          );
        }
        return _serveDirectoryAsZip(item, safePath, relParts, config: config);
      }
      return _renderDirectoryListing(item, safePath, relParts, config: config);
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
      final parentParts =
          relParts.length <= 1 ? const <String>[] : relParts.sublist(0, relParts.length - 1);
      final parentHref = parentParts.isEmpty
          ? '/share/${item.id}/'
          : '/share/${item.id}/${parentParts.map(Uri.encodeComponent).join('/')}/';
      final parentLabel = parentParts.isEmpty ? '全部文件' : parentParts.last;

      // Build clickable breadcrumb bar & previous/next sibling file navigation
      final crumbs = StringBuffer('<a href="/share/${item.id}/">全部文件</a>');
      for (var i = 0; i < parentParts.length; i++) {
        final h =
            '/share/${item.id}/${parentParts.sublist(0, i + 1).map(Uri.encodeComponent).join('/')}/';
        crumbs.write(
          ' <span class="sep">/</span> <a href="$h">${_htmlEscape(parentParts[i])}</a>',
        );
      }
      crumbs.write(
        ' <span class="sep">/</span> <span>${_htmlEscape(p.basename(safePath))}</span>',
      );

      String? prevHref;
      String? prevName;
      String? nextHref;
      String? nextName;
      String? siblingPosLabel;
      try {
        final parentDir = p.dirname(safePath);
        final rawSiblings = await PrivFs.listDir(parentDir);
        final fileSiblings = rawSiblings
            .where((e) =>
                !e.isDirectory &&
                !e.name.startsWith('.') &&
                !_isSensitiveShareFile(p.join(parentDir, e.name), config: config))
            .toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        final curName = p.basename(safePath);
        final curIdx = fileSiblings.indexWhere((e) => e.name == curName);
        if (curIdx >= 0 && fileSiblings.length > 1) {
          siblingPosLabel = '${curIdx + 1} / ${fileSiblings.length}';
          final prefixHref = parentHref;
          if (curIdx > 0) {
            prevName = fileSiblings[curIdx - 1].name;
            prevHref = '$prefixHref${Uri.encodeComponent(prevName)}';
          }
          if (curIdx + 1 < fileSiblings.length) {
            nextName = fileSiblings[curIdx + 1].name;
            nextHref = '$prefixHref${Uri.encodeComponent(nextName)}';
          }
        }
      } catch (_) {}

      return _renderUnifiedSingleFilePage(
        item: item,
        filePath: safePath,
        displayTitle: p.basename(safePath),
        rawHref: '$baseFileHref?raw=1',
        dlHref: '$baseFileHref?download=1',
        backToFolderHref: parentHref,
        backToFolderLabel: parentLabel,
        breadcrumbHtml: crumbs.toString(),
        prevFileHref: prevHref,
        prevFileName: prevName,
        nextFileHref: nextHref,
        nextFileName: nextName,
        siblingPosLabel: siblingPosLabel,
      );
    }

    if (!_consumeDownloadQuotaOrReject(item, req)) {
      return Response.notFound(
        _renderExpiredHtml(),
        headers: const {'content-type': 'text/html; charset=utf-8'},
      );
    }

    return _streamFileWithRange(
      req,
      item,
      safePath,
      forceDownload: forceDownload,
    );
  }

  /// Mode 3: Static Website / Single-Page HTML Share (renders website directly, never exposes directory list)
  Future<Response> _serveStaticWebsite(
    Request req,
    ExposureItem item,
    List<String> subSegments, {
    required ServerConfig config,
  }) async {
    final relParts = subSegments.where((s) => s.isNotEmpty).toList();

    // Case 3A: Single `.html` file shared as a live webpage (+ safe sibling asset resolution)
    if (!item.targetIsDirectory) {
      if (relParts.isEmpty) {
        return _streamFileWithRange(req, item, item.target);
      }
      final parentRoot = p.dirname(item.target);
      final assetPath = await _resolveSafeSharePath(
        parentRoot,
        relParts,
        config: config,
      );
      if (assetPath == null || assetPath == p.canonicalize(parentRoot)) {
        return Response.forbidden('Forbidden asset path.');
      }
      final assetStat = await PrivFs.stat(assetPath);
      if (assetStat.isFile) {
        return _streamFileWithRange(req, item, assetPath);
      }
      return Response.notFound('Static asset not found.');
    }

    // Case 3B: Website Directory (`index.html` + static assets + optional SPA fallback)
    final safePath = await _resolveSafeSharePath(
      item.target,
      relParts,
      config: config,
      allowMissingLeaf: item.spa,
    );
    if (safePath == null) {
      return Response.forbidden('Forbidden path or symlink traversal.');
    }

    final candStat = await PrivFs.stat(safePath);
    if (candStat.isDirectory) {
      for (final idxName in const ['index.html', 'index.htm']) {
        final idxSafe = await _resolveSafeSharePath(
          safePath,
          [idxName],
          config: config,
        );
        if (idxSafe != null && (await PrivFs.stat(idxSafe)).isFile) {
          return _streamFileWithRange(req, item, idxSafe);
        }
      }
      if (item.spa) {
        final spaIndex = await _resolveSafeSharePath(
          item.target,
          const ['index.html'],
          config: config,
        );
        if (spaIndex != null && (await PrivFs.stat(spaIndex)).isFile) {
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
      final spaIndex = await _resolveSafeSharePath(
        item.target,
        const ['index.html'],
        config: config,
      );
      if (spaIndex != null && (await PrivFs.stat(spaIndex)).isFile) {
        return _streamFileWithRange(req, item, spaIndex);
      }
    }

    if (!candStat.isFile) {
      return Response.notFound('File not found.');
    }

    return _streamFileWithRange(req, item, safePath);
  }

  /// Streams a folder as a standard `.zip` archive in 64KB chunks without
  /// loading file contents into heap memory.
  Future<Response> _serveDirectoryAsZip(
    ExposureItem item,
    String dirPath,
    List<String> relParts, {
    required ServerConfig config,
  }) async {
    final filesToPack = <({String fullPath, String relPath, DateTime modified})>[];
    var accumulatedBytes = 0;
    const maxZipBytes = 512 * 1024 * 1024; // 512 MB streaming cap
    final useBridge = await PrivFs.useBridgeForPath(dirPath);
    final rootReal = !useBridge
        ? Directory(dirPath).resolveSymbolicLinksSync()
        : p.normalize(p.absolute(dirPath));

    Future<void> walk(String currentDir, String relPrefix) async {
      final entries = await PrivFs.listDir(currentDir);
      entries.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      for (final e in entries) {
        if (e.name.startsWith('.') || defaultIgnoreDirs.contains(e.name)) {
          continue;
        }
        final full = p.join(currentDir, e.name);
        if (!useBridge) {
          final linkType = FileSystemEntity.typeSync(full, followLinks: false);
          if (linkType == FileSystemEntityType.link) {
            try {
              final resolved = e.isDirectory
                  ? Directory(full).resolveSymbolicLinksSync()
                  : File(full).resolveSymbolicLinksSync();
              if (!isWithin(resolved, rootReal)) continue;
            } catch (_) {
              continue;
            }
          }
        }
        if (_isSensitiveShareFile(full, config: config)) continue;
        final nextRel = relPrefix.isEmpty ? e.name : '$relPrefix/${e.name}';
        if (e.isDirectory) {
          await walk(full, nextRel);
        } else {
          if (accumulatedBytes + e.size > maxZipBytes) continue;
          accumulatedBytes += e.size;
          final st = await PrivFs.stat(full);
          if (st.isFile) {
            filesToPack.add((
              fullPath: full,
              relPath: nextRel,
              modified: st.modified,
            ));
          }
        }
      }
    }

    await walk(dirPath, '');
    final zipName = relParts.isEmpty ? item.label : relParts.last;
    final encodedZip = Uri.encodeComponent('$zipName.zip');
    final bodyStream = _streamPkZipEntries(
      filesToPack,
      onBytesEmitted: (delta) {
        item.bytesSent += delta;
      },
    );

    return Response.ok(
      bodyStream,
      headers: {
        'content-type': 'application/zip',
        'content-disposition': "attachment; filename*=UTF-8''$encodedZip",
        'cache-control': 'no-store',
      },
      context: const {'shelf.io.buffer_output': false},
    );
  }

  Future<Response> _renderDirectoryListing(
    ExposureItem item,
    String dirPath,
    List<String> relParts, {
    required ServerConfig config,
  }) async {
    final rawEntries = await PrivFs.listDir(dirPath);
    final useBridge = await PrivFs.useBridgeForPath(item.target);
    final rootReal = !useBridge
        ? Directory(item.target).resolveSymbolicLinksSync()
        : p.normalize(p.absolute(item.target));

    final entries = rawEntries.where((e) {
      if (e.name.startsWith('.')) return false;
      final full = p.join(dirPath, e.name);
      if (_isSensitiveShareFile(full, config: config)) return false;
      if (!useBridge) {
        final t = FileSystemEntity.typeSync(full, followLinks: false);
        if (t == FileSystemEntityType.link) {
          try {
            final targetType = FileSystemEntity.typeSync(full, followLinks: true);
            if (targetType == FileSystemEntityType.notFound) return false;
            final resolved = targetType == FileSystemEntityType.directory
                ? Directory(full).resolveSymbolicLinksSync()
                : File(full).resolveSymbolicLinksSync();
            if (!isWithin(resolved, rootReal) ||
                _isSensitiveShareFile(resolved, config: config)) {
              return false;
            }
          } catch (_) {
            return false;
          }
        }
      }
      return true;
    }).toList()
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
        ':root{--bg:#FAF9F6;--card:rgba(255,255,255,0.88);--soft:#EEF0F6;--hover:#E4E7F2;--ink:#121316;--muted:#646873;--accent:#4F46E5}'
        '@media(prefers-color-scheme:dark){:root{--bg:#111317;--card:rgba(24,26,32,0.88);--soft:#1E212B;--hover:#272B38;--ink:#F4F5F7;--muted:#8E93A0;--accent:#6366F1}}'
        'body{background-image:radial-gradient(640px 420px at 12% 0%,rgba(79,70,229,0.09),transparent 70%),radial-gradient(560px 380px at 90% 100%,rgba(14,165,233,0.07),transparent 70%);background-attachment:fixed}'
        '.top{backdrop-filter:blur(18px);-webkit-backdrop-filter:blur(18px);border-radius:16px}'
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
    String? backToFolderLabel,
    String? breadcrumbHtml,
    String? prevFileHref,
    String? prevFileName,
    String? nextFileHref,
    String? nextFileName,
    String? siblingPosLabel,
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

    final backLabel = (backToFolderLabel != null &&
            backToFolderLabel.isNotEmpty &&
            backToFolderLabel != '全部文件')
        ? '← 返回所在文件夹 (${_htmlEscape(backToFolderLabel)})'
        : '← 返回所在文件夹';
    final backLink = backToFolderHref != null
        ? '<a class="btn ghost" href="$backToFolderHref">$backLabel</a>'
        : '';

    final crumbBar = breadcrumbHtml != null
        ? '<div class="crumbs">$breadcrumbHtml</div>'
        : '';

    final siblingNav = (prevFileHref != null || nextFileHref != null)
        ? '<div class="sib-bar">'
            '<div>${prevFileHref != null ? '<a class="sib-btn" id="prevLink" href="$prevFileHref" title="${_htmlEscape(prevFileName ?? '')}">← 上一文件: ${_htmlEscape(prevFileName ?? '')}</a>' : '<span class="sib-muted">已是第一个文件</span>'}</div>'
            '${siblingPosLabel != null ? '<div class="sib-pos">$siblingPosLabel</div>' : ''}'
            '<div>${nextFileHref != null ? '<a class="sib-btn" id="nextLink" href="$nextFileHref" title="${_htmlEscape(nextFileName ?? '')}">下一文件: ${_htmlEscape(nextFileName ?? '')} →</a>' : '<span class="sib-muted">已是最后一个文件</span>'}</div>'
            '</div>'
        : '';

    final keyNavScript = (prevFileHref != null || nextFileHref != null)
        ? '<script>document.addEventListener("keydown",function(e){if(e.target&&(e.target.tagName==="INPUT"||e.target.tagName==="VIDEO"||e.target.tagName==="AUDIO"))return;if(e.key==="ArrowLeft"){var p=document.getElementById("prevLink");if(p)p.click();}else if(e.key==="ArrowRight"){var n=document.getElementById("nextLink");if(n)n.click();}});</script>'
        : '';

    final quotaMeta = item.remainingDownloads != null
        ? ' · 剩余可下载 ${item.remainingDownloads} 次'
        : '';

    final html = '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>${_htmlEscape(displayTitle)} · 在线预览</title>'
        '<style>'
        ':root{--bg:#FAF9F6;--card:rgba(255,255,255,0.88);--soft:#EEF0F6;--hover:#E4E7F2;--ink:#121316;--muted:#646873;--accent:#4F46E5}'
        '@media(prefers-color-scheme:dark){:root{--bg:#111317;--card:rgba(24,26,32,0.88);--soft:#1E212B;--hover:#272B38;--ink:#F4F5F7;--muted:#8E93A0;--accent:#6366F1}}'
        'body{background-image:radial-gradient(640px 420px at 12% 0%,rgba(79,70,229,0.09),transparent 70%),radial-gradient(560px 380px at 90% 100%,rgba(14,165,233,0.07),transparent 70%);background-attachment:fixed}'
        '*{box-sizing:border-box}body{margin:0;padding:24px 14px;background:var(--bg);color:var(--ink);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei UI",sans-serif;display:flex;justify-content:center}'
        '.card{width:100%;max-width:940px;background:var(--card);border-radius:24px;padding:22px 24px;box-shadow:0 14px 44px rgba(0,0,0,.08)}'
        '.crumbs{font-size:13px;color:var(--muted);margin-bottom:10px;word-break:break-all}.crumbs a{color:var(--accent);text-decoration:none;font-weight:600}.sep{margin:0 4px;opacity:.5}'
        '.top{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:center;gap:12px;margin-bottom:16px}'
        '.title{font-size:18px;font-weight:700;word-break:break-all}.meta{font-size:12.5px;color:var(--muted);margin-top:4px;font-family:ui-monospace,monospace}'
        '.btns{display:flex;flex-wrap:wrap;gap:8px;align-items:center}'
        '.btn{padding:8px 15px;border-radius:99px;text-decoration:none;font-size:13px;font-weight:600;background:var(--soft);color:var(--ink);transition:background .15s}'
        '.btn:hover{background:var(--hover)}'
        '.btn.pri{background:var(--accent);color:#FFF}.btn.big{padding:11px 22px;font-size:14px;margin-top:8px;display:inline-block}'
        '.btn.ghost{color:var(--accent)}'
        '.sib-bar{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:center;gap:10px;margin-top:16px;padding-top:14px;border-top:1px solid var(--soft);font-size:13px}'
        '.sib-btn{color:var(--ink);text-decoration:none;background:var(--soft);padding:7px 14px;border-radius:99px;font-weight:500;max-width:340px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;display:inline-block}'
        '.sib-btn:hover{background:var(--hover)}.sib-pos{font-family:ui-monospace,monospace;color:var(--muted);font-size:12px}.sib-muted{color:var(--muted);font-size:12.5px;opacity:.7}'
        'video{width:100%;max-height:74vh;border-radius:16px;background:#000;display:block}'
        '.img-box{background:var(--soft);border-radius:16px;padding:16px;text-align:center}img{max-width:100%;max-height:72vh;border-radius:10px}'
        '.pad-box{background:var(--soft);border-radius:16px;padding:28px}audio{width:100%}'
        '.pdf-frame{width:100%;height:74vh;border:none;border-radius:16px;background:var(--soft)}'
        '.code-box{margin:0;padding:18px;border-radius:16px;background:#191816;color:#EDEAE2;font-family:ui-monospace,Consolas,monospace;font-size:13px;line-height:1.6;overflow:auto;max-height:70vh;white-space:pre-wrap;word-break:break-word}'
        '.dl-stage{background:var(--soft);border-radius:18px;padding:42px 20px;text-align:center;display:flex;flex-direction:column;align-items:center;gap:8px}'
        '.dl-name{font-size:17px;font-weight:700}.dl-sub{font-size:13.5px;color:var(--muted)}'
        '</style></head><body><div class="card">$crumbBar<div class="top"><div>'
        '<div class="title">${_htmlEscape(displayTitle)}</div>'
        '<div class="meta">${_htmlEscape(fileName)} · $sizeHuman$quotaMeta</div>'
        '</div><div class="btns">$backLink'
        '<a class="btn" href="$rawHref" target="_blank">原始直链</a>'
        '<a class="btn pri" href="$dlHref">下载文件</a>'
        '</div></div>$stageHtml$siblingNav</div>$keyNavScript</body></html>';

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

    final stat = await PrivFs.stat(filePath);
    if (!stat.isFile) {
      return Response.notFound('File not found.');
    }
    final totalLen = stat.size;

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

        final rangeStream = await PrivFs.openRead(filePath, start, end + 1);
        return Response(
          206,
          body: rangeStream,
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
    final fullStream = await PrivFs.openRead(filePath);
    return Response.ok(
      fullStream,
      headers: {...baseHeaders, 'content-length': '$totalLen'},
      context: const {'shelf.io.buffer_output': false},
    );
  }

  /// Mode 4: Reverse proxy local port (`127.0.0.1:<port>`) with full-duplex
  /// WebSocket upgrade tunneling (supporting Vite/Next.js HMR, Gradio, Jupyter)
  /// and unbuffered SSE streaming.
  Future<Response> _proxyLocalPort(
    Request req,
    ExposureItem item,
    List<String> subSegments,
  ) async {
    final port = item.targetPort!;
    final subPath = '/${subSegments.join('/')}';
    final query = req.requestedUri.hasQuery ? '?${req.requestedUri.query}' : '';
    final targetPathAndQuery = '$subPath$query';

    // Full-duplex WebSocket / protocol Upgrade tunneling via raw TCP socket
    final upgradeHeader = (req.headers['upgrade'] ?? '').trim();
    final connHeader = (req.headers['connection'] ?? '').toLowerCase();
    final isWsUpgrade = upgradeHeader.toLowerCase() == 'websocket' ||
        (upgradeHeader.isNotEmpty && connHeader.contains('upgrade'));

    if (isWsUpgrade && req.canHijack) {
      // Connect upstream BEFORE hijacking so we can still return a friendly 502 if closed
      Socket upstream;
      try {
        upstream = await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(seconds: 5),
        );
        upstream.setOption(SocketOption.tcpNoDelay, true);
      } catch (e) {
        return Response(
          502,
          body: '无法建立本地端口 WebSocket 连接 127.0.0.1:$port ($e)',
          headers: const {'content-type': 'text/plain; charset=utf-8'},
        );
      }

      // NOTE: req.hijack throws HijackException intentionally for shelf_io!
      req.hijack((StreamChannel<List<int>> clientChannel) {
        final reqBuf = StringBuffer()
          ..write('${req.method} $targetPathAndQuery HTTP/1.1\r\n')
          ..write('Host: 127.0.0.1:$port\r\n');
        req.headers.forEach((k, v) {
          final lower = k.toLowerCase();
          if (lower == 'host') return;
          reqBuf.write('$k: $v\r\n');
        });
        reqBuf.write('X-Forwarded-Prefix: /share/${item.id}\r\n\r\n');
        upstream.add(utf8.encode(reqBuf.toString()));

        var closedBoth = false;
        void tearDown() {
          if (closedBoth) return;
          closedBoth = true;
          try {
            upstream.destroy();
          } catch (_) {}
          try {
            clientChannel.sink.close();
          } catch (_) {}
        }

        clientChannel.stream.listen(
          (chunk) {
            try {
              upstream.add(chunk);
            } catch (_) {
              tearDown();
            }
          },
          onDone: tearDown,
          onError: (_) => tearDown(),
          cancelOnError: true,
        );

        upstream.listen(
          (chunk) {
            item.bytesSent += chunk.length;
            try {
              clientChannel.sink.add(chunk);
            } catch (_) {
              tearDown();
            }
          },
          onDone: tearDown,
          onError: (_) => tearDown(),
          cancelOnError: true,
        );
      });
    }

    final upstreamUri = Uri.parse('http://127.0.0.1:$port$targetPathAndQuery');
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
      final origHost = req.headers['host'] ?? '';
      if (origHost.isNotEmpty) {
        upReq.headers.set('x-forwarded-host', origHost);
      }
      upReq.headers.set(
        'x-forwarded-proto',
        req.requestedUri.scheme.isNotEmpty ? req.requestedUri.scheme : 'http',
      );
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

  String _renderPinPromptHtml(
    ExposureItem item,
    String actionPath, {
    String? error,
  }) =>
      '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<title>${_htmlEscape(item.label)} · 输入提取码</title>'
      '<style>'
      ':root{--bg:#FAF9F6;--card:rgba(255,255,255,0.90);--soft:#EEF0F6;--ink:#121316;--muted:#646873;--accent:#4F46E5;--err:#DC2626}'
      '@media(prefers-color-scheme:dark){:root{--bg:#111317;--card:rgba(24,26,32,0.90);--soft:#1E212B;--ink:#F4F5F7;--muted:#8E93A0;--accent:#6366F1;--err:#F87171}}'
      'body{background-image:radial-gradient(560px 380px at 20% 10%,rgba(79,70,229,0.10),transparent 70%),radial-gradient(520px 360px at 80% 90%,rgba(14,165,233,0.08),transparent 70%)}'
      '*{box-sizing:border-box}body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;background:var(--bg);color:var(--ink);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC",sans-serif;padding:16px}'
      '.box{width:100%;max-width:380px;padding:30px 28px;background:var(--card);border-radius:24px;box-shadow:0 14px 40px rgba(0,0,0,.07);text-align:center}'
      'h2{margin:0 0 6px;font-size:19px;font-weight:700}p{margin:0 0 18px;color:var(--muted);font-size:13.5px;line-height:1.55}'
      'input{width:100%;padding:12px 16px;border-radius:14px;border:none;background:var(--soft);color:var(--ink);font-size:16px;text-align:center;letter-spacing:.12em;outline:none;margin-bottom:12px}'
      'button{width:100%;padding:12px;border-radius:99px;border:none;background:var(--accent);color:#FFF;font-size:14px;font-weight:600;cursor:pointer}'
      '.err{color:var(--err);font-size:13px;margin-bottom:12px;font-weight:500}'
      '</style></head><body><form class="box" method="POST" action="${_htmlEscape(actionPath)}?__pin_unlock=1">'
      '<h2>${_htmlEscape(item.label)}</h2>'
      '<p>这条分享已开启口令保护，请输入提取码继续访问。</p>'
      '${error != null ? '<div class="err">${_htmlEscape(error)}</div>' : ''}'
      '<input type="password" name="pin" placeholder="输入提取码" autofocus required autocomplete="off">'
      '<button type="submit">解锁查看</button></form></body></html>';

  String _renderExpiredHtml() =>
      '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<title>分享链接已收起</title>'
      '<style>body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;background:#FAF9F6;color:#121316;font-family:-apple-system,sans-serif;text-align:center;background-image:radial-gradient(520px 360px at 50% 35%,rgba(79,70,229,0.10),transparent 70%)}@media(prefers-color-scheme:dark){body{background:#111317;color:#F4F5F7}}'
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
        'Share a local single file (streaming video/PDF/APK preview), folder directory explorer (browse subfolders and click files to preview with breadcrumbs & sibling navigation), '
        'static website / single HTML page (renders directly as a live webpage), or local port (e.g. 3000/5173 with full WebSocket HMR support) via Tailscale, gateway domain, or temporary tunnel. '
        'Supports optional PIN code and max_downloads quota. Actions: "open", "close", "close_all", "list".',
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
              '"file" (single file preview/download), "folder" (directory browser with subfolder navigation -> single file preview), "site" (render single .html or website folder directly as live site), "port" (reverse proxy local port + WebSocket), or "auto".',
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
        'pin_code': {
          'type': 'string',
          'description':
              'Optional 4-16 character access PIN required before viewing or downloading.',
        },
        'max_downloads': {
          'type': 'integer',
          'description':
              'Optional maximum download count (e.g. 1 for burn-after-download) before automatically closing the share link.',
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
        final pinCode = (args['pin_code'] ?? args['pin'])?.toString();
        final maxDl = args['max_downloads'] is int
            ? args['max_downloads'] as int
            : int.tryParse('${args['max_downloads'] ?? ''}');
        final spa = args['spa'] == true;

        final created = await ExposureManager.instance.openExposure(
          config: config,
          rawTarget: rawTarget,
          mode: mode,
          portOverride: portVal,
          scope: scope,
          label: label,
          ttlMinutes: ttl,
          pinCode: pinCode,
          maxDownloads: maxDl,
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
