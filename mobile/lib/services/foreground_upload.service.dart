import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/asset_metadata.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart' hide AssetVisibility;
import 'package:immich_mobile/domain/models/config/backup_config.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/network_capability_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/extensions/translate_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart' show PMProgressHandler;

/// Callbacks for upload progress and status updates
class UploadCallbacks {
  final void Function(String id, String filename, int bytes, int totalBytes)? onProgress;
  final void Function(String id, String filename, double progress, int originalBytes, int? preparedBytes)?
  onPreparationProgress;
  final FutureOr<void> Function(String localId, String remoteId)? onSuccess;
  final void Function(String id, String errorMessage)? onError;
  final void Function(String id, double progress)? onICloudProgress;

  const UploadCallbacks({
    this.onProgress,
    this.onPreparationProgress,
    this.onSuccess,
    this.onError,
    this.onICloudProgress,
  });
}

class _PreparedAsset {
  final LocalAsset asset;
  final File file;
  final String originalFileName;
  final Map<String, String> fields;
  final bool isLivePhoto;
  final File? livePhotoFile;
  final File? temporaryFile;
  final File? temporaryLivePhotoFile;
  final File? sourceFile;
  final File? sourceLivePhotoFile;

  const _PreparedAsset({
    required this.asset,
    required this.file,
    required this.originalFileName,
    required this.fields,
    required this.isLivePhoto,
    required this.livePhotoFile,
    required this.temporaryFile,
    required this.temporaryLivePhotoFile,
    required this.sourceFile,
    required this.sourceLivePhotoFile,
  });
}

class _UploadAcknowledgement {
  final _PreparedAsset item;
  final String remoteAssetId;

  const _UploadAcknowledgement(this.item, this.remoteAssetId);
}

/// A small async queue with disk-safe back pressure. [close] stops producers
/// but permits consumers to drain items that were already prepared.
class _BoundedAsyncQueue<T> {
  final int capacity;
  final Queue<T> _items = Queue<T>();
  final Queue<Completer<T?>> _readers = Queue<Completer<T?>>();
  final Queue<Completer<void>> _writers = Queue<Completer<void>>();
  bool _closed = false;

  _BoundedAsyncQueue(int capacity) : capacity = capacity < 1 ? 1 : (capacity > 64 ? 64 : capacity);

  Future<bool> add(T item) async {
    while (!_closed && _items.length >= capacity && _readers.isEmpty) {
      final writer = Completer<void>();
      _writers.add(writer);
      await writer.future;
    }
    if (_closed) return false;

    if (_readers.isNotEmpty) {
      _readers.removeFirst().complete(item);
    } else {
      _items.addLast(item);
    }
    return true;
  }

  Future<T?> take() {
    if (_items.isNotEmpty) {
      final item = _items.removeFirst();
      if (_writers.isNotEmpty) _writers.removeFirst().complete();
      return Future<T?>.value(item);
    }
    if (_closed) return Future<T?>.value();
    final reader = Completer<T?>();
    _readers.add(reader);
    return reader.future;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    while (_writers.isNotEmpty) {
      _writers.removeFirst().complete();
    }
    while (_readers.isNotEmpty) {
      _readers.removeFirst().complete(null);
    }
  }
}

final foregroundUploadServiceProvider = Provider((ref) {
  return ForegroundUploadService(
    ref.watch(uploadRepositoryProvider),
    ref.watch(storageRepositoryProvider),
    ref.watch(backupRepositoryProvider),
    ref.watch(connectivityApiProvider),
    ref.watch(assetMediaRepositoryProvider),
  );
});

/// Service for handling foreground HTTP uploads
///
/// This service handles synchronous uploads using HTTP client with
/// concurrent worker pools. Used for manual backups, auto backups
/// (foreground mode), and share intent uploads.
class ForegroundUploadService {
  ForegroundUploadService(
    this._uploadRepository,
    this._storageRepository,
    this._backupRepository,
    this._connectivityApi,
    this._assetMediaRepository,
  );

  final UploadRepository _uploadRepository;
  final StorageRepository _storageRepository;
  final DriftBackupRepository _backupRepository;
  final ConnectivityApi _connectivityApi;
  final AssetMediaRepository _assetMediaRepository;
  final Logger _logger = Logger('ForegroundUploadService');

