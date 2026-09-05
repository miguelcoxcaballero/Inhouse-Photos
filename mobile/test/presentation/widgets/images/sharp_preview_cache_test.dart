import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/images/sharp_preview_cache.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';

Future<ui.Image> _image(int size) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(const Color(0xffff8000), BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(size, size);
  } finally {
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('warm preview paints immediately at a different grid size, without a provider', (tester) async {
    await tester.runAsync(() async {
      final image = await _image(64);
      sharpPreviewCache.put(image, {'warm': const Rect.fromLTWH(0, 0, 64, 64)});
      image.dispose();
    });
    addTearDown(sharpPreviewCache.clear);
    Future<void> show(double size) => tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: size,
            child: const Thumbnail(previewKey: 'warm'),
          ),
        ),
      ),
    );
    await show(32);
    expect(
      tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .where((widget) => widget.painter.runtimeType.toString() == '_SharpThumbnailPainter'),
      hasLength(1),
    );
    sharpPreviewCache.clear();
    await show(48);
    expect(tester.takeException(), isNull);
    expect(
      tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .where((widget) => widget.painter.runtimeType.toString() == '_SharpThumbnailPainter'),
      hasLength(1),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test('different grids reuse sharp sheet cells without new image decoding', () async {
    final cache = SharpPreviewCache();
    final image = await _image(64);
    cache.put(image, {'a': const Rect.fromLTWH(0, 0, 32, 32), 'b': const Rect.fromLTWH(32, 0, 32, 32)});
    image.dispose();
    final reordered = cache.take(['b', 'a', 'missing']);
    expect(reordered.cells.keys, [0, 1]);
    expect(reordered.cells[0]!.source.left, 32);
    expect(identical(reordered.cells[0]!.image, reordered.cells[1]!.image), isTrue);
    cache.clear();
    // Eviction cannot invalidate textures still displayed by a widget.
    expect(await reordered.cells[0]!.image.toByteData(), isNotNull);
    reordered.dispose();
    expect(cache.bytes, 0);
  });
  test('coarser zoom cannot overwrite a sharp thumbnail and memory is bounded', () async {
    final cache = SharpPreviewCache(maximumBytes: 64 * 64 * 4);
    addTearDown(cache.clear);
    final big = await _image(64);
    final small = await _image(16);
    cache.put(big, {'a': const Rect.fromLTWH(0, 0, 64, 64)});
    cache.put(small, {'a': const Rect.fromLTWH(0, 0, 16, 16)});
    final lease = cache.take(['a']);
    expect(lease.cells[0]!.pixels, 64);
    lease.dispose();
    cache.put(big, {'b': const Rect.fromLTWH(0, 0, 64, 64)});
    expect(cache.bytes, lessThanOrEqualTo(cache.maximumBytes));
    final gone = cache.take(['a']);
    expect(gone.cells, isEmpty);
    gone.dispose();
    big.dispose();
    small.dispose();
  });
}
