import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';

import 'config.dart';
import 'encoding_utils.dart';
import 'logging_utils.dart';
import 'privileged_exec.dart';
import 'tool_types.dart';

/// Attaches spawned Windows child processes to a Kernel32 Job Object configured
/// with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` (0x2000), ensuring zero orphan
/// background processes or dangling `cloudflared` daemons if the host exits.
class Win32ProcessJobGuard {
  static final Win32ProcessJobGuard instance = Win32ProcessJobGuard._();

  int _jobHandle = 0;
  bool _initialized = false;

  Win32ProcessJobGuard._();

  void attachPid(int pid) {
    if (!Platform.isWindows || pid <= 0) return;
    try {
      _ensureInitialized();
      if (_jobHandle == 0) return;
      final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
      final openProcess = kernel32.lookupFunction<
          ffi.IntPtr Function(ffi.Uint32, ffi.Int32, ffi.Uint32),
          int Function(int, int, int)>('OpenProcess');
      final assignToJob = kernel32.lookupFunction<
          ffi.Int32 Function(ffi.IntPtr, ffi.IntPtr),
          int Function(int, int)>('AssignProcessToJobObject');
      final closeHandle = kernel32.lookupFunction<
          ffi.Int32 Function(ffi.IntPtr), int Function(int)>('CloseHandle');

      // PROCESS_SET_QUOTA (0x0100) | PROCESS_TERMINATE (0x0001)
      final hProc = openProcess(0x0101, 0, pid);
      if (hProc != 0) {
        assignToJob(_jobHandle, hProc);
        closeHandle(hProc);
      }
    } catch (_) {}
  }

  void _ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    try {
      final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
      final createJob = kernel32.lookupFunction<
          ffi.IntPtr Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf16>),
          int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf16>)>(
        'CreateJobObjectW',
      );
      final setInfo = kernel32.lookupFunction<
          ffi.Int32 Function(
              ffi.IntPtr, ffi.Int32, ffi.Pointer<ffi.Uint8>, ffi.Uint32),
          int Function(int, int, ffi.Pointer<ffi.Uint8>, int)>(
        'SetInformationJobObject',
      );

      final hJob = createJob(ffi.nullptr, ffi.nullptr);
      if (hJob == 0) return;

      const structSize = 144;
      final buf = calloc<ffi.Uint8>(structSize);
      try {
        final flagsPtr = ffi.Pointer<ffi.Uint32>.fromAddress(buf.address + 16);
        flagsPtr.value = 0x00002800;
        final ok = setInfo(hJob, 9, buf, structSize);
        if (ok != 0) {
          _jobHandle = hJob;
        }
      } finally {
        calloc.free(buf);
      }
    } catch (_) {}
  }
}

class ManagedProcess {
  final String processId;
  final String command;
  final String cwd;
  final Process? proc;
  final int pid;
  final bool isPrivileged;
  final DateTime startedAt;
  final ListQueue<String> lines = ListQueue<String>(5000);
  final Completer<int> exitCompleter = Completer<int>();
  int? exitCodeValue;
  DateTime? endedAt;

  ManagedProcess({
    required this.processId,
    required this.command,
    required this.cwd,
    required this.proc,
    required this.pid,
    required this.startedAt,
    this.isPrivileged = false,
  });

  bool get isRunning => exitCodeValue == null;

  void appendChunk(String decodedText) {
    final split = decodedText.replaceAll('\r\n', '\n').split('\n');
    for (var i = 0; i < split.length; i++) {
      if (i == split.length - 1 && split[i].isEmpty) continue;
      if (lines.length >= 5000) lines.removeFirst();
      lines.addLast(split[i]);
    }
  }
}

class ProcessManager {
  final Map<String, ManagedProcess> _procs = {};

  static String _randomId() {
    const hex = '0123456789abcdef';
    final rng = Random.secure();
    return List.generate(8, (_) => hex[rng.nextInt(16)]).join();
  }

