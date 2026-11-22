import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'encoding_utils.dart';

class PrivStat {
  final bool exists;
  final String type; // 'file' | 'directory' | 'not_found'
  final int size;
  final DateTime modified;

  const PrivStat({
    required this.exists,
    required this.type,
    required this.size,
    required this.modified,
  });

  bool get isFile => exists && type == 'file';
  bool get isDirectory => exists && type == 'directory';
}

class PrivDirEntry {
  final String name;
  final String path;
  final bool isDirectory;
  final int size;

  const PrivDirEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
  });
}

/// Bridges Android Shizuku (ADB UID 2000 / Root UID 0) and Root SU (UID 0)
/// persistent loopback daemons into pure-Dart MCP file & process tools.
class PrivilegedExecutor {
  static final PrivilegedExecutor instance = PrivilegedExecutor._();

  PrivilegedExecutor._();

  String _requestedMode = 'none';
  String _activeMode = 'none';
  bool _mountMaster = true;
  bool _bridgeReady = false;
  int _bridgePort = 0;
  String _bridgeToken = '';
  int _effectiveUid = -1;
  String _effectiveUser = '';
  String _effectiveLabel = '';
  String _shortBadge = '沙盒';
  String _lastError = '';
  Map<String, dynamic> _rawStatus = const {};

  /// App-private internal directory (e.g. `/data/user/0/com.iamr0s.agent_mcp_app`),
  /// owned by app UID and blocked by SELinux from `shell` (`UID 2000`).
  String appInternalDir = '';

  Future<Map<String, dynamic>> Function()? onEnsureReady;
  Future<Map<String, dynamic>> Function({
    required String mode,
    required bool mountMaster,
    required bool interactive,
  })? onApplyConfig;

  late final HttpClient _http = _createLoopbackClient();

  static HttpClient _createLoopbackClient() {
    final c = HttpClient();
    c.findProxy = (_) => 'DIRECT';
    c.connectionTimeout = const Duration(seconds: 4);
    c.idleTimeout = const Duration(seconds: 30);
    return c;
  }

  bool get isSupported => Platform.isAndroid;
  String get requestedMode => _requestedMode;
  String get activeMode => _activeMode;
  bool get mountMaster => _mountMaster;
  bool get isActive =>
      Platform.isAndroid &&
      _bridgeReady &&
      _bridgePort > 0 &&
      _bridgeToken.isNotEmpty;
  int get effectiveUid => _effectiveUid;
  String get effectiveUser => _effectiveUser;
  String get effectiveLabel => _effectiveLabel;
  String get shortBadge => _shortBadge;
  String get lastError => _lastError;

  void updateFromNativeMap(Map<dynamic, dynamic> raw) {
    final map = <String, dynamic>{};
    raw.forEach((k, v) {
      if (v is List) {
        map[k.toString()] = v
            .map((e) => e is Map ? Map<String, dynamic>.from(e) : e)
            .toList();
      } else if (v is Map) {
        map[k.toString()] = Map<String, dynamic>.from(v);
      } else {
        map[k.toString()] = v;
      }
    });
    _requestedMode = (map['requested_mode'] ?? _requestedMode).toString();
    _activeMode = (map['active_mode'] ?? 'none').toString();
    _mountMaster = map['mount_master'] != false;
    _bridgeReady = map['bridge_ready'] == true;
    _bridgePort = int.tryParse('${map['bridge_port'] ?? 0}') ?? 0;
    _bridgeToken = (map['bridge_token'] ?? '').toString();
    _effectiveUid = int.tryParse('${map['effective_uid'] ?? -1}') ?? -1;
    _effectiveUser = (map['effective_user'] ?? '').toString();
    _effectiveLabel = (map['effective_label'] ?? '').toString();
    _shortBadge = (map['short_badge'] ?? '沙盒').toString();
    _lastError = (map['error'] ?? '').toString();
    final sanitized = Map<String, dynamic>.from(map)
      ..remove('bridge_token')
      ..remove('bridge_port');
    _rawStatus = sanitized;
  }

