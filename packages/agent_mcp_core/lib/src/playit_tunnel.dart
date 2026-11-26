import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'process_tools.dart';

const String kPlayitApiBase = 'https://api.playit.gg';

Map<String, dynamic> getPlayitDownloadInfo() {
  final binDir = StoragePaths.instance.binDir;
  final arch = Platform.version.toLowerCase();
  final isArm = arch.contains('arm64') || arch.contains('aarch64');

  String asset;
  File target;
  if (Platform.isWindows) {
    asset = 'playitd-windows-x86_64-signed.exe';
    target = File(p.join(binDir.path, 'playitd.exe'));
  } else if (Platform.isMacOS) {
    asset = 'playit-macos-universal.tar.gz';
    target = File(p.join(binDir.path, 'playitd'));
  } else {
    asset = isArm ? 'playit-linux-aarch64' : 'playit-linux-amd64';
    target = File(p.join(binDir.path, 'playitd'));
  }

  return {
    'asset': asset,
    'target': target,
    'download_url':
        'https://github.com/playit-cloud/playit-agent/releases/latest/download/$asset',
    'releases_url': 'https://github.com/playit-cloud/playit-agent/releases/latest',
  };
}

File? findPlayitd() {
  final exeNames = Platform.isWindows
      ? const ['playitd.exe', 'playit.exe']
      : const ['playitd', 'playit'];

  for (final exe in exeNames) {
    final localBin = File(p.join(StoragePaths.instance.binDir.path, exe));
    if (localBin.existsSync()) return localBin;
  }

  final pathEnv = Platform.environment['PATH'] ?? '';
  final sep = Platform.isWindows ? ';' : ':';
  for (final dir in pathEnv.split(sep)) {
    final d = dir.trim();
    if (d.isEmpty) continue;
    for (final exe in exeNames) {
      final candidate = File(p.join(d, exe));
      if (candidate.existsSync()) return candidate;
    }
  }

  if (Platform.isWindows) {
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final stdPaths = <String>[
      r'C:\Program Files\playit_gg\bin\playitd.exe',
      r'C:\Program Files\playit_gg\playitd.exe',
      r'C:\Program Files (x86)\playit_gg\bin\playitd.exe',
      if (localAppData.isNotEmpty)
        p.join(localAppData, 'Microsoft', 'WinGet', 'Links', 'playitd.exe'),
    ];
    for (final sp in stdPaths) {
      final f = File(sp);
      if (f.existsSync()) return f;
    }
  } else {
    for (final sp in const [
      '/opt/playit/playitd',
      '/usr/local/bin/playitd',
      '/usr/bin/playitd',
      '/opt/homebrew/bin/playitd',
    ]) {
      final f = File(sp);
      if (f.existsSync()) return f;
    }
  }
  return null;
}

String _cachedPlayitPath = '';
String _cachedPlayitVer = '';
bool _probingPlayitVer = false;

Future<String> warmPlayitVersionAsync([File? binary]) async {
  final bin = binary ?? findPlayitd();
  if (bin == null || !bin.existsSync()) return '';
  if (_cachedPlayitPath == bin.path && _cachedPlayitVer.isNotEmpty) {
    return _cachedPlayitVer;
  }
  if (_probingPlayitVer) return _cachedPlayitVer;
  _probingPlayitVer = true;
  try {
    final baseName = p.basenameWithoutExtension(bin.path).toLowerCase();
    final args = baseName == 'playit' ? const ['version'] : const ['--version'];
    final res = await Process.run(
      bin.path,
      args,
      runInShell: false,
    ).timeout(const Duration(seconds: 4));
    final out = '${res.stdout}\n${res.stderr}'.trim();
    final m = RegExp(r'([0-9]+\.[0-9]+\.[0-9]+)').firstMatch(out);
    final ver = m != null ? m.group(1)! : '2.0';
    _cachedPlayitPath = bin.path;
    _cachedPlayitVer = ver;
    return ver;
  } catch (_) {
    return _cachedPlayitVer;
  } finally {
    _probingPlayitVer = false;
  }
}

String getPlayitVersion(File? binary) {
  if (binary == null || !binary.existsSync()) return '';
  if (_cachedPlayitPath == binary.path && _cachedPlayitVer.isNotEmpty) {
    return _cachedPlayitVer;
  }
  unawaited(warmPlayitVersionAsync(binary));
  return _cachedPlayitVer;
}

String sanitizePlayitProfileKey(String profileId) {
  final cleaned =
      profileId.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  return cleaned.isEmpty ? 'default' : cleaned;
}

File resolvePlayitSecretFile(String profileId, [String? customSecretPath]) {
  final rawCustom = (customSecretPath ?? '').trim();
  if (rawCustom.isNotEmpty) {
    return File(expandAndResolvePath(rawCustom));
  }
  final dir = Directory(p.join(StoragePaths.instance.dataDir.path, 'playit'));
  final key = sanitizePlayitProfileKey(profileId);
  return File(p.join(dir.path, 'playit_$key.toml'));
}

Directory resolvePlayitCertDir(String profileId) {
  final dir = Directory(p.join(StoragePaths.instance.dataDir.path, 'playit'));
  final key = sanitizePlayitProfileKey(profileId);
  return Directory(p.join(dir.path, 'certs_$key'));
}

File resolvePlayitLogFile(String profileId) {
  final key = sanitizePlayitProfileKey(profileId);
  return File(p.join(StoragePaths.instance.logsDir.path, 'playit_$key.log'));
}

String? readPlayitSecretKey(File secretFile) {
  if (!secretFile.existsSync()) return null;
  try {
    final raw = secretFile.readAsStringSync().trim();
    if (raw.isEmpty) return null;
    final tomlMatch = RegExp(
      r'''^\s*(?:secret_key|secret)\s*=\s*["']([a-fA-F0-9]{24,128})["']''',
      multiLine: true,
    ).firstMatch(raw);
    if (tomlMatch != null) {
      return tomlMatch.group(1)!.trim().toLowerCase();
    }
    if (RegExp(r'^[a-fA-F0-9]{24,128}$').hasMatch(raw)) {
      return raw.toLowerCase();
    }
  } catch (_) {}
  return null;
}

