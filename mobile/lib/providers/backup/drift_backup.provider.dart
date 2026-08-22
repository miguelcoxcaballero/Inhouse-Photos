import 'dart:async';

import 'package:collection/collection.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:logging/logging.dart';

import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/utils/upload_speed_calculator.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/services/background_upload.service.dart';

class EnqueueStatus {
  final int enqueueCount;
  final int totalCount;

  const EnqueueStatus({required this.enqueueCount, required this.totalCount});

  EnqueueStatus copyWith({int? enqueueCount, int? totalCount}) {
    return EnqueueStatus(enqueueCount: enqueueCount ?? this.enqueueCount, totalCount: totalCount ?? this.totalCount);
  }

  @override
  String toString() => 'EnqueueStatus(enqueueCount: $enqueueCount, totalCount: $totalCount)';
}

class DriftUploadStatus {
  final String taskId;
  final String filename;
  final double preparationProgress;
  final double progress;
  final int originalFileSize;
  final int fileSize;
  final String networkSpeedAsString;
  final bool compressionExpected;
  final String compressionState;
  final bool? isFailed;
  final String? error;

  const DriftUploadStatus({
    required this.taskId,
    required this.filename,
    required this.preparationProgress,
    required this.progress,
    required this.originalFileSize,
    required this.fileSize,
    required this.networkSpeedAsString,
    this.compressionExpected = false,
    this.compressionState = 'none',
    this.isFailed,
    this.error,
  });

  DriftUploadStatus copyWith({
    String? taskId,
    String? filename,
    double? preparationProgress,
    double? progress,
    int? originalFileSize,
    int? fileSize,
    String? networkSpeedAsString,
    bool? compressionExpected,
    String? compressionState,
    bool? isFailed,
    String? error,
  }) {
    return DriftUploadStatus(
      taskId: taskId ?? this.taskId,
      filename: filename ?? this.filename,
      preparationProgress: preparationProgress ?? this.preparationProgress,
      progress: progress ?? this.progress,
      originalFileSize: originalFileSize ?? this.originalFileSize,
      fileSize: fileSize ?? this.fileSize,
      networkSpeedAsString: networkSpeedAsString ?? this.networkSpeedAsString,
      compressionExpected: compressionExpected ?? this.compressionExpected,
      compressionState: compressionState ?? this.compressionState,
      isFailed: isFailed ?? this.isFailed,
      error: error ?? this.error,
    );
  }

  @override
  String toString() {
    return 'DriftUploadStatus(taskId: $taskId, filename: $filename, preparationProgress: $preparationProgress, progress: $progress, originalFileSize: $originalFileSize, fileSize: $fileSize, networkSpeedAsString: $networkSpeedAsString, compressionExpected: $compressionExpected, compressionState: $compressionState, isFailed: $isFailed, error: $error)';
  }

  @override
  bool operator ==(covariant DriftUploadStatus other) {
    if (identical(this, other)) {
      return true;
    }

    return other.taskId == taskId &&
        other.filename == filename &&
        other.preparationProgress == preparationProgress &&
        other.progress == progress &&
        other.originalFileSize == originalFileSize &&
        other.fileSize == fileSize &&
        other.networkSpeedAsString == networkSpeedAsString &&
        other.compressionExpected == compressionExpected &&
        other.compressionState == compressionState &&
        other.isFailed == isFailed &&
        other.error == error;
  }

  @override
  int get hashCode {
    return taskId.hashCode ^
        filename.hashCode ^
        preparationProgress.hashCode ^
        progress.hashCode ^
        originalFileSize.hashCode ^
        fileSize.hashCode ^
        networkSpeedAsString.hashCode ^
        compressionExpected.hashCode ^
        compressionState.hashCode ^
        isFailed.hashCode ^
        error.hashCode;
  }
}

enum BackupError { none, syncFailed }

class DriftBackupState {
  final int totalCount;
  final int backupCount;
  final int remainderCount;
  final int processingCount;

