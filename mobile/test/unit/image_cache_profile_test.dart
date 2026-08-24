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
}
