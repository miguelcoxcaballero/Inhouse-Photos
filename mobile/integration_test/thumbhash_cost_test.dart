// What it would cost to give a local photo the instant placeholder that remote
// photos already get.
//
// Remote assets carry a server-generated ThumbHash, so the grid can paint a
// blurry preview the moment a panel appears. Local ones carry nothing, so their
// cells stay flat until a real thumbnail decodes - which is why not-yet-backed-up
// photos are the ones visibly loading. Deriving a ThumbHash from the thumbnail
// the grid already decodes would close that gap, but only if reading the pixels
// back and encoding them is cheap enough to do once per photo.
//
// It is not. Measured on device: the readback alone costs 7-12ms and the cost
// is per call, not per pixel - a 26px thumbnail is no cheaper than an 80px one,
// because it is a GPU synchronisation, not a copy. At 144 cells that is over a
// second per panel. Any real fix has to take the pixels from the platform
// decode before they ever reach the GPU, which is a different code path
// entirely. This test exists so that conclusion is not re-derived by guesswork.
// ignore_for_file: avoid_print

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:thumbhash/thumbhash.dart' as thumbhash;

Future<ui.Image> _thumbnail(int size) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..color = const Color(0xFF3A7BD5),
  );
  for (var i = 0; i < 12; i++) {
    canvas.drawCircle(
      Offset(size * ((i * 7) % 10) / 10, size * ((i * 3) % 10) / 10),
      size / 12,
      Paint()..color = Color.fromARGB(255, (i * 40) % 256, 255 - (i * 20) % 256, (i * 13) % 256),
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  picture.dispose();
  return image;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('cost of deriving a ThumbHash from a decoded thumbnail', (tester) async {
    await tester.runAsync(() async {
      // The sizes the dense grid actually decodes at: 26px at forty-eight
      // columns, 80px at eighteen. ThumbHash's encoder rejects anything over
      // 100x100, so twelve columns (120px) would need a downscale first - one
      // more reason this cannot simply be bolted onto the decode path.
      for (final size in [26, 80]) {
        final image = await _thumbnail(size);

        // Readback, which is the part that could be expensive: these pixels
        // live on the GPU.
        final warmData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final rgba = warmData!.buffer.asUint8List();

        const reps = 30;
        final readSw = Stopwatch()..start();
        for (var i = 0; i < reps; i++) {
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        }
        readSw.stop();

        // ThumbHash wants a small input; the encoder is defined for up to 100px.
        final encodeSw = Stopwatch()..start();
        for (var i = 0; i < reps; i++) {
          thumbhash.rgbaToThumbHash(size, size, rgba);
        }
        encodeSw.stop();

        final readUs = readSw.elapsedMicroseconds / reps;
        final encodeUs = encodeSw.elapsedMicroseconds / reps;
        print(
          'THCOST ${size}px  readback ${readUs.toStringAsFixed(0)}us  '
          'encode ${encodeUs.toStringAsFixed(0)}us  total ${(readUs + encodeUs).toStringAsFixed(0)}us  '
          '=> 144-cell panel ${((readUs + encodeUs) * 144 / 1000).toStringAsFixed(0)}ms',
        );
        image.dispose();
      }
    });
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