  final bool isSyncing;
  final BackupError error;

  final Map<String, DriftUploadStatus> uploadItems;

  final Map<String, double> iCloudDownloadProgress;

  const DriftBackupState({
    required this.totalCount,
    required this.backupCount,
    required this.remainderCount,
    required this.processingCount,
    required this.isSyncing,
    this.error = BackupError.none,
    required this.uploadItems,
    this.iCloudDownloadProgress = const {},
  });

  DriftBackupState copyWith({
    int? totalCount,
    int? backupCount,
    int? remainderCount,
    int? processingCount,
    bool? isSyncing,
    BackupError? error,
    Map<String, DriftUploadStatus>? uploadItems,
    Map<String, double>? iCloudDownloadProgress,
  }) {
    return DriftBackupState(
      totalCount: totalCount ?? this.totalCount,
      backupCount: backupCount ?? this.backupCount,
      remainderCount: remainderCount ?? this.remainderCount,
      processingCount: processingCount ?? this.processingCount,
      isSyncing: isSyncing ?? this.isSyncing,
      error: error ?? this.error,
      uploadItems: uploadItems ?? this.uploadItems,
      iCloudDownloadProgress: iCloudDownloadProgress ?? this.iCloudDownloadProgress,
    );
  }

  int get errorCount => uploadItems.values.where((item) => item.isFailed == true).length;

  @override
  String toString() {
    return 'DriftBackupState(totalCount: $totalCount, backupCount: $backupCount, remainderCount: $remainderCount, processingCount: $processingCount, isSyncing: $isSyncing, error: $error, uploadItems: $uploadItems, iCloudDownloadProgress: $iCloudDownloadProgress)';
  }

  @override
  bool operator ==(covariant DriftBackupState other) {
    if (identical(this, other)) {
      return true;
    }
    final mapEquals = const DeepCollectionEquality().equals;

    return other.totalCount == totalCount &&
        other.backupCount == backupCount &&
        other.remainderCount == remainderCount &&
        other.processingCount == processingCount &&
        other.isSyncing == isSyncing &&
        other.error == error &&
        mapEquals(other.iCloudDownloadProgress, iCloudDownloadProgress) &&
        mapEquals(other.uploadItems, uploadItems);
  }

  @override
  int get hashCode {
    return totalCount.hashCode ^
        backupCount.hashCode ^
        remainderCount.hashCode ^
        processingCount.hashCode ^
        isSyncing.hashCode ^
        error.hashCode ^
        uploadItems.hashCode ^
        iCloudDownloadProgress.hashCode;
  }
}

final driftBackupProvider = StateNotifierProvider<DriftBackupNotifier, DriftBackupState>((ref) {
  return DriftBackupNotifier(
    ref.watch(foregroundUploadServiceProvider),
    ref.watch(backgroundUploadServiceProvider),
    UploadSpeedManager(),
    ref.watch(localAssetRepository),
    ref.watch(remoteAssetRepositoryProvider),
  );
});

class DriftBackupNotifier extends StateNotifier<DriftBackupState> {
  DriftBackupNotifier(
    this._foregroundUploadService,
    this._backgroundUploadService,
    this._uploadSpeedManager,
    this._localAssetRepository,
    this._remoteAssetRepository,
  ) : super(
        const DriftBackupState(
          totalCount: 0,
          backupCount: 0,
          remainderCount: 0,
          processingCount: 0,
          isSyncing: false,
          uploadItems: {},
          error: BackupError.none,
        ),
      ) {
    _compressionSubscription = EventStream.shared.listen<ServerCompressionProgressEvent>(
      _handleServerCompressionProgress,
    );
  }

