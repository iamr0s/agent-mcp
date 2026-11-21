import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';

class DecodedTextFile {
  final String text;
  final String encoding; // 'utf-8' | 'utf-8-bom' | 'gbk' | 'latin-1'
  final String newline; // '\r\n' | '\n'

  const DecodedTextFile({
    required this.text,
    required this.encoding,
    required this.newline,
  });
}

bool isBinaryBytes(Uint8List sample) {
  if (sample.isEmpty) return false;
  final len = min(sample.length, 8192);
  var nonText = 0;
  for (var i = 0; i < len; i++) {
    final b = sample[i];
    if (b == 0) return true;
    final isAllowedCtrl =
        b == 7 || b == 8 || b == 9 || b == 10 || b == 12 || b == 13 || b == 27;
    final isPrintable = b >= 0x20 && b != 0x7F;
    if (!isAllowedCtrl && !isPrintable) {
      nonText++;
    }
  }
  return (nonText / len) > 0.30;
}

bool _containsCrlf(Uint8List bytes) {
  final limit = min(bytes.length - 1, 8192);
  for (var i = 0; i < limit; i++) {
    if (bytes[i] == 13 && bytes[i + 1] == 10) return true;
  }
  return false;
}

DecodedTextFile decodeTextBytesSmart(Uint8List raw, String displayPath) {
  if (isBinaryBytes(raw)) {
    throw FormatException("'$displayPath' appears to be a binary file.");
  }
  final nl = _containsCrlf(raw) ? '\r\n' : '\n';

  // UTF-8 BOM check
  if (raw.length >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF) {
    try {
      final decoded = utf8.decode(raw.sublist(3), allowMalformed: false);
      return DecodedTextFile(text: decoded, encoding: 'utf-8-bom', newline: nl);
    } catch (_) {}
  }

  try {
    final decoded = utf8.decode(raw, allowMalformed: false);
    return DecodedTextFile(text: decoded, encoding: 'utf-8', newline: nl);
  } catch (_) {}

  try {
    final decoded = gbk.decode(raw, allowMalformed: false);
    return DecodedTextFile(text: decoded, encoding: 'gbk', newline: nl);
  } catch (_) {}

  final decoded = latin1.decode(raw, allowInvalid: true);
  return DecodedTextFile(text: decoded, encoding: 'latin-1', newline: nl);
}

DecodedTextFile readTextSmart(File file) {
  final raw = file.readAsBytesSync();
  return decodeTextBytesSmart(raw, file.path);
}

Uint8List encodeTextPreservingBytes(
  String text, {
  String encoding = 'utf-8',
  String newline = '\n',
}) {
  var normalized = text.replaceAll('\r\n', '\n');
  if (newline == '\r\n') {
    normalized = normalized.replaceAll('\n', '\r\n');
  }

  List<int> bytes;
  switch (encoding) {
    case 'utf-8-bom':
      bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(normalized)];
      break;
    case 'gbk':
      try {
        bytes = gbk.encode(normalized);
      } catch (_) {
        bytes = utf8.encode(normalized);
      }
      break;
    case 'latin-1':
      try {
        bytes = latin1.encode(normalized);
      } catch (_) {
        bytes = utf8.encode(normalized);
      }
      break;
    default:
      bytes = utf8.encode(normalized);
  }
  return Uint8List.fromList(bytes);
}

int writeTextPreserving(
  File file,
  String text, {
  String encoding = 'utf-8',
  String newline = '\n',
}) {
  file.parent.createSync(recursive: true);
  final bytes = encodeTextPreservingBytes(
    text,
    encoding: encoding,
    newline: newline,
  );
  file.writeAsBytesSync(bytes, flush: true);
  return bytes.length;
}

String decodeBytesSmart(List<int> data) {
  if (data.isEmpty) return '';
  try {
    return utf8.decode(data, allowMalformed: false);
  } catch (_) {}
  try {
    return gbk.decode(data, allowMalformed: false);
  } catch (_) {}
  return utf8.decode(data, allowMalformed: true);
}

(String, bool) truncateHeadTail(String text, int maxChars) {
  if (text.length <= maxChars) return (text, false);
  final headLen = (maxChars * 0.35).floor();
  final tailLen = maxChars - headLen;
  final omitted = text.length - maxChars;
  final out = '${text.substring(0, headLen)}'
      '\n\n... [TRUNCATED $omitted chars to protect context; showing head + tail] ...\n\n'
      '${text.substring(text.length - tailLen)}';
  return (out, true);
}

List<String> splitLinesNoEol(String text) {
  if (text.isEmpty) return const <String>[];
  final norm = text.replaceAll('\r\n', '\n');
  final parts = norm.split('\n');
  if (parts.isNotEmpty && parts.last.isEmpty && norm.endsWith('\n')) {
    parts.removeLast();
  }
  return parts;
}

List<String> splitLinesKeepEnds(String text) {
  if (text.isEmpty) return const <String>[];
  final out = <String>[];
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 10) {
      out.add(text.substring(start, i + 1));
      start = i + 1;
    }
  }
  if (start < text.length) {
    out.add(text.substring(start));
  }
  return out;
}

