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

  const BackupMediaPreprocessor();

  Future<PreparedBackupMedia> prepare(
    File source,
    LocalAsset asset,
    String originalFileName, {
    bool? isVideoOverride,
  }) async {
    final original = PreparedBackupMedia(file: source, uploadFileName: originalFileName, isTemporary: false);
    final quality = SettingsRepository.instance.appConfig.backup.quality;
    final isVideo = isVideoOverride ?? asset.isVideo;

    if (quality != BackupQuality.storageSaver || !Platform.isAndroid || (!asset.isImage && !isVideo)) {
      return original;
    }

    // Flattening an animated image would destroy its animation.
    if (!isVideo && asset.isAnimatedImage) {
      return original;
    }

    try {
      final response = await _channel.invokeMapMethod<String, Object?>('prepare', {
        'sourcePath': source.path,
        'isVideo': isVideo,
        'width': asset.width,
        'height': asset.height,
        'originalFileName': originalFileName,
      });
      final outputPath = response?['path'] as String?;
      final outputFileName = response?['fileName'] as String?;
      if (outputPath == null || outputFileName == null) {
        return original;
      }

      final output = File(outputPath);
      if (!await output.exists()) {
        return original;
      }

      final sourceSize = await source.length();
      final outputSize = await output.length();
      if (outputSize <= 0 || outputSize >= sourceSize) {
        await output.delete().catchError((_) => output);
        return original;
      }

      _logger.info(
        'Storage saver prepared ${asset.id}: $sourceSize -> $outputSize bytes '
        '(${isVideo ? '1080p video' : '16 MP photo'})',
      );
      return PreparedBackupMedia(file: output, uploadFileName: outputFileName, isTemporary: true);
    } on MissingPluginException {
      _logger.warning('Storage saver is unavailable on this platform; uploading original');
      return original;
    } catch (error, stackTrace) {
      _logger.warning('Storage saver failed for ${asset.id}; uploading original', error, stackTrace);
      return original;
    }
  }
}
