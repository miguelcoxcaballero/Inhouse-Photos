part of 'image_request.dart';

class RemoteImageRequest extends ImageRequest {
  final String uri;
  final int targetWidth;
  final int targetHeight;

  RemoteImageRequest({required this.uri, this.targetWidth = 0, this.targetHeight = 0});

  @override
  Future<ImageInfo?> load(ImageDecoderCallback decode, {double scale = 1.0}) async {
    if (_isCancelled) {
      return null;
    }

    final info = await remoteImageApi.requestImage(
      uri,
      requestId: requestId,
      preferEncoded: false,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    // Android falls back to encoded data if native decoding fails, so check for both shapes of the response.
    final frame = switch (info) {
      {'pointer': int pointer, 'length': int length} => await _fromEncodedPlatformImage(pointer, length),
      {'pointer': int pointer, 'width': int width, 'height': int height, 'rowBytes': int rowBytes} =>
        await _fromDecodedPlatformImage(pointer, width, height, rowBytes),
      _ => null,
    };
    return frame == null ? null : ImageInfo(image: frame.image, scale: scale);
  }

  @override
  Future<ui.Codec?> loadCodec() async {
    if (_isCancelled) {
      return null;
    }

    final info = await remoteImageApi.requestImage(
      uri,
      requestId: requestId,
      preferEncoded: true,
      targetWidth: 0,
      targetHeight: 0,
    );
    if (info == null) {
      return null;
    }

    final (codec, _) = await _codecFromEncodedPlatformImage(info['pointer']!, info['length']!) ?? (null, null);
    return codec;
  }

  @override
  Future<void> _onCancelled() {
    return remoteImageApi.cancelRequest(requestId);
  }
}