  (String, List<String>, bool) _resolveCommand(String command, String shell) {
    if (Platform.isWindows) {
      if (shell == 'powershell') {
        return (
          'powershell.exe',
          ['-NoProfile', '-NonInteractive', '-Command', command],
          false,
        );
      }
      return ('cmd.exe', ['/c', command], false);
    } else {
      if (shell == 'bash' || shell == 'sh' || shell == 'zsh') {
        return (shell, ['-c', command], false);
      }
      final defaultSh = File('/bin/bash').existsSync()
          ? '/bin/bash'
          : (File('/bin/sh').existsSync() ? '/bin/sh' : '/system/bin/sh');
      return (defaultSh, ['-c', command], false);
    }
  }

  void _pruneExitedProcs({
    Duration maxExitedAge = const Duration(minutes: 30),
    int maxExitedKeep = 24,
  }) {
    final now = DateTime.now();
    final exited = <ManagedProcess>[];
    for (final mp in _procs.values.toList()) {
      if (!mp.isRunning) {
        final ended = mp.endedAt ?? mp.startedAt;
        if (now.difference(ended) > maxExitedAge) {
          _procs.remove(mp.processId);
        } else {
          exited.add(mp);
        }
      }
    }
    if (exited.length > maxExitedKeep) {
      exited.sort(
        (a, b) => (a.endedAt ?? a.startedAt).compareTo(b.endedAt ?? b.startedAt),
      );
      final excess = exited.length - maxExitedKeep;
      for (var i = 0; i < excess; i++) {
        _procs.remove(exited[i].processId);
      }
    }
  }

  Future<ManagedProcess> start({
    required String command,
    required String cwd,
    String shell = 'auto',
    Map<String, String>? env,
  }) async {
    _pruneExitedProcs();
    if (Platform.isAndroid &&
        await PrivilegedExecutor.instance.ensureActiveIfRequested()) {
      final res = await PrivilegedExecutor.instance.procStart(
        command: command,
        cwd: cwd,
        shell: shell,
        env: env,
      );
      if (res['ok'] != true) {
        throw ProcessException(
          shell,
          [command],
          (res['error'] ?? 'Privileged procStart failed').toString(),
        );
      }
      final id = (res['process_id'] ?? _randomId()).toString();
      final pid = int.tryParse('${res['pid'] ?? -1}') ?? -1;
      final actualCwd = (res['cwd'] ?? cwd).toString();
      final mp = ManagedProcess(
        processId: id,
        command: command,
        cwd: actualCwd,
        proc: null,
        pid: pid,
        startedAt: DateTime.now(),
        isPrivileged: true,
      );
      _procs[id] = mp;
      return mp;
    }

    final mergedEnv = Map<String, String>.from(Platform.environment);
    mergedEnv.putIfAbsent('PYTHONIOENCODING', () => 'utf-8');
    if (env != null) {
      mergedEnv.addAll(env);
    }

    final (exe, args, runInShell) = _resolveCommand(command, shell);
    final proc = await Process.start(
      exe,
      args,
      workingDirectory: cwd,
      environment: mergedEnv,
      runInShell: runInShell,
    );
    Win32ProcessJobGuard.instance.attachPid(proc.pid);

    final id = _randomId();
    final mp = ManagedProcess(
      processId: id,
      command: command,
      cwd: cwd,
      proc: proc,
      pid: proc.pid,
      startedAt: DateTime.now(),
    );
    _procs[id] = mp;

    void onBytes(List<int> chunk) {
      mp.appendChunk(decodeBytesSmart(chunk));
    }

    final outSub = proc.stdout.listen(onBytes, onError: (_) {});
    final errSub = proc.stderr.listen(onBytes, onError: (_) {});

    unawaited(
      proc.exitCode.then((rc) async {
        await Future<void>.delayed(const Duration(milliseconds: 35));
        mp.exitCodeValue = rc;
        mp.endedAt = DateTime.now();
        if (!mp.exitCompleter.isCompleted) {
          mp.exitCompleter.complete(rc);
        }
        unawaited(outSub.cancel());
        unawaited(errSub.cancel());
        McpLogger.instance.info(
          '[PROC EXIT] id=${mp.processId} pid=${proc.pid} exit_code=$rc cmd=${abbrevValue(mp.command, 80)}',
        );
      }),
    );

    return mp;
  }

