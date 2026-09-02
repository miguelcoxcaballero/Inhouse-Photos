import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/config/image_config.dart';
import 'package:immich_mobile/utils/cache/custom_image_cache.dart';

void main() {
  test('cache profiles scale monotonically without becoming unbounded', () {
    final compact = imageCacheProfileForMode(ImageCacheMode.compact);
    final automatic = imageCacheProfileForMode(ImageCacheMode.automatic);
    final performance = imageCacheProfileForMode(ImageCacheMode.performance);

    expect(compact.thumbnailCount, lessThan(automatic.thumbnailCount));
    expect(automatic.thumbnailCount, lessThan(performance.thumbnailCount));
    expect(performance.fullImageCount, lessThanOrEqualTo(6));
    expect(performance.thumbnailBytes + performance.fullImageBytes, lessThanOrEqualTo(512 * 1024 * 1024));
  });

  test('the byte budget is what bounds thumbnails, not the count', () {
    // Two different limits, and only one of them is meaningful across zoom
    // levels. A tile at forty-eight columns decodes to 2.7KB, so a count tuned
    // for full-size thumbnails capped the cache at a fraction of the memory it
    // was allowed, while a single screen at that density wants roughly five
    // thousand tiles. Everything past the count was evicted at once and
    // refetched on the way back.
    const denseScreenTiles = 5000;
    for (final mode in [ImageCacheMode.automatic, ImageCacheMode.performance]) {
      expect(
        imageCacheProfileForMode(mode).thumbnailCount,
        greaterThanOrEqualTo(denseScreenTiles),
        reason: '$mode cannot hold one screen of the densest grid',
      );
    }
  });

  test('a large thumbnail still hits the byte budget first', () {
    // The other end has to keep working, and this is what keeps the raised
    // counts from costing memory: an 80-pixel tile is 25.6KB, so for every
    // profile the bytes run out before the count does and the ceiling is
    // unchanged from before.
    const largeTileBytes = 80 * 80 * 4;
    for (final mode in ImageCacheMode.values) {
      final profile = imageCacheProfileForMode(mode);
      expect(
        profile.thumbnailCount * largeTileBytes,
        greaterThan(profile.thumbnailBytes),
        reason: '$mode would let the count bind before its byte budget',
      );
    }
  });
}