  bool shouldAbortUpload = false;

  Future<({int total, int remainder, int processing})> getBackupCounts(String userId) {
    return _backupRepository.getAllCounts(userId);
  }

  Future<List<LocalAsset>> getBackupCandidates(String userId, {bool onlyHashed = true}) {
    return _backupRepository.getCandidates(userId, onlyHashed: onlyHashed);
  }

  /// Bulk upload of backup candidates from selected albums
  Future<void> uploadCandidates(
    String userId,
    Completer<void> cancelToken, {
    UploadCallbacks callbacks = const UploadCallbacks(),
    bool useSequentialUpload = false,
  }) async {
    final candidates = await _backupRepository.getCandidates(userId);
    if (candidates.isEmpty) {
      return;
    }

    final networkCapabilities = await _connectivityApi.getCapabilities();
    final hasWifi = networkCapabilities.isUnmetered;
    _logger.info('Network capabilities: $networkCapabilities, hasWifi/isUnmetered: $hasWifi');

    if (useSequentialUpload) {
      await _uploadSequentially(items: candidates, cancelToken: cancelToken, hasWifi: hasWifi, callbacks: callbacks);
    } else {
      await _uploadWithPipeline(
        items: candidates,
        cancelToken: cancelToken,
        shouldSkip: (asset) {
          final requireWifi = _shouldRequireWiFi(asset);
          return requireWifi && !hasWifi;
        },
        callbacks: callbacks,
      );
    }
  }

  /// Upload candidates through three independent bounded stages. The former
  /// worker pool compressed, uploaded and acknowledged one asset at a time,
  /// leaving the network idle whenever a worker was preparing media or writing
  /// local state. Keeping those stages separate gives the uploader enough
  /// read-ahead to keep the connection saturated without filling disk storage.
  Future<void> _uploadWithPipeline({
    required List<LocalAsset> items,
    required Completer<void>? cancelToken,
    required bool Function(LocalAsset) shouldSkip,
    required UploadCallbacks callbacks,
  }) async {
    await _storageRepository.clearCache();
    shouldAbortUpload = false;

    final speed = SettingsRepository.instance.appConfig.backup.speed;
    final prepared = _BoundedAsyncQueue<_PreparedAsset>(speed.preparedQueueCapacity);
    final acknowledgements = _BoundedAsyncQueue<_UploadAcknowledgement>(speed.uploadWorkers * 2);
    var currentIndex = 0;

    // Wake producers blocked on a full preparation queue. Existing uploads are
    // allowed to receive their cancellation signal and every temporary file is
    // still cleaned up by its owning worker.
    cancelToken?.future.whenComplete(prepared.close);

    LocalAsset? nextAsset() {
      if (shouldAbortUpload || (cancelToken?.isCompleted ?? false) || currentIndex >= items.length) {
        return null;
      }
      return items[currentIndex++];
    }

    Future<void> prepareWorker() async {
      while (true) {
        final asset = nextAsset();
        if (asset == null) return;
        if (shouldSkip(asset)) continue;

        final item = await _prepareAsset(asset, callbacks: callbacks);
        if (item == null) continue;
        if (!await prepared.add(item)) {
          await _cleanupPreparedAsset(item);
          return;
        }
      }
    }

    Future<void> uploadWorker() async {
      while (true) {
        final item = await prepared.take();
        if (item == null) return;
        if (shouldAbortUpload || (cancelToken?.isCompleted ?? false)) {
          await _cleanupPreparedAsset(item);
          continue;
        }

        final acknowledgement = await _uploadPreparedAsset(item, cancelToken, callbacks: callbacks);
        if (acknowledgement == null) {
          await _cleanupPreparedAsset(item);
          continue;
        }
        if (!await acknowledgements.add(acknowledgement)) {
          await _cleanupPreparedAsset(item);
        }
      }
    }

    Future<void> acknowledgementWorker() async {
      while (true) {
        final acknowledgement = await acknowledgements.take();
        if (acknowledgement == null) return;
        try {
          final onSuccess = callbacks.onSuccess;
          if (onSuccess != null) {
            await Future<void>.value(onSuccess(acknowledgement.item.asset.localId!, acknowledgement.remoteAssetId));
          }
        } catch (error, stackTrace) {
          _logger.severe(() => 'Error recording uploaded asset: $error', stackTrace);
          callbacks.onError?.call(acknowledgement.item.asset.localId!, error.toString());
        } finally {
          await _cleanupPreparedAsset(acknowledgement.item);
        }
      }
    }

    final preparationWorkers = List.generate(speed.preparationWorkers, (_) => prepareWorker());
    final uploadWorkers = List.generate(speed.uploadWorkers, (_) => uploadWorker());
    final acknowledgementWorkers = List.generate(2, (_) => acknowledgementWorker());

    await Future.wait(preparationWorkers);
    prepared.close();
    await Future.wait(uploadWorkers);
    acknowledgements.close();
    await Future.wait(acknowledgementWorkers);
  }