  /// Safe public status dictionary (tokens stripped) for `/status` and `list_roots`.
  Map<String, dynamic> get publicStatus {
    if (!Platform.isAndroid) {
      return const {
        'supported': false,
        'requested_mode': 'none',
        'active_mode': 'none',
        'bridge_ready': false,
      };
    }
    if (_rawStatus.isNotEmpty) {
      return Map<String, dynamic>.from(_rawStatus);
    }
    return {
      'supported': true,
      'requested_mode': _requestedMode,
      'active_mode': isActive ? _activeMode : 'none',
      'mount_master': _mountMaster,
      'bridge_ready': isActive,
      'effective_uid': _effectiveUid,
      'effective_user': _effectiveUser,
      'effective_label':
          _effectiveLabel.isEmpty ? '普通沙盒' : _effectiveLabel,
      'short_badge': _shortBadge,
      'error': _lastError,
    };
  }

  Future<bool> ensureActiveIfRequested() async {
    if (!Platform.isAndroid) return false;
    if (isActive) return true;
    if (_requestedMode == 'none') return false;
    final cb = onEnsureReady;
    if (cb != null) {
      try {
        final snap = await cb();
        updateFromNativeMap(snap);
      } catch (_) {}
    }
    return isActive;
  }

  Uri _uri(String path) => Uri.parse('http://127.0.0.1:$_bridgePort$path');

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final req = await _http.postUrl(_uri(path)).timeout(timeout);
    req.headers.set('x-mcp-priv-token', _bridgeToken);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
    final encoded = utf8.encode(jsonEncode(body));
    req.contentLength = encoded.length;
    req.add(encoded);
    final res = await req.close().timeout(timeout);
    final respText = await utf8.decodeStream(res).timeout(timeout);
    final decoded = jsonDecode(respText);
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    return {'ok': false, 'error': 'Invalid JSON from privileged daemon'};
  }

  Future<PrivStat> fsStat(String targetPath) async {
    final r = await _postJson('/fs/stat', {'path': targetPath});
    if (r['ok'] != true) {
      throw FileSystemException(
        (r['error'] ?? 'stat failed').toString(),
        targetPath,
      );
    }
    final exists = r['exists'] == true;
    final type = (r['type'] ?? 'not_found').toString();
    final size = int.tryParse('${r['size'] ?? 0}') ?? 0;
    final mtimeMs = int.tryParse('${r['mtime_ms'] ?? 0}') ?? 0;
    return PrivStat(
      exists: exists,
      type: type,
      size: size,
      modified: DateTime.fromMillisecondsSinceEpoch(mtimeMs),
    );
  }

  Future<List<PrivDirEntry>> fsList(String dirPath) async {
    final r = await _postJson('/fs/list', {'path': dirPath});
    if (r['ok'] != true) {
      throw FileSystemException(
        (r['error'] ?? 'Permission denied').toString(),
        dirPath,
      );
    }
    final raw = (r['entries'] as List?) ?? const [];
    return raw.whereType<Map>().map((m) {
      return PrivDirEntry(
        name: (m['name'] ?? '').toString(),
        path: (m['path'] ?? '').toString(),
        isDirectory: m['type'] == 'directory',
        size: int.tryParse('${m['size'] ?? 0}') ?? 0,
      );
    }).toList();
  }

  Future<Uint8List> fsReadBytes(
    String targetPath, {
    int maxBytes = 32 * 1024 * 1024,
  }) async {
    final req = await _http
        .postUrl(_uri('/fs/read'))
        .timeout(const Duration(seconds: 25));
    req.headers.set('x-mcp-priv-token', _bridgeToken);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
    final encoded = utf8.encode(
      jsonEncode({'path': targetPath, 'max_bytes': maxBytes}),
    );
    req.contentLength = encoded.length;
    req.add(encoded);
    final res = await req.close().timeout(const Duration(seconds: 25));
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res) {
      builder.add(chunk);
    }
    final data = builder.takeBytes();
    if (res.statusCode != 200) {
      String msg = 'HTTP ${res.statusCode}';
      try {
        final d = jsonDecode(utf8.decode(data, allowMalformed: true));
        if (d is Map && d['error'] != null) msg = d['error'].toString();
      } catch (_) {}
      throw FileSystemException(msg, targetPath);
    }
    return data;
  }

  /// Streams arbitrary byte ranges (including >32MB video/APK files) over the
  /// privileged loopback socket in 64KB chunks without full-file buffering.
  Stream<List<int>> fsOpenRead(
    String targetPath, [
    int? start,
    int? end,
  ]) async* {
    final offset = (start ?? 0) < 0 ? 0 : (start ?? 0);
    final length = (end != null && end >= offset) ? (end - offset) : -1;
    final req = await _http
        .postUrl(_uri('/fs/read_range'))
        .timeout(const Duration(seconds: 15));
    req.headers.set('x-mcp-priv-token', _bridgeToken);
    req.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/json; charset=utf-8',
    );
    final encoded = utf8.encode(
      jsonEncode({
        'path': targetPath,
        'offset': offset,
        'length': length,
      }),
    );
    req.contentLength = encoded.length;
    req.add(encoded);
    final res = await req.close().timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) {
      final errBytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      String msg = 'HTTP ${res.statusCode}';
      try {
        final d = jsonDecode(utf8.decode(errBytes, allowMalformed: true));
        if (d is Map && d['error'] != null) msg = d['error'].toString();
      } catch (_) {}
      throw FileSystemException(msg, targetPath);
    }
    await for (final chunk in res) {
      yield chunk;
    }
  }

  Future<int> fsWriteBytes(
    String targetPath,
    List<int> bytes, {
    bool createParents = true,
  }) async {
    final req = await _http
        .postUrl(_uri('/fs/write'))
        .timeout(const Duration(seconds: 25));
    req.headers.set('x-mcp-priv-token', _bridgeToken);
    req.headers.set(
      'x-target-path-b64',
      base64UrlEncode(utf8.encode(targetPath)).replaceAll('=', ''),
    );
    req.headers.set('x-create-parents', createParents ? '1' : '0');
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/octet-stream');
    req.contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close().timeout(const Duration(seconds: 25));
    final respText =
        await utf8.decodeStream(res).timeout(const Duration(seconds: 25));
    final d = jsonDecode(respText);
    if (res.statusCode != 200 || (d is Map && d['ok'] != true)) {
      final err = (d is Map ? d['error'] : null)?.toString() ?? 'write failed';
      throw FileSystemException(err, targetPath);
    }
    return bytes.length;
  }

  Future<void> fsOp({
    required String action,
    required String src,
    String? dst,
    bool overwrite = false,
  }) async {
    final r = await _postJson('/fs/op', {
      'action': action,
      'src': src,
      if (dst != null) 'dst': dst,
      'overwrite': overwrite,
    });
    if (r['ok'] != true) {
      throw FileSystemException(
        (r['error'] ?? '$action failed').toString(),
        src,
      );
    }
  }

  Future<Map<String, dynamic>> procStart({
    required String command,
    required String cwd,
    String shell = 'auto',
    Map<String, String>? env,
  }) {
    return _postJson('/proc/start', {
      'command': command,
      'cwd': cwd,
      'shell': shell,
      if (env != null && env.isNotEmpty) 'env': env,
    });
  }

  Future<Map<String, dynamic>> procWait({
    required String processId,
    required int timeoutMs,
  }) {
    return _postJson(
      '/proc/wait',
      {'process_id': processId, 'timeout_ms': timeoutMs},
      timeout: Duration(milliseconds: timeoutMs + 8000),
    );
  }

  Future<Map<String, dynamic>> procManage({
    required String action,
    String? processId,
    String? inputText,
    int tailLines = 100,
  }) {
    return _postJson('/proc/manage', {
      'action': action,
      if (processId != null) 'process_id': processId,
      if (inputText != null) 'input_text': inputText,
      'tail_lines': tailLines,
    });
  }

  Future<void> procStopAll() async {
    if (!isActive) return;
    try {
      await _postJson('/proc/stop_all', const {});
    } catch (_) {}
  }
}

