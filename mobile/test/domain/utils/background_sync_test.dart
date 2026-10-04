import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/utils/background_sync.dart';
import 'package:worker_manager/worker_manager.dart';

void main() {
  test('shares a single sync and reports the real failure before callers resume', () async {
    final completer = Completer<bool?>();
    final callbacks = <String>[];
    int runs = 0;
    final manager = BackgroundSyncManager(
      remoteSyncRunner: () {
        runs++;
        return Cancelable<bool?>(completer: completer);
      },
      onRemoteSyncStart: () => callbacks.add('start'),
      onRemoteSyncError: (error) => callbacks.add(error),
      onRemoteSyncComplete: (_) => callbacks.add('complete'),
    );
    final first = manager.syncRemote();
    final second = manager.syncRemote();
    expect(identical(first, second), isTrue);
    completer.completeError(StateError('database unavailable'));
    expect(await first, isFalse);
    expect(await second, isFalse);
    expect(runs, 1);
    expect(callbacks, ['start', 'Bad state: database unavailable']);
  });

  test('a failed attempt does not prevent a later successful retry', () async {
    int runs = 0;
    final results = <bool?>[];
    final manager = BackgroundSyncManager(
      remoteSyncRunner: () => Cancelable<bool?>.fromFuture(Future.value(++runs > 1)),
      onRemoteSyncComplete: results.add,
    );
    expect(await manager.syncRemote(), isFalse);
    expect(await manager.syncRemote(), isTrue);
    expect(results, [false, true]);
  });

  test('cancellation never reports success and a subsequent sync can run', () async {
    final completer = Completer<bool?>();
    int runs = 0;
    final results = <bool?>[];
    final manager = BackgroundSyncManager(
      remoteSyncRunner: () => ++runs == 1
          ? Cancelable<bool?>(completer: completer, onCancel: () => completer.completeError(CanceledError()))
          : Cancelable<bool?>.fromFuture(Future.value(true)),
      onRemoteSyncComplete: results.add,
    );
    final pending = manager.syncRemote();
    await manager.cancel();
    expect(await pending, isFalse);
    expect(results, isEmpty);
    expect(await manager.syncRemote(), isTrue);
  });
}
