// What it costs to turn decoded pixels into images the grid can draw.
//
// A zoomed-out screen wants around eight hundred cells, and each one currently
// becomes its own `ui.Image`. Filling that screen measured flat against every
// in-flight limit tried - eight, sixteen, thirty-two - which says the queue
// forms somewhere that does not care how many callers there are. This isolates
// one candidate with no server, no platform channel and no decoding in it: just
// raw pixels of exactly the size a dense cell decodes to, turned into images the
// way the loader turns them.
//
// If eight hundred of these cost seconds, the per-cell image is the wall and the
// fix is to stop making one per cell. If they cost milliseconds, the wall is the
// fetch and this rules the engine out.
// ignore_for_file: avoid_print

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<ui.Image> _materialise(Uint8List rgba, int size) async {
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('cost of one image per cell, against one image per panel', (tester) async {
    await tester.runAsync(() async {
      // 24px is what a cell decodes to at the densest zoom levels on a 3x screen.
      const cell = 24;
      const cells = 800;
      final pixels = Uint8List(cell * cell * 4);
      for (var i = 0; i < pixels.length; i++) {
        pixels[i] = (i * 7) & 0xFF;
      }

      // Warm the engine so the first call's one-off setup is not counted.
      (await _materialise(pixels, cell)).dispose();

      for (final inFlight in [1, 8, 32]) {
        final clock = Stopwatch()..start();
        var done = 0;
        final images = <ui.Image>[];
        while (done < cells) {
          final batch = <Future<ui.Image>>[];
          for (var i = 0; i < inFlight && done + i < cells; i++) {
            batch.add(_materialise(pixels, cell));
          }
          images.addAll(await Future.wait(batch));
          done += batch.length;
        }
        clock.stop();
        print(
          'MATCOST $cells cells, $inFlight at a time: ${clock.elapsedMilliseconds} ms '
          '(${(clock.elapsedMicroseconds / cells / 1000).toStringAsFixed(2)} ms each)',
        );
        for (final image in images) {
          image.dispose();
        }
      }

      // The alternative, for scale: one panel-sized image instead of 144 cells.
      // A dense panel is 18 columns by 8 rows at 24px, so this is the same
      // pixels arriving as one texture rather than as a hundred and forty-four.
      const panelWidth = 18 * cell;
      const panelHeight = 8 * cell;
      final panelPixels = Uint8List(panelWidth * panelHeight * 4);
      final panelClock = Stopwatch()..start();
      const panels = 6;
      for (var i = 0; i < panels; i++) {
        final buffer = await ui.ImmutableBuffer.fromUint8List(panelPixels);
        final descriptor = ui.ImageDescriptor.raw(
          buffer,
          width: panelWidth,
          height: panelHeight,
          rowBytes: panelWidth * 4,
          pixelFormat: ui.PixelFormat.rgba8888,
        );
        final codec = await descriptor.instantiateCodec();
        (await codec.getNextFrame()).image.dispose();
        codec.dispose();
        descriptor.dispose();
        buffer.dispose();
      }
      panelClock.stop();
      print('MATCOST same pixels as $panels whole panels: ${panelClock.elapsedMilliseconds} ms');
    });
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