/// Unified filesystem facade that transparently uses `PrivilegedExecutor` when
/// active on Android (while respecting SELinux app-private ownership under UID 2000)
/// and zero-overhead `dart:io` everywhere else.
class PrivFs {
  static Future<bool> useBridgeForPath(String targetPath) async {
    final exec = PrivilegedExecutor.instance;
    if (!Platform.isAndroid) return false;
    final ready = await exec.ensureActiveIfRequested();
    if (!ready) return false;

    // Under Shizuku ADB (UID 2000), SELinux prevents `shell` from accessing
    // untrusted_app internal `/data/user/0/<pkg>` or `/data/data/<pkg>`,
    // whereas the app itself owns those files directly.
    if (exec.effectiveUid != 0) {
      final norm = p.normalize(targetPath);
      final appInt = exec.appInternalDir;
      if ((appInt.isNotEmpty &&
              (norm == appInt || norm.startsWith('$appInt/'))) ||
          norm.startsWith('/data/user/0/com.iamr0s.agent_mcp_app') ||
          norm.startsWith('/data/data/com.iamr0s.agent_mcp_app')) {
        return false;
      }
    }
    return true;
  }

  static Future<PrivStat> stat(String targetPath) async {
    if (await useBridgeForPath(targetPath)) {
      return PrivilegedExecutor.instance.fsStat(targetPath);
    }
    final type = FileSystemEntity.typeSync(targetPath);
    if (type == FileSystemEntityType.notFound) {
      return PrivStat(
        exists: false,
        type: 'not_found',
        size: 0,
        modified: DateTime.fromMillisecondsSinceEpoch(0),
      );
    }
    final st = FileStat.statSync(targetPath);
    return PrivStat(
      exists: true,
      type: type == FileSystemEntityType.directory ? 'directory' : 'file',
      size: st.size,
      modified: st.modified,
    );
  }

