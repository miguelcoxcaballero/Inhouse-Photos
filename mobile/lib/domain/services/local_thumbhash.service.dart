import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:logging/logging.dart';
import 'package:thumbhash/thumbhash.dart' as thumbhash;

/// Generates the blurry preview a local photo needs to appear instantly.
///
/// A remote asset arrives with a ThumbHash from the server, so the grid can
/// paint something the moment a panel appears. A photo that has not been backed
/// up yet has no such thing, and its tile stays blank until a full thumbnail
/// decodes - which is why not-yet-uploaded photos were the ones visibly
/// loading. This fills that gap on device, once per photo, in the background.
///
/// It deliberately does not derive the hash from the thumbnail the grid already
/// decodes. That would mean reading pixels back off the GPU, measured at 7-12ms
/// per call and per call rather than per pixel, which is over a second for a
/// single dense panel. The pixels here come straight from the platform decode
/// and never reach the GPU at all.
class LocalThumbHashService {
  final DriftLocalAssetRepository _repository;
  final Logger _log = Logger('LocalThumbHashService');

  LocalThumbHashService(this._repository);

  /// Longest edge handed to the encoder.
  ///
  /// ThumbHash rejects anything above 100x100, and the hash keeps only a
  /// handful of coefficients, so a larger source buys no detail and costs a
  /// bigger platform decode.
  static const int sourceExtent = 96;

  /// Photos per batch. Small enough that a batch is finished long before it
  /// could hold up anything else, and that the writes stay tiny.
  static const int batchSize = 16;

  /// Gap between batches, so this never occupies the platform channel that the
  /// grid also uses for the thumbnails a person is looking at right now.
  static const Duration betweenBatches = Duration(milliseconds: 400);

  /// Gap after a batch that produced nothing, to avoid spinning on assets the
  /// platform cannot decode.
  static const Duration afterEmptyBatch = Duration(seconds: 5);

  bool _running = false;
  bool _stopped = false;
  int _requestId = 1 << 30;

  /// True while the grid is actively resolving thumbnails a person can see.
  ///
  /// Generation yields to that entirely: an instant preview for a photo further
  /// down the library is worth nothing if producing it delays the photo on
  /// screen.
  static bool Function() foregroundIsBusy = () => false;

  Future<void> start() async {
    if (_running) {
      return;
    }
    _running = true;
    _stopped = false;
    unawaited(_pump());
  }

  void stop() {
    _stopped = true;
    _running = false;
  }

  Future<void> _pump() async {
    try {
      while (!_stopped) {
        if (foregroundIsBusy()) {
          await Future<void>.delayed(betweenBatches);
          continue;
        }
        final pending = await _repository.getAssetsMissingThumbHash(limit: batchSize);
        if (pending.isEmpty) {
          // Nothing left. The partial index makes this check almost free, but
          // there is no point asking often.
          await Future<void>.delayed(afterEmptyBatch);
          continue;
        }

        final generated = <String, String>{};
        for (final asset in pending) {
          if (_stopped) {
            return;
          }
          if (foregroundIsBusy()) {
            break;
          }
          final hash = await generateFor(asset.id, isVideo: asset.isVideo);
          if (hash != null) {
            generated[asset.id] = hash;
          }
        }

        if (generated.isNotEmpty) {
          await _repository.updateThumbHashes(generated);
        }
        // A batch where nothing decoded would otherwise spin over the same rows
        // forever, so back off as if it were empty.
        await Future<void>.delayed(generated.isEmpty ? afterEmptyBatch : betweenBatches);
      }
    } catch (error, stackTrace) {
      _log.warning('Local preview generation stopped', error, stackTrace);
    } finally {
      _running = false;
    }
  }

  /// Decodes one photo small and encodes a ThumbHash from the raw pixels.
  ///
  /// Returns null when the platform cannot produce an image for it, which is
  /// normal for a file that has since been deleted or is not readable.
  Future<String?> generateFor(String assetId, {required bool isVideo}) async {
    final requestId = _requestId++;
    Map<String, int>? info;
    try {
      info = await localImageApi.requestImage(
        assetId,
        requestId: requestId,
        width: sourceExtent,
        height: sourceExtent,
        isVideo: isVideo,
        preferEncoded: false,
      );
    } catch (_) {
      return null;
    }
    if (info == null) {
      return null;
    }

    final address = info['pointer'];
    final width = info['width'];
    final height = info['height'];
    final rowBytes = info['rowBytes'];
    if (address == null || width == null || height == null || rowBytes == null) {
      return null;
    }

    final pointer = Pointer<Uint8>.fromAddress(address);
    try {
      if (width <= 0 || height <= 0) {
        return null;
      }
      final pixels = pointer.asTypedList(rowBytes * height);
      return encodeThumbHash(pixels, width: width, height: height, rowBytes: rowBytes);
    } catch (_) {
      return null;
    } finally {
      // The native side hands over a malloc'd buffer and expects Dart to free
      // it, whatever happens above.
      malloc.free(pointer);
    }
  }
}

/// Encodes a ThumbHash from a raw RGBA buffer.
///
/// Handles the two things a platform decode can hand back that the encoder
/// cannot take: rows padded out to [rowBytes], and an image larger than the
/// 100x100 the encoder accepts.
String? encodeThumbHash(Uint8List pixels, {required int width, required int height, required int rowBytes}) {
  const maxExtent = 100;
  if (width <= 0 || height <= 0 || pixels.length < rowBytes * height) {
    return null;
  }

  // Nearest-neighbour is plenty: the result is about to be reduced to a handful
  // of DCT coefficients, and anything better costs more than the hash is worth.
  final scale = math.max(width / maxExtent, height / maxExtent);
  final targetWidth = scale > 1 ? math.max(1, (width / scale).floor()) : width;
  final targetHeight = scale > 1 ? math.max(1, (height / scale).floor()) : height;

  final packed = Uint8List(targetWidth * targetHeight * 4);
  for (var y = 0; y < targetHeight; y++) {
    final sourceY = scale > 1 ? math.min(height - 1, (y * scale).floor()) : y;
    final sourceRow = sourceY * rowBytes;
    final targetRow = y * targetWidth * 4;
    for (var x = 0; x < targetWidth; x++) {
      final sourceX = scale > 1 ? math.min(width - 1, (x * scale).floor()) : x;
      packed.setRange(targetRow + x * 4, targetRow + x * 4 + 4, pixels, sourceRow + sourceX * 4);
    }
  }

  try {
    return base64Encode(thumbhash.rgbaToThumbHash(targetWidth, targetHeight, packed));
  } catch (_) {
    return null;
  }
}
