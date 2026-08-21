enum BackupQuality { original, storageSaver }

/// Controls how aggressively the backup pipeline uses device and network
/// resources. The selected mode only affects new uploads and can be changed
/// without touching the server or already backed-up assets.
enum BackupSpeedMode { balanced, fast, maximum }

extension BackupSpeedModeProfile on BackupSpeedMode {
  /// Number of compression/file-acquisition workers.
  int get preparationWorkers => switch (this) {
    .balanced => 2,
    .fast => 3,
    .maximum => 4,
  };

  /// Number of concurrent network requests. This is deliberately independent
  /// from preparation workers so the network stays busy while later assets are
  /// being compressed.
  int get uploadWorkers => switch (this) {
    .balanced => 3,
    .fast => 5,
    .maximum => 8,
  };

  /// Prepared files are held on disk, so keeping this bounded prevents a large
  /// library from filling temporary storage while still giving upload workers a
  /// useful read-ahead buffer.
  int get preparedQueueCapacity => uploadWorkers * 2;
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

  const BackupConfig({
    this.enabled = false,
    this.useCellularForVideos = false,
    this.useCellularForPhotos = false,
    this.requireCharging = false,
    this.triggerDelay = 30,
    this.syncAlbums = false,
    this.quality = BackupQuality.storageSaver,
    this.speed = BackupSpeedMode.balanced,
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
  }) => BackupConfig(
    enabled: enabled ?? this.enabled,
    useCellularForVideos: useCellularForVideos ?? this.useCellularForVideos,
    useCellularForPhotos: useCellularForPhotos ?? this.useCellularForPhotos,
    requireCharging: requireCharging ?? this.requireCharging,
    triggerDelay: triggerDelay ?? this.triggerDelay,
    syncAlbums: syncAlbums ?? this.syncAlbums,
    quality: quality ?? this.quality,
    speed: speed ?? this.speed,
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
          other.speed == speed);

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
  );

  @override
  String toString() =>
      'BackupConfig(enabled: $enabled, useCellularForVideos: $useCellularForVideos, useCellularForPhotos: $useCellularForPhotos, requireCharging: $requireCharging, triggerDelay: $triggerDelay, syncAlbums: $syncAlbums, quality: $quality, speed: $speed)';
}
