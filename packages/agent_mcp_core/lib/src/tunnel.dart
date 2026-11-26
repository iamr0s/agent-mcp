import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'process_tools.dart';

final RegExp _quickUrlRe =
    RegExp(r'https://[a-z0-9-]+\.trycloudflare\.com', caseSensitive: false);

Map<String, dynamic> getCloudflaredDownloadInfo() {
  final binDir = StoragePaths.instance.binDir;
  final arch = Platform.version.toLowerCase();
  final isArm = arch.contains('arm64') || arch.contains('aarch64');

  String asset;
  File target;
  if (Platform.isWindows) {
    asset = 'cloudflared-windows-amd64.exe';
    target = File(p.join(binDir.path, 'cloudflared.exe'));
  } else if (Platform.isMacOS) {
    asset = isArm
        ? 'cloudflared-darwin-arm64.tgz'
        : 'cloudflared-darwin-amd64.tgz';
    target = File(p.join(binDir.path, 'cloudflared'));
  } else {
    asset = isArm ? 'cloudflared-linux-arm64' : 'cloudflared-linux-amd64';
    target = File(p.join(binDir.path, 'cloudflared'));
  }

  return {
    'asset': asset,
    'target': target,
    'download_url':
        'https://github.com/cloudflare/cloudflared/releases/latest/download/$asset',
    'releases_url': 'https://github.com/cloudflare/cloudflared/releases/latest',
  };
}

File? findCloudflared() {
  final exe = Platform.isWindows ? 'cloudflared.exe' : 'cloudflared';
  final localBin = File(p.join(StoragePaths.instance.binDir.path, exe));
  if (localBin.existsSync()) return localBin;

  final pathEnv = Platform.environment['PATH'] ?? '';
  final sep = Platform.isWindows ? ';' : ':';
  for (final dir in pathEnv.split(sep)) {
    final d = dir.trim();
    if (d.isEmpty) continue;
    final candidate = File(p.join(d, exe));
    if (candidate.existsSync()) return candidate;
  }

  if (Platform.isWindows) {
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final stdPaths = <String>[
      r'C:\Program Files (x86)\cloudflared\cloudflared.exe',
      r'C:\Program Files\cloudflared\cloudflared.exe',
      if (localAppData.isNotEmpty)
        p.join(localAppData, 'Microsoft', 'WinGet', 'Links', 'cloudflared.exe'),
    ];
    for (final sp in stdPaths) {
      final f = File(sp);
      if (f.existsSync()) return f;
    }
  } else {
    for (final sp in const [
      '/opt/homebrew/bin/cloudflared',
      '/usr/local/bin/cloudflared',
      '/usr/bin/cloudflared',
    ]) {
      final f = File(sp);
      if (f.existsSync()) return f;
    }
  }
  return null;
}

String _cachedCfPath = '';
String _cachedCfVer = '';
bool _probingCfVer = false;

Future<String> warmCloudflaredVersionAsync([File? binary]) async {
  final bin = binary ?? findCloudflared();
  if (bin == null || !bin.existsSync()) return '';
  if (_cachedCfPath == bin.path && _cachedCfVer.isNotEmpty) {
    return _cachedCfVer;
  }
  if (_probingCfVer) return _cachedCfVer;
  _probingCfVer = true;
  try {
    final res = await Process.run(
      bin.path,
      const ['--version'],
      runInShell: false,
    ).timeout(const Duration(seconds: 4));
    final out = '${res.stdout}\n${res.stderr}'.trim();
    final m =
        RegExp(r'version\s+([0-9]+\.[0-9]+\.[0-9]+)', caseSensitive: false)
            .firstMatch(out);
    final ver = m != null
        ? m.group(1)!
        : (out.isNotEmpty ? out.split(RegExp(r'\r?\n')).first : '');
    _cachedCfPath = bin.path;
    _cachedCfVer = ver;
    return ver;
  } catch (_) {
    return _cachedCfVer;
  } finally {
    _probingCfVer = false;
  }
}

String getCloudflaredVersion(File? binary) {
  if (binary == null || !binary.existsSync()) return '';
  if (_cachedCfPath == binary.path && _cachedCfVer.isNotEmpty) {
    return _cachedCfVer;
  }
  unawaited(warmCloudflaredVersionAsync(binary));
  return _cachedCfVer;
}