  /// Sequential upload - used for background isolate where concurrent HTTP clients may cause issues
  Future<void> _uploadSequentially({
    required List<LocalAsset> items,
    required Completer<void> cancelToken,
    required bool hasWifi,
    required UploadCallbacks callbacks,
  }) async {
    await _storageRepository.clearCache();
    shouldAbortUpload = false;

    for (final asset in items) {
      if (shouldAbortUpload || cancelToken.isCompleted) {
        break;
      }

      final requireWifi = _shouldRequireWiFi(asset);
      if (requireWifi && !hasWifi) {
        _logger.warning('Skipping upload for ${asset.id} because it requires WiFi');
        continue;
      }

      await uploadSingleAsset(asset, cancelToken, callbacks: callbacks);
    }
  }

  /// Manually upload picked local assets
  Future<void> uploadManual(
    List<LocalAsset> localAssets, {
    Completer<void>? cancelToken,
    UploadCallbacks callbacks = const UploadCallbacks(),
  }) async {
    if (localAssets.isEmpty) {
      return;
    }

    await _executeWithWorkerPool<LocalAsset>(
      items: localAssets,
      cancelToken: cancelToken,
      processItem: (asset) => uploadSingleAsset(asset, cancelToken, callbacks: callbacks),
    );
  }

  /// Upload files from shared intent
  Future<void> uploadShareIntent(
    List<File> files, {
    Completer<void>? cancelToken,
    void Function(String fileId, int bytes, int totalBytes)? onProgress,
    void Function(String fileId, String remoteAssetId)? onSuccess,
    void Function(String fileId, String errorMessage)? onError,
  }) async {
    if (files.isEmpty) {
      return;
    }
    await _executeWithWorkerPool<File>(
      items: files,
      cancelToken: cancelToken,
      processItem: (file) async {
        final fileId = p.hash(file.path).toString();

        final result = await _uploadSingleFile(
          file,
          deviceAssetId: fileId,
          cancelToken: cancelToken,
          onProgress: (bytes, totalBytes) => onProgress?.call(fileId, bytes, totalBytes),
        );

        if (result.isSuccess) {
          onSuccess?.call(fileId, result.remoteAssetId!);
        } else if (!result.isCancelled && result.errorMessage != null) {
          onError?.call(fileId, result.errorMessage!);
        }
      },
    );
  }

  void cancel() {
    shouldAbortUpload = true;
  }

  /// Generic worker pool for concurrent uploads
  ///
  /// [items] - List of items to process
  /// [cancelToken] - Token to cancel the operation
  /// [processItem] - Function to process each item with an HTTP client
  /// [shouldSkip] - Optional function to skip items (e.g., WiFi requirement check)
  /// [concurrentWorkers] - Number of concurrent workers (default: 3)
  Future<void> _executeWithWorkerPool<T>({
    required List<T> items,
    required Completer<void>? cancelToken,
    required Future<void> Function(T item) processItem,
    bool Function(T item)? shouldSkip,
    int concurrentWorkers = 3,
  }) async {
    await _storageRepository.clearCache();
    shouldAbortUpload = false;

    int currentIndex = 0;

    Future<void> worker() async {
      while (true) {
        if (shouldAbortUpload || (cancelToken != null && cancelToken.isCompleted)) {
          break;
        }

        final index = currentIndex;
        if (index >= items.length) {
          break;
        }
        currentIndex++;

        final item = items[index];

        if (shouldSkip?.call(item) ?? false) {
          continue;
        }

        await processItem(item);
      }
    }

    final workerFutures = <Future<void>>[];
    for (int i = 0; i < concurrentWorkers; i++) {
      workerFutures.add(worker());
    }

    await Future.wait(workerFutures);
  }