  static Future<bool> isDirectory(String targetPath) async {
    final st = await stat(targetPath);
    return st.isDirectory;
  }

  static Future<bool> isFile(String targetPath) async {
    final st = await stat(targetPath);
    return st.isFile;
  }

  static Future<List<PrivDirEntry>> listDir(String dirPath) async {
    if (await useBridgeForPath(dirPath)) {
      return PrivilegedExecutor.instance.fsList(dirPath);
    }
    final entries = Directory(dirPath).listSync(followLinks: false);
    return entries.map((e) {
      final isDir = e is Directory;
      var sz = 0;
      if (!isDir) {
        try {
          sz = File(e.path).lengthSync();
        } catch (_) {}
      }
      return PrivDirEntry(
        name: p.basename(e.path),
        path: e.path,
        isDirectory: isDir,
        size: sz,
      );
    }).toList();
  }

  static Future<Uint8List> readBytes(String targetPath) async {
    if (await useBridgeForPath(targetPath)) {
      return PrivilegedExecutor.instance.fsReadBytes(targetPath);
    }
    return File(targetPath).readAsBytesSync();
  }

  /// Opens a zero-buffering read stream for [targetPath] over optional [start]..[end]
  /// byte bounds, working seamlessly across both native `dart:io` and Android Shizuku/Root.
  static Future<Stream<List<int>>> openRead(
    String targetPath, [
    int? start,
    int? end,
  ]) async {
    if (await useBridgeForPath(targetPath)) {
      return PrivilegedExecutor.instance.fsOpenRead(targetPath, start, end);
    }
    return File(targetPath).openRead(start, end);
  }