void writePlayitSecretToml(File secretFile, String secretKey) {
  final cleanKey = secretKey.trim().toLowerCase();
  secretFile.parent.createSync(recursive: true);
  final tomlPath = secretFile.path.toLowerCase().endsWith('.toml')
      ? secretFile
      : File('${secretFile.path}.toml');
  tomlPath.writeAsStringSync('secret_key = "$cleanKey"\n', flush: true);
  if (tomlPath.path != secretFile.path) {
    secretFile.writeAsStringSync('secret_key = "$cleanKey"\n', flush: true);
  }
  if (!Platform.isWindows) {
    try {
      Process.runSync('chmod', ['600', secretFile.path]);
    } catch (_) {}
  }
}

String generatePlayitClaimCode([int byteCount = 5]) {
  final rng = Random.secure();
  final bytes = List<int>.generate(byteCount, (_) => rng.nextInt(256));
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

String buildPlayitClaimUrl(String claimCode) {
  final clean = claimCode.trim().toLowerCase();
  return 'https://playit.gg/claim/$clean';
}

bool isValidHexClaimCode(String code) {
  final c = code.trim();
  return c.length >= 6 &&
      c.length <= 64 &&
      c.length.isEven &&
      RegExp(r'^[a-fA-F0-9]+$').hasMatch(c);
}

({String kind, String value}) parsePlayitUserClaimInput(String rawInput) {
  var s = rawInput.trim();
  if (s.isEmpty) return (kind: 'empty', value: '');

  final urlMatch = RegExp(
    r'playit\.gg/claim/([a-fA-F0-9]{6,64})',
    caseSensitive: false,
  ).firstMatch(s);
  if (urlMatch != null) {
    return (kind: 'claim_code', value: urlMatch.group(1)!.toLowerCase());
  }

  final tomlMatch = RegExp(
    r'''(?:secret_key|secret)\s*=\s*["']([a-fA-F0-9]{32,128})["']''',
  ).firstMatch(s);
  if (tomlMatch != null) {
    return (kind: 'secret_key', value: tomlMatch.group(1)!.toLowerCase());
  }

  s = s.replaceAll(RegExp(r'''^["']|["']$'''), '').trim();
  if (RegExp(r'^[a-fA-F0-9]{48,128}$').hasMatch(s)) {
    return (kind: 'secret_key', value: s.toLowerCase());
  }
  if (isValidHexClaimCode(s)) {
    return (kind: 'claim_code', value: s.toLowerCase());
  }
  return (kind: 'invalid', value: s);
}

class _PlayitClaimSession {
  final String profileId;
  final String claimCode;
  final String claimUrl;
  final String claimMode; // 'random' | 'custom'
  final DateTime startedAt = DateTime.now();
  String phase = 'waiting_visit'; // waiting_visit | waiting_approve | exchanging | claimed | rejected | error
  String message = '请在浏览器打开认领链接并登录 Playit.gg 点击批准';
  String error = '';
  bool cancelled = false;

  _PlayitClaimSession({
    required this.profileId,
    required this.claimCode,
    required this.claimUrl,
    required this.claimMode,
  });

  Map<String, dynamic> toJson() => {
        'profile_id': profileId,
        'claim_code': claimCode,
        'claim_url': claimUrl,
        'claim_mode': claimMode,
        'phase': phase,
        'active': !cancelled &&
            (phase == 'waiting_visit' ||
                phase == 'waiting_approve' ||
                phase == 'exchanging'),
        'message': message,
        'error': error,
        'started_at': startedAt.toUtc().toIso8601String(),
      };
}

class _PlayitProc {
  final String profileId;
  final Process proc;
  final File secretFile;
  int localPort;
  String liveUrl = '';
  String displayAddress = '';
  bool connected = false;
  String error = '';
  bool stopped = false;
  bool exited = false;
  bool hasPremium = false;
  String accountStatus = '';
  List<String> availableDomains = const [];
  final List<String> lastLines = [];
  Timer? syncTimer;

  _PlayitProc({
    required this.profileId,
    required this.proc,
    required this.secretFile,
    required this.localPort,
  });
}

class PlayitManager {
  static final PlayitManager instance = PlayitManager._();
  PlayitManager._();

  String apiBaseUrl = kPlayitApiBase;
  Future<Map<String, dynamic>> Function(
    String path,
    Map<String, dynamic> body, {
    String? secretKey,
  })? apiOverrideForTesting;

  final Map<String, _PlayitProc> _procs = {};
  final Map<String, _PlayitClaimSession> _claims = {};
  final Map<String, Map<String, dynamic>> _cachedAgentMeta = {};
  VoidCallback? onStateChanged;

  bool _dlActive = false;
  bool _dlPaused = false;
  bool _dlPauseReq = false;
  bool _dlCancelReq = false;
  int _dlDownloaded = 0;
  int _dlTotal = 0;
  int _dlPercent = 0;
  String _dlStatus = '';
  String _dlError = '';

  Map<String, dynamic> getInstallStatus() => {
        'active': _dlActive,
        'paused': _dlPaused,
        'downloaded': _dlDownloaded,
        'total': _dlTotal,
        'percent': _dlPercent,
        'status': _dlStatus,
        'error': _dlError,
      };

  Map<String, dynamic> getComponentStatus([List<Map<String, dynamic>>? profiles]) {
    final binary = findPlayitd();
    final exe = Platform.isWindows ? 'playitd.exe' : 'playitd';
    final expectedLocal =
        p.normalize(p.absolute(p.join(StoragePaths.instance.binDir.path, exe)));
    final localManaged = binary != null &&
        (Platform.isWindows
            ? p.normalize(binary.absolute.path).toLowerCase() ==
                expectedLocal.toLowerCase()
            : p.normalize(binary.absolute.path) == expectedLocal);
    final dlInfo = getPlayitDownloadInfo();

    final profileStates = <String, dynamic>{};
    if (profiles != null) {
      for (final prof in profiles) {
        final pid = (prof['id'] ?? 'default').toString();
        profileStates[pid] = getProfilePlayitStatus(
          pid,
          customSecretPath: prof['playit_secret_path']?.toString(),
        );
      }
    } else {
      for (final pid in {..._procs.keys, ..._claims.keys, ..._cachedAgentMeta.keys}) {
        profileStates[pid] = getProfilePlayitStatus(pid);
      }
    }

    return {
      'installed': binary != null,
      'binary': binary?.path,
      'version': getPlayitVersion(binary),
      'local_managed': localManaged,
      'download_url': dlInfo['download_url'],
      'releases_url': dlInfo['releases_url'],
      'asset': dlInfo['asset'],
      'install': getInstallStatus(),
      'profiles': profileStates,
    };
  }

  Map<String, dynamic> getProfilePlayitStatus(
    String profileId, {
    String? customSecretPath,
  }) {
    final secretFile = resolvePlayitSecretFile(profileId, customSecretPath);
    final secretKey = readPlayitSecretKey(secretFile);
    final tp = _procs[profileId];
    final claim = _claims[profileId];
    final meta = _cachedAgentMeta[profileId] ?? const <String, dynamic>{};
    final running = tp != null && !tp.exited;

    return {
      'profile_id': profileId,
      'claimed': secretKey != null && secretKey.isNotEmpty,
      'secret_path': secretFile.path,
      'secret_exists': secretFile.existsSync(),
      'running': running,
      'connected': running && tp.connected,
      'live_url': running
          ? tp.liveUrl
          : (meta['live_url'] ?? '').toString(),
      'display_address': running
          ? tp.displayAddress
          : (meta['display_address'] ?? '').toString(),
      'has_premium': running ? tp.hasPremium : (meta['has_premium'] == true),
      'account_status': running
          ? tp.accountStatus
          : (meta['account_status'] ?? '').toString(),
      'domains': running
          ? tp.availableDomains
          : ((meta['domains'] as List?) ?? const <String>[]),
      'error': running ? tp.error : '',
      'claim': claim?.toJson(),
    };
  }

  Map<String, Map<String, dynamic>> getActiveTunnelEntries() {
    final out = <String, Map<String, dynamic>>{};
    for (final e in _procs.entries) {
      final tp = e.value;
      final running = !tp.exited;
      out[e.key] = {
        'running': running,
        'mode': 'playit',
        'live_url': tp.liveUrl,
        'display_address': tp.displayAddress,
        'connected': tp.connected && running,
        'claimed': true,
        'secret_path': tp.secretFile.path,
        'error': tp.error,
        'pid': running ? tp.proc.pid : null,
      };
    }
    return out;
  }

  Map<String, Map<String, dynamic>> getPersistedEntries() {
    final out = <String, Map<String, dynamic>>{};
    for (final e in _procs.entries) {
      final tp = e.value;
      if (!tp.exited) {
        out[e.key] = {
          'mode': 'playit',
          'live_url': tp.liveUrl,
          'connected': tp.connected,
          'pid': tp.proc.pid,
        };
      }
    }
    return out;
  }

  Future<Map<String, dynamic>> startPlayitDownload({
    bool forceUpdate = false,
    bool resume = false,
  }) async {
    final existing = findPlayitd();
    if (existing != null && !forceUpdate && !resume) {
      _dlActive = false;
      _dlPaused = false;
      _dlPercent = 100;
      _dlStatus = '已安装';
      _dlError = '';
      return {
        'ok': true,
        'path': existing.path,
        'message': '已检测到 Playit 组件: ${existing.path}',
      };
    }
    if (forceUpdate && !resume) {
      await stopAll();
    }
    if (_dlActive) {
      return {'ok': true, 'in_progress': true, 'message': '正在下载 playitd...'};
    }

    _dlPauseReq = false;
    _dlCancelReq = false;
    final shouldResume = resume && _dlPaused;
    _dlActive = true;
    _dlPaused = false;
    _dlError = '';
    if (!shouldResume) {
      _dlDownloaded = 0;
      _dlTotal = 0;
      _dlPercent = 0;
      _dlStatus = '正在连接 Playit 官方下载源...';
    } else {
      _dlStatus = '正在恢复下载...';
    }

    unawaited(_downloadWorker(shouldResume));
    return {
      'ok': true,
      'started': true,
      'message': shouldResume ? '已继续下载 playitd' : '已开始下载 playitd 守护组件',
    };
  }

  Map<String, dynamic> pauseDownload() {
    if (!_dlActive) {
      return {'ok': false, 'error': '当前没有进行中的下载'};
    }
    _dlPauseReq = true;
    return {'ok': true, 'message': '正在暂停下载...'};
  }

  Map<String, dynamic> cancelDownload() {
    _dlCancelReq = true;
    _dlPauseReq = false;
    final info = getPlayitDownloadInfo();
    final target = info['target'] as File;
    final tmp = File('${target.path}.downloading');
    if (!_dlActive) {
      if (tmp.existsSync()) {
        try {
          tmp.deleteSync();
        } catch (_) {}
      }
      _dlActive = false;
      _dlPaused = false;
      _dlDownloaded = 0;
      _dlTotal = 0;
      _dlPercent = 0;
      _dlStatus = '';
      _dlError = '';
    }
    return {'ok': true, 'message': '已取消下载'};
  }

  Future<void> _downloadWorker(bool resume) async {
    final info = getPlayitDownloadInfo();
    final asset = info['asset'] as String;
    final target = info['target'] as File;
    final url = info['download_url'] as String;
    target.parent.createSync(recursive: true);
    final tmp = File('${target.path}.downloading');
    var existingBytes = (resume && tmp.existsSync()) ? tmp.lengthSync() : 0;
    if (!resume && tmp.existsSync()) {
      try {
        tmp.deleteSync();
      } catch (_) {}
      existingBytes = 0;
    }

    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(
        'User-Agent',
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AgentMCP/3.5',
      );
      if (existingBytes > 0) {
        req.headers.set('Range', 'bytes=$existingBytes-');
      }
      final resp = await req.close();
      if (resp.statusCode >= 400) {
        throw HttpException('HTTP ${resp.statusCode}');
      }

      RandomAccessFile raf;
      if (existingBytes > 0 && resp.statusCode == 206) {
        raf = tmp.openSync(mode: FileMode.append);
        _dlDownloaded = existingBytes;
        _dlTotal =
            resp.contentLength > 0 ? existingBytes + resp.contentLength : 0;
      } else {
        raf = tmp.openSync(mode: FileMode.write);
        _dlDownloaded = 0;
        _dlTotal = resp.contentLength > 0 ? resp.contentLength : 0;
      }

      try {
        await for (final chunk in resp) {
          if (_dlCancelReq || _dlPauseReq) break;
          raf.writeFromSync(chunk);
          _dlDownloaded += chunk.length;
          _dlPercent = _dlTotal > 0
              ? min(99, ((_dlDownloaded * 100) / _dlTotal).round())
              : 0;
          final mbDone = (_dlDownloaded / 1048576).toStringAsFixed(1);
          if (_dlTotal > 0) {
            final mbTot = (_dlTotal / 1048576).toStringAsFixed(1);
            _dlStatus = '下载中 $mbDone / $mbTot MB ($_dlPercent%)';
          } else {
            _dlStatus = '下载中 $mbDone MB...';
          }
        }
      } finally {
        raf.closeSync();
      }

      if (_dlCancelReq) {
        if (tmp.existsSync()) tmp.deleteSync();
        _dlActive = false;
        _dlPaused = false;
        _dlDownloaded = 0;
        _dlTotal = 0;
        _dlPercent = 0;
        _dlStatus = '';
        _dlError = '';
        return;
      }

      if (_dlPauseReq) {
        final mbDone = (_dlDownloaded / 1048576).toStringAsFixed(1);
        _dlActive = false;
        _dlPaused = true;
        _dlStatus = '已暂停 $mbDone MB ($_dlPercent%)';
        return;
      }

      if (asset.endsWith('.tgz') || asset.endsWith('.tar.gz')) {
        _dlStatus = '正在解压 playitd...';
        _dlPercent = 99;
        _extractPlayitTgz(tmp.readAsBytesSync(), target);
        if (tmp.existsSync()) tmp.deleteSync();
      } else {
        if (target.existsSync()) target.deleteSync();
        tmp.renameSync(target.path);
      }

      if (!Platform.isWindows) {
        Process.runSync('chmod', ['755', target.path]);
      }
      _cachedPlayitPath = '';
      _cachedPlayitVer = '';
      _dlActive = false;
      _dlPaused = false;
      _dlPercent = 100;
      _dlStatus = '安装完成';
      _dlError = '';
    } catch (e) {
      _dlActive = false;
      _dlPaused = false;
      _dlError = '下载失败: $e';
      _dlStatus = '';
    } finally {
      client.close(force: true);
    }
  }

  void _extractPlayitTgz(Uint8List bytes, File target) {
    final gz = const GZipDecoder().decodeBytes(bytes);
    final archive = TarDecoder().decodeBytes(gz);
    ArchiveFile? fallbackPlayit;
    for (final file in archive) {
      if (!file.isFile) continue;
      final base = p.basename(file.name);
      if (base == 'playitd' || base == 'playitd.exe') {
        target.writeAsBytesSync(file.content as List<int>, flush: true);
        return;
      }
      if (base == 'playit' || base == 'playit.exe') {
        fallbackPlayit = file;
      }
    }
    if (fallbackPlayit != null) {
      target.writeAsBytesSync(fallbackPlayit.content as List<int>, flush: true);
      return;
    }
    throw StateError('压缩包中未找到 playitd 可执行文件');
  }

  Future<Map<String, dynamic>> importPlayitBytes(
    String filename,
    Uint8List data,
  ) async {
    if (data.length < 100000) {
      return {
        'ok': false,
        'error': '文件过小，不像有效的 playitd 可执行文件或压缩包。',
      };
    }
    final nameL = filename.toLowerCase();
    final isTgz = nameL.endsWith('.tgz') ||
        nameL.endsWith('.tar.gz') ||
        (data[0] == 0x1F && data[1] == 0x8B);
    if (!isTgz) {
      final isPe = data[0] == 0x4D && data[1] == 0x5A;
      final isElf = data[0] == 0x7F &&
          data[1] == 0x45 &&
          data[2] == 0x4C &&
          data[3] == 0x46;
      final isMachO = (data[0] == 0xCF && data[1] == 0xFA) ||
          (data[0] == 0xFE && data[1] == 0xED) ||
          (data[0] == 0xCA && data[1] == 0xFE);
      if (!isPe && !isElf && !isMachO) {
        return {
          'ok': false,
          'error': '文件格式不受支持，请选择官方下载的 playitd 可执行文件或 .tar.gz 压缩包。',
        };
      }
    }

    cancelDownload();
    await stopAll();
    final info = getPlayitDownloadInfo();
    final target = info['target'] as File;
    target.parent.createSync(recursive: true);

    try {
      if (isTgz) {
        _extractPlayitTgz(data, target);
      } else {
        target.writeAsBytesSync(data, flush: true);
      }
      if (!Platform.isWindows) {
        Process.runSync('chmod', ['755', target.path]);
      }
      _cachedPlayitPath = '';
      _cachedPlayitVer = '';
      final ver = getPlayitVersion(target);
      _dlActive = false;
      _dlPaused = false;
      _dlPercent = 100;
      _dlStatus = '导入完成';
      _dlError = '';
      return {
        'ok': true,
        'path': target.path,
        'version': ver,
        'message': '已导入 Playit 组件${ver.isNotEmpty ? " v$ver" : ""}',
      };
    } catch (e) {
      return {'ok': false, 'error': '导入失败: $e'};
    }
  }

  Future<Map<String, dynamic>> uninstallPlayit() async {
    await stopAll();
    final exe = Platform.isWindows ? 'playitd.exe' : 'playitd';
    final localBin = File(p.join(StoragePaths.instance.binDir.path, exe));
    if (!localBin.existsSync()) {
      return {
        'ok': false,
        'error': '仅支持移除项目 bin/ 目录内由本应用管理的 playitd。',
      };
    }
    try {
      localBin.deleteSync();
      _cachedPlayitPath = '';
      _cachedPlayitVer = '';
      return {'ok': true, 'message': '已移除本地 playitd 副本'};
    } catch (e) {
      return {'ok': false, 'error': '移除失败: $e'};
    }
  }

  Future<Map<String, dynamic>> _callPlayitApi(
    String path,
    Map<String, dynamic> body, {
    String? secretKey,
  }) async {
    if (apiOverrideForTesting != null) {
      return apiOverrideForTesting!(path, body, secretKey: secretKey);
    }
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      final uri = Uri.parse('$apiBaseUrl$path');
      final req = await client.postUrl(uri);
      req.headers.set('Content-Type', 'application/json');
      req.headers.set('Accept', 'application/json');
      req.headers.set('User-Agent', 'playit-agent/2.0.2 AgentMCP/3.5');
      if (secretKey != null && secretKey.trim().isNotEmpty) {
        req.headers.set('Authorization', 'Agent-Key ${secretKey.trim()}');
      }
      req.add(utf8.encode(jsonEncode(body)));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode == 429) {
        return {'status': 'http_error', 'code': 429, 'error': '请求过于频繁，请稍后重试'};
      }
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return {'status': 'error', 'data': text};
    } catch (e) {
      return {'status': 'network_error', 'error': '$e'};
    } finally {
      client.close(force: true);
    }
  }

  /// Starts or applies a Playit claim flow (supports random claim generation,
  /// custom claim code / URL, or direct existing Agent Secret Key).
  Future<Map<String, dynamic>> startClaim({
    required String profileId,
    String claimMode = 'random',
    String customInput = '',
    String? customSecretPath,
    int? localPort,
    Map<String, dynamic>? profile,
  }) async {
    final secretFile = resolvePlayitSecretFile(profileId, customSecretPath);
    final prev = _claims[profileId];
    if (prev != null) {
      prev.cancelled = true;
    }

    String claimCode;
    final normMode = claimMode.trim().toLowerCase() == 'custom' ? 'custom' : 'random';
    if (normMode == 'custom') {
      final parsed = parsePlayitUserClaimInput(customInput);
      if (parsed.kind == 'empty') {
        return {
          'ok': false,
          'error': '请输入自定义十六进制认领码、认领链接或已有的 Agent Secret Key。',
        };
      }
      if (parsed.kind == 'invalid') {
        return {
          'ok': false,
          'error':
              '格式无效：认领码须为偶数位十六进制字符（如 a1b2c3d4e5），或直接粘贴后台生成的 64 位 Secret Key。',
        };
      }
      if (parsed.kind == 'secret_key') {
        final verify = await _callPlayitApi(
          '/v1/agents/rundata',
          const <String, dynamic>{},
          secretKey: parsed.value,
        );
        if (verify['status'] != 'success') {
          return {
            'ok': false,
            'error': '校验 Secret Key 失败，请确认密钥有效且未被撤销。',
          };
        }
        writePlayitSecretToml(secretFile, parsed.value);
        final session = _PlayitClaimSession(
          profileId: profileId,
          claimCode: '',
          claimUrl: 'https://playit.gg/account/agents',
          claimMode: 'custom',
        )
          ..phase = 'claimed'
          ..message = '已验证并写入持久化密钥文件 (${p.basename(secretFile.path)})';
        _claims[profileId] = session;

        if (localPort != null && localPort > 0) {
          await syncProfileEndpointFromApi(
            profileId: profileId,
            secretKey: parsed.value,
            localPort: localPort,
            profile: profile,
          );
        }
        onStateChanged?.call();
        return {
          'ok': true,
          'claimed_immediately': true,
          'secret_path': secretFile.path,
          'claim': session.toJson(),
          'status': getProfilePlayitStatus(
            profileId,
            customSecretPath: customSecretPath,
          ),
        };
      }
      claimCode = parsed.value;
    } else {
      claimCode = generatePlayitClaimCode(5);
    }

    final claimUrl = buildPlayitClaimUrl(claimCode);
    final session = _PlayitClaimSession(
      profileId: profileId,
      claimCode: claimCode,
      claimUrl: claimUrl,
      claimMode: normMode,
    );
    _claims[profileId] = session;

    unawaited(
      _pollClaimExchangeLoop(
        session: session,
        secretFile: secretFile,
        localPort: localPort,
        profile: profile,
      ),
    );

    return {
      'ok': true,
      'claim_code': claimCode,
      'claim_url': claimUrl,
      'secret_path': secretFile.path,
      'claim': session.toJson(),
    };
  }

  Future<void> _pollClaimExchangeLoop({
    required _PlayitClaimSession session,
    required File secretFile,
    int? localPort,
    Map<String, dynamic>? profile,
  }) async {
    final deadline = DateTime.now().add(const Duration(minutes: 10));

    while (!session.cancelled && DateTime.now().isBefore(deadline)) {
      final setupRes = await _callPlayitApi('/claim/setup', {
        'code': session.claimCode,
        'agent_type': 'assignable',
        'version': 'playit 2.0.2',
      });

      if (session.cancelled) return;
      final st = setupRes['status']?.toString() ?? '';
      final data = setupRes['data']?.toString() ?? '';

      if (st == 'success') {
        if (data == 'WaitingForUserVisit') {
          session.phase = 'waiting_visit';
          session.message = '请打开认领链接并在浏览器登录 Playit.gg...';
        } else if (data == 'WaitingForUser') {
          session.phase = 'waiting_approve';
          session.message = '已检测到网页访问，请在网页上点击 Approve 完成认领...';
        } else if (data == 'UserAccepted') {
          session.phase = 'exchanging';
          session.message = '网页已批准认领，正在换取持久化密钥...';
          break;
        } else if (data == 'UserRejected') {
          session.phase = 'rejected';
          session.error = '认领请求已在浏览器中被拒绝。';
          session.message = session.error;
          onStateChanged?.call();
          return;
        }
      } else if (st == 'fail') {
        if (data == 'CodeExpired' || data == 'InvalidCode') {
          session.phase = 'error';
          session.error = data == 'CodeExpired'
              ? '认领链接已过期，请重新生成。'
              : '认领码无效或已被占用，请更换或重新生成。';
          session.message = session.error;
          onStateChanged?.call();
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 1600));
    }

    if (session.cancelled) return;
    if (session.phase != 'exchanging') {
      session.phase = 'error';
      session.error = '认领等待超时，请点击重新生成认领链接。';
      session.message = session.error;
      onStateChanged?.call();
      return;
    }

    for (var i = 0; i < 20 && !session.cancelled; i++) {
      final exRes = await _callPlayitApi('/claim/exchange', {
        'code': session.claimCode,
      });
      if (exRes['status'] == 'success' && exRes['data'] is Map) {
        final dataMap = exRes['data'] as Map;
        final secretKey = (dataMap['secret_key'] ?? '').toString().trim();
        if (secretKey.isNotEmpty) {
          writePlayitSecretToml(secretFile, secretKey);
          session.phase = 'claimed';
          session.error = '';
          session.message =
              '认领成功！已生成持久化密钥文件 ${p.basename(secretFile.path)}';

          if (localPort != null && localPort > 0) {
            await syncProfileEndpointFromApi(
              profileId: session.profileId,
              secretKey: secretKey,
              localPort: localPort,
              profile: profile,
            );
            if (profile != null &&
                (profile['tunnel_mode'] ?? '').toString().toLowerCase() ==
                    'playit' &&
                findPlayitd() != null) {
              await startTunnel(profile, localPort);
            }
          }
          onStateChanged?.call();
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }

    if (!session.cancelled) {
      session.phase = 'error';
      session.error = '换取持久化密钥超时，请重试。';
      session.message = session.error;
      onStateChanged?.call();
    }
  }

  Future<Map<String, dynamic>> resetProfileSecret(
    String profileId, {
    String? customSecretPath,
  }) async {
    await stopTunnel(profileId);
    final prev = _claims.remove(profileId);
    if (prev != null) prev.cancelled = true;
    _cachedAgentMeta.remove(profileId);

    final secretFile = resolvePlayitSecretFile(profileId, customSecretPath);
    if (secretFile.existsSync()) {
      try {
        secretFile.deleteSync();
      } catch (e) {
        return {'ok': false, 'error': '删除密钥文件失败: $e'};
      }
    }
    onStateChanged?.call();
    return {
      'ok': true,
      'message': '已重置该入口的 Playit 认领密钥，可重新生成认领链接。',
    };
  }

  String _formatPlayitLiveUrl({
    required String displayAddress,
    String? tunnelType,
    String? preferredHostname,
  }) {
    final pref = (preferredHostname ?? '').trim().replaceAll(RegExp(r'/+$'), '');
    if (pref.isNotEmpty &&
        displayAddress.isEmpty) {
      if (pref.startsWith('http://') || pref.startsWith('https://')) {
        return pref;
      }
      final hasNonTlsPort = pref.contains(':') && !pref.endsWith(':443');
      return '${hasNonTlsPort ? "http" : "https"}://$pref';
    }

    final addr = displayAddress.trim().replaceAll(RegExp(r'/+$'), '');
    if (addr.isEmpty) return '';
    if (addr.startsWith('http://') || addr.startsWith('https://')) {
      return addr;
    }
    final isHttpsTunnel = (tunnelType ?? '').toLowerCase() == 'https';
    final hasCustomPort = addr.contains(':') && !addr.endsWith(':443');
    final scheme = (isHttpsTunnel || !hasCustomPort) ? 'https' : 'http';
    final stripped443 =
        (scheme == 'https' && addr.endsWith(':443'))
            ? addr.substring(0, addr.length - 4)
            : addr;
    return '$scheme://$stripped443';
  }

  Map<String, String> _tunnelConfigMap(dynamic rawAgentConfig) {
    final out = <String, String>{};
    if (rawAgentConfig is Map && rawAgentConfig['fields'] is List) {
      for (final item in rawAgentConfig['fields'] as List) {
        if (item is Map) {
          final k = (item['name'] ?? '').toString().trim();
          final v = (item['value'] ?? '').toString().trim();
          if (k.isNotEmpty) out[k] = v;
        }
      }
    }
    return out;
  }

  /// Queries `/v1/agents/rundata` & `/domains/list` and automatically provisions
  /// a persistent Playit tunnel pointing to `127.0.0.1:$localPort` if none exists.
  Future<Map<String, dynamic>> syncProfileEndpointFromApi({
    required String profileId,
    required String secretKey,
    required int localPort,
    Map<String, dynamic>? profile,
    bool allowAutoCreate = true,
  }) async {
    final runRes = await _callPlayitApi(
      '/v1/agents/rundata',
      const <String, dynamic>{},
      secretKey: secretKey,
    );
    if (runRes['status'] != 'success' || runRes['data'] is! Map) {
      return {'ok': false, 'error': '无法读取 Playit 节点运行数据'};
    }

    final data = Map<String, dynamic>.from(runRes['data'] as Map);
    final agentId = (data['agent_id'] ?? '').toString().trim();
    final perms = data['permissions'] is Map
        ? Map<String, dynamic>.from(data['permissions'] as Map)
        : const <String, dynamic>{};
    final hasPremium = perms['has_premium'] == true;
    final accountStatus = (perms['account_status'] ?? '').toString();

    final domainsRes = await _callPlayitApi(
      '/domains/list',
      const <String, dynamic>{},
      secretKey: secretKey,
    );
    final domainItems = <Map<String, dynamic>>[];
    final domainNames = <String>[];
    if (domainsRes['status'] == 'success' &&
        domainsRes['data'] is Map &&
        (domainsRes['data'] as Map)['domains'] is List) {
      for (final d in (domainsRes['data'] as Map)['domains'] as List) {
        if (d is Map) {
          final dm = Map<String, dynamic>.from(d);
          final nm = (dm['name'] ?? '').toString().trim();
          if (nm.isNotEmpty) {
            domainItems.add(dm);
            if (!domainNames.contains(nm)) domainNames.add(nm);
          }
        }
      }
    }

    final domainMode = (profile?['playit_domain_mode'] ?? 'random')
        .toString()
        .trim()
        .toLowerCase();
    final rawDesiredHost = (profile?['playit_hostname'] ?? '')
        .toString()
        .trim()
        .replaceFirst(RegExp(r'^https?://', caseSensitive: false), '')
        .replaceAll(RegExp(r'/.*$'), '')
        .toLowerCase();

    final rawTunnels = (data['tunnels'] is List)
        ? (data['tunnels'] as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : <Map<String, dynamic>>[];
    final pendingList = (data['pending'] is List)
        ? (data['pending'] as List).whereType<Map>().toList()
        : const <Map>[];

    final wantsCustomHost = domainMode == 'custom' && rawDesiredHost.isNotEmpty;
    Map<String, dynamic>? matched;
    for (final t in rawTunnels) {
      if ((t['disabled_reason'] ?? '').toString().isNotEmpty) continue;
      final disp = (t['display_address'] ?? '').toString().trim().toLowerCase();
      if (wantsCustomHost) {
        if (disp == rawDesiredHost || disp.startsWith('$rawDesiredHost:')) {
          matched = t;
          break;
        }
        continue;
      }
      final cfgFields = _tunnelConfigMap(t['agent_config']);
      final lp = cfgFields['local_port'] ?? cfgFields['http_port'] ?? '';
      if (lp == '$localPort') {
        matched ??= t;
      }
    }
    if (!wantsCustomHost && matched == null && rawTunnels.isNotEmpty) {
      matched = rawTunnels.firstWhere(
        (t) => (t['disabled_reason'] ?? '').toString().isEmpty,
        orElse: () => rawTunnels.first,
      );
    }

    if (matched == null &&
        allowAutoCreate &&
        pendingList.isEmpty &&
        agentId.isNotEmpty) {
      Map<String, dynamic>? matchedDomainObj;
      if (domainMode == 'custom' && rawDesiredHost.isNotEmpty) {
        for (final dm in domainItems) {
          if ((dm['name'] ?? '').toString().trim().toLowerCase() ==
              rawDesiredHost) {
            matchedDomainObj = dm;
            break;
          }
        }
      }

      Map<String, dynamic> createRes;
      if (matchedDomainObj != null && hasPremium) {
        createRes = await _callPlayitApi(
          '/v1/tunnels/create',
          {
            'name': 'agent-mcp-$profileId',
            'ports': {'type': 'tunnel-type', 'details': 'https'},
            'origin': {
              'type': 'agent',
              'data': {
                'agent_id': agentId,
                'config': {
                  'fields': [
                    {'name': 'local_ip', 'value': '127.0.0.1'},
                    {'name': 'http_port', 'value': '$localPort'},
                    {'name': 'https_port', 'value': '0'},
                    {'name': 'tls_termination', 'value': 'letsencrypt'},
                  ],
                },
              },
            },
            'enabled': true,
            'alloc': {
              'type': 'hostname',
              'details': {'hostname_id': matchedDomainObj['id']},
            },
            'firewall_id': null,
          },
          secretKey: secretKey,
        );
      } else {
        createRes = await _callPlayitApi(
          '/v1/tunnels/create',
          {
            'name': 'agent-mcp-$profileId',
            'ports': {'type': 'custom-tcp', 'details': 1},
            'origin': {
              'type': 'agent',
              'data': {
                'agent_id': agentId,
                'config': {
                  'fields': [
                    {'name': 'local_ip', 'value': '127.0.0.1'},
                    {'name': 'local_port', 'value': '$localPort'},
                  ],
                },
              },
            },
            'enabled': true,
            'alloc': null,
            'firewall_id': null,
          },
          secretKey: secretKey,
        );
      }

      if (createRes['status'] == 'success') {
        final followUp = await _callPlayitApi(
          '/v1/agents/rundata',
          const <String, dynamic>{},
          secretKey: secretKey,
        );
        if (followUp['status'] == 'success' && followUp['data'] is Map) {
          final followData = Map<String, dynamic>.from(followUp['data'] as Map);
          final refreshedTunnels = (followData['tunnels'] is List)
              ? (followData['tunnels'] as List)
                  .whereType<Map>()
                  .map((e) => Map<String, dynamic>.from(e))
                  .toList()
              : <Map<String, dynamic>>[];
          for (final t in refreshedTunnels) {
            if ((t['disabled_reason'] ?? '').toString().isNotEmpty) continue;
            final disp =
                (t['display_address'] ?? '').toString().trim().toLowerCase();
            if (wantsCustomHost) {
              if (disp == rawDesiredHost ||
                  disp.startsWith('$rawDesiredHost:')) {
                matched = t;
                break;
              }
              continue;
            }
            matched = t;
            break;
          }
        }
      }
    }

    final displayAddr = (matched?['display_address'] ?? '').toString().trim();
    final tType = matched?['tunnel_type']?.toString();
    final liveUrl = _formatPlayitLiveUrl(
      displayAddress: displayAddr,
      tunnelType: tType,
      preferredHostname: domainMode == 'custom' ? rawDesiredHost : null,
    );

    final summary = <String, dynamic>{
      'ok': true,
      'agent_id': agentId,
      'has_premium': hasPremium,
      'account_status': accountStatus,
      'domains': domainNames,
      'display_address': displayAddr,
      'live_url': liveUrl,
      'pending_count': pendingList.length,
    };
    _cachedAgentMeta[profileId] = summary;

    final tp = _procs[profileId];
    if (tp != null && !tp.exited) {
      var changed = false;
      tp.hasPremium = hasPremium;
      tp.accountStatus = accountStatus;
      tp.availableDomains = domainNames;
      if (displayAddr.isNotEmpty && tp.displayAddress != displayAddr) {
        tp.displayAddress = displayAddr;
        changed = true;
      }
      if (liveUrl.isNotEmpty && tp.liveUrl != liveUrl) {
        tp.liveUrl = liveUrl;
        tp.connected = true;
        changed = true;
      }
      if (changed) {
        onStateChanged?.call();
      }
    }
    return summary;
  }

  Future<Map<String, dynamic>> startTunnel(
    Map<String, dynamic> profile,
    int localPort,
  ) async {
    final pid = (profile['id'] ?? 'default').toString();
    final customSecretPath = profile['playit_secret_path']?.toString();
    final secretFile = resolvePlayitSecretFile(pid, customSecretPath);
    final secretKey = readPlayitSecretKey(secretFile);

    if (secretKey == null || secretKey.isEmpty) {
      final claimMode =
          (profile['playit_claim_mode'] ?? 'random').toString().toLowerCase();
      final customCode = (profile['playit_custom_code'] ?? '').toString();
      final claimRes = await startClaim(
        profileId: pid,
        claimMode: claimMode,
        customInput: customCode,
        customSecretPath: customSecretPath,
        localPort: localPort,
        profile: profile,
      );
      if (claimRes['claimed_immediately'] != true) {
        return {
          'ok': false,
          'needs_claim': true,
          'claim_url': claimRes['claim_url'],
          'claim': claimRes['claim'],
          'secret_path': secretFile.path,
          'error':
              claimRes['error'] ??
              '首次使用 Playit 需先完成节点认领：已为您生成认领链接，请打开或复制链接完成登录批准。',
        };
      }
    }

    final binary = findPlayitd();
    if (binary == null) {
      return {
        'ok': false,
        'error': '未检测到 playitd 守护组件，请先在「外网与隧道」或入口弹窗中一键下载。',
      };
    }

    final verifiedKey = readPlayitSecretKey(secretFile);
    if (verifiedKey == null || verifiedKey.isEmpty) {
      return {'ok': false, 'error': 'Playit 密钥文件为空，请重新执行认领。'};
    }

    await stopTunnel(pid);

    final certDir = resolvePlayitCertDir(pid)..createSync(recursive: true);
    final logFile = resolvePlayitLogFile(pid);
    logFile.parent.createSync(recursive: true);

    final cleanKeyId = sanitizePlayitProfileKey(pid);
    final socketArg = Platform.isWindows
        ? r'\\.\pipe\agent-mcp-playit-' '$cleanKeyId'
        : p.join(
            StoragePaths.instance.dataDir.path,
            'playit',
            'playit_$cleanKeyId.sock',
          );

    final baseExe = p.basenameWithoutExtension(binary.path).toLowerCase();
    final List<String> args = baseExe == 'playit'
        ? <String>['--stdout', '--socket-path', socketArg]
        : <String>[
            '--secret-path',
            secretFile.path,
            '--cert-dir',
            certDir.path,
            '--log-path',
            logFile.path,
            '--socket-path',
            socketArg,
          ];

    try {
      final proc = await Process.start(
        binary.path,
        args,
        environment: {
          'SECRET_KEY_FILE': secretFile.path,
          'CERT_DIR': certDir.path,
        },
      );
      Win32ProcessJobGuard.instance.attachPid(proc.pid);
      final tp = _PlayitProc(
        profileId: pid,
        proc: proc,
        secretFile: secretFile,
        localPort: localPort,
      );
      _procs[pid] = tp;
      onStateChanged?.call();

      void handleLine(String rawLine) {
        final line = rawLine.trim();
        if (line.isEmpty) return;
        tp.lastLines.add(line);
        if (tp.lastLines.length > 16) tp.lastLines.removeAt(0);
        final low = line.toLowerCase();
        if (low.contains('tunnel running') ||
            low.contains('agent registered') ||
            low.contains('connected') ||
            low.contains('control channel')) {
          if (!tp.connected) {
            tp.connected = true;
            onStateChanged?.call();
          }
        }
        if (low.contains('invalid secret') ||
            low.contains('unauthorized') ||
            low.contains('error:')) {
          tp.error =
              line.length > 240 ? line.substring(line.length - 240) : line;
          onStateChanged?.call();
        }
      }

      proc.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(handleLine, onError: (_) {});
      proc.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(handleLine, onError: (_) {});

      unawaited(() async {
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        if (tp.exited) return;
        await syncProfileEndpointFromApi(
          profileId: pid,
          secretKey: verifiedKey,
          localPort: localPort,
          profile: profile,
          allowAutoCreate: true,
        );
        for (var i = 0; i < 6 && !tp.exited && tp.liveUrl.isEmpty; i++) {
          await Future<void>.delayed(const Duration(seconds: 2));
          await syncProfileEndpointFromApi(
            profileId: pid,
            secretKey: verifiedKey,
            localPort: localPort,
            profile: profile,
            allowAutoCreate: false,
          );
        }
        if (!tp.exited) {
          tp.connected = true;
          onStateChanged?.call();
        }
      }());

      tp.syncTimer = Timer.periodic(const Duration(seconds: 25), (t) {
        if (tp.exited) {
          t.cancel();
          return;
        }
        unawaited(
          syncProfileEndpointFromApi(
            profileId: pid,
            secretKey: verifiedKey,
            localPort: localPort,
            profile: profile,
            allowAutoCreate: false,
          ),
        );
      });

      unawaited(
        proc.exitCode.then((rc) {
          tp.syncTimer?.cancel();
          tp.exited = true;
          tp.connected = false;
          if (!tp.stopped && rc != 0 && tp.error.isEmpty) {
            final hint = tp.lastLines.isNotEmpty ? tp.lastLines.last : '';
            tp.error = hint.isNotEmpty
                ? '$hint (code=$rc)'
                : 'playitd 已退出 (code=$rc)';
          }
          onStateChanged?.call();
        }),
      );

      return {
        'ok': true,
        'pid': proc.pid,
        'mode': 'playit',
        'secret_path': secretFile.path,
      };
    } catch (e) {
      return {'ok': false, 'error': '启动 playitd 失败: $e'};
    }
  }

  Future<Map<String, dynamic>> stopTunnel(String profileId) async {
    final tp = _procs.remove(profileId);
    if (tp != null) {
      tp.stopped = true;
      tp.syncTimer?.cancel();
      if (!tp.exited) {
        if (Platform.isWindows) {
          try {
            await Process.run('taskkill', ['/F', '/T', '/PID', '${tp.proc.pid}']);
          } catch (_) {
            tp.proc.kill();
          }
        } else {
          tp.proc.kill();
        }
      }
      onStateChanged?.call();
    }
    return {'ok': true};
  }

  Future<void> stopAll() async {
    for (final pid in _procs.keys.toList()) {
      await stopTunnel(pid);
    }
  }
}

typedef VoidCallback = void Function();