  @visibleForTesting
  Future<void> uploadSingleAsset(
    LocalAsset asset,
    Completer<void>? cancelToken, {
    required UploadCallbacks callbacks,
  }) async {
    final item = await _prepareAsset(asset, callbacks: callbacks);
    if (item == null) return;

    try {
      final acknowledgement = await _uploadPreparedAsset(item, cancelToken, callbacks: callbacks);
      if (acknowledgement != null) {
        final onSuccess = callbacks.onSuccess;
        if (onSuccess != null) {
          await Future<void>.value(onSuccess(acknowledgement.item.asset.localId!, acknowledgement.remoteAssetId));
        }
      }
    } finally {
      await _cleanupPreparedAsset(item);
    }
  }

  Future<_PreparedAsset?> _prepareAsset(LocalAsset asset, {required UploadCallbacks callbacks}) async {
    File? file;
    File? livePhotoFile;
    File? sourceFile;
    File? sourceLivePhotoFile;
    File? temporaryFile;
    File? temporaryLivePhotoFile;

    try {
      final entity = await _storageRepository.getAssetEntityForAsset(asset);
      if (entity == null) {
        callbacks.onError?.call(
          asset.localId!,
          CurrentPlatform.isAndroid ? "asset_not_found_on_device_android".t() : "asset_not_found_on_device_ios".t(),
        );
        return null;
      }

      final isAvailableLocally = await _storageRepository.isAssetAvailableLocally(asset.id);

      if (!isAvailableLocally && CurrentPlatform.isIOS) {
        _logger.info("Loading iCloud asset ${asset.id} - ${asset.name}");

        // Create progress handler for iCloud download
        PMProgressHandler? progressHandler;
        StreamSubscription? progressSubscription;

        progressHandler = PMProgressHandler();
        progressSubscription = progressHandler.stream.listen((event) {
          callbacks.onICloudProgress?.call(asset.localId!, event.progress);
        });

        try {
          file = await _storageRepository.loadFileFromCloud(asset.id, progressHandler: progressHandler);
          if (entity.isLivePhoto) {
            livePhotoFile = await _storageRepository.loadMotionFileFromCloud(
              asset.id,
              progressHandler: progressHandler,
            );
          }
        } finally {
          await progressSubscription.cancel();
        }
      } else {
        // Get files locally
        file = await _storageRepository.getFileForAsset(asset.id);
        if (file == null) {
          _logger.warning("Failed to get file ${asset.id} - ${asset.name}");
          callbacks.onError?.call(
            asset.localId!,
            CurrentPlatform.isAndroid ? "asset_not_found_on_device_android".t() : "asset_not_found_on_device_ios".t(),
          );
          return null;
        }

        // For live photos, get the motion video file
        if (entity.isLivePhoto) {
          livePhotoFile = await _storageRepository.getMotionFileForAsset(asset);
          if (livePhotoFile == null) {
            _logger.warning("Failed to obtain motion part of the livePhoto - ${asset.name}");
            callbacks.onError?.call(
              asset.localId!,
              CurrentPlatform.isAndroid ? "asset_not_found_on_device_android".t() : "asset_not_found_on_device_ios".t(),
            );
          }
        }
      }

      if (file == null) {
        _logger.warning("Failed to obtain file from iCloud for asset ${asset.id} - ${asset.name}");
        callbacks.onError?.call(asset.localId!, "asset_not_found_on_icloud".t());
        return null;
      }

      sourceFile = file;
      sourceLivePhotoFile = livePhotoFile;

      final fileName = await _assetMediaRepository.getOriginalFilename(asset.id) ?? asset.name;
      // Some apps (e.g. DJI/Fusion) return names without an extension; fall back to the asset name for those.
      final extension = p.extension(file.path).isNotEmpty ? p.extension(file.path) : p.extension(asset.name);
      var originalFileName = p.setExtension(fileName, extension);

      // Storage saver is deliberately performed by the server. The phone only
      // reads and uploads the source file, avoiding a CPU/thermal-heavy encode
      // before every transfer.
      final storageSaver = SettingsRepository.instance.appConfig.backup.quality == BackupQuality.storageSaver;
      final originalBytes = await file.length().onError((_, __) => 0);
      callbacks.onPreparationProgress?.call(asset.localId!, originalFileName, 1, originalBytes, null);
      final fields = <String, String>{
        // deviceAssetId/deviceId required by server v2.7.5 and below (drop in v4.0 per #27818).
        'deviceAssetId': asset.localId!,
        'deviceId': Store.get(StoreKey.deviceId),
        'fileCreatedAt': asset.createdAt.toUtc().toIso8601String(),
        'fileModifiedAt': asset.updatedAt.toUtc().toIso8601String(),
        'isFavorite': asset.isFavorite.toString(),
        'duration': (asset.durationMs ?? 0).toString(),
        'storageSaver': storageSaver.toString(),
      };

      // Add cloudId metadata only to the still image, not the motion video,
      // because a motion upload can otherwise be associated with the wrong
      // still image during a sync.
      final sourceChecksum = storageSaver ? asset.checksum : null;
      if ((CurrentPlatform.isIOS && asset.cloudId != null) || sourceChecksum != null) {
        fields['metadata'] = jsonEncode([
          RemoteAssetMetadataItem(
            key: RemoteAssetMetadataKey.mobileApp,
            value: RemoteAssetMobileAppMetadata(
              // For Storage saver uploads the server checksum belongs to the
              // compressed copy. Persist the original local checksum here so
              // future syncs still recognize the source as already backed up.
              cloudId: CurrentPlatform.isIOS ? asset.cloudId : sourceChecksum,
              createdAt: asset.createdAt.toIso8601String(),
              adjustmentTime: asset.adjustmentTime?.toIso8601String(),
              latitude: asset.latitude?.toString(),
              longitude: asset.longitude?.toString(),
            ),
          ),
        ]);
      }

      return _PreparedAsset(
        asset: asset,
        file: file,
        originalFileName: originalFileName,
        fields: fields,
        isLivePhoto: entity.isLivePhoto,
        livePhotoFile: livePhotoFile,
        temporaryFile: temporaryFile,
        temporaryLivePhotoFile: temporaryLivePhotoFile,
        sourceFile: sourceFile,
        sourceLivePhotoFile: sourceLivePhotoFile,
      );
    } catch (error, stackTrace) {
      _logger.severe(() => "Error backup asset: ${error.toString()}", stackTrace);
      callbacks.onError?.call(asset.localId!, error.toString());
      await _cleanupFiles(
        temporaryFile: temporaryFile,
        temporaryLivePhotoFile: temporaryLivePhotoFile,
        sourceFile: sourceFile,
        sourceLivePhotoFile: sourceLivePhotoFile,
      );
      return null;
    }
  }

