import 'dart:ui' as ui;
import 'package:flutter/services.dart';

/// Opt-in measurement API. The production gallery uses retained sharp sheets;
/// this native cold-load prototype is not enabled without device evidence.
class ContactSheetPrototype {
  static const _channel = MethodChannel('inhouse.photos/contact-sheet');
  static Future<({ui.Image image, List<int> completed, int nativeMicros})> render(
    List<String> localIds, {
    required int pixels,
    required int columns,
  }) async {
    final result = (await _channel.invokeMapMethod<String, dynamic>('render', {
      'ids': localIds,
      'pixels': pixels,
      'columns': columns,
    }))!;
    final buffer = await ui.ImmutableBuffer.fromUint8List(result['rgba'] as Uint8List);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: result['width'] as int,
      height: result['height'] as int,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    try {
      final codec = await descriptor.instantiateCodec();
      try {
        return (
          image: (await codec.getNextFrame()).image,
          completed: (result['completed'] as List).cast<int>(),
          nativeMicros: result['nativeMicros'] as int,
        );
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
      buffer.dispose();
    }
  }
}
