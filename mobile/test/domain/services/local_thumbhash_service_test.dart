import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/local_thumbhash.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:thumbhash/thumbhash.dart' as thumbhash;

import '../../infrastructure/repository.mock.dart';

/// An RGBA buffer whose rows are padded out to [rowBytes], the way a platform
/// decode hands them over.
Uint8List _buffer({required int width, required int height, required int rowBytes}) {
  final pixels = Uint8List(rowBytes * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final offset = y * rowBytes + x * 4;
      pixels[offset] = (x * 255 ~/ width);
      pixels[offset + 1] = (y * 255 ~/ height);
      pixels[offset + 2] = 128;
      pixels[offset + 3] = 255;
    }
    // Padding left as zeroes; reading it as image data would corrupt the hash.
    for (var pad = width * 4; pad < rowBytes; pad++) {
      pixels[y * rowBytes + pad] = 0;
    }
  }
  return pixels;
}

void main() {
  test('encodes a tightly packed buffer', () {
    final hash = encodeThumbHash(_buffer(width: 64, height: 64, rowBytes: 64 * 4), width: 64, height: 64, rowBytes: 64 * 4);
    expect(hash, isNotNull);
    final decoded = thumbhash.thumbHashToRGBA(base64Decode(hash!));
    expect(decoded.width, greaterThan(0));
    expect(decoded.height, greaterThan(0));
  });

  test('row padding is skipped rather than read as pixels', () {
    // A platform decode commonly pads each row. Treating the padding as image
    // data shifts every row and produces a hash of something that is not the
    // photo, so the padded and unpadded forms of one image must agree.
    const width = 40;
    const height = 30;
    final packed = _buffer(width: width, height: height, rowBytes: width * 4);
    final padded = _buffer(width: width, height: height, rowBytes: width * 4 + 48);

    final fromPacked = encodeThumbHash(packed, width: width, height: height, rowBytes: width * 4);
    final fromPadded = encodeThumbHash(padded, width: width, height: height, rowBytes: width * 4 + 48);

    expect(fromPacked, isNotNull);
    expect(fromPadded, fromPacked, reason: 'padding must not shift the image');
  });

  test('downscales past the encoder limit instead of failing', () {
    // ThumbHash rejects anything above 100x100, and twelve columns decodes at
    // 120px, so this path is reachable in normal use rather than exceptional.
    const width = 240;
    const height = 180;
    final hash = encodeThumbHash(
      _buffer(width: width, height: height, rowBytes: width * 4),
      width: width,
      height: height,
      rowBytes: width * 4,
    );
    expect(hash, isNotNull);
    expect(() => thumbhash.thumbHashToRGBA(base64Decode(hash!)), returnsNormally);
  });

  test('refuses input it cannot trust rather than writing a wrong preview', () {
    expect(encodeThumbHash(Uint8List(0), width: 0, height: 0, rowBytes: 0), isNull);
    expect(encodeThumbHash(Uint8List(16), width: 8, height: 8, rowBytes: 32), isNull, reason: 'buffer shorter than declared');
  });

  test('a landscape photo keeps its orientation through the hash', () {
    final hash = encodeThumbHash(
      _buffer(width: 120, height: 60, rowBytes: 120 * 4),
      width: 120,
      height: 60,
      rowBytes: 120 * 4,
    );
    final decoded = thumbhash.thumbHashToRGBA(base64Decode(hash!));
    expect(decoded.width, greaterThan(decoded.height));
  });

  group('throttling', () {
    late MockDriftLocalAssetRepository repository;

    setUp(() {
      repository = MockDriftLocalAssetRepository();
      LocalThumbHashService.foregroundIsBusy = () => false;
    });

    tearDown(() => LocalThumbHashService.foregroundIsBusy = () => false);

    test('does not touch the database while the grid is loading what a person can see', () async {
      // Generating a preview for a photo further down the library is worth
      // nothing if it delays the photo on screen, so the whole pass stands
      // aside - it does not merely lower its priority.
      LocalThumbHashService.foregroundIsBusy = () => true;
      final service = LocalThumbHashService(repository);
      addTearDown(service.stop);

      await service.start();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      service.stop();

      verifyNever(() => repository.getAssetsMissingThumbHash(limit: any(named: 'limit')));
    });

    test('asks for work in bounded batches once the grid is idle', () async {
      when(
        () => repository.getAssetsMissingThumbHash(limit: any(named: 'limit')),
      ).thenAnswer((_) async => <({String id, bool isVideo})>[]);

      final service = LocalThumbHashService(repository);
      addTearDown(service.stop);
      await service.start();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      service.stop();

      final captured = verify(
        () => repository.getAssetsMissingThumbHash(limit: captureAny(named: 'limit')),
      ).captured;
      expect(captured, isNotEmpty);
      expect(captured.first, LocalThumbHashService.batchSize);
      // An empty backlog must back off rather than spin on the same query.
      expect(captured.length, lessThan(5));
    });

    test('stops for good once told to', () async {
      when(
        () => repository.getAssetsMissingThumbHash(limit: any(named: 'limit')),
      ).thenAnswer((_) async => <({String id, bool isVideo})>[]);

      final service = LocalThumbHashService(repository);
      await service.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      service.stop();
      final afterStop = verify(
        () => repository.getAssetsMissingThumbHash(limit: any(named: 'limit')),
      ).callCount;

      await Future<void>.delayed(const Duration(milliseconds: 300));
      // The verify above marked everything seen so far, so anything here would
      // be a query the service made after it was told to stop.
      verifyNever(() => repository.getAssetsMissingThumbHash(limit: any(named: 'limit')));
      expect(afterStop, greaterThan(0), reason: 'it must have been running before it was stopped');
    });
  });
}
