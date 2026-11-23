import 'dart:convert';
import 'dart:typed_data';

/// Pure-Dart zero-dependency ISO/IEC 18004 QR Code encoder (Versions 1..10,
/// Byte mode UTF-8, Error Correction Level L, 8-mask penalty optimizer).
/// Generates both a boolean matrix (for Flutter CustomPainter) and crisp inline SVG.

class _QrVersionSpec {
  final int version;
  final int totalDataCodewords;
  final int ecCodewordsPerBlock;
  final List<int> blockDataLengths;
  final List<int> alignCenters;

  const _QrVersionSpec(
    this.version,
    this.totalDataCodewords,
    this.ecCodewordsPerBlock,
    this.blockDataLengths,
    this.alignCenters,
  );
}

const List<_QrVersionSpec> _kSpecsLevelL = [
  _QrVersionSpec(1, 19, 7, [19], []),
  _QrVersionSpec(2, 34, 10, [34], [6, 18]),
  _QrVersionSpec(3, 55, 15, [55], [6, 22]),
  _QrVersionSpec(4, 80, 20, [80], [6, 26]),
  _QrVersionSpec(5, 108, 26, [108], [6, 30]),
  _QrVersionSpec(6, 136, 18, [68, 68], [6, 34]),
  _QrVersionSpec(7, 156, 20, [78, 78], [6, 22, 38]),
  _QrVersionSpec(8, 194, 24, [97, 97], [6, 24, 42]),
  _QrVersionSpec(9, 232, 30, [116, 116], [6, 26, 46]),
  _QrVersionSpec(10, 274, 18, [68, 68, 69, 69], [6, 28, 50]),
];

int _gfMul(int x, int y) {
  var z = 0;
  for (var i = 7; i >= 0; i--) {
    z = (z << 1) ^ ((z >> 7) * 0x11D);
    z ^= ((y >> i) & 1) * x;
  }
  return z & 0xFF;
}

Uint8List _rsComputeDivisor(int degree) {
  final result = Uint8List(degree);
  result[degree - 1] = 1;
  var root = 1;
  for (var i = 0; i < degree; i++) {
    for (var j = 0; j < degree; j++) {
      result[j] = _gfMul(result[j], root);
      if (j + 1 < degree) {
        result[j] ^= result[j + 1];
      }
    }
    root = _gfMul(root, 0x02);
  }
  return result;
}

Uint8List _rsComputeRemainder(Uint8List data, Uint8List divisor) {
  final result = Uint8List(divisor.length);
  for (final b in data) {
    final factor = b ^ result[0];
    for (var i = 0; i < result.length - 1; i++) {
      result[i] = result[i + 1];
    }
    result[result.length - 1] = 0;
    for (var i = 0; i < divisor.length; i++) {
      result[i] ^= _gfMul(divisor[i], factor);
    }
  }
  return result;
}