  Future<_UploadAcknowledgement?> _uploadPreparedAsset(
    _PreparedAsset item,
    Completer<void>? cancelToken, {
    required UploadCallbacks callbacks,
  }) async {
    final asset = item.asset;
    final onProgress = callbacks.onProgress;
    final fields = Map<String, String>.of(item.fields);

    try {
      String? livePhotoVideoId;
      if (item.isLivePhoto && item.livePhotoFile != null) {
        final livePhotoTitle = p.setExtension(item.originalFileName, p.extension(item.livePhotoFile!.path));
        final livePhotoResult = await _uploadRepository.uploadFile(
          file: item.livePhotoFile!,
          originalFileName: livePhotoTitle,
          fields: {...fields, 'visibility': AssetVisibility.hidden.toString()},
          cancelToken: cancelToken,
          onProgress: onProgress != null
              ? (bytes, totalBytes) => onProgress(asset.localId!, livePhotoTitle, bytes, totalBytes)
              : null,
          logContext: 'livePhotoVideo[${asset.localId}]',
        );
        if (livePhotoResult.isCancelled) {
          shouldAbortUpload = true;
          return null;
        }
        if (livePhotoResult.isSuccess && livePhotoResult.remoteAssetId != null) {
          livePhotoVideoId = livePhotoResult.remoteAssetId;
        }
      }

      if (livePhotoVideoId != null) fields['livePhotoVideoId'] = livePhotoVideoId;

      final result = await _uploadRepository.uploadFile(
        file: item.file,
        originalFileName: item.originalFileName,
        fields: fields,
        cancelToken: cancelToken,
        onProgress: onProgress != null
            ? (bytes, totalBytes) => onProgress(asset.localId!, item.originalFileName, bytes, totalBytes)
            : null,
        logContext: 'asset[${asset.localId}]',
      );

      if (result.isSuccess && result.remoteAssetId != null) {
        return _UploadAcknowledgement(item, result.remoteAssetId!);
      }
      if (result.isCancelled) {
        _logger.warning(() => 'Backup was cancelled by the user');
        shouldAbortUpload = true;
      } else if (result.errorMessage != null) {
        _logger.severe(
          () =>
              'Error(${result.statusCode}) uploading ${asset.localId} | ${item.originalFileName} | Created on ${asset.createdAt} | ${result.errorMessage}',
        );
        callbacks.onError?.call(asset.localId!, result.errorMessage!);
        if (result.errorMessage == 'Quota has been exceeded!') shouldAbortUpload = true;
      }
    } catch (error, stackTrace) {
      _logger.severe(() => 'Error uploading prepared asset: $error', stackTrace);
      callbacks.onError?.call(asset.localId!, error.toString());
    }
    return null;
  }