  Future<void> killManaged(ManagedProcess mp) async {
    if (mp.isPrivileged) {
      try {
        await PrivilegedExecutor.instance.procManage(
          action: 'kill',
          processId: mp.processId,
        );
      } catch (_) {}
      mp.exitCodeValue ??= -9;
      mp.endedAt ??= DateTime.now();
      return;
    }
    if (mp.proc != null) {
      await killTree(mp.proc!, pidOverride: mp.pid);
    }
  }

  Future<void> killTree(Process proc, {int? pidOverride}) async {
    final pid = pidOverride ?? proc.pid;
    if (pid <= 0) return;
    if (Platform.isWindows) {
      try {
        await Process.run('taskkill', ['/F', '/T', '/PID', '$pid']);
      } catch (_) {
        proc.kill(ProcessSignal.sigkill);
      }
    } else {
      try {
        await Process.run('pkill', ['-KILL', '-P', '$pid']);
      } catch (_) {}
      proc.kill(ProcessSignal.sigkill);
    }
  }

  ManagedProcess? get(String processId) => _procs[processId];

  Future<List<Map<String, dynamic>>> listAllAsync() async {
    final privMap = <String, Map<String, dynamic>>{};
    if (PrivilegedExecutor.instance.isActive) {
      try {
        final r = await PrivilegedExecutor.instance.procManage(action: 'list');
        final list = (r['processes'] as List?) ?? const [];
        for (final item in list) {
          if (item is Map) {
            final m = Map<String, dynamic>.from(item);
            final id = (m['process_id'] ?? '').toString();
            if (id.isNotEmpty) privMap[id] = m;
          }
        }
      } catch (_) {}
    }

    final now = DateTime.now();
    return _procs.values.map((mp) {
      if (mp.isPrivileged && privMap.containsKey(mp.processId)) {
        return privMap[mp.processId]!;
      }
      final end = mp.endedAt ?? now;
      final elapsedSec = end.difference(mp.startedAt).inMilliseconds / 1000.0;
      return <String, dynamic>{
        'process_id': mp.processId,
        'pid': mp.pid,
        'command': mp.command,
        'cwd': mp.cwd,
        'status': mp.isRunning ? 'running' : 'exited (${mp.exitCodeValue})',
        'buffered_lines': mp.lines.length,
        'elapsed_sec': double.parse(elapsedSec.toStringAsFixed(2)),
      };
    }).toList();
  }

  Future<void> stopAll() async {
    for (final mp in _procs.values.toList()) {
      if (mp.isRunning) {
        await killManaged(mp);
      }
    }
    await PrivilegedExecutor.instance.procStopAll();
  }
}

