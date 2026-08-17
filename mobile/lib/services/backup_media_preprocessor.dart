import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/backup_config.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:logging/logging.dart';

class PreparedBackupMedia {
  final File file;
  final String uploadFileName;
  final bool isTemporary;

  const PreparedBackupMedia({required this.file, required this.uploadFileName, required this.isTemporary});
}

/// Prepares Storage saver copies without ever modifying the device original.
///
/// The surrounding upload worker pool owns concurrency. Since it has three
/// workers, at most three media items are prepared/uploaded at the same time.
class BackupMediaPreprocessor {
  static const _channel = MethodChannel('com.inhousesoftware.photos/backup_media');
  static final _logger = Logger('BackupMediaPreprocessor');
  static final Map<String, void Function(double progress)> _progressListeners = {};
  static bool _progressHandlerInstalled = false;

  final Duration photoTimeout;
  final Duration videoTimeout;

  const BackupMediaPreprocessor({
    this.photoTimeout = const Duration(seconds: 20),
    this.videoTimeout = const Duration(minutes: 8),
  });

  Future<PreparedBackupMedia> prepare(
    File source,
    LocalAsset asset,
    String originalFileName, {
    bool? isVideoOverride,
    void Function(double progress, int originalBytes, int? preparedBytes)? onProgress,
  }) async {
    final original = PreparedBackupMedia(file: source, uploadFileName: originalFileName, isTemporary: false);
    final quality = SettingsRepository.instance.appConfig.backup.quality;
    final isVideo = isVideoOverride ?? asset.isVideo;
    final sourceSize = await source.length().catchError((_) => 0);

    final supportsStorageSaver = Platform.isAndroid || Platform.isIOS;
    if (quality != BackupQuality.storageSaver || !supportsStorageSaver || (!asset.isImage && !isVideo)) {
      onProgress?.call(1, sourceSize, sourceSize);
      return original;
    }

    // Flattening an animated image would destroy its animation.
    if (!isVideo && asset.isAnimatedImage) {
      onProgress?.call(1, sourceSize, sourceSize);
      return original;
    }

    _installProgressHandler();
    final operationId = '${asset.localId ?? asset.id}:${isVideo ? 'video' : 'photo'}';
    _progressListeners[operationId] = (progress) => onProgress?.call(progress, sourceSize, null);
    onProgress?.call(0, sourceSize, null);

    try {
      final response = await _channel
          .invokeMapMethod<String, Object?>('prepare', {
            'sourcePath': source.path,
            'isVideo': isVideo,
            'width': asset.width,
            'height': asset.height,
            'originalFileName': originalFileName,
            'operationId': operationId,
          })
          .timeout(
            isVideo ? videoTimeout : photoTimeout,
            onTimeout: () {
              // A native codec must never be allowed to occupy one of the
              // three backup workers forever. Ask iOS/Android to release any
              // active exporter, then let the caller upload the original.
              unawaited(_cancelNativeOperation(operationId));
              throw TimeoutException('Storage saver timed out for $operationId');
            },
          );
      final outputPath = response?['path'] as String?;
      final outputFileName = response?['fileName'] as String?;
      if (outputPath == null || outputFileName == null) {
        onProgress?.call(1, sourceSize, sourceSize);
        return original;
      }

      final output = File(outputPath);
      if (!await output.exists()) {
        onProgress?.call(1, sourceSize, sourceSize);
        return original;
      }

      final outputSize = await output.length();
      if (outputSize <= 0 || outputSize >= sourceSize) {
        await output.delete().catchError((_) => output);
        onProgress?.call(1, sourceSize, sourceSize);
        return original;
      }

      _logger.info(
        'Storage saver prepared ${asset.id}: $sourceSize -> $outputSize bytes '
        '(${isVideo ? '1080p video' : '16 MP photo'})',
      );
      onProgress?.call(1, sourceSize, outputSize);
      return PreparedBackupMedia(file: output, uploadFileName: outputFileName, isTemporary: true);
    } on MissingPluginException {
      _logger.warning('Storage saver is unavailable on this platform; uploading original');
      onProgress?.call(1, sourceSize, sourceSize);
      return original;
    } catch (error, stackTrace) {
      _logger.warning('Storage saver failed for ${asset.id}; uploading original', error, stackTrace);
      onProgress?.call(1, sourceSize, sourceSize);
      return original;
    } finally {
      _progressListeners.remove(operationId);
    }
  }

  static void _installProgressHandler() {
    if (_progressHandlerInstalled) {
      return;
    }
    _progressHandlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'progress') {
        return;
      }
      final arguments = Map<Object?, Object?>.from(call.arguments as Map);
      final operationId = arguments['operationId'] as String?;
      final progress = (arguments['progress'] as num?)?.toDouble();
      if (operationId != null && progress != null) {
        _progressListeners[operationId]?.call(progress.clamp(0, 1));
      }
    });
  }

  static Future<void> _cancelNativeOperation(String operationId) async {
    try {
      await _channel.invokeMethod<void>('cancel', {'operationId': operationId});
    } catch (_) {
      // Cancellation is best effort. The Dart timeout has already released
      // the upload worker and the native output lives only in the cache.
    }
  }
}
