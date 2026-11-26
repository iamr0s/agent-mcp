import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'config.dart';

const String jsonEventPrefix = '@@MCP_EVENT@@';

class StructuredEventBus {
  static final StructuredEventBus instance = StructuredEventBus._();
  StructuredEventBus._();

  final ListQueue<Map<String, dynamic>> _history =
      ListQueue<Map<String, dynamic>>(1500);
  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();

  bool emitStderrJsonEvents = Platform.environment['MCP_JSON_EVENTS'] == '1' &&
      !(Platform.isWindows &&
          Platform.resolvedExecutable
              .toLowerCase()
              .endsWith('agent_mcp_app.exe'));

  Stream<Map<String, dynamic>> get stream => _controller.stream;

  List<Map<String, dynamic>> getHistory() =>
      List<Map<String, dynamic>>.unmodifiable(_history);

  void clearHistory() => _history.clear();

  void emit(Map<String, dynamic> event) {
    final now = DateTime.now();
    final ts =
        '${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}';
    final tsFull =
        '${now.year}-${_two(now.month)}-${_two(now.day)} $ts';
    final payload = <String, dynamic>{
      'ts': ts,
      'ts_full': tsFull,
      ...event,
    };
    if (_history.length >= 1500) {
      _history.removeFirst();
    }
    _history.addLast(payload);
    if (!_controller.isClosed) {
      _controller.add(payload);
    }
    if (emitStderrJsonEvents) {
      try {
        stderr.writeln('$jsonEventPrefix${jsonEncode(payload)}');
      } catch (_) {
        emitStderrJsonEvents = false;
      }
    }
  }
}

String _two(int n) => n.toString().padLeft(2, '0');

enum LogLevel { debug, info, warning, error }

class McpLogger {
  static final McpLogger instance = McpLogger._();
  McpLogger._();

  String serverName = 'local-agent-mcp';
  LogLevel minLevel = LogLevel.info;
  bool useColor = true;
  File? logFile;
  bool quietStderr = Platform.isWindows &&
      Platform.resolvedExecutable.toLowerCase().endsWith('agent_mcp_app.exe');

  void configure({
    required String name,
    required String levelName,
    String? logFilePath,
    bool noColor = false,
    bool quiet = false,
  }) {
    serverName = name;
    minLevel = _parseLevel(levelName);
    final isWinGuiExe = Platform.isWindows &&
        Platform.resolvedExecutable.toLowerCase().endsWith('agent_mcp_app.exe');
    quietStderr = quiet || isWinGuiExe;
    useColor = !noColor && stderr.hasTerminal;
    if (logFilePath != null && logFilePath.trim().isNotEmpty) {
      final resolved = expandAndResolvePath(logFilePath.trim());
      final f = File(resolved);
      f.parent.createSync(recursive: true);
      logFile = f;
    } else {
      logFile = null;
    }
  }

  LogLevel _parseLevel(String raw) {
    switch (raw.trim().toUpperCase()) {
      case 'DEBUG':
        return LogLevel.debug;
      case 'WARNING':
      case 'WARN':
        return LogLevel.warning;
      case 'ERROR':
      case 'CRITICAL':
        return LogLevel.error;
      default:
        return LogLevel.info;
    }
  }

  void debug(String msg) => _log(LogLevel.debug, 'DEBUG', msg);
  void info(String msg) => _log(LogLevel.info, 'INFO', msg);
  void warning(String msg) => _log(LogLevel.warning, 'WARNING', msg);
  void error(String msg, [Object? err, StackTrace? st]) {
    final full = err == null ? msg : '$msg\n$err${st != null ? '\n$st' : ''}';
    _log(LogLevel.error, 'ERROR', full);
  }

