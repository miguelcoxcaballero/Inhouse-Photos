import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_layout_transition.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('batched sprites retain their positions when resized and reordered', () async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    const colors = [ui.Color(0xFFFF0000), ui.Color(0xFF00FF00), ui.Color(0xFF0000FF), ui.Color(0xFFFFFF00)];
    for (var index = 0; index < 4; index++) {
      canvas.drawRect(ui.Rect.fromLTWH((index % 2) * 10, (index ~/ 2) * 10, 10, 10), ui.Paint()..color = colors[index]);
    }
    final picture = recorder.endRecording();
    final sheet = await picture.toImage(20, 20);
    picture.dispose();
    addTearDown(sheet.dispose);

    for (final size in [5.0, 10.0, 20.0]) {
      final transforms = Float32List(16);
      final sources = Float32List(16);
      for (var index = 0; index < 4; index++) {
        final offset = index * 4;
        sources[offset] = (index % 2) * 10;
        sources[offset + 1] = (index ~/ 2) * 10;
        sources[offset + 2] = sources[offset] + 10;
        sources[offset + 3] = sources[offset + 1] + 10;
        writeTimelineSpriteTransform(transforms, offset, 10, 10, ui.Rect.fromLTWH((3 - index) * size, 0, size, size));
      }
      final outputRecorder = ui.PictureRecorder();
      ui.Canvas(outputRecorder).drawRawAtlas(sheet, transforms, sources, null, null, null, ui.Paint());
      final outputPicture = outputRecorder.endRecording();
      final output = await outputPicture.toImage((size * 4).toInt(), size.toInt());
      outputPicture.dispose();
      final bytes = (await output.toByteData())!;
      for (var index = 0; index < 4; index++) {
        final x = ((3 - index) * size + size / 2).floor();
        final y = (size / 2).floor();
        final offset = (y * output.width + x) * 4;
        final argb = colors[index].toARGB32();
        expect(bytes.getUint8(offset), (argb >> 16) & 255);
        expect(bytes.getUint8(offset + 1), (argb >> 8) & 255);
        expect(bytes.getUint8(offset + 2), argb & 255);
        expect(bytes.getUint8(offset + 3), 255);
      }
      output.dispose();
    }
  });
}