class _TunnelProc {
  final String profileId;
  final String mode;
  final Process proc;
  String liveUrl = '';
  bool connected = false;
  String error = '';
  bool stopped = false;
  bool exited = false;
  final List<String> lastLines = [];

  _TunnelProc({
    required this.profileId,
    required this.mode,
    required this.proc,
  });
}

class TunnelManager {
  static final TunnelManager instance = TunnelManager._();
  TunnelManager._();

  final Map<String, _TunnelProc> _procs = {};

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

  Future<Map<String, dynamic>> startCloudflaredDownload({
    bool forceUpdate = false,
    bool resume = false,
  }) async {
    final existing = findCloudflared();
    if (existing != null && !forceUpdate && !resume) {
      _dlActive = false;
      _dlPaused = false;
      _dlPercent = 100;
      _dlStatus = '已安装';
      _dlError = '';
      return {
        'ok': true,
        'path': existing.path,
        'message': '已检测到 cloudflared: ${existing.path}',
      };
    }
    if (forceUpdate && !resume) {
      await stopAll();
    }
    if (_dlActive) {
      return {'ok': true, 'in_progress': true, 'message': '正在下载中...'};
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
      _dlStatus = '正在连接下载源...';
    } else {
      _dlStatus = '正在恢复下载...';
    }

    unawaited(_downloadWorker(shouldResume));
    return {
      'ok': true,
      'started': true,
      'message': shouldResume ? '已继续下载' : '已开始下载 cloudflared',
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
    final info = getCloudflaredDownloadInfo();
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
    final info = getCloudflaredDownloadInfo();
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
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AgentMCP/2.0',
      );
      if (existingBytes > 0) {
        req.headers.set('Range', 'bytes=$existingBytes-');
      }
      final resp = await req.close();
      if (resp.statusCode >= 400) {
        throw HttpException('HTTP ${resp.statusCode}');
      }

      RandomAccessFile raf;
      if (existingBytes 
          > 0 && resp.statusCode == 206) {
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

      if (asset.endsWith('.tgz')) {
        _dlStatus = '正在解压安装包...';
        _dlPercent = 99;
        _extractCloudflaredTgz(tmp.readAsBytesSync(), target);
        if (tmp.existsSync()) tmp.deleteSync();
      } else {
        if (target.existsSync()) target.deleteSync();
        tmp.renameSync(target.path);
      }

      if (!Platform.isWindows) {
        Process.runSync('chmod', ['755', target.path]);
      }
      _cachedCfPath = '';
      _cachedCfVer = '';
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

  void _extractCloudflaredTgz(Uint8List bytes, File target) {
    final gz = const GZipDecoder().decodeBytes(bytes);
    final archive = TarDecoder().decodeBytes(gz);
    for (final file in archive) {
      final base = p.basename(file.name);
      if (file.isFile && (base == 'cloudflared' || base == 'cloudflared.exe')) {
        target.writeAsBytesSync(file.content as List<int>, flush: true);
        return;
      }
    }
    throw StateError('压缩包中未找到 cloudflared 可执行文件');
  }

  Future<Map<String, dynamic>> importCloudflaredBytes(
    String filename,
    Uint8List data,
  ) async {
    if (data.length < 100000) {
      return {
        'ok': false,
        'error': '文件过小，不像有效的 cloudflared 可执行文件或压缩包。',
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
          'error': '文件格式不受支持，请选择官方下载的 cloudflared 可执行文件或 .tgz 压缩包。',
        };
      }
    }

    cancelDownload();
    await stopAll();
    final info = getCloudflaredDownloadInfo();
    final target = info['target'] as File;
    target.parent.createSync(recursive: true);

    try {
      if (isTgz) {
        _extractCloudflaredTgz(data, target);
      } else {
        target.writeAsBytesSync(data, flush: true);
      }
      if (!Platform.isWindows) {
        Process.runSync('chmod', ['755', target.path]);
      }
      _cachedCfPath = '';
      _cachedCfVer = '';
      final ver = getCloudflaredVersion(target);
      _dlActive = false;
      _dlPaused = false;
      _dlPercent = 100;
      _dlStatus = '导入完成';
      _dlError = '';
      return {
        'ok': true,
        'path': target.path,
        'version': ver,
        'message': '已导入 cloudflared${ver.isNotEmpty ? " v$ver" : ""}',
      };
    } catch (e) {
      return {'ok': false, 'error': '导入失败: $e'};
    }
  }

  Future<Map<String, dynamic>> uninstallCloudflared() async {
    await stopAll();
    final exe = Platform.isWindows ? 'cloudflared.exe' : 'cloudflared';
    final localBin = File(p.join(StoragePaths.instance.binDir.path, exe));
    if (!localBin.existsSync()) {
      return {
        'ok': false,
        'error': '仅支持移除项目 bin/ 目录内由本应用管理的 cloudflared。',
      };
    }
    try {
      localBin.deleteSync();
      _cachedCfPath = '';
      _cachedCfVer = '';
      return {'ok': true, 'message': '已移除本地 cloudflared'};
    } catch (e) {
      return {'ok': false, 'error': '移除失败: $e'};
    }
  }

  Map<String, dynamic> loadDiskState() {
    final f = StoragePaths.instance.tunnelStateFile;
    if (!f.existsSync()) return <String, dynamic>{};
    try {
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is Map) return Map<String, dynamic>.from(raw);
    } catch (_) {}
    return <String, dynamic>{};
  }

