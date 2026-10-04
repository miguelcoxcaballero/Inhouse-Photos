import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';

void main() {
  test('a successful retry clears the previous remote sync error', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(syncStatusProvider.notifier);
    notifier.errorRemoteSync('Connection reset');
    expect(container.read(syncStatusProvider).remoteSyncStatus, SyncStatus.error);
    expect(container.read(syncStatusProvider).errorMessage, 'Connection reset');
    notifier.startRemoteSync();
    expect(container.read(syncStatusProvider).errorMessage, isNull);
    notifier.completeRemoteSync();
    expect(container.read(syncStatusProvider).remoteSyncStatus, SyncStatus.success);
    expect(container.read(syncStatusProvider).errorMessage, isNull);
  });
}