  static Future<DecodedTextFile> readText(String targetPath) async {
    final bytes = await readBytes(targetPath);
    return decodeTextBytesSmart(bytes, targetPath);
  }

  static Future<int> writeBytes(
    String targetPath,
    List<int> bytes, {
    bool createParents = true,
  }) async {
    if (await useBridgeForPath(targetPath)) {
      return PrivilegedExecutor.instance.fsWriteBytes(
        targetPath,
        bytes,
        createParents: createParents,
      );
    }
    final f = File(targetPath);
    if (createParents) {
      f.parent.createSync(recursive: true);
    }
    f.writeAsBytesSync(bytes, flush: true);
    return bytes.length;
  }

  static Future<int> writeText(
    String targetPath,
    String text, {
    String encoding = 'utf-8',
    String newline = '\n',
  }) async {
    final bytes = encodeTextPreservingBytes(
      text,
      encoding: encoding,
      newline: newline,
    );
    return writeBytes(targetPath, bytes, createParents: true);
  }

  static Future<void> delete(String targetPath, {bool recursive = false}) async {
    if (await useBridgeForPath(targetPath)) {
      await PrivilegedExecutor.instance.fsOp(action: 'delete', src: targetPath);
      return;
    }
    final type = FileSystemEntity.typeSync(targetPath);
    if (type == FileSystemEntityType.directory) {
      Directory(targetPath).deleteSync(recursive: recursive);
    } else if (type != FileSystemEntityType.notFound) {
      File(targetPath).deleteSync();
    }
  }

  static Future<void> move(
    String srcPath,
    String dstPath, {
    bool overwrite = false,
  }) async {
    if (await useBridgeForPath(srcPath) || await useBridgeForPath(dstPath)) {
      await PrivilegedExecutor.instance.fsOp(
        action: 'move',
        src: srcPath,
        dst: dstPath,
        overwrite: overwrite,
      );
      return;
    }
    final dstType = FileSystemEntity.typeSync(dstPath);
    if (dstType == FileSystemEntityType.directory) {
      Directory(dstPath).deleteSync(recursive: true);
    } else if (dstType == FileSystemEntityType.file) {
      File(dstPath).deleteSync();
    }
    File(dstPath).parent.createSync(recursive: true);
    final srcType = FileSystemEntity.typeSync(srcPath);
    try {
      if (srcType == FileSystemEntityType.directory) {
        Directory(srcPath).renameSync(dstPath);
      } else {
        File(srcPath).renameSync(dstPath);
      }
    } on FileSystemException {
      if (srcType == FileSystemEntityType.directory) {
        _copyDirLocal(Directory(srcPath), Directory(dstPath));
        Directory(srcPath).deleteSync(recursive: true);
      } else {
        File(srcPath).copySync(dstPath);
        File(srcPath).deleteSync();
      }
    }
  }

  static Future<void> copy(
    String srcPath,
    String dstPath, {
    bool overwrite = false,
  }) async {
    if (await useBridgeForPath(srcPath) || await useBridgeForPath(dstPath)) {
      await PrivilegedExecutor.instance.fsOp(
        action: 'copy',
        src: srcPath,
        dst: dstPath,
        overwrite: overwrite,
      );
      return;
    }
    File(dstPath).parent.createSync(recursive: true);
    final srcType = FileSystemEntity.typeSync(srcPath);
    if (srcType == FileSystemEntityType.directory) {
      _copyDirLocal(Directory(srcPath), Directory(dstPath));
    } else {
      File(srcPath).copySync(dstPath);
    }
  }

  static void _copyDirLocal(Directory src, Directory dst) {
    dst.createSync(recursive: true);
    for (final entity in src.listSync(followLinks: false)) {
      final target = p.join(dst.path, p.basename(entity.path));
      if (entity is Directory) {
        _copyDirLocal(entity, Directory(target));
      } else if (entity is File) {
        entity.copySync(target);
      }
    }
  }
}