  void _persistState() {
    StoragePaths.instance.ensureLayout();
    final payload = <String, dynamic>{};
    for (final e in _procs.entries) {
      final tp = e.value;
      if (!tp.exited) {
        payload[e.key] = {
          'mode': tp.mode,
          'live_url': tp.liveUrl,
          'connected': tp.connected,
          'pid': tp.proc.pid,
        };
      }
    }
    try {
      StoragePaths.instance.tunnelStateFile.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(payload)}\n',
        flush: true,
      );
    } catch (_) {}
  }

  Map<String, dynamic> getStatuses() {
    final binary = findCloudflared();
    final diskState = loadDiskState();
    final tunnels = <String, dynamic>{};

    for (final e in _procs.entries) {
      final tp = e.value;
      final running = !tp.exited;
      tunnels[e.key] = {
        'running': running,
        'mode': tp.mode,
        'live_url': tp.liveUrl,
        'connected': tp.connected && running,
        'error': tp.error,
        'pid': running ? tp.proc.pid : null,
      };
    }

    for (final e in diskState.entries) {
      if (!tunnels.containsKey(e.key) && e.value is Map) {
        final info = Map<String, dynamic>.from(e.value as Map);
        tunnels[e.key] = {
          'running': true,
          'mode': info['mode'] ?? '',
          'live_url': info['live_url'] ?? '',
          'connected': info['connected'] == true,
          'error': '',
          'pid': info['pid'],
        };
      }
    }

    final exe = Platform.isWindows ? 'cloudflared.exe' : 'cloudflared';
    final expectedLocal =
        p.normalize(p.absolute(p.join(StoragePaths.instance.binDir.path, exe)));
    final localManaged = binary != null &&
        (Platform.isWindows
            ? p.normalize(binary.absolute.path).toLowerCase() ==
                expectedLocal.toLowerCase()
            : p.normalize(binary.absolute.path) == expectedLocal);
    final dlInfo = getCloudflaredDownloadInfo();

    return {
      'installed': binary != null,
      'binary': binary?.path,
      'version': getCloudflaredVersion(binary),
      'local_managed': localManaged,
      'download_url': dlInfo['download_url'],
      'releases_url': dlInfo['releases_url'],
      'asset': dlInfo['asset'],
      'install': getInstallStatus(),
      'tunnels': tunnels,
    };
  }

  Future<Map<String, dynamic>> startTunnel(
    Map<String, dynamic> profile,
    int localPort,
  ) async {
    final pid = (profile['id'] ?? 'default').toString();
    final mode = (profile['tunnel_mode'] ?? 'none').toString().toLowerCase();
    if (mode != 'token' && mode != 'quick') {
      return {'ok': false, 'error': '该入口未启用 Cloudflared 隧道模式。'};
    }

    final binary = findCloudflared();
    if (binary == null) {
      return {'ok': false, 'error': '未检测到 cloudflared，请先下载安装。'};
    }

    await stopTunnel(pid);

    List<String> args;
    if (mode == 'token') {
      var token = (profile['tunnel_token'] ?? '').toString().trim();
      if (token.isEmpty) {
        return {
          'ok': false,
          'error': 'Token 固定隧道模式必须填写 Cloudflare Tunnel Token。',
        };
      }
      final parts = token.split(RegExp(r'\s+'));
      if (parts.length > 1) token = parts.last.trim();
      args = ['tunnel', '--no-autoupdate', 'run', '--token', token];
    } else {
      final upstream = Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: localPort,
      ).toString();
      args = ['tunnel', '--no-autoupdate', '--url', upstream];
    }

    try {
      final proc = await Process.start(binary.path, args);
      Win32ProcessJobGuard.instance.attachPid(proc.pid);
      final tp = _TunnelProc(profileId: pid, mode: mode, proc: proc);
      _procs[pid] = tp;
      _persistState();

      void handleLine(String rawLine) {
        final line = rawLine.trim();
        if (line.isEmpty) return;
        tp.lastLines.add(line);
        if (tp.lastLines.length > 12) tp.lastLines.removeAt(0);
        var changed = false;
        if (mode == 'quick') {
          final m = _quickUrlRe.firstMatch(line);
          if (m != null && tp.liveUrl.isEmpty) {
            tp.liveUrl = m.group(0)!.replaceAll(RegExp(r'/+$'), '');
            tp.connected = true;
            changed = true;
          }
        }
        if (line.contains('Registered tunnel connection') ||
            line.contains('Connection registered')) {
          if (!tp.connected) {
            tp.connected = true;
            changed = true;
          }
        }
        final low = line.toLowerCase();
        if ((low.contains('err ') ||
                low.contains('error') ||
                low.contains('not valid') ||
                low.contains('failed')) &&
            (low.contains('failed') ||
                low.contains('unauthorized') ||
                low.contains('invalid') ||
                low.contains('unable') ||
                low.contains('cannot'))) {
          tp.error =
              line.length > 240 ? line.substring(line.length - 240) : line;
        }
        if (changed) _persistState();
      }

      proc.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(handleLine, onError: (_) {});
      proc.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(handleLine, onError: (_) {});

      unawaited(
        proc.exitCode.then((rc) {
          tp.exited = true;
          tp.connected = false;
          if (!tp.stopped && rc != 0 && tp.error.isEmpty) {
            final hint = tp.lastLines.isNotEmpty ? tp.lastLines.last : '';
            tp.error = hint.isNotEmpty
                ? '$hint (code=$rc)'
                : 'cloudflared 已退出 (code=$rc)';
          }
          _persistState();
        }),
      );

      return {'ok': true, 'pid': proc.pid, 'mode': mode};
    } catch (e) {
      return {'ok': false, 'error': '启动 cloudflared 失败: $e'};
    }
  }

  Future<Map<String, dynamic>> stopTunnel(String profileId) async {
    final tp = _procs.remove(profileId);
    if (tp != null) {
      tp.stopped = true;
      if (!tp.exited) {
        if (Platform.isWindows) {
          try {
            await Process.run(
              'taskkill',
              ['/F', '/T', '/PID', '${tp.proc.pid}'],
            );
          } catch (_) {
            tp.proc.kill();
          }
        } else {
          tp.proc.kill();
        }
      }
    }
    _persistState();
    return {'ok': true};
  }

  Future<void> startAutoTunnels(
    List<Map<String, dynamic>> profiles,
    int localPort,
  ) async {
    for (final prof in profiles) {
      final enabled = prof['enabled'] != false;
      final mode = (prof['tunnel_mode'] ?? 'none').toString();
      final autoStart = prof['tunnel_auto_start'] != false;
      if (enabled && (mode == 'token' || mode == 'quick') && autoStart) {
        await startTunnel(prof, localPort);
      }
    }
  }

  Future<void> stopAll() async {
    for (final pid in _procs.keys.toList()) {
      await stopTunnel(pid);
    }
  }
}
