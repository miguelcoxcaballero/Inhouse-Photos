import 'package:flutter/painting.dart';
import 'package:immich_mobile/domain/models/config/image_config.dart';
import 'package:immich_mobile/presentation/widgets/images/local_image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/thumb_hash_provider.dart';

/// [ImageCache] that uses two caches for small and large images
/// so that a single large image does not evict all small images
final class CustomImageCache implements ImageCache {
  final _thumbhash = ImageCache()..maximumSize = 0;
  final _small = ImageCache();
  final _large = ImageCache()..maximumSize = 5; // Maximum 5 images

  void configure(ImageCacheProfile profile) {
    _small
      ..maximumSize = profile.thumbnailCount
      ..maximumSizeBytes = profile.thumbnailBytes;
    _large
      ..maximumSize = profile.fullImageCount
      ..maximumSizeBytes = profile.fullImageBytes;
  }

  @override
  int get maximumSize => _small.maximumSize + _large.maximumSize;

  @override
  int get maximumSizeBytes => _small.maximumSizeBytes + _large.maximumSizeBytes;

  @override
  set maximumSize(int value) => _small.maximumSize = value;

  @override
  set maximumSizeBytes(int value) => _small.maximumSizeBytes = value;

  @override
  void clear() {
    _small.clear();
    _large.clear();
  }

  @override
  void clearLiveImages() {
    _small.clearLiveImages();
    _large.clearLiveImages();
  }

  /// Gets the cache for the given key
  ImageCache _cacheForKey(Object key) {
    return switch (key) {
      LocalFullImageProvider() || RemoteFullImageProvider() => _large,
      ThumbHashProvider() => _thumbhash,
      _ => _small,
    };
  }

  @override
  bool containsKey(Object key) {
    // [ImmichLocalImageProvider] and [ImmichRemoteImageProvider] are both
    // large size images while the other thumbnail providers are small
    return _cacheForKey(key).containsKey(key);
  }

  @override
  int get currentSize => _small.currentSize + _large.currentSize;

  @override
  int get currentSizeBytes => _small.currentSizeBytes + _large.currentSizeBytes;

  @override
  bool evict(Object key, {bool includeLive = true}) => _cacheForKey(key).evict(key, includeLive: includeLive);

  @override
  int get liveImageCount => _small.liveImageCount + _large.liveImageCount;

  @override
  int get pendingImageCount => _small.pendingImageCount + _large.pendingImageCount;

  @override
  ImageStreamCompleter? putIfAbsent(
    Object key,
    ImageStreamCompleter Function() loader, {
    ImageErrorListener? onError,
  }) => _cacheForKey(key).putIfAbsent(key, loader, onError: onError);

  @override
  ImageCacheStatus statusForKey(Object key) => _cacheForKey(key).statusForKey(key);
}

class ImageCacheProfile {
  final int thumbnailCount;
  final int thumbnailBytes;
  final int fullImageCount;
  final int fullImageBytes;

  const ImageCacheProfile({
    required this.thumbnailCount,
    required this.thumbnailBytes,
    required this.fullImageCount,
    required this.fullImageBytes,
  });
}

/// Thumbnail counts are deliberately far above what the byte budgets allow for
/// a large thumbnail, so that the bytes do the bounding.
///
/// The two limits are not interchangeable, and a count tuned for full-size
/// thumbnails is meaningless in the zoomed-out grid. A tile at forty-eight
/// columns is 26 pixels square, which is 2.7KB decoded, so the old count of 320
/// capped the cache at under a megabyte of a budget that allowed 128 - while one
/// screen at that density wants around five thousand thumbnails. Everything
/// beyond the first 320 was evicted immediately and refetched on the way back.
///
/// At the other end nothing changes: an 80-pixel tile is 25.6KB, so the byte
/// budget still binds first and memory stays where it was.
ImageCacheProfile imageCacheProfileForMode(ImageCacheMode mode) => switch (mode) {
  ImageCacheMode.compact => const ImageCacheProfile(
    thumbnailCount: 3072,
    thumbnailBytes: 64 * 1024 * 1024,
    fullImageCount: 2,
    fullImageBytes: 64 * 1024 * 1024,
  ),
  ImageCacheMode.automatic => const ImageCacheProfile(
    thumbnailCount: 8192,
    thumbnailBytes: 128 * 1024 * 1024,
    fullImageCount: 4,
    fullImageBytes: 128 * 1024 * 1024,
  ),
  ImageCacheMode.performance => const ImageCacheProfile(
    thumbnailCount: 16384,
    thumbnailBytes: 256 * 1024 * 1024,
    fullImageCount: 6,
    fullImageBytes: 256 * 1024 * 1024,
  ),
};

void applyImageCacheMode(ImageCache cache, ImageCacheMode mode) {
  final profile = imageCacheProfileForMode(mode);
  if (cache is CustomImageCache) {
    cache.configure(profile);
    return;
  }
  cache
    ..maximumSize = profile.thumbnailCount
    ..maximumSizeBytes = profile.thumbnailBytes;
}
