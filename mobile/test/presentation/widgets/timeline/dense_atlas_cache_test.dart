import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment.model.dart';

Future<ui.Image> _image(int size) async {
  final pixels = Uint8List(size * size * 4);
  for (var i = 0; i < pixels.length; i++) {
    pixels[i] = i % 256;
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
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
  test('one texture held under two keys is charged once', () async {
    // A finished panel is stored under both its position and its content, and
    // `clone` shares a single texture between them. Charging for both halved
    // the cache's real capacity, so scrolling back over recent panels evicted
    // them and refetched every thumbnail instead of reading memory.
    final cache = DenseRowAtlasCache();
    addTearDown(cache.clear);
    final atlas = await _image(64);
    addTearDown(atlas.dispose);
    const bytes = 64 * 64 * 4;

    cache.put('slot', atlas, signature: 'sig');
    expect(cache.accountedBytes, bytes);

    cache.put('content', atlas, signature: 'sig');
    expect(cache.accountedBytes, bytes, reason: 'the second key shares the first key texture');

    final distinct = await _image(64);
    addTearDown(distinct.dispose);
    cache.put('other', distinct, signature: 'other');
    expect(cache.accountedBytes, bytes * 2, reason: 'a genuinely different texture still costs its own bytes');
  });

  test('dropping one of two keys keeps the texture accounted, dropping the last releases it', () async {
    final cache = DenseRowAtlasCache();
    addTearDown(cache.clear);
    final atlas = await _image(32);
    addTearDown(atlas.dispose);
    const bytes = 32 * 32 * 4;

    cache.put('slot', atlas, signature: 'sig');
    cache.put('content', atlas, signature: 'sig');
    expect(cache.accountedBytes, bytes);

    // Overwriting one key with an unrelated texture must not refund bytes the
    // other key is still holding.
    final replacement = await _image(32);
    addTearDown(replacement.dispose);
    cache.put('slot', replacement, signature: 'new');
    expect(cache.accountedBytes, bytes * 2);
  });
}