enum _DiffOpType { equal, delete, insert }

class _DiffOp {
  final _DiffOpType type;
  final String line;
  const _DiffOp(this.type, this.line);
}

/// Generates a standard Unified Diff (`--- a/name`, `+++ b/name`, `@@ ... @@`).
/// Trims common prefix/suffix first so edits inside huge files run in <1ms.
String makeUnifiedDiff(
  String oldText,
  String newText,
  String fileName, {
  int contextLines = 3,
}) {
  final a = splitLinesNoEol(oldText);
  final b = splitLinesNoEol(newText);
  if (_listEquals(a, b)) return '';

  var prefix = 0;
  final minLen = min(a.length, b.length);
  while (prefix < minLen && a[prefix] == b[prefix]) {
    prefix++;
  }

  var suffix = 0;
  while (suffix < (minLen - prefix) &&
      a[a.length - 1 - suffix] == b[b.length - 1 - suffix]) {
    suffix++;
  }

  final midA = a.sublist(prefix, a.length - suffix);
  final midB = b.sublist(prefix, b.length - suffix);

  final ops = <_DiffOp>[];
  for (var i = 0; i < prefix; i++) {
    ops.add(_DiffOp(_DiffOpType.equal, a[i]));
  }

  if (midA.length * midB.length <= 1500000) {
    // Exact DP LCS on the changed middle window
    final m = midA.length;
    final n = midB.length;
    final dp = List.generate(m + 1, (_) => Int32List(n + 1));
    for (var i = m - 1; i >= 0; i--) {
      for (var j = n - 1; j >= 0; j--) {
        if (midA[i] == midB[j]) {
          dp[i][j] = dp[i + 1][j + 1] + 1;
        } else {
          final d1 = dp[i + 1][j];
          final d2 = dp[i][j + 1];
          dp[i][j] = d1 >= d2 ? d1 : d2;
        }
      }
    }
    var i = 0;
    var j = 0;
    while (i < m && j < n) {
      if (midA[i] == midB[j]) {
        ops.add(_DiffOp(_DiffOpType.equal, midA[i]));
        i++;
        j++;
      } else if (dp[i + 1][j] >= dp[i][j + 1]) {
        ops.add(_DiffOp(_DiffOpType.delete, midA[i]));
        i++;
      } else {
        ops.add(_DiffOp(_DiffOpType.insert, midB[j]));
        j++;
      }
    }
    while (i < m) {
      ops.add(_DiffOp(_DiffOpType.delete, midA[i++]));
    }
    while (j < n) {
      ops.add(_DiffOp(_DiffOpType.insert, midB[j++]));
    }
  } else {
    for (final line in midA) {
      ops.add(_DiffOp(_DiffOpType.delete, line));
    }
    for (final line in midB) {
      ops.add(_DiffOp(_DiffOpType.insert, line));
    }
  }

  for (var i = a.length - suffix; i < a.length; i++) {
    ops.add(_DiffOp(_DiffOpType.equal, a[i]));
  }

  // Group non-equal indices into hunks with `contextLines` padding
  final changeIndices = <int>[];
  for (var idx = 0; idx < ops.length; idx++) {
    if (ops[idx].type != _DiffOpType.equal) changeIndices.add(idx);
  }
  if (changeIndices.isEmpty) return '';

  final ranges = <(int, int)>[];
  var curStart = max(0, changeIndices.first - contextLines);
  var curEnd = min(ops.length - 1, changeIndices.first + contextLines);
  for (var k = 1; k < changeIndices.length; k++) {
    final s = max(0, changeIndices[k] - contextLines);
    final e = min(ops.length - 1, changeIndices[k] + contextLines);
    if (s <= curEnd + 1) {
      curEnd = max(curEnd, e);
    } else {
      ranges.add((curStart, curEnd));
      curStart = s;
      curEnd = e;
    }
  }
  ranges.add((curStart, curEnd));

  // Precompute 1-based old/new line numbers before each op
  final oldPos = Int32List(ops.length + 1);
  final newPos = Int32List(ops.length + 1);
  var oLine = 1;
  var nLine = 1;
  for (var idx = 0; idx < ops.length; idx++) {
    oldPos[idx] = oLine;
    newPos[idx] = nLine;
    if (ops[idx].type != _DiffOpType.insert) oLine++;
    if (ops[idx].type != _DiffOpType.delete) nLine++;
  }
  oldPos[ops.length] = oLine;
  newPos[ops.length] = nLine;

  final buf = StringBuffer()
    ..writeln('--- a/$fileName')
    ..writeln('+++ b/$fileName');

  for (final (s, e) in ranges) {
    var oCount = 0;
    var nCount = 0;
    for (var idx = s; idx <= e; idx++) {
      if (ops[idx].type != _DiffOpType.insert) oCount++;
      if (ops[idx].type != _DiffOpType.delete) nCount++;
    }
    final oStart = oCount == 0 ? oldPos[s] - 1 : oldPos[s];
    final nStart = nCount == 0 ? newPos[s] - 1 : newPos[s];
    buf.writeln('@@ -$oStart,$oCount +$nStart,$nCount @@');
    for (var idx = s; idx <= e; idx++) {
      final op = ops[idx];
      switch (op.type) {
        case _DiffOpType.equal:
          buf.writeln(' ${op.line}');
          break;
        case _DiffOpType.delete:
          buf.writeln('-${op.line}');
          break;
        case _DiffOpType.insert:
          buf.writeln('+${op.line}');
          break;
      }
    }
  }
  return buf.toString();
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _stripCrLf(String s) => s.replaceAll(RegExp(r'[\r\n]+$'), '');

bool _linesMatch(List<String> orig, int start, List<String> expected) {
  if (start + expected.length > orig.length) return false;
  for (var i = 0; i < expected.length; i++) {
    if (_stripCrLf(orig[start + i]) != _stripCrLf(expected[i])) {
      return false;
    }
  }
  return true;
}

int? _findHunkPosition(List<String> orig, List<String> expected, int minStart) {
  if (expected.isEmpty) return minStart;
  for (var pos = minStart; pos <= orig.length - expected.length; pos++) {
    if (_linesMatch(orig, pos, expected)) return pos;
  }
  return null;
}

/// Applies standard Unified Diff (`@@ -a,b +c,d @@`) hunks to [original].
String applyUnifiedDiffText(String original, String diffText) {
  final origLines = splitLinesKeepEnds(original);
  final diffLines = splitLinesKeepEnds(diffText);
  final hunkHeaderRe = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@');

  final hunks = <(int, List<String>)>[];
  var idx = 0;
  while (idx < diffLines.length) {
    final m = hunkHeaderRe.firstMatch(diffLines[idx]);
    if (m != null) {
      final oldStart = int.parse(m.group(1)!);
      idx++;
      final body = <String>[];
      while (idx < diffLines.length && !diffLines[idx].startsWith('@@ ')) {
        final line = diffLines[idx];
        if (line.startsWith(' ') ||
            line.startsWith('-') ||
            line.startsWith('+') ||
            line.startsWith(r'\')) {
          body.add(line);
        }
        idx++;
      }
      hunks.add((oldStart, body));
    } else {
      idx++;
    }
  }

  if (hunks.isEmpty) {
    throw const FormatException(
      'No valid unified diff hunks (@@ -a,b +c,d @@) found.',
    );
  }

  final result = <String>[];
  var cursor = 0;
  for (final (oldStart, body) in hunks) {
    final expectedOld = <String>[];
    final newChunk = <String>[];
    for (final l in body) {
      if (l.startsWith(' ') || l.startsWith('-')) {
        final s = l.substring(1);
        expectedOld.add(s.endsWith('\n') ? s : '$s\n');
      }
      if (l.startsWith(' ') || l.startsWith('+')) {
        final s = l.substring(1);
        newChunk.add(s.endsWith('\n') ? s : '$s\n');
      }
    }

    var targetIdx = max(0, oldStart - 1);
    if (!_linesMatch(origLines, targetIdx, expectedOld)) {
      final found = _findHunkPosition(origLines, expectedOld, cursor);
      if (found == null) {
        throw FormatException(
          'Hunk at line $oldStart failed to match file content. '
          'Ensure context lines match the current file.',
        );
      }
      targetIdx = found;
    }
    if (targetIdx < cursor) {
      throw FormatException('Overlapping hunk near line $oldStart.');
    }
    result.addAll(origLines.sublist(cursor, targetIdx));
    result.addAll(newChunk);
    cursor = targetIdx + expectedOld.length;
  }
  result.addAll(origLines.sublist(cursor));
  final joined = result.join();
  return joined;
}

double _diceSimilarity(String a, String b) {
  final sa = a.trim();
  final sb = b.trim();
  if (sa == sb) return 1.0;
  if (sa.length < 2 || sb.length < 2) return 0.0;
  final bigramsA = <String, int>{};
  for (var i = 0; i < sa.length - 1; i++) {
    final bg = sa.substring(i, i + 2);
    bigramsA[bg] = (bigramsA[bg] ?? 0) + 1;
  }
  var matches = 0;
  for (var i = 0; i < sb.length - 1; i++) {
    final bg = sb.substring(i, i + 2);
    final cnt = bigramsA[bg] ?? 0;
    if (cnt > 0) {
      bigramsA[bg] = cnt - 1;
      matches++;
    }
  }
  return (2.0 * matches) / ((sa.length - 1) + (sb.length - 1));
}

List<(int, String)> findClosestLines(
  String needle,
  List<String> fileLines, {
  int limit = 3,
  double cutoff = 0.5,
}) {
  final scored = <(double, int, String)>[];
  for (var i = 0; i < fileLines.length; i++) {
    final score = _diceSimilarity(needle, fileLines[i]);
    if (score >= cutoff) {
      scored.add((score, i + 1, fileLines[i]));
    }
  }
  scored.sort((a, b) => b.$1.compareTo(a.$1));
  return scored.take(limit).map((e) => (e.$2, e.$3)).toList();
}