  final ForegroundUploadService _foregroundUploadService;
  final BackgroundUploadService _backgroundUploadService;
  final UploadSpeedManager _uploadSpeedManager;
  final DriftLocalAssetRepository _localAssetRepository;
  final RemoteAssetRepository _remoteAssetRepository;
  Completer<void>? _cancelToken;
  Future<void>? _activeForegroundBackup;
  bool _restartForegroundBackup = false;
  late final StreamSubscription<ServerCompressionProgressEvent> _compressionSubscription;
  final Map<String, String> _remoteToLocalAssetIds = {};
  final Map<String, ServerCompressionProgressEvent> _pendingCompressionEvents = {};

  final _logger = Logger("DriftBackupNotifier");

  @override
  void dispose() {
    unawaited(_compressionSubscription.cancel());
    super.dispose();
  }

  /// Remove upload item from state
  void _removeUploadItem(String taskId) {
    if (!mounted) {
      _logger.warning("Skip _removeUploadItem: notifier disposed");
      return;
    }
    if (state.uploadItems.containsKey(taskId)) {
      final updatedItems = Map<String, DriftUploadStatus>.from(state.uploadItems);
      updatedItems.remove(taskId);
      state = state.copyWith(uploadItems: updatedItems);
    }
  }

  Future<void> getBackupStatus(String userId) async {
    if (!mounted) {
      _logger.warning("Skip getBackupStatus (pre-call): notifier disposed");
      return;
    }
    final counts = await _foregroundUploadService.getBackupCounts(userId);
    if (!mounted) {
      _logger.warning("Skip getBackupStatus (post-call): notifier disposed");
      return;
    }

    state = state.copyWith(
      totalCount: counts.total,
      backupCount: counts.total - counts.remainder,
      remainderCount: counts.remainder,
      processingCount: counts.processing,
    );
  }

  void updateError(BackupError error) {
    if (!mounted) {
      _logger.warning("Skip updateError: notifier disposed");
      return;
    }
    state = state.copyWith(error: error);
  }

  void updateSyncing(bool isSyncing) {
    state = state.copyWith(isSyncing: isSyncing);
  }

  Future<void> startForegroundBackup(String userId) {
    final activeBackup = _activeForegroundBackup;
    if (activeBackup != null) {
      // Resume/sync notifications can arrive together on iOS. Cancelling the
      // first worker pool here used to race its replacement and leave all
      // three upload slots stuck. Finish the active pass, then scan once more
      // for assets that became eligible while it was running.
      _restartForegroundBackup = true;
      return activeBackup;
    }

    state = state.copyWith(error: BackupError.none);

    final cancelToken = Completer<void>();
    _cancelToken = cancelToken;

    late final Future<void> backup;
    backup = _foregroundUploadService
        .uploadCandidates(
          userId,
          cancelToken,
          callbacks: UploadCallbacks(
            onProgress: _handleForegroundBackupProgress,
            onServerCompressionExpected: _handleServerCompressionExpected,
            onSuccess: (localId, remoteId) => _handleForegroundBackupSuccess(userId, localId, remoteId),
            onError: _handleForegroundBackupError,
            onICloudProgress: _handleICloudProgress,
          ),
        )
        .whenComplete(() {
          if (!identical(_activeForegroundBackup, backup)) {
            return;
          }

          _activeForegroundBackup = null;
          if (identical(_cancelToken, cancelToken)) {
            _cancelToken = null;
          }

          final shouldRestart = _restartForegroundBackup && !cancelToken.isCompleted;
          _restartForegroundBackup = false;
          if (shouldRestart && mounted) {
            unawaited(startForegroundBackup(userId));
          }
        });
    _activeForegroundBackup = backup;
    return backup;
  }

  void stopForegroundBackup() {
    final cancelToken = _cancelToken;
    if (cancelToken != null && !cancelToken.isCompleted) {
      cancelToken.complete();
    }
    _restartForegroundBackup = false;
    _uploadSpeedManager.clear();
    _remoteToLocalAssetIds.clear();
    _pendingCompressionEvents.clear();
    state = state.copyWith(uploadItems: {}, iCloudDownloadProgress: {});
  }

