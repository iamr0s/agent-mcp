import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'encoding_utils.dart';
import 'privileged_exec.dart';
import 'tool_types.dart';

class UndoSnapshot {
  final bool existed;
  final Uint8List? bytes;
  final String note;
  const UndoSnapshot({
    required this.existed,
    required this.bytes,
    required this.note,
  });

  int get byteSize => bytes?.length ?? 0;
}

/// Per-file async mutex preventing lost updates when parallel Agent tool calls
/// edit or patch the same file concurrently.
class FileAsyncMutex {
  final Map<String, Future<void>> _tails = {};

  static String _normKey(String filePath) {
    final norm = p.normalize(p.absolute(filePath));
    return Platform.isWindows ? norm.toLowerCase() : norm;
  }

  Future<T> synchronized<T>(String filePath, Future<T> Function() action) {
    final key = _normKey(filePath);
    final prev = _tails[key] ?? Future<void>.value();
    final done = Completer<void>();
    final nextTail = prev.whenComplete(() => done.future);
    _tails[key] = nextTail;

    return prev.then((_) => action()).whenComplete(() {
      if (!done.isCompleted) done.complete();
      if (identical(_tails[key], nextTail)) {
        _tails.remove(key);
      }
    });
  }
}

class UndoStore {
  final int maxPerFile;
  final int maxTotalBytes;
  final Map<String, ListQueue<UndoSnapshot>> _history = {};
  final ListQueue<(String, UndoSnapshot)> _globalOrder = ListQueue();
  int _totalBytes = 0;

  UndoStore({
    this.maxPerFile = 10,
    this.maxTotalBytes = 64 * 1024 * 1024,
  });

  int get totalBytes => _totalBytes;

  String _key(String filePath) {
    final norm = p.normalize(p.absolute(filePath));
    return Platform.isWindows ? norm.toLowerCase() : norm;
  }

  void save(File file, String note) {
    final k = _key(file.path);
    final existed = file.existsSync();
    Uint8List? data;
    if (existed) {
      final len = file.lengthSync();
      if (len <= maxTotalBytes) {
        data = file.readAsBytesSync();
      } else {
        return;
      }
    }
    _pushSnapshot(k, UndoSnapshot(existed: existed, bytes: data, note: note));
  }

  Future<void> savePath(String filePath, String note) async {
    final k = _key(filePath);
    final st = await PrivFs.stat(filePath);
    final existed = st.isFile;
    Uint8List? data;
    if (existed) {
      if (st.size > maxTotalBytes) return;
      data = await PrivFs.readBytes(filePath);
    }
    _pushSnapshot(k, UndoSnapshot(existed: existed, bytes: data, note: note));
  }

  void _pushSnapshot(String k, UndoSnapshot snap) {
    final q = _history.putIfAbsent(k, () => ListQueue<UndoSnapshot>());
    while (q.length >= maxPerFile) {
      final evicted = q.removeFirst();
      _removeFromGlobalOrder(k, evicted);
    }
    while (_totalBytes + snap.byteSize > maxTotalBytes &&
        _globalOrder.isNotEmpty) {
      final (oldKey, oldSnap) = _globalOrder.removeFirst();
      final oldQ = _history[oldKey];
      if (oldQ != null && oldQ.remove(oldSnap)) {
        _totalBytes -= oldSnap.byteSize;
        if (oldQ.isEmpty) _history.remove(oldKey);
      }
    }
    q.addLast(snap);
    _globalOrder.addLast((k, snap));
    _totalBytes += snap.byteSize;
  }

  void _removeFromGlobalOrder(String k, UndoSnapshot snap) {
    final kept = <(String, UndoSnapshot)>[];
    var removed = false;
    while (_globalOrder.isNotEmpty) {
      final pair = _globalOrder.removeFirst();
      if (!removed && pair.$1 == k && identical(pair.$2, snap)) {
        _totalBytes -= snap.byteSize;
        removed = true;
      } else {
        kept.add(pair);
      }
    }
    _globalOrder.addAll(kept);
  }

  UndoSnapshot? popPath(String filePath) {
    final k = _key(filePath);
    final q = _history[k];
    if (q == null || q.isEmpty) return null;
    final snap = q.removeLast();
    _removeFromGlobalOrder(k, snap);
    if (q.isEmpty) _history.remove(k);
    return snap;
  }

  UndoSnapshot? pop(File file) => popPath(file.path);
}

Future<List<String>> loadGitignorePatternsPath(String rootDirPath) async {
  final giPath = p.join(rootDirPath, '.gitignore');
  if (!await PrivFs.isFile(giPath)) return const <String>[];
  final out = <String>[];
  try {
    final dec = await PrivFs.readText(giPath);
    for (final line in splitLinesNoEol(dec.text)) {
      final s = line.trim();
      if (s.isNotEmpty && !s.startsWith('#') && !s.startsWith('!')) {
        out.add(s.replaceAll(RegExp(r'/+$'), ''));
      }
    }
  } catch (_) {}
  return out;
}

bool isIgnoredEntry(
  String relPosix,
  String name,
  List<String> giPatterns, {
  required bool showHidden,
}) {
  if (!showHidden && name.startsWith('.') && name != '.env.example') {
    return true;
  }
  if (defaultIgnoreDirs.contains(name)) return true;
  for (final pat in giPatterns) {
    if (wildcardMatch(name, pat) || wildcardMatch(relPosix, pat)) {
      return true;
    }
  }
  return false;
}