  void _log(LogLevel lvl, String label, String msg) {
    if (lvl.index < minLevel.index) return;
    final now = DateTime.now();
    final ts =
        '${now.year}-${_two(now.month)}-${_two(now.day)} ${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}';
    final srcCol = '[${serverName.padRight(18).substring(0, 18)}]';
    final lvlCol = '[${label.padRight(7)}]';
    final plain = '$ts $lvlCol $srcCol $msg';

    if (logFile != null) {
      try {
        logFile!.writeAsStringSync('$plain\n', mode: FileMode.append);
      } catch (_) {}
    }

    if (quietStderr) return;

    if (!useColor) {
      try {
        stderr.writeln(plain);
      } catch (_) {
        quietStderr = true;
      }
      return;
    }

    final lvlAnsi = switch (lvl) {
      LogLevel.debug => '\x1B[36m',
      LogLevel.info => '\x1B[32m',
      LogLevel.warning => '\x1B[33m',
      LogLevel.error => '\x1B[91m',
    };
    final colored = '\x1B[90m$ts\x1B[0m '
        '$lvlAnsi$lvlCol\x1B[0m '
        '\x1B[34m$srcCol\x1B[0m '
        '$msg';
    try {
      stderr.writeln(colored);
    } catch (_) {
      quietStderr = true;
    }
  }
}

final RegExp _inlineBearerRe = RegExp(
  r'\b(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}',
  caseSensitive: false,
);

bool isSensitiveKeyName(String key) {
  final kl = key.trim().toLowerCase();
  if (kl == 'pin' || kl == 'pin_code' || kl == 'pincode') return true;
  return kl.contains('password') ||
      kl.contains('passwd') ||
      kl.contains('secret') ||
      kl.contains('token') ||
      kl.contains('api_key') ||
      kl.contains('apikey') ||
      kl.contains('authorization') ||
      kl.contains('cookie') ||
      kl.contains('private_key') ||
      kl.contains('credential');
}

dynamic _redactDynamic(dynamic value, int depth) {
  if (depth > 6 || value == null) return value;
  if (value is String) {
    if (_inlineBearerRe.hasMatch(value)) {
      return value.replaceAllMapped(_inlineBearerRe, (m) => '${m.group(1)}***');
    }
    return value;
  }
  if (value is Map) {
    final out = <String, dynamic>{};
    value.forEach((rawKey, v) {
      final k = rawKey.toString();
      out[k] = isSensitiveKeyName(k) ? '***' : _redactDynamic(v, depth + 1);
    });
    return out;
  }
  if (value is List) {
    return value.map((item) => _redactDynamic(item, depth + 1)).toList();
  }
  return value;
}

Map<String, dynamic> redactArgs(Map<String, dynamic> args) {
  final res = _redactDynamic(args, 0);
  return res is Map<String, dynamic> ? res : Map<String, dynamic>.from(res as Map);
}

String abbrevValue(dynamic val, [int maxLen = 120, int depth = 0]) {
  if (depth > 6) return '...';
  if (val is String) {
    final masked = _inlineBearerRe.hasMatch(val)
        ? val.replaceAllMapped(_inlineBearerRe, (m) => '${m.group(1)}***')
        : val;
    final s = masked.replaceAll('\r', r'\r').replaceAll('\n', r'\n');
    if (s.length > maxLen) {
      return "'${s.substring(0, maxLen)}...' (len=${val.length})";
    }
    return "'$s'";
  }
  if (val is List) {
    if (val.length > 5) {
      final preview =
          val.take(3).map((e) => abbrevValue(e, 40, depth + 1)).join(', ');
      return '[$preview, ... (${val.length} items)]';
    }
    return '[${val.map((e) => abbrevValue(e, 60, depth + 1)).join(', ')}]';
  }
  if (val is Map) {
    final entries = val.entries.toList();
    final parts = <String>[];
    for (final e in entries.take(5)) {
      final k = e.key.toString();
      parts.add(
        isSensitiveKeyName(k)
            ? '$k=***'
            : '$k=${abbrevValue(e.value, 50, depth + 1)}',
      );
    }
    if (entries.length > 5) {
      parts.add('...(+${entries.length - 5})');
    }
    return '{${parts.join(', ')}}';
  }
  final s = '$val';
  return s.length > maxLen ? '${s.substring(0, maxLen)}...' : s;
}

String formatCallArgs(Map<String, dynamic> args) {
  final parts = <String>[];
  for (final e in args.entries) {
    parts.add(
      isSensitiveKeyName(e.key)
          ? '${e.key}=***'
          : '${e.key}=${abbrevValue(e.value)}',
    );
  }
  final joined = parts.join(', ');
  return joined.length > 320 ? '${joined.substring(0, 320)}... (truncated)' : joined;
}