  void _handleICloudProgress(String localAssetId, double progress) {
    state = state.copyWith(iCloudDownloadProgress: {...state.iCloudDownloadProgress, localAssetId: progress});

    if (progress >= 1.0) {
      Future.delayed(const Duration(milliseconds: 250), () {
        final updatedProgress = Map<String, double>.from(state.iCloudDownloadProgress);
        updatedProgress.remove(localAssetId);
        state = state.copyWith(iCloudDownloadProgress: updatedProgress);
      });
    }
  }

  void _handleForegroundBackupProgress(String localAssetId, String filename, int bytes, int totalBytes) {
    if (_cancelToken == null || _cancelToken!.isCompleted) {
      return;
    }

    final progress = totalBytes > 0 ? bytes / totalBytes : 0.0;
    final networkSpeedAsString = _uploadSpeedManager.updateProgress(localAssetId, bytes, totalBytes);
    final currentItem = state.uploadItems[localAssetId];
    if (currentItem != null) {
      state = state.copyWith(
        uploadItems: {
          ...state.uploadItems,
          localAssetId: currentItem.copyWith(
            filename: filename,
            progress: progress,
            fileSize: currentItem.compressionExpected ? currentItem.fileSize : totalBytes,
            networkSpeedAsString: networkSpeedAsString,
          ),
        },
      );
    } else {
      state = state.copyWith(
        uploadItems: {
          ...state.uploadItems,
          localAssetId: DriftUploadStatus(
            taskId: localAssetId,
            filename: filename,
            preparationProgress: 1,
            progress: progress,
            originalFileSize: totalBytes,
            fileSize: totalBytes,
            networkSpeedAsString: networkSpeedAsString,
          ),
        },
      );
    }
  }

  void _handleServerCompressionExpected(String localAssetId, String filename, int originalBytes) {
    if (_cancelToken == null || _cancelToken!.isCompleted) {
      return;
    }

    final currentItem = state.uploadItems[localAssetId];
    final item =
        currentItem?.copyWith(
          filename: filename,
          preparationProgress: 0,
          originalFileSize: originalBytes,
          fileSize: 0,
          compressionExpected: true,
          compressionState: 'waiting',
        ) ??
        DriftUploadStatus(
          taskId: localAssetId,
          filename: filename,
          preparationProgress: 0,
          progress: 0,
          originalFileSize: originalBytes,
          fileSize: 0,
          networkSpeedAsString: '',
          compressionExpected: true,
          compressionState: 'waiting',
        );
    state = state.copyWith(uploadItems: {...state.uploadItems, localAssetId: item});
  }

  Future<void> _handleForegroundBackupSuccess(String userId, String localAssetId, String remoteAssetId) async {
    _remoteToLocalAssetIds[remoteAssetId] = localAssetId;
    final pendingCompression = _pendingCompressionEvents.remove(remoteAssetId);
    if (pendingCompression != null) {
      _handleServerCompressionProgress(pendingCompression);
    }

    try {
      final source = await _localAssetRepository.getById(localAssetId);
      if (source == null) {
        _logger.warning('Uploaded local asset $localAssetId is no longer in the device database');
      } else {
        await _remoteAssetRepository.registerCompletedUpload(remoteId: remoteAssetId, ownerId: userId, source: source);
      }
    } catch (error, stackTrace) {
      // The upload itself succeeded. A later server sync can still reconcile
      // the asset, so never turn this local UI update into an upload failure.
      _logger.warning('Unable to register completed upload $remoteAssetId locally', error, stackTrace);
    }

    state = state.copyWith(backupCount: state.backupCount + 1, remainderCount: state.remainderCount - 1);
    _uploadSpeedManager.removeTask(localAssetId);

    final uploadItem = state.uploadItems[localAssetId];
    if (uploadItem?.compressionExpected != true || _isCompressionFinished(uploadItem!.compressionState)) {
      _scheduleUploadItemRemoval(localAssetId);
    } else {
      // Do not leave a completed upload pinned forever if the app lost its
      // websocket connection while the server was encoding it.
      Future.delayed(const Duration(minutes: 15), () => _removeUploadItem(localAssetId));
    }
  }

