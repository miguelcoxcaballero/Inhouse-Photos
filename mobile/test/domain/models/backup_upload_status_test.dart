import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/providers/backup/drift_backup.provider.dart';

DriftUploadStatus status({
  double upload = 0,
  double compression = 0,
  bool compressionExpected = true,
  bool uploadStarted = true,
  bool failed = false,
}) => DriftUploadStatus(
  taskId: 'asset',
  filename: 'photo.jpg',
  preparationProgress: compression,
  progress: upload,
  originalFileSize: 100,
  fileSize: 50,
  networkSpeedAsString: '',
  uploadStarted: uploadStarted,
  compressionExpected: compressionExpected,
  isFailed: failed,
);

void main() {
  test('prepared videos waiting for bandwidth are not reported as uploading', () {
    final waiting = status(uploadStarted: false);
    expect(waiting.isQueued, isTrue);
    expect(waiting.isActivelyUploading, isFalse);
    final uploading = waiting.copyWith(uploadStarted: true);
    expect(uploading.isQueued, isFalse);
    expect(uploading.isActivelyUploading, isTrue);
  });

  test('network upload and cloud processing are mutually exclusive stages', () {
    final uploading = status(upload: 0.5);
    final processing = status(upload: 1, compression: 0.4);
    final completed = status(upload: 1, compression: 1);

    expect(uploading.isActivelyUploading, isTrue);
    expect(uploading.isCloudProcessing, isFalse);
    expect(processing.isActivelyUploading, isFalse);
    expect(processing.isCloudProcessing, isTrue);
    expect(completed.isActivelyUploading, isFalse);
    expect(completed.isCloudProcessing, isFalse);
  });

  test('failed items are not reported as active work', () {
    final failed = status(upload: 0.5, failed: true);

    expect(failed.isActivelyUploading, isFalse);
    expect(failed.isCloudProcessing, isFalse);
  });
}
