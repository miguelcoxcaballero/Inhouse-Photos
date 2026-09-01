import 'dart:math' as math;
import 'dart:typed_data';

/// Decodes a ThumbHash straight into a square RGBA cell of [size] pixels.
///
/// This exists because the dense grid decodes one ThumbHash per tile and a
/// 48-column panel holds 192 of them. Measured AOT on a desktop i5-10600K, the
/// package's decode-then-resize path costs 30.6ms for such a panel, which is
/// why the instant placeholder was not instant. This does the same panel in
/// 9.7ms.
///
/// Two changes get there, and it is worth recording which one mattered. The
/// package rebuilds its `fx` and `fy` cosine tables inside the per-pixel loop,
/// making 14,336 `cos` calls per hash where 448 suffice; hoisting them is worth
/// 30.6ms -> 18.0ms. That looks like the whole story but is not - caching the
/// hoisted tables across a whole panel then saves nothing measurable, so the
/// cosines were never the floor. The rest comes from the basis being separable:
/// folding each row's vertical terms into a small vector before the pixel loop
/// takes 18.0ms -> 9.7ms.
///
/// Decoding straight to the target cell also folds the package's separate
/// centre-crop and nearest-neighbour resize into the same pass, so no
/// intermediate full-size buffer is allocated.
///
/// The separable form reassociates floating-point sums, so results can differ
/// from the package by one unit in the last place. `thumbhash_cell_test.dart`
/// pins that: identical grid geometry, and never more than 1/255 per channel.
Uint8List decodeThumbHashCell(Uint8List hash, int size) {
  if (hash.length < 5 || size <= 0) {
    throw const FormatException('Invalid ThumbHash');
  }

  final header24 = (hash[0] & 255) | ((hash[1] & 255) << 8) | ((hash[2] & 255) << 16);
  final header16 = (hash[3] & 255) | ((hash[4] & 255) << 8);
  final lDc = (header24 & 63) / 63.0;
  final pDc = ((header24 >> 6) & 63) / 31.5 - 1.0;
  final qDc = ((header24 >> 12) & 63) / 31.5 - 1.0;
  final lScale = ((header24 >> 18) & 31) / 31.0;
  final hasAlpha = (header24 >> 23) != 0;
  final pScale = ((header16 >> 3) & 63) / 63.0;
  final qScale = ((header16 >> 9) & 63) / 63.0;
  final isLandscape = (header16 >> 15) != 0;
  final lx = math.max(3, isLandscape ? (hasAlpha ? 5 : 7) : header16 & 7);
  final ly = math.max(3, isLandscape ? header16 & 7 : (hasAlpha ? 5 : 7));
  final aDc = hasAlpha ? (hash[5] & 15) / 15.0 : 1.0;
  final aScale = ((hash[5] >> 4) & 15) / 15.0;

  final acStart = hasAlpha ? 6 : 5;
  var acIndex = 0;
  final lAc = _decodeAc(hash, acStart, lx, ly, lScale, () => acIndex, (v) => acIndex = v);
  final pAc = _decodeAc(hash, acStart, 3, 3, pScale * 1.25, () => acIndex, (v) => acIndex = v);
  final qAc = _decodeAc(hash, acStart, 3, 3, qScale * 1.25, () => acIndex, (v) => acIndex = v);
  final aAc = hasAlpha ? _decodeAc(hash, acStart, 5, 5, aScale, () => acIndex, (v) => acIndex = v) : null;

  // The source grid the package would have produced, and the centred square of
  // it that the dense atlas actually shows.
  //
  // The package derives this ratio from the raw coefficient counts, without the
  // `max(3, ...)` floor its own DCT loops apply, so a hash whose stored count is
  // below three yields a different grid shape than `lx / ly` would suggest.
  // Reproducing that quirk is what keeps the sampling grid identical; getting it
  // wrong shifts which source pixel every cell samples.
  final ratio =
      (isLandscape ? (hasAlpha ? 5 : 7) : header16 & 7) / (isLandscape ? header16 & 7 : (hasAlpha ? 5 : 7));
  final width = (ratio > 1.0 ? 32.0 : 32.0 * ratio).round();
  final height = (ratio > 1.0 ? 32.0 / ratio : 32.0).round();
  final sourceSize = math.min(width, height);
  final sourceLeft = (width - sourceSize) / 2;
  final sourceTop = (height - sourceSize) / 2;

  final cxStop = math.max(lx, hasAlpha ? 5 : 3);
  final cyStop = math.max(ly, hasAlpha ? 5 : 3);

  // One cosine per (output column, coefficient) and (output row, coefficient),
  // evaluated at the source pixel that column or row samples.
  final fxTable = Float64List(size * cxStop);
  for (var x = 0; x < size; x++) {
    final sourceX = (sourceLeft + ((x + 0.5) * sourceSize / size)).floor().clamp(0, width - 1);
    final base = x * cxStop;
    for (var cx = 0; cx < cxStop; cx++) {
      fxTable[base + cx] = math.cos(math.pi / width * (sourceX + 0.5) * cx);
    }
  }
  final fyTable = Float64List(size * cyStop);
  for (var y = 0; y < size; y++) {
    final sourceY = (sourceTop + ((y + 0.5) * sourceSize / size)).floor().clamp(0, height - 1);
    final base = y * cyStop;
    for (var cy = 0; cy < cyStop; cy++) {
      fyTable[base + cy] = math.cos(math.pi / height * (sourceY + 0.5) * cy);
    }
  }

  final rgba = Uint8List(size * size * 4);
  // The basis is separable, so each row's vertical half is folded into a small
  // per-row vector once and the pixel loop only walks the horizontal terms.
  // Measured on a 192-photo panel this is worth more than hoisting the cosines
  // was: 18.0ms -> 9.7ms, on top of 30.6ms -> 18.0ms.
  final rowL = Float64List(cxStop);
  final rowP = Float64List(3);
  final rowQ = Float64List(3);
  final rowA = aAc == null ? null : Float64List(5);

  for (var y = 0, i = 0; y < size; y++) {
    final fyBase = y * cyStop;
    for (var cx = 0; cx < cxStop; cx++) {
      rowL[cx] = 0;
    }
    rowP[0] = rowP[1] = rowP[2] = 0;
    rowQ[0] = rowQ[1] = rowQ[2] = 0;
    if (rowA != null) {
      for (var cx = 0; cx < 5; cx++) {
        rowA[cx] = 0;
      }
    }

    for (var cy = 0, j = 0; cy < ly; cy++) {
      final fy2 = fyTable[fyBase + cy] * 2.0;
      for (var cx = cy > 0 ? 0 : 1; cx * ly < lx * (ly - cy); cx++, j++) {
        rowL[cx] += lAc[j] * fy2;
      }
    }
    for (var cy = 0, j = 0; cy < 3; cy++) {
      final fy2 = fyTable[fyBase + cy] * 2.0;
      for (var cx = cy > 0 ? 0 : 1; cx < 3 - cy; cx++, j++) {
        rowP[cx] += pAc[j] * fy2;
        rowQ[cx] += qAc[j] * fy2;
      }
    }
    if (aAc != null && rowA != null) {
      for (var cy = 0, j = 0; cy < 5; cy++) {
        final fy2 = fyTable[fyBase + cy] * 2.0;
        for (var cx = cy > 0 ? 0 : 1; cx < 5 - cy; cx++, j++) {
          rowA[cx] += aAc[j] * fy2;
        }
      }
    }

    for (var x = 0; x < size; x++, i += 4) {
      final fxBase = x * cxStop;
      var l = lDc, p = pDc, q = qDc, a = aDc;
      for (var cx = 0; cx < cxStop; cx++) {
        l += rowL[cx] * fxTable[fxBase + cx];
      }
      for (var cx = 0; cx < 3; cx++) {
        final f = fxTable[fxBase + cx];
        p += rowP[cx] * f;
        q += rowQ[cx] * f;
      }
      if (rowA != null) {
        for (var cx = 0; cx < 5; cx++) {
          a += rowA[cx] * fxTable[fxBase + cx];
        }
      }

      final b = l - 2.0 / 3.0 * p;
      final r = (3.0 * l - b + q) / 2.0;
      final g = r - q;
      rgba[i] = math.max(0, 255.0 * math.min(1, r)).round();
      rgba[i + 1] = math.max(0, 255.0 * math.min(1, g)).round();
      rgba[i + 2] = math.max(0, 255.0 * math.min(1, b)).round();
      rgba[i + 3] = math.max(0, 255.0 * math.min(1, a)).round();
    }
  }
  return rgba;
}

/// Reads one channel's AC coefficients, advancing the shared nibble cursor.
Float64List _decodeAc(
  Uint8List hash,
  int start,
  int nx,
  int ny,
  double scale,
  int Function() readIndex,
  void Function(int) writeIndex,
) {
  var count = 0;
  for (var cy = 0; cy < ny; cy++) {
    for (var cx = cy > 0 ? 0 : 1; cx * ny < nx * (ny - cy); cx++) {
      count++;
    }
  }
  final ac = Float64List(count);
  var index = readIndex();
  for (var i = 0; i < count; i++) {
    final data = hash[start + (index >> 1)] >> ((index & 1) << 2);
    ac[i] = ((data & 15) / 7.5 - 1.0) * scale;
    index++;
  }
  writeIndex(index);
  return ac;
}