  bool _isCompressionFinished(String compressionState) =>
      compressionState == 'completed' || compressionState == 'skipped' || compressionState == 'failed';

  void _scheduleUploadItemRemoval(String localAssetId) {
    Future.delayed(const Duration(milliseconds: 1200), () => _removeUploadItem(localAssetId));
  }

  void _handleServerCompressionProgress(ServerCompressionProgressEvent event) {
    final localAssetId = _remoteToLocalAssetIds[event.assetId];
    if (localAssetId == null) {
      // The queued/first encode event can beat the HTTP upload response. Keep
      // only the newest event for that asset until its remote ID is known.
      if (_pendingCompressionEvents.length >= 128 && !_pendingCompressionEvents.containsKey(event.assetId)) {
        _pendingCompressionEvents.remove(_pendingCompressionEvents.keys.first);
      }
      _pendingCompressionEvents[event.assetId] = event;
      return;
    }

    final currentItem = state.uploadItems[localAssetId];
    if (currentItem == null) {
      return;
    }

    final finished = event.isFinished;
    state = state.copyWith(
      uploadItems: {
        ...state.uploadItems,
        localAssetId: currentItem.copyWith(
          preparationProgress: event.progress,
          originalFileSize: event.originalBytes,
          fileSize: event.outputBytes,
          compressionExpected: true,
          compressionState: event.state,
        ),
      },
    );

    if (finished) {
      _remoteToLocalAssetIds.remove(event.assetId);
      _pendingCompressionEvents.remove(event.assetId);
      _scheduleUploadItemRemoval(localAssetId);
    }
  }

  void _handleForegroundBackupError(String localAssetId, String errorMessage) {
    _logger.severe("Upload failed for $localAssetId: $errorMessage");

    final currentItem = state.uploadItems[localAssetId];
    if (currentItem != null) {
      state = state.copyWith(
        uploadItems: {
          ...state.uploadItems,
          localAssetId: currentItem.copyWith(isFailed: true, error: errorMessage),
        },
      );
    } else {
      state = state.copyWith(
        uploadItems: {
          ...state.uploadItems,
          localAssetId: DriftUploadStatus(
            taskId: localAssetId,
            filename: 'Unknown',
            preparationProgress: 0,
            progress: 0,
            originalFileSize: 0,
            fileSize: 0,
            networkSpeedAsString: '',
            isFailed: true,
            error: errorMessage,
          ),
        },
      );
    }

    _uploadSpeedManager.removeTask(localAssetId);
  }

  Future<void> startBackupWithURLSession(String userId) async {
    if (!mounted) {
      _logger.warning("Skip handleBackupResume (pre-call): notifier disposed");
      return;
    }
    _logger.info("Start background backup sequence");
    state = state.copyWith(error: BackupError.none);
    final tasks = await _backgroundUploadService.getActiveTasks(kBackupGroup);
    if (!mounted) {
      _logger.warning("Skip handleBackupResume (post-call): notifier disposed");
      return;
    }
    _logger.info("Found ${tasks.length} pending tasks");

    if (tasks.isEmpty) {
      _logger.info("No pending tasks, starting new upload");
      return _backgroundUploadService.uploadBackupCandidates(userId);
    }

    _logger.info("Resuming upload ${tasks.length} assets");
    return _backgroundUploadService.resume();
  }
}

final driftBackupCandidateProvider = FutureProvider.autoDispose<List<LocalAsset>>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    return [];
  }

  return ref.read(foregroundUploadServiceProvider).getBackupCandidates(user.id, onlyHashed: false);
});

final driftCandidateBackupAlbumInfoProvider = FutureProvider.autoDispose.family<List<LocalAlbum>, String>((
  ref,
  assetId,
) {
  return ref.read(localAssetRepository).getSourceAlbums(assetId, backupSelection: BackupSelection.selected);
});
