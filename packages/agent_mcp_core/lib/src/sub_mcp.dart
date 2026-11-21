import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'encoding_utils.dart';
import 'process_tools.dart';
import 'tool_types.dart';
import 'version.dart';

final RegExp _subNameRe = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$');

String sanitizeSubName(String raw) {
  final cleaned = raw
      .trim()
      .replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '-')
      .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
  return cleaned.length > 64 ? cleaned.substring(0, 64) : cleaned;
}

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
  final url = (raw['url'] ?? '').toString().trim();

  if (transport == 'streamable-http' || transport == 'streamable_http') {
    transport = 'http';
  }
  if (transport.isEmpty) {
    if (command.isNotEmpty) {
      transport = 'stdio';
    } else if (url.replaceAll(RegExp(r'/+$'), '').endsWith('/sse')) {
      transport = 'sse';
    } else {
      transport = 'http';
    }
  }
  if (transport != 'stdio' && transport != 'http' && transport != 'sse') {
    throw FormatException('不支持的传输协议: $transport（仅支持 stdio / http / sse）');
  }
  if (transport == 'stdio' && command.isEmpty) {
    throw const FormatException('stdio 模式必须填写启动命令 (command)。');
  }
  if ((transport == 'http' || transport == 'sse') && url.isEmpty) {
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

  final timeout =
      (int.tryParse('${raw['timeout'] ?? 30}') ?? 30).clamp(3, 300);

  return <String, dynamic>{
    'name': name,
    'description': (raw['description'] ?? '').toString().trim(),
    'transport': transport,
    'enabled': raw['enabled'] == null ? true : raw['enabled'] == true,
    'command': command,
    'args': args,
    'cwd': (raw['cwd'] ?? '').toString().trim(),
    'env': parseStringMap(raw['env']),
    'url': url,
    'headers': parseStringMap(raw['headers']),
    'timeout': timeout,
  };
}