void registerProcessTools(
  RegisterToolFn registerTool,
  ServerConfig config,
  ProcessManager procMgr,
) {
  final hasWritableProfile = config.profiles.any((prof) {
    if (prof['enabled'] == false) return false;
    final ro = prof['inherit_permissions'] == false
        ? prof['read_only'] == true
        : config.readOnly;
    return !ro;
  });
  if (config.readOnly && !hasWritableProfile) return;

  const jsonEncoder = JsonEncoder.withIndent('  ');

  Map<String, String>? parseEnvMap(dynamic raw) {
    if (raw is! Map) return null;
    return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
  }

  String resolveWorkDir(String? rawCwd) {
    final roots = getEffectivePolicy(config).roots;
    if (rawCwd != null && rawCwd.trim().isNotEmpty) {
      return normalizePath(rawCwd, roots);
    }
    if (roots.isNotEmpty) return expandAndResolvePath(roots.first);
    return Directory.current.absolute.path;
  }

  registerTool(
    name: 'run_command',
    description:
        'Execute a command synchronously with UTF-8/GBK decoding, head+tail truncation, and process-tree timeout kill.',
    annotations: destructiveAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'command': {
          'type': 'string',
          'description': 'Shell command to execute.',
        },
        'cwd': {
          'type': 'string',
          'description':
              'Working directory (defaults to server cwd or first root).',
        },
        'timeout': {
          'type': 'integer',
          'description': 'Timeout in seconds.',
          'default': config.defaultTimeout,
          'minimum': 1,
          'maximum': 600,
        },
        'shell': {
          'type': 'string',
          'enum': ['auto', 'cmd', 'powershell', 'bash', 'sh'],
          'description': 'Shell to invoke.',
          'default': 'auto',
        },
        'env': {
          'type': 'object',
          'description': 'Extra environment variables.',
        },
      },
      'required': ['command'],
    },
    handler: (args) async {
      final command = (args['command'] ?? '').toString();
      final rawCwd = args['cwd']?.toString();
      final timeoutSec =
          (int.tryParse('${args['timeout'] ?? config.defaultTimeout}') ??
                  config.defaultTimeout)
              .clamp(1, 600);
      final shell = (args['shell'] ?? 'auto').toString();
      final extraEnv = parseEnvMap(args['env']);

      final workDir = resolveWorkDir(rawCwd);
      final err = checkAccess(workDir, config);
      if (err != null) return 'Error: $err';
      if (!await PrivFs.isDirectory(workDir)) {
        return 'Error: cwd is not a directory: $workDir';
      }

      final mp = await procMgr.start(
        command: command,
        cwd: workDir,
        shell: shell,
        env: extraEnv,
      );

      if (mp.isPrivileged) {
        final waitRes = await PrivilegedExecutor.instance.procWait(
          processId: mp.processId,
          timeoutMs: timeoutSec * 1000,
        );
        final stillRunning = waitRes['running'] == true;
        var rc = -1;
        if (stillRunning) {
          await procMgr.killManaged(mp);
        } else {
          rc = int.tryParse('${waitRes['exit_code'] ?? 0}') ?? 0;
          mp.exitCodeValue = rc;
          mp.endedAt = DateTime.now();
        }
        final outLines = ((waitRes['lines'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList();
        final rawOutput = outLines.join('\n');
        final (output, _) = truncateHeadTail(rawOutput, config.maxCmdChars);
        final status = stillRunning
            ? 'TIMEOUT after ${timeoutSec}s (process tree killed)'
            : 'exit_code=$rc';
        final header = '[$status] cwd=${mp.cwd}';
        return output.isNotEmpty ? '$header\n$output' : '$header\n(no output)';
      }

      var timedOut = false;
      int rc;
      try {
        rc = await mp.exitCompleter.future
            .timeout(Duration(seconds: timeoutSec));
      } on TimeoutException {
        timedOut = true;
        rc = -1;
        await procMgr.killManaged(mp);
      }

      await Future<void>.delayed(const Duration(milliseconds: 40));
      final rawOutput = mp.lines.join('\n');
      final (output, _) = truncateHeadTail(rawOutput, config.maxCmdChars);
      final status = timedOut
          ? 'TIMEOUT after ${timeoutSec}s (process tree killed)'
          : 'exit_code=$rc';
      final header = '[$status] cwd=$workDir';
      return output.isNotEmpty ? '$header\n$output' : '$header\n(no output)';
    },
  );

  registerTool(
    name: 'start_process',
    description:
        'Start a background process (e.g. build, dev server) and return its process_id.',
    annotations: destructiveAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'command': {
          'type': 'string',
          'description': 'Long-running command to start in the background.',
        },
        'cwd': {
          'type': 'string',
          'description': 'Working directory.',
        },
        'shell': {
          'type': 'string',
          'enum': ['auto', 'cmd', 'powershell', 'bash', 'sh'],
          'description': 'Shell to invoke.',
          'default': 'auto',
        },
        'env': {
          'type': 'object',
          'description': 'Extra environment variables.',
        },
      },
      'required': ['command'],
    },
    handler: (args) async {
      final command = (args['command'] ?? '').toString();
      final rawCwd = args['cwd']?.toString();
      final shell = (args['shell'] ?? 'auto').toString();
      final extraEnv = parseEnvMap(args['env']);

      final workDir = resolveWorkDir(rawCwd);
      final err = checkAccess(workDir, config);
      if (err != null) return 'Error: $err';
      if (!await PrivFs.isDirectory(workDir)) {
        return 'Error: cwd is not a directory: $workDir';
      }

      final mp = await procMgr.start(
        command: command,
        cwd: workDir,
        shell: shell,
        env: extraEnv,
      );
      return jsonEncoder.convert({
        'process_id': mp.processId,
        'pid': mp.pid,
        'cwd': mp.cwd,
        'status': 'running',
        if (mp.isPrivileged)
          'privileged_uid': PrivilegedExecutor.instance.effectiveUid,
      });
    },
  );

  registerTool(
    name: 'manage_process',
    description:
        'List, read output from, send stdin to, or terminate background processes.',
    annotations: destructiveAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['list', 'read', 'write', 'kill'],
          'description': 'Action on managed background processes.',
        },
        'process_id': {
          'type': 'string',
          'description': 'Target process_id (required for read/write/kill).',
        },
        'input_text': {
          'type': 'string',
          'description': "Text to send to stdin (for action='write').",
        },
        'tail_lines': {
          'type': 'integer',
          'description':
              "Number of recent output lines to return (for action='read').",
          'default': 100,
          'minimum': 1,
          'maximum': 2000,
        },
      },
      'required': ['action'],
    },
    handler: (args) async {
      final action = (args['action'] ?? '').toString();
      if (action == 'list') {
        return jsonEncoder.convert(await procMgr.listAllAsync());
      }

      final processId = (args['process_id'] ?? '').toString().trim();
      if (processId.isEmpty) {
        return "Error: 'process_id' is required for action='$action'.";
      }
      final mp = procMgr.get(processId);
      if (mp == null) {
        return "Error: Unknown process_id '$processId'.";
      }

      if (action == 'read') {
        final tailLines =
            (int.tryParse('${args['tail_lines'] ?? 100}') ?? 100)
                .clamp(1, 2000);
        if (mp.isPrivileged) {
          final r = await PrivilegedExecutor.instance.procManage(
            action: 'read',
            processId: processId,
            tailLines: tailLines,
          );
          if (r['ok'] != true) {
            return 'Error: ${r['error'] ?? 'Failed to read process'}';
          }
          final running = r['running'] == true;
          final rc = r['exit_code'];
          if (!running && rc != null) {
            mp.exitCodeValue = int.tryParse('$rc');
          }
          final lines = ((r['lines'] as List?) ?? const [])
              .map((e) => e.toString())
              .join('\n');
          final (body, _) = truncateHeadTail(lines, config.maxCmdChars);
          final status = running ? 'running' : 'exited ($rc)';
          return '[${mp.processId} | pid=${mp.pid} | $status]\n${body.isEmpty ? "(no output yet)" : body}';
        }

        final all = mp.lines.toList();
        final start = max(0, all.length - tailLines);
        final recent = all.sublist(start).join('\n');
        final (body, _) = truncateHeadTail(recent, config.maxCmdChars);
        final status =
            mp.isRunning ? 'running' : 'exited (${mp.exitCodeValue})';
        return '[${mp.processId} | pid=${mp.pid} | $status]\n${body.isEmpty ? "(no output yet)" : body}';
      }

      if (action == 'write') {
        final inputText = args['input_text']?.toString();
        if (inputText == null) {
          return "Error: 'input_text' is required for action='write'.";
        }
        if (mp.isPrivileged) {
          final r = await PrivilegedExecutor.instance.procManage(
            action: 'write',
            processId: processId,
            inputText: inputText,
          );
          if (r['ok'] != true) {
            return 'Error: ${r['error'] ?? 'Failed to write to stdin'}';
          }
          return 'Sent ${inputText.length} chars to process $processId.';
        }

        if (!mp.isRunning) {
          return 'Error: Process $processId already exited (${mp.exitCodeValue}).';
        }
        mp.proc!.stdin.add(utf8.encode(inputText));
        await mp.proc!.stdin.flush();
        return 'Sent ${inputText.length} chars to process $processId.';
      }

      if (action == 'kill') {
        await procMgr.killManaged(mp);
        return 'Terminated process $processId (pid=${mp.pid}).';
      }

      return "Error: Unsupported action '$action'.";
    },
  );
}