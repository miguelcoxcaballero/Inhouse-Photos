// What a resolution cap actually costs visually at dense zoom levels.
//
// At forty-eight columns a tile is about thirty physical pixels. Fetching and
// compositing a full-resolution thumbnail for each one is what puts raster past
// the frame budget, and the question is how much of that resolution can be given
// back without it being visible. "Imperceptible" needs a number rather than an
// opinion, so this renders the same photo at native cell size and at a series of
// caps, upscales each back the way the painter does, and reports how far the
// pixels actually move.
// ignore_for_file: avoid_print

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// A stand-in photo with the spatial structure a photograph actually has.
///
/// The first version of this drew one random dot per output pixel, which made
/// every cap look identical - white noise has no structure to preserve, so any
/// downscale destroys all of it equally and the measurement could not tell 88%
/// from 50%. Photographs are dominated by low and mid frequencies with edges,
/// so that is what this builds: broad tonal regions, curved and straight edges,
/// and texture at a scale of several pixels rather than one.
Future<ui.Image> _detailedPhoto(int size) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final rnd = math.Random(7);

  // Broad tonal ground, the way a sky or a wall behaves.
  canvas.drawRect(
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(size.toDouble(), size.toDouble()),
        const [Color(0xFF2C5A78), Color(0xFFD8C6A8)],
      ),
  );
  // Subject-sized regions.
  for (var i = 0; i < 5; i++) {
    canvas.drawCircle(
      Offset(rnd.nextDouble() * size, rnd.nextDouble() * size),
      size * (0.15 + rnd.nextDouble() * 0.2),
      Paint()..color = Color.fromARGB(200, rnd.nextInt(256), rnd.nextInt(256), rnd.nextInt(256)),
    );
  }
  // Edges, which is what a downscale visibly softens first.
  for (var i = 0; i < 8; i++) {
    canvas.drawRect(
      Rect.fromLTWH(rnd.nextDouble() * size, rnd.nextDouble() * size, size * 0.3, size * 0.02),
      Paint()..color = Color.fromARGB(255, rnd.nextInt(256), rnd.nextInt(256), rnd.nextInt(256)),
    );
  }
  // Texture at a realistic scale: features several output pixels across, not
  // one, so there is detail a cap can plausibly preserve or lose.
  final feature = math.max(2.0, size / 24);
  for (var i = 0; i < 120; i++) {
    canvas.drawCircle(
      Offset(rnd.nextDouble() * size, rnd.nextDouble() * size),
      feature * (0.5 + rnd.nextDouble()),
      Paint()..color = Color.fromARGB(120, rnd.nextInt(256), rnd.nextInt(256), rnd.nextInt(256)),
    );
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  picture.dispose();
  return image;
}

/// Draws [source] into a [size]x[size] target the way the grid's painter does.
Future<Uint8List> _renderAt(ui.Image source, int size) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawImageRect(
    source,
    Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..filterQuality = FilterQuality.low,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  return data!.buffer.asUint8List();
}

({double mean, int worst}) _difference(Uint8List a, Uint8List b) {
  var total = 0;
  var worst = 0;
  var samples = 0;
  for (var i = 0; i < a.length; i += 4) {
    for (var channel = 0; channel < 3; channel++) {
      final delta = (a[i + channel] - b[i + channel]).abs();
      total += delta;
      if (delta > worst) {
        worst = delta;
      }
      samples++;
    }
  }
  return (mean: total / samples, worst: worst);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('how much resolution a dense tile can give back before it shows', (tester) async {
    await tester.runAsync(() async {
      // Physical cell sizes the dense levels actually use on a 1440px screen.
      for (final cell in [30, 40, 60]) {
        // The source is far larger than the cell, standing in for the real
        // photo the thumbnail is derived from.
        final source = await _detailedPhoto(cell * 8);
        final native = await _renderAt(source, cell);

        final report = StringBuffer('RESCAP cell ${cell}px  ');
        for (final factor in [0.875, 0.75, 0.667, 0.5]) {
          final capped = math.max(8, (cell * factor).round());
          // Decode at the capped size, then let the painter scale it up to the
          // cell, which is exactly what a cap would do in the grid.
          final small = await _renderAt(source, capped);
          final smallImage = await _imageFrom(small, capped);
          final upscaled = await _renderAt(smallImage, cell);
          smallImage.dispose();

          final diff = _difference(native, upscaled);
          final pixelsSaved = 1 - (capped * capped) / (cell * cell);
          report.write(
            '| ${capped}px (${(factor * 100).round()}%) mean ${diff.mean.toStringAsFixed(1)} '
            'worst ${diff.worst} saves ${(pixelsSaved * 100).round()}% ',
          );
        }
        print(report.toString());
        source.dispose();
      }
    });
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 5)));
}

Future<ui.Image> _imageFrom(Uint8List rgba, int size) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: size,
    height: size,
    rowBytes: size * 4,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return frame.image;
}