List<Map<String, dynamic>> parseMcpServersJson(String rawText) {
  final dynamic data;
  try {
    data = jsonDecode(rawText);
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
    throw const FormatException('顶层必须是 JSON 对象或数组。');
  }

  final serversObj = data['mcpServers'] is Map
      ? Map<String, dynamic>.from(data['mcpServers'] as Map)
      : Map<String, dynamic>.from(data);
  if (serversObj.isEmpty) {
    throw const FormatException('未找到有效的 mcpServers 配置项。');
  }

  if (serversObj.containsKey('command') || serversObj.containsKey('url')) {
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

class _McpClientSession {
  final Map<String, dynamic> entry;
  final Duration timeout;

  _McpClientSession(this.entry)
      : timeout = Duration(seconds: (entry['timeout'] as int?) ?? 30);

  Future<(Map<String, dynamic>, List<Map<String, dynamic>>)>
      initializeAndListTools() async {
    final tr = entry['transport'] as String;
    if (tr == 'stdio') {
      return _runStdio((send) async {
        final initRes = await send('initialize', _initParams());
        await send('notifications/initialized', null, isNotification: true);
        final listRes = await send('tools/list', const <String, dynamic>{});
        return (initRes, _extractTools(listRes));
      });
    } else if (tr == 'sse') {
      return _runSse((send) async {
        final initRes = await send('initialize', _initParams());
        await send('notifications/initialized', null, isNotification: true);
        final listRes = await send('tools/list', const <String, dynamic>{});
        return (initRes, _extractTools(listRes));
      });
    } else {
      return _runHttp((send) async {
        final initRes = await send('initialize', _initParams());
        await send('notifications/initialized', null, isNotification: true);
        final listRes = await send('tools/list', const <String, dynamic>{});
        return (initRes, _extractTools(listRes));
      });
    }
  }

  Future<String> callTool(
    String toolName,
    Map<String, dynamic> arguments, {
    Duration? overrideTimeout,
  }) async {
    final tr = entry['transport'] as String;
    final effTimeout = overrideTimeout ?? timeout;
    Future<Map<String, dynamic>> invoke(
      Future<Map<String, dynamic>> Function(
        String method,
        Map<String, dynamic>? params, {
        bool isNotification,
      }) send,
    ) async {
      await send('initialize', _initParams());
      await send('notifications/initialized', null, isNotification: true);
      return send('tools/call', {
        'name': toolName,
        'arguments': arguments,
      });
    }

    final Map<String, dynamic> res;
    if (tr == 'stdio') {
      res = await _runStdio(invoke, overrideTimeout: effTimeout);
    } else if (tr == 'sse') {
      res = await _runSse(invoke, overrideTimeout: effTimeout);
    } else {
      res = await _runHttp(invoke, overrideTimeout: effTimeout);
    }
    return _formatCallToolResult(res);
  }

  Map<String, dynamic> _initParams() => {
        'protocolVersion': '2025-03-26',
        'capabilities': const <String, dynamic>{},
        'clientInfo': {'name': 'agent-mcp-gateway', 'version': agentMcpVersion},
      };

  List<Map<String, dynamic>> _extractTools(Map<String, dynamic> res) {
    final raw = (res['tools'] as List?) ?? const [];
    return raw.whereType<Map>().map((t) {
      return <String, dynamic>{
        'name': (t['name'] ?? '').toString(),
        'description': (t['description'] ?? '').toString(),
        'inputSchema': t['inputSchema'] ??
            t['input_schema'] ??
            const {'type': 'object', 'properties': <String, dynamic>{}},
        if (t['annotations'] != null) 'annotations': t['annotations'],
      };
    }).toList();
  }

  Future<T> _runStdio<T>(
    Future<T> Function(
      Future<Map<String, dynamic>> Function(
        String method,
        Map<String, dynamic>? params, {
        bool isNotification,
      }) send,
    ) action, {
    Duration? overrideTimeout,
  }) async {
    final effTimeout = overrideTimeout ?? timeout;
    final cmd = (entry['command'] ?? '').toString();
    final args = ((entry['args'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
    final cwd = (entry['cwd'] ?? '').toString().trim();
    final env = Map<String, String>.from(Platform.environment)
      ..addAll(Map<String, String>.from((entry['env'] as Map?) ?? const {}));

    Process proc;
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
    Future<T> Function(
      Future<Map<String, dynamic>> Function(
        String method,
        Map<String, dynamic>? params, {
        bool isNotification,
      }) send,
    ) action, {
    Duration? overrideTimeout,
  }) async {
    final effTimeout = overrideTimeout ?? timeout;
    final uri = Uri.parse(entry['url'] as String);
    final baseHeaders = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
      ...Map<String, String>.from((entry['headers'] as Map?) ?? const {}),
    };
    final client = http.Client();
    String? sessionId;
    var nextId = 1;

    Future<Map<String, dynamic>> send(
      String method,
      Map<String, dynamic>? params, {
      bool isNotification = false,
    }) async {
      final headers = <String, String>{
        ...baseHeaders,
        if (sessionId != null) 'Mcp-Session-Id': sessionId!,
      };
      final bodyObj = <String, dynamic>{
        'jsonrpc': '2.0',
        if (!isNotification) 'id': nextId++,
        'method': method,
        if (params != null) 'params': params,
      };
      final resp = await client
          .post(uri, headers: headers, body: jsonEncode(bodyObj))
          .timeout(effTimeout);

      final sid =
          resp.headers['mcp-session-id'] ?? resp.headers['Mcp-Session-Id'];
      if (sid != null && sid.isNotEmpty) sessionId = sid;

      if (isNotification || resp.statusCode == 202 || resp.body.trim().isEmpty) {
        return const <String, dynamic>{};
      }
      if (resp.statusCode >= 400) {
        throw HttpException(
          'HTTP ${resp.statusCode}: ${resp.body}',
          uri: uri,
        );
      }

      final ctype = (resp.headers['content-type'] ?? '').toLowerCase();
      Map<String, dynamic>? rpcMsg;
      if (ctype.contains('text/event-stream')) {
        for (final line in resp.body.split(RegExp(r'\r?\n'))) {
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
      return Map<String, dynamic>.from((rpcMsg['result'] as Map?) ?? const {});
    }

    try {
      return await action(send);
    } finally {
      client.close();
    }
  }

  Future<T> _runSse<T>(
    Future<T> Function(
      Future<Map<String, dynamic>> Function(
        String method,
        Map<String, dynamic>? params, {
        bool isNotification,
      }) send,
    ) action, {
    Duration? overrideTimeout,
  }) async {
    final effTimeout = overrideTimeout ?? timeout;
    final sseUri = Uri.parse(entry['url'] as String);
    final customHeaders =
        Map<String, String>.from((entry['headers'] as Map?) ?? const {});
    final httpClient = HttpClient();
    final endpointCompleter = Completer<Uri>();
    final pending = <int, Completer<Map<String, dynamic>>>{};
    var nextId = 1;

    try {
      final req = await httpClient.getUrl(sseUri).timeout(effTimeout);
      req.headers.set('Accept', 'text/event-stream');
      customHeaders.forEach(req.headers.set);
      final resp = await req.close().timeout(effTimeout);
      if (resp.statusCode >= 400) {
        throw HttpException('SSE HTTP ${resp.statusCode}', uri: sseUri);
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

      final postUri = await endpointCompleter.future.timeout(effTimeout);
      final postClient = http.Client();

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
}

String _formatCallToolResult(Map<String, dynamic> res) {
  final isError = res['isError'] == true || res['is_error'] == true;
  final structured = res['structuredContent'] ?? res['structured_content'];
  final content = (res['content'] as List?) ?? const [];

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
  final Map<String, Map<String, dynamic>> _cache = {};

  SubMcpManager([this._customConfigFile]);

  File get configFile =>
      _customConfigFile ?? StoragePaths.instance.subMcpConfigFile;

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
    final payload = {'version': 1, 'servers': entries};
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
      final c = _cache[e['name']] ?? const <String, dynamic>{};
      final tools = (c['tools'] as List?) ?? const [];
      return <String, dynamic>{
        ...e,
        'status': c['status'] ?? 'idle',
        'tool_count': c.containsKey('tools') ? tools.length : null,
        'tools': tools
            .whereType<Map>()
            .map((t) => {
                  'name': t['name'] ?? '',
                  'description': t['description'] ?? '',
                })
            .toList(),
        'last_error': c['error'],
        'last_ms': c['ms'],
      };
    }).toList();
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
    if (oldName != null) _cache.remove(oldName);
    _cache.remove(entry['name']);
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
    return true;
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
      final (initRes, tools) =
          await _McpClientSession(entry).initializeAndListTools();
      sw.stop();
      final elapsed = double.parse((sw.elapsedMicroseconds / 1000.0).toStringAsFixed(1));
      final serverInfo = (initRes['serverInfo'] as Map?) ?? const {};
      final rawName = (serverInfo['name'] ?? '').toString().trim();
      final version = (serverInfo['version'] ?? '').toString().trim();
      final instructions = (initRes['instructions'] ?? '').toString().trim();
      final suggestedName = rawName.isNotEmpty ? sanitizeSubName(rawName) : '';

      String desc;
      if (instructions.isNotEmpty) {
        final firstPara = instructions.split(RegExp(r'\r?\n')).first.trim();
        desc = firstPara.length > 180
            ? '${firstPara.substring(0, 180)}...'
            : firstPara;
      } else if (tools.isNotEmpty) {
        final sample = tools.take(5).map((t) => t['name']).join(', ');
        final suffix = tools.length > 5 ? ' 等' : '';
        final verTag = version.isNotEmpty ? 'v$version · ' : '';
        desc = '$verTag提供 ${tools.length} 个工具（$sample$suffix）';
      } else {
        desc = '$rawName $version'.trim();
      }

      return {
        'ok': true,
        'name': suggestedName,
        'raw_name': rawName,
        'version': version,
        'description': desc,
        'tool_count': tools.length,
        'ms': elapsed,
      };
    } catch (e) {
      sw.stop();
      final elapsed = double.parse((sw.elapsedMicroseconds / 1000.0).toStringAsFixed(1));
      return {'ok': false, 'error': '$e', 'ms': elapsed};
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
        'ms': cached['ms'] ?? 0.0,
        'cached': true,
      };
    }

    final sw = Stopwatch()..start();
    try {
      final (_, tools) =
          await _McpClientSession(entry).initializeAndListTools();
      sw.stop();
      final elapsed = double.parse((sw.elapsedMicroseconds / 1000.0).toStringAsFixed(1));
      _cache[name] = {
        'status': 'ok',
        'tools': tools,
        'error': null,
        'ms': elapsed,
      };
      return {'ok': true, 'tools': tools, 'ms': elapsed, 'cached': false};
    } catch (e) {
      sw.stop();
      final elapsed = double.parse((sw.elapsedMicroseconds / 1000.0).toStringAsFixed(1));
      final errMsg = '$e';
      _cache[name] = {
        'status': 'error',
        'tools': const <Map<String, dynamic>>[],
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
    try {
      final res = await _McpClientSession(entry).callTool(
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
        'List all configured and enabled nested Sub-MCP servers without polluting the main toolset.\n'
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
                'status': it['status'] ?? 'idle',
                'cached_tool_count': it['tool_count'],
              })
          .toList();
      return jsonEncoder.convert({
        'count': enabledItems.length,
        'sub_mcps': enabledItems,
        'usage':
            '1) Call inspect_sub_mcp(server_name) to list tool names and summaries. '
                '2) Call inspect_sub_mcp(server_name, tool_name) to inspect exact inputSchema before calling. '
                '3) Call call_sub_mcp(server_name, tool_name, arguments={...}) to execute.',
      });
    },
  );

  registerTool(
    name: 'inspect_sub_mcp',
    description: 'Inspect tools exposed by a nested Sub-MCP server.\n'
        'Omit tool_name to get a compact list of tool names & descriptions; pass tool_name to get its full inputSchema.',
    annotations: readOnlyAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'server_name': {'type': 'string'},
        'tool_name': {'type': 'string'},
        'refresh': {'type': 'boolean', 'default': false},
      },
      'required': ['server_name'],
    },
    handler: (args) async {
      final serverName = (args['server_name'] ?? '').toString();
      final toolName = args['tool_name']?.toString();
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

      final tools =
          ((res['tools'] as List?) ?? const []).whereType<Map>().toList();
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
        'hint':
            'Call inspect_sub_mcp(server_name, tool_name) to view full parameter schema before calling.',
      });
    },
  );

  registerTool(
    name: 'call_sub_mcp',
    description:
        'Invoke a specific tool on a nested Sub-MCP server by server_name, tool_name, and arguments dict.\n'
        'Always inspect_sub_mcp(server_name, tool_name) first if you are unsure about required parameter names or types.',
    annotations: subCallAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'server_name': {'type': 'string'},
        'tool_name': {'type': 'string'},
        'arguments': {'type': 'object'},
        'timeout': {'type': 'integer'},
      },
      'required': ['server_name', 'tool_name'],
    },
    handler: (args) async {
      final serverName = (args['server_name'] ?? '').toString();
      final toolName = (args['tool_name'] ?? '').toString();
      final rawArgs = args['arguments'];
      final callArgs = rawArgs is Map
          ? Map<String, dynamic>.from(rawArgs)
          : <String, dynamic>{};
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