/// Encodes [text] into a square boolean matrix (`true` = dark module).
List<List<bool>> encodeQrMatrix(String text) {
  final payload = utf8.encode(text);
  _QrVersionSpec? chosen;
  for (final spec in _kSpecsLevelL) {
    final lenBits = spec.version <= 9 ? 8 : 16;
    final neededBits = 4 + lenBits + payload.length * 8;
    if (neededBits <= spec.totalDataCodewords * 8) {
      chosen = spec;
      break;
    }
  }
  if (chosen == null) {
    // Truncate gracefully only if caller passes >270 bytes URL
    final truncated = utf8.decode(payload.sublist(0, 260), allowMalformed: true);
    return encodeQrMatrix(truncated);
  }

  final bits = <int>[];
  void appendBits(int val, int len) {
    for (var i = len - 1; i >= 0; i--) {
      bits.add((val >> i) & 1);
    }
  }

  // Byte mode indicator (0100) + character count
  appendBits(0x4, 4);
  appendBits(payload.length, chosen.version <= 9 ? 8 : 16);
  for (final b in payload) {
    appendBits(b, 8);
  }

  final capacityBits = chosen.totalDataCodewords * 8;
  final termLen = capacityBits - bits.length < 4 ? capacityBits - bits.length : 4;
  appendBits(0, termLen);
  while (bits.length % 8 != 0) {
    bits.add(0);
  }
  var padToggle = true;
  while (bits.length < capacityBits) {
    appendBits(padToggle ? 0xEC : 0x11, 8);
    padToggle = !padToggle;
  }

  final dataBytes = Uint8List(chosen.totalDataCodewords);
  for (var i = 0; i < dataBytes.length; i++) {
    var v = 0;
    for (var b = 0; b < 8; b++) {
      v = (v << 1) | bits[i * 8 + b];
    }
    dataBytes[i] = v;
  }

  // Split into blocks, compute Reed-Solomon EC, and interleave
  final divisor = _rsComputeDivisor(chosen.ecCodewordsPerBlock);
  final dataBlocks = <Uint8List>[];
  final ecBlocks = <Uint8List>[];
  var offset = 0;
  var maxBlockLen = 0;
  for (final bLen in chosen.blockDataLengths) {
    final blk = Uint8List.sublistView(dataBytes, offset, offset + bLen);
    offset += bLen;
    if (bLen > maxBlockLen) maxBlockLen = bLen;
    dataBlocks.add(blk);
    ecBlocks.add(_rsComputeRemainder(blk, divisor));
  }

  final allCodewords = <int>[];
  for (var i = 0; i < maxBlockLen; i++) {
    for (final blk in dataBlocks) {
      if (i < blk.length) allCodewords.add(blk[i]);
    }
  }
  for (var i = 0; i < chosen.ecCodewordsPerBlock; i++) {
    for (final ec in ecBlocks) {
      allCodewords.add(ec[i]);
    }
  }

  final size = 17 + 4 * chosen.version;
  final modules = List.generate(size, (_) => List<bool>.filled(size, false));
  final isFunc = List.generate(size, (_) => List<bool>.filled(size, false));

  void setFunc(int x, int y, bool dark) {
    if (x < 0 || y < 0 || x >= size || y >= size) return;
    modules[y][x] = dark;
    isFunc[y][x] = true;
  }

  void drawFinder(int cx, int cy) {
    for (var dy = -4; dy <= 4; dy++) {
      for (var dx = -4; dx <= 4; dx++) {
        final dist = dx.abs() > dy.abs() ? dx.abs() : dy.abs();
        final x = cx + dx;
        final y = cy + dy;
        if (x >= 0 && x < size && y >= 0 && y < size) {
          setFunc(x, y, dist != 2 && dist != 4);
        }
      }
    }
  }

  void drawAlignment(int cx, int cy) {
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        final dist = dx.abs() > dy.abs() ? dx.abs() : dy.abs();
        setFunc(cx + dx, cy + dy, dist != 1);
      }
    }
  }

  // Timing patterns
  for (var i = 0; i < size; i++) {
    setFunc(6, i, i % 2 == 0);
    setFunc(i, 6, i % 2 == 0);
  }

  // Finder patterns (3 corners)
  drawFinder(3, 3);
  drawFinder(size - 4, 3);
  drawFinder(3, size - 4);

  // Alignment patterns
  final ac = chosen.alignCenters;
  for (var i = 0; i < ac.length; i++) {
    for (var j = 0; j < ac.length; j++) {
      if ((i == 0 && j == 0) ||
          (i == 0 && j == ac.length - 1) ||
          (i == ac.length - 1 && j == 0)) {
        continue;
      }
      drawAlignment(ac[i], ac[j]);
    }
  }

  // Reserve format bits & dark module
  for (var i = 0; i <= 8; i++) {
    if (i != 6) {
      if (!isFunc[8][i]) setFunc(i, 8, false);
      if (!isFunc[i][8]) setFunc(8, i, false);
    }
  }
  for (var i = 0; i < 8; i++) {
    setFunc(size - 1 - i, 8, false);
    setFunc(8, size - 1 - i, false);
  }
  setFunc(8, size - 8, true); // Dark module

  // Version info (versions 7..10)
  if (chosen.version >= 7) {
    var rem = chosen.version;
    for (var i = 0; i < 12; i++) {
      rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    }
    final vBits = (chosen.version << 12) | rem;
    for (var i = 0; i < 18; i++) {
      final bit = ((vBits >> i) & 1) != 0;
      final a = size - 11 + (i % 3);
      final b = i ~/ 3;
      setFunc(a, b, bit);
      setFunc(b, a, bit);
    }
  }

  // Zigzag codeword placement
  var bitIdx = 0;
  final totalCodewordBits = allCodewords.length * 8;
  for (var right = size - 1; right >= 1; right -= 2) {
    if (right == 6) right = 5;
    for (var vert = 0; vert < size; vert++) {
      for (var j = 0; j < 2; j++) {
        final x = right - j;
        final upward = ((right + 1) & 2) == 0;
        final y = upward ? size - 1 - vert : vert;
        if (!isFunc[y][x] && bitIdx < totalCodewordBits) {
          final byteVal = allCodewords[bitIdx >> 3];
          final dark = ((byteVal >> (7 - (bitIdx & 7))) & 1) != 0;
          modules[y][x] = dark;
          bitIdx++;
        }
      }
    }
  }

  void drawFormatBits(List<List<bool>> mat, int mask) {
    // EC Level L = 01
    final data = (0x01 << 3) | mask;
    var rem = data;
    for (var i = 0; i < 10; i++) {
      rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    }
    final bits15 = ((data << 10) | rem) ^ 0x5412;
    bool bit(int idx) => ((bits15 >> idx) & 1) != 0;

    for (var i = 0; i <= 5; i++) {
      mat[i][8] = bit(i);
    }
    mat[7][8] = bit(6);
    mat[8][8] = bit(7);
    mat[8][7] = bit(8);
    for (var i = 9; i < 15; i++) {
      mat[8][14 - i] = bit(i);
    }

    for (var i = 0; i < 8; i++) {
      mat[8][size - 1 - i] = bit(i);
    }
    for (var i = 8; i < 15; i++) {
      mat[size - 15 + i][8] = bit(i);
    }
    mat[size - 8][8] = true;
  }

  bool maskInvert(int mask, int x, int y) => switch (mask) {
        0 => (x + y) % 2 == 0,
        1 => y % 2 == 0,
        2 => x % 3 == 0,
        3 => (x + y) % 3 == 0,
        4 => ((y ~/ 2) + (x ~/ 3)) % 2 == 0,
        5 => (x * y) % 2 + (x * y) % 3 == 0,
        6 => ((x * y) % 2 + (x * y) % 3) % 2 == 0,
        _ => (((x + y) % 2) + ((x * y) % 3)) % 2 == 0,
      };

  int penaltyScore(List<List<bool>> mat) {
    var score = 0;
    for (var y = 0; y < size; y++) {
      var runColor = mat[y][0];
      var runLen = 1;
      for (var x = 1; x < size; x++) {
        if (mat[y][x] == runColor) {
          runLen++;
          if (runLen == 5) {
            score += 3;
          } else if (runLen > 5) {
            score += 1;
          }
        } else {
          runColor = mat[y][x];
          runLen = 1;
        }
      }
    }
    for (var x = 0; x < size; x++) {
      var runColor = mat[0][x];
      var runLen = 1;
      for (var y = 1; y < size; y++) {
        if (mat[y][x] == runColor) {
          runLen++;
          if (runLen == 5) {
            score += 3;
          } else if (runLen > 5) {
            score += 1;
          }
        } else {
          runColor = mat[y][x];
          runLen = 1;
        }
      }
    }
    for (var y = 0; y < size - 1; y++) {
      for (var x = 0; x < size - 1; x++) {
        final c = mat[y][x];
        if (c == mat[y][x + 1] &&
            c == mat[y + 1][x] &&
            c == mat[y + 1][x + 1]) {
          score += 3;
        }
      }
    }
    return score;
  }

  List<List<bool>>? bestMat;
  var bestScore = 1 << 30;
  for (var mask = 0; mask < 8; mask++) {
    final cand = List.generate(
      size,
      (y) => List<bool>.generate(
        size,
        (x) => isFunc[y][x] ? modules[y][x] : (modules[y][x] ^ maskInvert(mask, x, y)),
      ),
    );
    drawFormatBits(cand, mask);
    final sc = penaltyScore(cand);
    if (sc < bestScore) {
      bestScore = sc;
      bestMat = cand;
    }
  }
  return bestMat!;
}

/// Renders [text] as a self-contained inline `<svg>` QR code.
String generateQrSvg(
  String text, {
  String fgColor = '#111113',
  String bgColor = '#FFFFFF',
  int quietZone = 2,
  double borderRadius = 0,
}) {
  final mat = encodeQrMatrix(text);
  final n = mat.length;
  final total = n + quietZone * 2;
  final pathBuf = StringBuffer();
  for (var y = 0; y < n; y++) {
    var x = 0;
    while (x < n) {
      if (!mat[y][x]) {
        x++;
        continue;
      }
      var run = 1;
      while (x + run < n && mat[y][x + run]) {
        run++;
      }
      pathBuf.write('M${x + quietZone},${y + quietZone}h${run}v1h-${run}z');
      x += run;
    }
  }
  final rxAttr = borderRadius > 0 ? ' rx="$borderRadius"' : '';
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $total $total" shape-rendering="crispEdges">'
      '<rect width="$total" height="$total" fill="$bgColor"$rxAttr/>'
      '<path d="$pathBuf" fill="$fgColor"/>'
      '</svg>';
}
