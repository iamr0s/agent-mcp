import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'prism_theme.dart';

/// Pure-Dart ISO/IEC 18004 QR Code (Byte mode, ECC Level L, Versions 1..10)
/// vector renderer that works identically across Windows, macOS, Linux, Android, and Web.
class PrismQrCodeBox extends StatelessWidget {
  final String data;
  final double size;
  final Color? foregroundColor;
  final Color? backgroundColor;

  const PrismQrCodeBox({
    super.key,
    required this.data,
    this.size = 188,
    this.foregroundColor,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    final matrix = encodePrismQrMatrix(data);
    final bg = backgroundColor ?? Colors.white;
    final fg = foregroundColor ?? const Color(0xFF111827);

    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(12),
      decoration: ShapeDecoration(
        color: bg,
        shape: prismSuperellipse(
          16,
          side: BorderSide(color: c.hairline),
        ),
      ),
      child: CustomPaint(
        painter: _PrismQrMatrixPainter(
          matrix: matrix,
          color: fg,
        ),
      ),
    );
  }
}

class _PrismQrMatrixPainter extends CustomPainter {
  final List<List<bool>> matrix;
  final Color color;

  const _PrismQrMatrixPainter({
    required this.matrix,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = matrix.length;
    if (n == 0) return;
    final cell = size.width / n;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;

    for (var r = 0; r < n; r++) {
      final row = matrix[r];
      var c = 0;
      while (c < n) {
        if (!row[c]) {
          c++;
          continue;
        }
        var end = c + 1;
        while (end < n && row[end]) {
          end++;
        }
        canvas.drawRect(
          Rect.fromLTWH(
            c * cell,
            r * cell,
            (end - c) * cell + 0.15,
            cell + 0.15,
          ),
          paint,
        );
        c = end;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PrismQrMatrixPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.matrix.length != matrix.length;
}

class _QrVersionSpec {
  final int version;
  final int totalDataCodewords;
  final int ecCodewordsPerBlock;
  final int numBlocksGroup1;
  final int dataCodewordsGroup1;
  final int numBlocksGroup2;
  final int dataCodewordsGroup2;
  final List<int> alignmentCenters;

  const _QrVersionSpec(
    this.version,
    this.totalDataCodewords,
    this.ecCodewordsPerBlock,
    this.numBlocksGroup1,
    this.dataCodewordsGroup1,
    this.numBlocksGroup2,
    this.dataCodewordsGroup2,
    this.alignmentCenters,
  );
}

const List<_QrVersionSpec> _kSpecsL = [
  _QrVersionSpec(1, 19, 7, 1, 19, 0, 0, []),
  _QrVersionSpec(2, 34, 10, 1, 34, 0, 0, [6, 18]),
  _QrVersionSpec(3, 55, 15, 1, 55, 0, 0, [6, 22]),
  _QrVersionSpec(4, 80, 20, 1, 80, 0, 0, [6, 26]),
  _QrVersionSpec(5, 108, 26, 1, 108, 0, 0, [6, 30]),
  _QrVersionSpec(6, 136, 18, 2, 68, 0, 0, [6, 34]),
  _QrVersionSpec(7, 156, 20, 2, 78, 0, 0, [6, 22, 38]),
  _QrVersionSpec(8, 194, 24, 2, 97, 0, 0, [6, 24, 42]),
  _QrVersionSpec(9, 232, 30, 2, 116, 0, 0, [6, 26, 46]),
  _QrVersionSpec(10, 274, 18, 2, 68, 2, 69, [6, 28, 50]),
];

const List<int> _kVersionInfoBits = [
  0, 0, 0, 0, 0, 0, 0,
  0x07C94,
  0x085BC,
  0x09A99,
  0x0A4D3,
];

final Uint8List _gfExp = _initGfExp();
final Uint8List _gfLog = _initGfLog();

Uint8List _initGfExp() {
  final exp = Uint8List(512);
  var x = 1;
  for (var i = 0; i < 255; i++) {
    exp[i] = x;
    x <<= 1;
    if ((x & 0x100) != 0) x ^= 0x11D;
  }
  for (var i = 255; i < 512; i++) {
    exp[i] = exp[i - 255];
  }
  return exp;
}

Uint8List _initGfLog() {
  final log = Uint8List(256);
  for (var i = 0; i < 255; i++) {
    log[_gfExp[i]] = i;
  }
  return log;
}

int _gfMul(int a, int b) {
  if (a == 0 || b == 0) return 0;
  return _gfExp[_gfLog[a] + _gfLog[b]];
}

Uint8List _rsGeneratorPoly(int degree) {
  var poly = Uint8List.fromList([1]);
  for (var i = 0; i < degree; i++) {
    final next = Uint8List(poly.length + 1);
    final root = _gfExp[i];
    for (var j = 0; j < poly.length; j++) {
      next[j] ^= poly[j];
      next[j + 1] ^= _gfMul(poly[j], root);
    }
    poly = next;
  }
  return poly;
}

Uint8List _rsComputeRemainder(Uint8List data, int degree) {
  final gen = _rsGeneratorPoly(degree);
  final rem = Uint8List(degree);
  for (final b in data) {
    final factor = b ^ rem[0];
    for (var i = 0; i < degree - 1; i++) {
      rem[i] = rem[i + 1] ^ _gfMul(gen[i + 1], factor);
    }
    rem[degree - 1] = _gfMul(gen[degree], factor);
  }
  return rem;
}

List<List<bool>> encodePrismQrMatrix(String text) {
  final payload = utf8.encode(text);
  _QrVersionSpec? chosen;
  for (final s in _kSpecsL) {
    final headerBits = 4 + (s.version <= 9 ? 8 : 16);
    final maxBytes = ((s.totalDataCodewords * 8) - headerBits) ~/ 8;
    if (payload.length <= maxBytes) {
      chosen = s;
      break;
    }
  }
  chosen ??= _kSpecsL.last;
  final effectivePayload = payload.length > 270
      ? Uint8List.sublistView(Uint8List.fromList(payload), 0, 270)
      : payload;

  final bits = <int>[];
  void pushBits(int val, int len) {
    for (var i = len - 1; i >= 0; i--) {
      bits.add((val >> i) & 1);
    }
  }

  pushBits(0x4, 4);
  pushBits(effectivePayload.length, chosen.version <= 9 ? 8 : 16);
  for (final b in effectivePayload) {
    pushBits(b, 8);
  }

  final capacityBits = chosen.totalDataCodewords * 8;
  final termLen = (capacityBits - bits.length).clamp(0, 4);
  pushBits(0, termLen);
  while (bits.length % 8 != 0) {
    bits.add(0);
  }

  final dataBytes = Uint8List(chosen.totalDataCodewords);
  final filledBytes = bits.length ~/ 8;
  for (var i = 0; i < filledBytes; i++) {
    var v = 0;
    for (var b = 0; b < 8; b++) {
      v = (v << 1) | bits[i * 8 + b];
    }
    dataBytes[i] = v;
  }
  const padBytes = [0xEC, 0x11];
  for (var i = filledBytes; i < chosen.totalDataCodewords; i++) {
    dataBytes[i] = padBytes[(i - filledBytes) % 2];
  }

  final dataBlocks = <Uint8List>[];
  final ecBlocks = <Uint8List>[];
  var offset = 0;
  for (var i = 0; i < chosen.numBlocksGroup1; i++) {
    final blk = Uint8List.sublistView(
      dataBytes,
      offset,
      offset + chosen.dataCodewordsGroup1,
    );
    offset += chosen.dataCodewordsGroup1;
    dataBlocks.add(blk);
    ecBlocks.add(_rsComputeRemainder(blk, chosen.ecCodewordsPerBlock));
  }
  for (var i = 0; i < chosen.numBlocksGroup2; i++) {
    final blk = Uint8List.sublistView(
      dataBytes,
      offset,
      offset + chosen.dataCodewordsGroup2,
    );
    offset += chosen.dataCodewordsGroup2;
    dataBlocks.add(blk);
    ecBlocks.add(_rsComputeRemainder(blk, chosen.ecCodewordsPerBlock));
  }

  final finalCodewords = <int>[];
  final maxDataLen = chosen.numBlocksGroup2 > 0
      ? chosen.dataCodewordsGroup2
      : chosen.dataCodewordsGroup1;
  for (var i = 0; i < maxDataLen; i++) {
    for (final blk in dataBlocks) {
      if (i < blk.length) finalCodewords.add(blk[i]);
    }
  }
  for (var i = 0; i < chosen.ecCodewordsPerBlock; i++) {
    for (final blk in ecBlocks) {
      finalCodewords.add(blk[i]);
    }
  }

  final size = chosen.version * 4 + 17;
  final modules = List.generate(size, (_) => List<bool>.filled(size, false));
  final isFunc = List.generate(size, (_) => List<bool>.filled(size, false));

  void setFunc(int r, int c, bool dark) {
    if (r < 0 || r >= size || c < 0 || c >= size) return;
    modules[r][c] = dark;
    isFunc[r][c] = true;
  }

  void placeFinder(int top, int left) {
    for (var dr = -1; dr <= 7; dr++) {
      for (var dc = -1; dc <= 7; dc++) {
        final r = top + dr;
        final c = left + dc;
        if (r < 0 || r >= size || c < 0 || c >= size) continue;
        final inOuter = dr >= 0 && dr <= 6 && dc >= 0 && dc <= 6;
        final onBorder = dr == 0 || dr == 6 || dc == 0 || dc == 6;
        final inCenter = dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4;
        setFunc(r, c, inOuter && (onBorder || inCenter));
      }
    }
  }

  placeFinder(0, 0);
  placeFinder(0, size - 7);
  placeFinder(size - 7, 0);

  for (var i = 8; i < size - 8; i++) {
    if (!isFunc[6][i]) setFunc(6, i, i.isEven);
    if (!isFunc[i][6]) setFunc(i, 6, i.isEven);
  }

  final centers = chosen.alignmentCenters;
  for (var i = 0; i < centers.length; i++) {
    for (var j = 0; j < centers.length; j++) {
      if ((i == 0 && j == 0) ||
          (i == 0 && j == centers.length - 1) ||
          (i == centers.length - 1 && j == 0)) {
        continue;
      }
      final cr = centers[i];
      final cc = centers[j];
      for (var dr = -2; dr <= 2; dr++) {
        for (var dc = -2; dc <= 2; dc++) {
          final dark =
              dr.abs() == 2 || dc.abs() == 2 || (dr == 0 && dc == 0);
          setFunc(cr + dr, cc + dc, dark);
        }
      }
    }
  }

  setFunc(size - 8, 8, true);
  for (var i = 0; i < 9; i++) {
    if (!isFunc[8][i]) setFunc(8, i, false);
    if (!isFunc[i][8]) setFunc(i, 8, false);
  }
  for (var i = 0; i < 8; i++) {
    if (!isFunc[8][size - 1 - i]) setFunc(8, size - 1 - i, false);
    if (!isFunc[size - 1 - i][8]) setFunc(size - 1 - i, 8, false);
  }

  if (chosen.version >= 7) {
    final vbits = _kVersionInfoBits[chosen.version];
    for (var i = 0; i < 18; i++) {
      final dark = ((vbits >> i) & 1) == 1;
      final a = size - 11 + (i % 3);
      final b = i ~/ 3;
      setFunc(b, a, dark);
      setFunc(a, b, dark);
    }
  }

  final streamBits = <int>[];
  for (final cw in finalCodewords) {
    for (var b = 7; b >= 0; b--) {
      streamBits.add((cw >> b) & 1);
    }
  }

  var bitIdx = 0;
  var upward = true;
  for (var right = size - 1; right >= 1; right -= 2) {
    if (right == 6) right = 5;
    for (var vert = 0; vert < size; vert++) {
      final r = upward ? (size - 1 - vert) : vert;
      for (var j = 0; j < 2; j++) {
        final c = right - j;
        if (!isFunc[r][c]) {
          final dark =
              bitIdx < streamBits.length ? streamBits[bitIdx] == 1 : false;
          modules[r][c] = dark;
          bitIdx++;
        }
      }
    }
    upward = !upward;
  }

  void writeFormatBits(int mask) {
    final data = (0x01 << 3) | mask;
    var rem = data;
    for (var i = 0; i < 10; i++) {
      rem = (rem << 1) ^ (((rem >> 9) & 1) * 0x537);
    }
    final bits15 = ((data << 10) | rem) ^ 0x5412;
    for (var i = 0; i <= 5; i++) {
      modules[8][i] = ((bits15 >> i) & 1) == 1;
    }
    modules[8][7] = ((bits15 >> 6) & 1) == 1;
    modules[8][8] = ((bits15 >> 7) & 1) == 1;
    modules[7][8] = ((bits15 >> 8) & 1) == 1;
    for (var i = 9; i < 15; i++) {
      modules[14 - i][8] = ((bits15 >> i) & 1) == 1;
    }
    for (var i = 0; i < 8; i++) {
      modules[8][size - 1 - i] = ((bits15 >> i) & 1) == 1;
    }
    for (var i = 8; i < 15; i++) {
      modules[size - 15 + i][8] = ((bits15 >> i) & 1) == 1;
    }
    modules[size - 8][8] = true;
  }

  for (var r = 0; r < size; r++) {
    for (var c = 0; c < size; c++) {
      if (!isFunc[r][c] && ((r + c) % 2 == 0)) {
        modules[r][c] = !modules[r][c];
      }
    }
  }
  writeFormatBits(0);
  return modules;
}