  Future<void> _cleanupFiles({
    File? temporaryFile,
    File? temporaryLivePhotoFile,
    File? sourceFile,
    File? sourceLivePhotoFile,
  }) async {
    try {
      await temporaryFile?.delete();
      await temporaryLivePhotoFile?.delete();
      if (Platform.isIOS) {
        await sourceFile?.delete();
        await sourceLivePhotoFile?.delete();
      }
    } catch (error, stackTrace) {
      _logger.severe(() => 'ERROR deleting prepared upload file: $error', stackTrace);
    }
  }

  Future<void> _cleanupPreparedAsset(_PreparedAsset item) => _cleanupFiles(
    temporaryFile: item.temporaryFile,
    temporaryLivePhotoFile: item.temporaryLivePhotoFile,
    sourceFile: item.sourceFile,
    sourceLivePhotoFile: item.sourceLivePhotoFile,
  );

  Future<UploadResult> _uploadSingleFile(
    File file, {
    required String deviceAssetId,
    required Completer<void>? cancelToken,
    void Function(int bytes, int totalBytes)? onProgress,
  }) async {
    try {
      final stats = await file.stat();
      final fileCreatedAt = stats.changed;
      final fileModifiedAt = stats.modified;
      final filename = p.basename(file.path);

      final fields = {
        // deviceAssetId/deviceId required by server v2.7.5 and below (drop in v4.0 per #27818).
        'deviceAssetId': deviceAssetId,
        'deviceId': Store.get(StoreKey.deviceId),
        'fileCreatedAt': fileCreatedAt.toUtc().toIso8601String(),
        'fileModifiedAt': fileModifiedAt.toUtc().toIso8601String(),
        'isFavorite': 'false',
        'duration': '0',
      };

      return await _uploadRepository.uploadFile(
        file: file,
        originalFileName: filename,
        fields: fields,
        cancelToken: cancelToken,
        onProgress: onProgress,
        logContext: 'shareIntent[$deviceAssetId]',
      );
    } catch (e) {
      return UploadResult.error(errorMessage: e.toString());
    }
  }

  bool _shouldRequireWiFi(LocalAsset asset) {
    final backup = SettingsRepository.instance.appConfig.backup;
    if (asset.isVideo && backup.useCellularForVideos) {
      return false;
    }
    if (!asset.isVideo && backup.useCellularForPhotos) {
      return false;
    }
    return true;
  }
}