String _formatLocalTime(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  final l = dt.toLocal();
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
}

String? _findExecutableInPath(String cmd) {
  final exeNames = Platform.isWindows ? ['$cmd.exe', '$cmd.cmd', cmd] : [cmd];
  final pathEnv = Platform.environment['PATH'] ?? '';
  final sep = Platform.isWindows ? ';' : ':';
  for (final dir in pathEnv.split(sep)) {
    final trimmed = dir.trim();
    if (trimmed.isEmpty) continue;
    for (final name in exeNames) {
      final f = File(p.join(trimmed, name));
      if (f.existsSync()) return f.path;
    }
  }
  return null;
}

void registerFileTools(
  RegisterToolFn registerTool,
  ServerConfig config,
  UndoStore undoStore,
) {
  const jsonEncoder = JsonEncoder.withIndent('  ');
  final fileMutex = FileAsyncMutex();

  String resolveTarget(String rawPath) {
    final roots = getEffectivePolicy(config).effectiveRoots;
    return normalizePath(rawPath, roots);
  }

  Future<String> readFileImpl({
    required String rawPath,
    int offset = 1,
    int limit = 200,
  }) async {
    final targetPath = resolveTarget(rawPath);
    final err = checkAccess(targetPath, config);
    if (err != null) return 'Error: $err';

    final st = await PrivFs.stat(targetPath);
    if (!st.isFile) {
      return 'Error: Not a file or does not exist: $targetPath';
    }

    final DecodedTextFile decoded;
    try {
      decoded = await PrivFs.readText(targetPath);
    } on FormatException catch (e) {
      return 'Error: ${e.message}';
    } catch (e) {
      return 'Error: $e';
    }

    final lines = splitLinesNoEol(decoded.text);
    final total = lines.length;
    if (total == 0) {
      return 'File: $targetPath (empty file, 0 lines)';
    }
    if (offset > total) {
      return 'Error: offset $offset exceeds total lines ($total) in $targetPath.';
    }

    final safeOffset = max(1, offset);
    final safeLimit = limit.clamp(1, 2000);
    final end = min(total, safeOffset + safeLimit - 1);
    final width = end.toString().length;
    final numbered = <String>[];
    for (var i = safeOffset; i <= end; i++) {
      numbered.add('${i.toString().padLeft(width)} | ${lines[i - 1]}');
    }
    final (body, truncated) =
        truncateHeadTail(numbered.join('\n'), config.maxReadChars);

    final header = 'File: $targetPath (lines $safeOffset-$end of $total)';
    final footerBuf = StringBuffer();
    if (end < total) {
      footerBuf.write(
        '\n\n[More lines available: call read_file(path=${jsonEncode(targetPath)}, offset=${end + 1}, limit=$safeLimit)]',
      );
    }
    if (truncated) {
      footerBuf.write('\n[Output was character-truncated; use a smaller limit.]');
    }
    return '$header\n$body$footerBuf';
  }

  registerTool(
    name: 'stat_file',
    description:
        'Check file or directory metadata (size, line count, estimated tokens, type) before reading.',
    annotations: readOnlyAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'Absolute or relative file/directory path.',
        },
      },
      'required': ['path'],
    },
    handler: (args) async {
      final rawPath = (args['path'] ?? '').toString();
      if (rawPath.isEmpty) return "Error: 'path' is required.";
      final targetPath = resolveTarget(rawPath);
      final err = checkAccess(targetPath, config);
      if (err != null) return 'Error: $err';

      final st = await PrivFs.stat(targetPath);
      if (!st.exists) {
        return 'Error: Path does not exist: $targetPath';
      }
      final info = <String, dynamic>{
        'path': targetPath,
        'type': st.isDirectory ? 'directory' : 'file',
        'size_bytes': st.size,
        'modified_time': _formatLocalTime(st.modified),
      };
      if (st.isFile) {
        try {
          final dec = await PrivFs.readText(targetPath);
          final lines = splitLinesNoEol(dec.text);
          info.addAll({
            'is_binary': false,
            'encoding': dec.encoding == 'utf-8-bom' ? 'utf-8' : dec.encoding,
            'newline': dec.newline == '\r\n' ? 'CRLF' : 'LF',
            'total_lines': lines.length,
            'total_chars': dec.text.length,
            'estimated_tokens': max(1, dec.text.length ~/ 4),
          });
        } on FormatException {
          info['is_binary'] = true;
        } catch (_) {}
      }
      return jsonEncoder.convert(info);
    },
  );

  registerTool(
    name: 'read_file',
    description:
        'Read a text file with line numbers and range slicing to save context.',
    annotations: readOnlyAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'File path to read.'},
        'offset': {
          'type': 'integer',
          'description': '1-based starting line number.',
          'default': 1,
          'minimum': 1,
        },
        'limit': {
          'type': 'integer',
          'description': 'Maximum number of lines to return.',
          'default': 200,
          'minimum': 1,
          'maximum': 2000,
        },
      },
      'required': ['path'],
    },
    handler: (args) async {
      final rawPath = (args['path'] ?? '').toString();
      final offset = int.tryParse('${args['offset'] ?? 1}') ?? 1;
      final limit = int.tryParse('${args['limit'] ?? 200}') ?? 200;
      return readFileImpl(rawPath: rawPath, offset: offset, limit: limit);
    },
  );

  registerTool(
    name: 'read_files',
    description:
        'Batch-read multiple files in a single tool call to reduce round-trips.',
    annotations: readOnlyAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'paths': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'List of file paths to read in one batch (max 20).',
        },
        'max_lines_per_file': {
          'type': 'integer',
          'description': 'Max lines per file.',
          'default': 150,
          'minimum': 1,
          'maximum': 500,
        },
      },
      'required': ['paths'],
    },
    handler: (args) async {
      final rawList = (args['paths'] as List?) ?? const [];
      if (rawList.length > 20) {
        return 'Error: Maximum 20 files per batch.';
      }
      final maxLines =
          (int.tryParse('${args['max_lines_per_file'] ?? 150}') ?? 150)
              .clamp(1, 500);
      final chunks = <String>[];
      var totalChars = 0;
      for (final item in rawList) {
        final pStr = item.toString();
        final res =
            await readFileImpl(rawPath: pStr, offset: 1, limit: maxLines);
        if (totalChars + res.length > config.maxReadChars) {
          chunks.add(
            '=== $pStr ===\n[Skipped: batch character budget reached; read individually]',
          );
          continue;
        }
        chunks.add(res);
        totalChars += res.length;
      }
      return chunks.join('\n\n---\n\n');
    },
  );

  registerTool(
    name: 'list_dir',
    description:
        'List directory contents as a clean tree, skipping .git, node_modules, build, and .gitignore matches.',
    annotations: readOnlyAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'Directory path to list.',
          'default': '.',
        },
        'max_depth': {
          'type': 'integer',
          'description': 'Directory traversal depth (1 = immediate children).',
          'default': 2,
          'minimum': 1,
          'maximum': 6,
        },
        'show_hidden': {
          'type': 'boolean',
          'description': 'Include dotfiles/hidden entries.',
          'default': false,
        },
        'max_entries': {
          'type': 'integer',
          'description': 'Maximum entries to return.',
          'default': 300,
          'minimum': 10,
          'maximum': 1000,
        },
      },
    },
    handler: (args) async {
      final rawPath = (args['path'] ?? '.').toString();
      final maxDepth =
          (int.tryParse('${args['max_depth'] ?? 2}') ?? 2).clamp(1, 6);
      final showHidden = args['show_hidden'] == true;
      final maxEntries =
          (int.tryParse('${args['max_entries'] ?? 300}') ?? 300)
              .clamp(10, 1000);

      final rootPath = resolveTarget(rawPath);
      final err = checkAccess(rootPath, config);
      if (err != null) return 'Error: $err';
      if (!await PrivFs.isDirectory(rootPath)) {
        return 'Error: Not a directory: $rootPath';
      }

      final giPatterns = await loadGitignorePatternsPath(rootPath);
      final lines = <String>['$rootPath/'];
      var count = 0;
      var hitLimit = false;

      Future<void> walk(String curDir, int depth, String prefix) async {
        if (depth > maxDepth || hitLimit) return;
        List<PrivDirEntry> entries;
        try {
          entries = await PrivFs.listDir(curDir);
        } on FileSystemException {
          lines.add('$prefix[Permission Denied]');
          return;
        }
        entries.sort((a, b) {
          final aDir = a.isDirectory ? 0 : 1;
          final bDir = b.isDirectory ? 0 : 1;
          if (aDir != bDir) return aDir.compareTo(bDir);
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });

        final visible = <PrivDirEntry>[];
        for (final e in entries) {
          final relPosix =
              p.relative(e.path, from: rootPath).replaceAll(r'\', '/');
          if (!isIgnoredEntry(
            relPosix,
            e.name,
            giPatterns,
            showHidden: showHidden,
          )) {
            visible.add(e);
          }
        }

        for (var idx = 0; idx < visible.length; idx++) {
          if (count >= maxEntries) {
            hitLimit = true;
            return;
          }
          final entry = visible[idx];
          final isLast = idx == visible.length - 1;
          final connector = isLast ? '└── ' : '├── ';
          final childPrefix = prefix + (isLast ? '    ' : '│   ');
          count++;
          if (entry.isDirectory) {
            lines.add('$prefix$connector${entry.name}/');
            await walk(entry.path, depth + 1, childPrefix);
          } else {
            lines.add('$prefix$connector${entry.name} (${entry.size} B)');
          }
        }
      }

      await walk(rootPath, 1, '');
      if (hitLimit) {
        lines.add(
          '\n[Truncated at $maxEntries entries. Narrow path or reduce max_depth.]',
        );
      }
      return lines.join('\n');
    },
  );
  registerTool(
    name: 'glob_files',
    description:
        'Find files matching a glob pattern while respecting default ignore directories.',
    annotations: readOnlyAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'pattern': {
          'type': 'string',
          'description': "Glob pattern, e.g. '**/*.py' or 'src/*.kt'.",
        },
        'path': {
          'type': 'string',
          'description': 'Base directory to search from.',
          'default': '.',
        },
        'max_results': {
          'type': 'integer',
          'description': 'Maximum matching paths to return.',
          'default': 200,
          'minimum': 1,
          'maximum': 500,
        },
      },
      'required': ['pattern'],
    },
    handler: (args) async {
      final pattern = (args['pattern'] ?? '').toString();
      final rawPath = (args['path'] ?? '.').toString();
      final maxResults =
          (int.tryParse('${args['max_results'] ?? 200}') ?? 200).clamp(1, 500);

      final rootPath = resolveTarget(rawPath);
      final err = checkAccess(rootPath, config);
      if (err != null) return 'Error: $err';
      if (!await PrivFs.isDirectory(rootPath)) {
        return 'Error: Not a directory: $rootPath';
      }

      final giPatterns = await loadGitignorePatternsPath(rootPath);
      final matches = <String>[];
      final normalizedPat =
          pattern.startsWith('**/') ? pattern.substring(3) : pattern;

      Future<void> scan(String dirPath) async {
        if (matches.length >= maxResults) return;
        List<PrivDirEntry> items;
        try {
          items = await PrivFs.listDir(dirPath);
        } catch (_) {
          return;
        }
        items.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
        final subDirs = <String>[];
        for (final it in items) {
          final relPosix =
              p.relative(it.path, from: rootPath).replaceAll(r'\', '/');
          if (isIgnoredEntry(relPosix, it.name, giPatterns, showHidden: false)) {
            continue;
          }
          if (it.isDirectory) {
            subDirs.add(it.path);
          } else {
            final matched = wildcardMatch(relPosix, pattern) ||
                wildcardMatch(relPosix, normalizedPat) ||
                wildcardMatch(it.name, pattern) ||
                wildcardMatch(it.name, normalizedPat);
            if (matched && checkAccess(it.path, config) == null) {
              matches.add(it.path);
              if (matches.length >= maxResults) return;
            }
          }
        }
        for (final sd in subDirs) {
          if (matches.length >= maxResults) return;
          await scan(sd);
        }
      }

      await scan(rootPath);
      if (matches.isEmpty) {
        return "No files matched '$pattern' under $rootPath.";
      }
      final suffix = matches.length >= maxResults
          ? '\n[Showing first $maxResults matches]'
          : '';
      return '${matches.join('\n')}$suffix';
    },
  );

  registerTool(
    name: 'search_text',
    description:
        'Search file contents (uses ripgrep if available, otherwise pure Dart fallback).',
    annotations: readOnlyAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'pattern': {
          'type': 'string',
          'description':
              'Search pattern (regex by default, or literal if regex=False).',
        },
        'path': {
          'type': 'string',
          'description': 'File or directory to search.',
          'default': '.',
        },
        'glob': {
          'type': 'string',
          'description': "Optional file glob filter, e.g. '*.py' or '*.dart'.",
        },
        'case_sensitive': {
          'type': 'boolean',
          'description': 'Case-sensitive matching.',
          'default': true,
        },
        'regex': {
          'type': 'boolean',
          'description': 'Treat pattern as regular expression.',
          'default': true,
        },
        'context_lines': {
          'type': 'integer',
          'description': 'Number of context lines around each match.',
          'default': 0,
          'minimum': 0,
          'maximum': 5,
        },
        'max_results': {
          'type': 'integer',
          'description': 'Maximum matches to return.',
          'default': 50,
          'minimum': 1,
          'maximum': 200,
        },
      },
      'required': ['pattern'],
    },
    handler: (args) async {
      final pattern = (args['pattern'] ?? '').toString();
      final rawPath = (args['path'] ?? '.').toString();
      final globFilter = args['glob']?.toString();
      final caseSensitive = args['case_sensitive'] != false;
      final useRegex = args['regex'] != false;
      final contextLines =
          (int.tryParse('${args['context_lines'] ?? 0}') ?? 0).clamp(0, 5);
      final maxResults =
          (int.tryParse('${args['max_results'] ?? 50}') ?? 50).clamp(1, 200);

      final targetPath = resolveTarget(rawPath);
      final err = checkAccess(targetPath, config);
      if (err != null) return 'Error: $err';
      final st = await PrivFs.stat(targetPath);
      if (!st.exists) {
        return 'Error: Path does not exist: $targetPath';
      }

      // Fast path via ripgrep on desktop/sandbox when not using privileged bridge
      final rgBin = _findExecutableInPath('rg');
      if (rgBin != null &&
          !PrivilegedExecutor.instance.isActive &&
          getEffectivePolicy(config).allowSecrets) {
        final rgArgs = <String>[
          '--line-number',
          '--no-heading',
          '--color',
          'never',
          if (!caseSensitive) '--ignore-case',
          if (!useRegex) '--fixed-strings',
          if (contextLines > 0) ...['-C', '$contextLines'],
          if (globFilter != null && globFilter.isNotEmpty) ...[
            '--glob',
            globFilter,
          ],
          '--max-count',
          '$maxResults',
          pattern,
          targetPath,
        ];
        try {
          final res = await Process.run(
            rgBin,
            rgArgs,
            stdoutEncoding: null,
            stderrEncoding: null,
          ).timeout(const Duration(seconds: 20));
          final out = decodeBytesSmart(res.stdout as List<int>).trim();
          if (res.exitCode == 1 || out.isEmpty) {
            return "No matches found for '$pattern' in $targetPath.";
          }
          if (res.exitCode == 0) {
            final lines = out.split(RegExp(r'\r?\n'));
            final cap = maxResults * (1 + 2 * contextLines);
            if (lines.length > cap) {
              return '${lines.take(cap).join('\n')}\n... [Truncated output; refine query or glob]';
            }
            return lines.join('\n');
          }
        } catch (_) {}
      }

      final RegExp compiled;
      try {
        compiled = RegExp(
          useRegex ? pattern : RegExp.escape(pattern),
          caseSensitive: caseSensitive,
        );
      } on FormatException catch (e) {
        return "Error: Invalid regex '$pattern': ${e.message}";
      }

      final filesToScan = <(String, int)>[];
      if (st.isFile) {
        filesToScan.add((targetPath, st.size));
      } else {
        final giPatterns = await loadGitignorePatternsPath(targetPath);
        Future<void> collect(String dirPath) async {
          List<PrivDirEntry> children;
          try {
            children = await PrivFs.listDir(dirPath);
          } catch (_) {
            return;
          }
          children.sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
          for (final ch in children) {
            final relPosix =
                p.relative(ch.path, from: targetPath).replaceAll(r'\', '/');
            if (isIgnoredEntry(relPosix, ch.name, giPatterns, showHidden: false)) {
              continue;
            }
            if (ch.isDirectory) {
              await collect(ch.path);
            } else {
              if (globFilter != null &&
                  globFilter.isNotEmpty &&
                  !wildcardMatch(ch.name, globFilter)) {
                continue;
              }
              if (checkAccess(ch.path, config) == null) {
                filesToScan.add((ch.path, ch.size));
              }
            }
          }
        }

        await collect(targetPath);
      }

      final hits = <String>[];
      var matchCount = 0;
      for (final (fpPath, fpSize) in filesToScan) {
        if (fpSize > 8 * 1024 * 1024) continue;
        DecodedTextFile dec;
        try {
          dec = await PrivFs.readText(fpPath);
        } catch (_) {
          continue;
        }
        final fileLines = splitLinesNoEol(dec.text);
        for (var idx = 1; idx <= fileLines.length; idx++) {
          final line = fileLines[idx - 1];
          if (compiled.hasMatch(line)) {
            matchCount++;
            if (contextLines == 0) {
              hits.add('$fpPath:$idx:$line');
            } else {
              final startC = max(1, idx - contextLines);
              final endC = min(fileLines.length, idx + contextLines);
              hits.add('--- $fpPath:$idx ---');
              for (var ci = startC; ci <= endC; ci++) {
                final marker = ci == idx ? '>' : ' ';
                hits.add('$marker $ci: ${fileLines[ci - 1]}');
              }
            }
            if (matchCount >= maxResults) {
              hits.add('... [Stopped after $maxResults matches]');
              return hits.join('\n');
            }
          }
        }
      }
      return hits.isEmpty
          ? "No matches found for '$pattern' in $targetPath."
          : hits.join('\n');
    },
  );

  // Check if any profile allows writing before registering write tools
  final hasWritableProfile = config.profiles.any((prof) {
    if (prof['enabled'] == false) return false;
    final ro = prof['inherit_permissions'] == false
        ? prof['read_only'] == true
        : config.readOnly;
    return !ro;
  });
  if (config.readOnly && !hasWritableProfile) return;

  registerTool(
    name: 'create_file',
    description:
        'Create a new file (creating parent directories automatically) or overwrite if overwrite=True.',
    annotations: safeWriteAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'Target file path to create or overwrite.',
        },
        'content': {
          'type': 'string',
          'description': 'Full text content to write.',
        },
        'overwrite': {
          'type': 'boolean',
          'description': 'Must be True to replace an existing file.',
          'default': false,
        },
      },
      'required': ['path', 'content'],
    },
    handler: (args) async {
      final rawPath = (args['path'] ?? '').toString();
      final content = (args['content'] ?? '').toString();
      final overwrite = args['overwrite'] == true;

      final targetPath = resolveTarget(rawPath);
      final err = checkAccess(targetPath, config);
      if (err != null) return 'Error: $err';

      return fileMutex.synchronized(targetPath, () async {
        final st = await PrivFs.stat(targetPath);
        if (st.isDirectory) {
          return 'Error: Target is a directory: $targetPath';
        }
        if (st.exists) {
          if (!overwrite) {
            return 'Error: File already exists: $targetPath. Pass overwrite=True or use edit_file.';
          }
          await undoStore.savePath(targetPath, 'create_file(overwrite=True)');
        } else {
          await undoStore.savePath(targetPath, 'create_file(new)');
        }

        final written = await PrivFs.writeText(targetPath, content);
        final lineCount = splitLinesNoEol(content).length;
        return 'Written $written bytes ($lineCount lines) to $targetPath.';
      });
    },
  );

  registerTool(
    name: 'edit_file',
    description:
        'Apply exact surgical text replacements to a file atomically, with close-match hints on failure.',
    annotations: safeWriteAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'File path to edit.'},
        'edits': {
          'type': 'array',
          'description':
              "List of edit objects: [{'old_str': '...', 'new_str': '...', 'replace_all': False}]. Applied atomically.",
          'items': {'type': 'object'},
        },
        'dry_run': {
          'type': 'boolean',
          'description': 'Preview unified diff without modifying the file.',
          'default': false,
        },
      },
      'required': ['path', 'edits'],
    },
    handler: (args) async {
      final rawPath = (args['path'] ?? '').toString();
      final rawEdits = (args['edits'] as List?) ?? const [];
      final dryRun = args['dry_run'] == true;

      final targetPath = resolveTarget(rawPath);
      final err = checkAccess(targetPath, config);
      if (err != null) return 'Error: $err';
      return fileMutex.synchronized(targetPath, () async {
        if (!await PrivFs.isFile(targetPath)) {
          return 'Error: File does not exist: $targetPath';
        }

        final DecodedTextFile dec;
        try {
          dec = await PrivFs.readText(targetPath);
        } on FormatException catch (e) {
          return 'Error: ${e.message}';
        }

        var working = dec.text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
        for (var idx = 0; idx < rawEdits.length; idx++) {
          final item = rawEdits[idx];
          if (item is! Map) {
            return "Error: Edit #${idx + 1} must be an object containing 'old_str' and 'new_str'.";
          }
          final oldStr = item['old_str'];
          final newStr = item['new_str'];
          final replaceAll = item['replace_all'] == true;
          if (oldStr == null || newStr == null) {
            return "Error: Edit #${idx + 1} must contain 'old_str' and 'new_str'.";
          }

          final oldNorm =
              oldStr.toString().replaceAll('\r\n', '\n').replaceAll('\r', '\n');
          final newNorm =
              newStr.toString().replaceAll('\r\n', '\n').replaceAll('\r', '\n');
          final count = _countOccurrences(working, oldNorm);

          if (count == 0) {
            final trimmedMatch = _matchTrailingWhitespaceInsensitive(
              working,
              oldNorm,
              newNorm,
              replaceAll: replaceAll,
            );
            if (trimmedMatch.status == 'applied') {
              working = trimmedMatch.updated!;
              continue;
            } else if (trimmedMatch.status == 'ambiguous') {
              return "Error: Edit #${idx + 1} 'old_str' matched ${trimmedMatch.count} times (ignoring trailing spaces) in $targetPath. "
                  'Include more surrounding context to make it unique, or set replace_all=True.';
            }

            final oldLines = splitLinesNoEol(oldNorm);
            final firstLine = oldLines.isNotEmpty ? oldLines.first : oldNorm;
            final fileLines = splitLinesNoEol(working);
            final close = findClosestLines(firstLine, fileLines);
            var hint = '';
            if (close.isNotEmpty) {
              final hintLines =
                  close.map((e) => '  line ${e.$1}: ${e.$2}').join('\n');
              hint = '\nClosest lines in file:\n$hintLines';
            }
            return "Error: Edit #${idx + 1} 'old_str' not found in $targetPath.$hint";
          }

          if (count > 1 && !replaceAll) {
            return "Error: Edit #${idx + 1} 'old_str' matched $count times in $targetPath. "
                'Include more surrounding context to make it unique, or set replace_all=True.';
          }

          working = replaceAll
              ? working.replaceAll(oldNorm, newNorm)
              : working.replaceFirst(oldNorm, newNorm);
        }

        final origNorm =
            dec.text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
        final diffPreview =
            makeUnifiedDiff(origNorm, working, p.basename(targetPath));
        if (dryRun) {
          return '[DRY RUN] Diff for $targetPath:\n${diffPreview.isEmpty ? "(no changes)" : diffPreview}';
        }

        await undoStore.savePath(
          targetPath,
          'edit_file(${rawEdits.length} edits)',
        );
        await PrivFs.writeText(
          targetPath,
          working,
          encoding: dec.encoding,
          newline: dec.newline,
        );
        return 'Successfully applied ${rawEdits.length} edit(s) to $targetPath.\n$diffPreview';
      });
    },
  );

  registerTool(
    name: 'apply_patch',
    description:
        'Apply a unified diff patch to a file with optional dry-run preview.',
    annotations: safeWriteAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'Target file path to patch.'},
        'unified_diff': {
          'type': 'string',
          'description': 'Unified diff text containing @@ hunks.',
        },
        'dry_run': {
          'type': 'boolean',
          'description': 'Preview result without writing to disk.',
          'default': false,
        },
      },
      'required': ['path', 'unified_diff'],
    },
    handler: (args) async {
      final rawPath = (args['path'] ?? '').toString();
      final unifiedDiff = (args['unified_diff'] ?? '').toString();
      final dryRun = args['dry_run'] == true;

      final targetPath = resolveTarget(rawPath);
      final err = checkAccess(targetPath, config);
      if (err != null) return 'Error: $err';
      return fileMutex.synchronized(targetPath, () async {
        if (!await PrivFs.isFile(targetPath)) {
          return 'Error: File does not exist: $targetPath';
        }

        final DecodedTextFile dec;
        final String patched;
        try {
          dec = await PrivFs.readText(targetPath);
          patched = applyUnifiedDiffText(
            dec.text.replaceAll('\r\n', '\n').replaceAll('\r', '\n'),
            unifiedDiff,
          );
        } on FormatException catch (e) {
          return 'Error: ${e.message}';
        }

        final origNorm =
            dec.text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
        final diffPreview =
            makeUnifiedDiff(origNorm, patched, p.basename(targetPath));
        if (dryRun) {
          return '[DRY RUN] Patch preview for $targetPath:\n${diffPreview.isEmpty ? "(no changes)" : diffPreview}';
        }

        await undoStore.savePath(targetPath, 'apply_patch');
        await PrivFs.writeText(
          targetPath,
          patched,
          encoding: dec.encoding,
          newline: dec.newline,
        );
        return 'Patch applied to $targetPath.\n$diffPreview';
      });
    },
  );

  registerTool(
    name: 'replace_text',
    description:
        'Find and replace text across one or multiple files, with dry-run diff preview.',
    annotations: destructiveAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'pattern': {
          'type': 'string',
          'description': 'Text or regex pattern to replace.',
        },
        'replacement': {
          'type': 'string',
          'description': 'Replacement string.',
        },
        'path': {
          'type': 'string',
          'description': 'File or directory to process.',
          'default': '.',
        },
        'glob': {
          'type': 'string',
          'description': "Optional file glob filter, e.g. '*.dart'.",
        },
        'regex': {
          'type': 'boolean',
          'description': 'Treat pattern as regular expression.',
          'default': false,
        },
        'case_sensitive': {
          'type': 'boolean',
          'description': 'Case-sensitive match.',
          'default': true,
        },
        'dry_run': {
          'type': 'boolean',
          'description': 'Preview changes across files without modifying disk.',
          'default': false,
        },
        'max_files': {
          'type': 'integer',
          'description': 'Safety cap on modified files.',
          'default': 50,
          'minimum': 1,
          'maximum': 200,
        },
      },
      'required': ['pattern', 'replacement'],
    },
    handler: (args) async {
      final pattern = (args['pattern'] ?? '').toString();
      final replacement = (args['replacement'] ?? '').toString();
      final rawPath = (args['path'] ?? '.').toString();
      final globFilter = args['glob']?.toString();
      final useRegex = args['regex'] == true;
      final caseSensitive = args['case_sensitive'] != false;
      final dryRun = args['dry_run'] == true;
      final maxFiles =
          (int.tryParse('${args['max_files'] ?? 50}') ?? 50).clamp(1, 200);

      final targetPath = resolveTarget(rawPath);
      final err = checkAccess(targetPath, config);
      if (err != null) return 'Error: $err';
      final st = await PrivFs.stat(targetPath);
      if (!st.exists) {
        return 'Error: Path does not exist: $targetPath';
      }

      final RegExp compiled;
      try {
        compiled = RegExp(
          useRegex ? pattern : RegExp.escape(pattern),
          caseSensitive: caseSensitive,
        );
      } on FormatException catch (e) {
        return "Error: Invalid regex '$pattern': ${e.message}";
      }

      final candidates = <String>[];
      if (st.isFile) {
        candidates.add(targetPath);
      } else {
        final giPatterns = await loadGitignorePatternsPath(targetPath);
        Future<void> walk(String dirPath) async {
          List<PrivDirEntry> children;
          try {
            children = await PrivFs.listDir(dirPath);
          } catch (_) {
            return;
          }
          children.sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
          for (final ch in children) {
            final relPosix =
                p.relative(ch.path, from: targetPath).replaceAll(r'\', '/');
            if (isIgnoredEntry(relPosix, ch.name, giPatterns, showHidden: false)) {
              continue;
            }
            if (ch.isDirectory) {
              await walk(ch.path);
            } else {
              if (globFilter != null &&
                  globFilter.isNotEmpty &&
                  !wildcardMatch(ch.name, globFilter)) {
                continue;
              }
              if (checkAccess(ch.path, config) == null) {
                candidates.add(ch.path);
              }
            }
          }
        }

        await walk(targetPath);
      }

      final changedReports = <String>[];
      var modifiedFiles = 0;
      for (final fpPath in candidates) {
        DecodedTextFile dec;
        try {
          dec = await PrivFs.readText(fpPath);
        } catch (_) {
          continue;
        }
        final origNorm = dec.text.replaceAll('\r\n', '\n');
        var count = 0;
        final newText = origNorm.replaceAllMapped(compiled, (_) {
          count++;
          return replacement;
        });
        if (count > 0) {
          modifiedFiles++;
          if (modifiedFiles > maxFiles) {
            changedReports.add('[Stopped: exceeded max_files=$maxFiles]');
            break;
          }
          if (!dryRun) {
            await undoStore.savePath(fpPath, 'replace_text($pattern)');
            await PrivFs.writeText(
              fpPath,
              newText,
              encoding: dec.encoding,
              newline: dec.newline,
            );
          }
          changedReports.add('$fpPath: $count replacement(s)');
        }
      }

      if (changedReports.isEmpty) {
        return "No occurrences of '$pattern' found in $targetPath.";
      }
      final prefix = dryRun ? '[DRY RUN] ' : '';
      return '${prefix}Updated ${changedReports.length} file(s):\n${changedReports.join('\n')}';
    },
  );

  registerTool(
    name: 'file_op',
    description: 'Move, copy, or delete a file or directory safely.',
    annotations: destructiveAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['move', 'copy', 'delete'],
          'description': 'Operation to perform.',
        },
        'src': {
          'type': 'string',
          'description': 'Source file or directory path.',
        },
        'dst': {
          'type': 'string',
          'description': 'Destination path (required for move/copy).',
        },
        'overwrite': {
          'type': 'boolean',
          'description': 'Allow overwriting destination if it exists.',
          'default': false,
        },
      },
      'required': ['action', 'src'],
    },
    handler: (args) async {
      final action = (args['action'] ?? '').toString();
      final rawSrc = (args['src'] ?? '').toString();
      final rawDst = args['dst']?.toString();
      final overwrite = args['overwrite'] == true;

      final srcPath = resolveTarget(rawSrc);
      final err = checkAccess(srcPath, config);
      if (err != null) return 'Error: $err';
      final srcSt = await PrivFs.stat(srcPath);
      if (!srcSt.exists) {
        return 'Error: Source does not exist: $srcPath';
      }

      if (action == 'delete') {
        if (srcSt.isFile) {
          await undoStore.savePath(srcPath, 'file_op(delete)');
          await PrivFs.delete(srcPath);
          return 'Deleted file: $srcPath (undoable via undo_edit).';
        }
        await PrivFs.delete(srcPath, recursive: true);
        return 'Deleted directory: $srcPath';
      }

      if (rawDst == null || rawDst.trim().isEmpty) {
        return "Error: 'dst' is required for action='$action'.";
      }
      final dstPath = resolveTarget(rawDst);
      final dstErr = checkAccess(dstPath, config);
      if (dstErr != null) return 'Error: $dstErr';

      final dstSt = await PrivFs.stat(dstPath);
      if (dstSt.exists && !overwrite) {
        return 'Error: Destination exists: $dstPath. Set overwrite=True to replace.';
      }

      if (dstSt.isFile && overwrite) {
        await undoStore.savePath(dstPath, 'file_op($action, overwrite)');
      }

      if (action == 'move') {
        await PrivFs.move(srcPath, dstPath, overwrite: overwrite);
        return 'Moved $srcPath -> $dstPath';
      }

      if (action == 'copy') {
        await PrivFs.copy(srcPath, dstPath, overwrite: overwrite);
        return 'Copied $srcPath -> $dstPath';
      }

      return "Error: Unsupported action '$action'.";
    },
  );

  registerTool(
    name: 'undo_edit',
    description:
        'Undo the most recent create/edit/patch/delete operation on a file.',
    annotations: safeWriteAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'File path to restore to its previous version.',
        },
      },
      'required': ['path'],
    },
    handler: (args) async {
      final rawPath = (args['path'] ?? '').toString();
      final targetPath = resolveTarget(rawPath);
      final err = checkAccess(targetPath, config);
      if (err != null) return 'Error: $err';

      return fileMutex.synchronized(targetPath, () async {
        final snap = undoStore.popPath(targetPath);
        if (snap == null) {
          return 'Error: No undo history available for $targetPath.';
        }
        if (!snap.existed) {
          final st = await PrivFs.stat(targetPath);
          if (st.exists) await PrivFs.delete(targetPath);
          return "Undid '${snap.note}': removed newly created $targetPath.";
        }
        await PrivFs.writeBytes(targetPath, snap.bytes!, createParents: true);
        return "Undid '${snap.note}': restored $targetPath (${snap.bytes!.length} bytes).";
      });
    },
  );
}

