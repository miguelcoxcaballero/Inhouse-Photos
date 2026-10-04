import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/utils/background_sync.dart';
import 'package:immich_mobile/providers/backup/drift_backup.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';

final backgroundSyncProvider = Provider<BackgroundSyncManager>((ref) {
  final syncStatusNotifier = ref.read(syncStatusProvider.notifier);
  bool disposed = false;

  final manager = BackgroundSyncManager(
    onRemoteSyncStart: () {
      if (disposed) {
        return;
      }
      syncStatusNotifier.startRemoteSync();
      final backupProvider = ref.read(driftBackupProvider.notifier);
      if (backupProvider.mounted) {
        backupProvider.updateError(BackupError.none);
      }
    },
    onRemoteSyncComplete: (isSuccess) {
      if (disposed) {
        return;
      }
      if (isSuccess == true) {
        syncStatusNotifier.completeRemoteSync();
      } else {
        syncStatusNotifier.errorRemoteSync("Remote synchronization did not complete. Retry to resume backup.");
      }
      final backupProvider = ref.read(driftBackupProvider.notifier);
      if (backupProvider.mounted) {
        backupProvider.updateError(isSuccess == true ? BackupError.none : BackupError.syncFailed);
      }
    },
    onRemoteSyncError: (error) {
      if (disposed) {
        return;
      }
      syncStatusNotifier.errorRemoteSync(error);
      final backupProvider = ref.read(driftBackupProvider.notifier);
      if (backupProvider.mounted) {
        backupProvider.updateError(BackupError.syncFailed);
      }
    },
    onLocalSyncStart: syncStatusNotifier.startLocalSync,
    onLocalSyncComplete: syncStatusNotifier.completeLocalSync,
    onLocalSyncError: syncStatusNotifier.errorLocalSync,
    onHashingStart: syncStatusNotifier.startHashJob,
    onHashingComplete: syncStatusNotifier.completeHashJob,
    onHashingError: syncStatusNotifier.errorHashJob,
    onCloudIdSyncStart: syncStatusNotifier.startCloudIdSync,
    onCloudIdSyncComplete: syncStatusNotifier.completeCloudIdSync,
    onCloudIdSyncError: syncStatusNotifier.errorCloudIdSync,
  );
  ref.onDispose(() {
    disposed = true;
    manager.cancel();
  });
  return manager;
});
