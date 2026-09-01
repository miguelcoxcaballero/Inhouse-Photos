// ignore_for_file: avoid_print
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/thumbhash_cell.dart';
import 'package:thumbhash/thumbhash.dart' as thumbhash;

/// The decode path this replaces: package decode, centre crop, nearest resize.
Uint8List referenceCell(Uint8List hash, int size) {
  final decoded = thumbhash.thumbHashToRGBA(hash);
  final sourceWidth = decoded.width;
  final sourceHeight = decoded.height;
  final sourceSize = math.min(sourceWidth, sourceHeight);
  final sourceLeft = (sourceWidth - sourceSize) / 2;
  final sourceTop = (sourceHeight - sourceSize) / 2;
  final output = Uint8List(size * size * 4);
  for (var y = 0; y < size; y++) {
    final sy = (sourceTop + ((y + 0.5) * sourceSize / size)).floor().clamp(0, sourceHeight - 1);
    for (var x = 0; x < size; x++) {
      final sx = (sourceLeft + ((x + 0.5) * sourceSize / size)).floor().clamp(0, sourceWidth - 1);
      output.setRange((y * size + x) * 4, (y * size + x) * 4 + 4, decoded.rgba, (sy * sourceWidth + sx) * 4);
    }
  }
  return output;
}

Uint8List _hashBytes(int seed, {required int w, required int h, required bool alpha}) {
  final rnd = math.Random(seed);
  final rgba = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    rgba[i * 4] = rnd.nextInt(256);
    rgba[i * 4 + 1] = rnd.nextInt(256);
    rgba[i * 4 + 2] = rnd.nextInt(256);
    rgba[i * 4 + 3] = alpha ? rnd.nextInt(256) : 255;
  }
  return thumbhash.rgbaToThumbHash(w, h, rgba);
}

void main() {
  test('decodes byte-identically to the package across shapes, alpha and sizes', () {
    var cases = 0;
    for (final shape in [(4, 4), (8, 4), (4, 8), (10, 3), (3, 10), (7, 6)]) {
      for (final alpha in [false, true]) {
        for (var seed = 0; seed < 12; seed++) {
          final hash = _hashBytes(seed, w: shape.$1, h: shape.$2, alpha: alpha);
          for (final size in [4, 8, 16, 32, 48]) {
            final actual = decodeThumbHashCell(hash, size);
            final expected = referenceCell(hash, size);
            expect(actual, hasLength(expected.length));
            var worst = 0;
            for (var i = 0; i < expected.length; i++) {
              final delta = (actual[i] - expected[i]).abs();
              if (delta > worst) {
                worst = delta;
              }
            }
            // The separable form reassociates the DCT sums, so a channel may
            // land one step either side of the package's rounding. Anything
            // beyond that means the sampling grid itself diverged.
            expect(
              worst,
              lessThanOrEqualTo(1),
              reason: 'shape ${shape.$1}x${shape.$2} alpha=$alpha seed=$seed size=$size differed by $worst/255',
            );
            cases++;
          }
        }
      }
    }
    print('verified $cases decode cases within 1/255 of the package');
  });

  test('rejects malformed input the same way', () {
    expect(() => decodeThumbHashCell(Uint8List(3), 32), throwsFormatException);
    expect(() => decodeThumbHashCell(_hashBytes(1, w: 4, h: 4, alpha: false), 0), throwsFormatException);
  });

  test('speedup over the package decoder', () {
    final hash = _hashBytes(7, w: 4, h: 4, alpha: false);
    for (var i = 0; i < 50; i++) {
      referenceCell(hash, 32);
      decodeThumbHashCell(hash, 32);
    }
    const reps = 500;
    final oldSw = Stopwatch()..start();
    for (var i = 0; i < reps; i++) {
      referenceCell(hash, 32);
    }
    oldSw.stop();
    final newSw = Stopwatch()..start();
    for (var i = 0; i < reps; i++) {
      decodeThumbHashCell(hash, 32);
    }
    newSw.stop();
    final oldUs = oldSw.elapsedMicroseconds / reps;
    final newUs = newSw.elapsedMicroseconds / reps;
    print('');
    print('package + resize : ${oldUs.toStringAsFixed(1)} us/hash');
    print('direct cell      : ${newUs.toStringAsFixed(1)} us/hash   ${(oldUs / newUs).toStringAsFixed(1)}x');
    print('');
    // Deliberately loose: this runs in the test runner's JIT, where the ratio is
    // smaller than the AOT build the app actually ships. The AOT figure is 3.2x.
    expect(newUs, lessThan(oldUs), reason: 'the direct decoder must not be slower than the package path');
  });
}
