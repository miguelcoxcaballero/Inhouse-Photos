import 'dart:math' as math;

enum BackupQuality { original, storageSaver }

/// Controls how aggressively the backup pipeline uses device and network
/// resources. The selected mode only affects new uploads and can be changed
/// without touching the server or already backed-up assets.
enum BackupSpeedMode { balanced, fast, maximum }

/// Resolved concurrency for one backup run.
///
/// Keeping this as a value object makes the throughput policy deterministic
/// and testable. Worker counts are capped by the number of pending assets, and
/// both queues stay bounded so a large library cannot exhaust memory or file
/// descriptors while the network is busy.
class BackupTransferPlan {
  final int preparationWorkers;
  final int uploadWorkers;
  final int acknowledgementWorkers;
  final int preparedQueueCapacity;
  final int acknowledgementQueueCapacity;

  const BackupTransferPlan({
    required this.preparationWorkers,
    required this.uploadWorkers,
    required this.acknowledgementWorkers,
    required this.preparedQueueCapacity,
    required this.acknowledgementQueueCapacity,
  });

  static const empty = BackupTransferPlan(
    preparationWorkers: 0,
    uploadWorkers: 0,
    acknowledgementWorkers: 0,
    preparedQueueCapacity: 0,
    acknowledgementQueueCapacity: 0,
  );
}

extension BackupSpeedModeProfile on BackupSpeedMode {
  /// Builds an adaptive plan for the current network and remaining library.
  ///
  /// HTTPS request latency is significant when backing up many small photos.
  /// Wi-Fi therefore uses enough concurrent requests to keep the connection
  /// saturated. Metered networks remain deliberately more conservative.
  BackupTransferPlan transferPlan({required bool isUnmetered, required int itemCount}) {
    if (itemCount <= 0) {
      return BackupTransferPlan.empty;
    }

    final uploadLimit = switch (this) {
      .balanced => isUnmetered ? 6 : 3,
      .fast => isUnmetered ? 12 : 6,
      .maximum => isUnmetered ? 24 : 12,
    };
    final preparationLimit = switch (this) {
      .balanced => isUnmetered ? 4 : 2,
      .fast => isUnmetered ? 6 : 3,
      .maximum => isUnmetered ? 8 : 4,
    };
    final acknowledgementLimit = switch (this) {
      .balanced => 2,
      .fast => isUnmetered ? 3 : 2,
      .maximum => isUnmetered ? 6 : 3,
    };

    final uploadWorkers = math.min(itemCount, uploadLimit);
    final preparationWorkers = math.min(itemCount, preparationLimit);
    final acknowledgementWorkers = math.min(itemCount, acknowledgementLimit);

    return BackupTransferPlan(
      preparationWorkers: preparationWorkers,
      uploadWorkers: uploadWorkers,
      acknowledgementWorkers: acknowledgementWorkers,
      // A deeper read-ahead queue prevents slow Android media-provider lookups
      // from starving a fast connection. The queue implementation also caps
      // capacities at 64 as a final safety net.
      preparedQueueCapacity: math.min(64, uploadWorkers * 3),
      acknowledgementQueueCapacity: math.min(64, uploadWorkers * 4),
    );
  }
}

class BackupConfig {
  final bool enabled;
  final bool useCellularForVideos;
  final bool useCellularForPhotos;
  final bool requireCharging;
  final int triggerDelay;
  final bool syncAlbums;
  final BackupQuality quality;
  final BackupSpeedMode speed;
  final int uploadedOriginalBytes;
  final int storedBytes;

  const BackupConfig({
    this.enabled = false,
    this.useCellularForVideos = false,
    this.useCellularForPhotos = false,
    this.requireCharging = false,
    this.triggerDelay = 30,
    this.syncAlbums = false,
    this.quality = BackupQuality.storageSaver,
    this.speed = BackupSpeedMode.maximum,
    this.uploadedOriginalBytes = 0,
    this.storedBytes = 0,
  });

  BackupConfig copyWith({
    bool? enabled,
    bool? useCellularForVideos,
    bool? useCellularForPhotos,
    bool? requireCharging,
    int? triggerDelay,
    bool? syncAlbums,
    BackupQuality? quality,
    BackupSpeedMode? speed,
    int? uploadedOriginalBytes,
    int? storedBytes,
  }) => BackupConfig(
    enabled: enabled ?? this.enabled,
    useCellularForVideos: useCellularForVideos ?? this.useCellularForVideos,
    useCellularForPhotos: useCellularForPhotos ?? this.useCellularForPhotos,
    requireCharging: requireCharging ?? this.requireCharging,
    triggerDelay: triggerDelay ?? this.triggerDelay,
    syncAlbums: syncAlbums ?? this.syncAlbums,
    quality: quality ?? this.quality,
    speed: speed ?? this.speed,
    uploadedOriginalBytes: uploadedOriginalBytes ?? this.uploadedOriginalBytes,
    storedBytes: storedBytes ?? this.storedBytes,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BackupConfig &&
          other.enabled == enabled &&
          other.useCellularForVideos == useCellularForVideos &&
          other.useCellularForPhotos == useCellularForPhotos &&
          other.requireCharging == requireCharging &&
          other.triggerDelay == triggerDelay &&
          other.syncAlbums == syncAlbums &&
          other.quality == quality &&
          other.speed == speed &&
          other.uploadedOriginalBytes == uploadedOriginalBytes &&
          other.storedBytes == storedBytes);

  @override
  int get hashCode => Object.hash(
    enabled,
    useCellularForVideos,
    useCellularForPhotos,
    requireCharging,
    triggerDelay,
    syncAlbums,
    quality,
    speed,
    uploadedOriginalBytes,
    storedBytes,
  );

  @override
  String toString() =>
      'BackupConfig(enabled: $enabled, useCellularForVideos: $useCellularForVideos, useCellularForPhotos: $useCellularForPhotos, requireCharging: $requireCharging, triggerDelay: $triggerDelay, syncAlbums: $syncAlbums, quality: $quality, speed: $speed, uploadedOriginalBytes: $uploadedOriginalBytes, storedBytes: $storedBytes)';
}