int _countOccurrences(String text, String needle) {
  if (needle.isEmpty) return 0;
  var count = 0;
  var idx = 0;
  while (true) {
    final found = text.indexOf(needle, idx);
    if (found == -1) break;
    count++;
    idx = found + needle.length;
  }
  return count;
}

({String status, String? updated, int count}) _matchTrailingWhitespaceInsensitive(
  String working,
  String oldNorm,
  String newNorm, {
  required bool replaceAll,
}) {
  final oldLines = oldNorm.split('\n');
  if (oldLines.isEmpty || (oldLines.length == 1 && oldLines.first.trim().isEmpty)) {
    return (status: 'none', updated: null, count: 0);
  }
  final workLines = working.split('\n');
  if (oldLines.length > workLines.length) {
    return (status: 'none', updated: null, count: 0);
  }

  final matchStarts = <int>[];
  var i = 0;
  while (i <= workLines.length - oldLines.length) {
    var ok = true;
    for (var j = 0; j < oldLines.length; j++) {
      if (workLines[i + j].trimRight() != oldLines[j].trimRight()) {
        ok = false;
        break;
      }
    }
    if (ok) {
      matchStarts.add(i);
      i += oldLines.length;
    } else {
      i++;
    }
  }

  if (matchStarts.isEmpty) {
    return (status: 'none', updated: null, count: 0);
  }
  if (matchStarts.length > 1 && !replaceAll) {
    return (status: 'ambiguous', updated: null, count: matchStarts.length);
  }

  final newLines = newNorm.split('\n');
  final targets = replaceAll ? matchStarts : <int>[matchStarts.first];
  final out = <String>[];
  var cursor = 0;
  for (final start in targets) {
    out.addAll(workLines.sublist(cursor, start));
    out.addAll(newLines);
    cursor = start + oldLines.length;
  }
  out.addAll(workLines.sublist(cursor));
  return (status: 'applied', updated: out.join('\n'), count: matchStarts.length);
}
