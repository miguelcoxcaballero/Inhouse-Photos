import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment.model.dart';

void main() {
  test('a full queue discards the newest request before schedule returns', () {
    // This is the contract a dense screen hits constantly: it asks for more
    // cells than the queue holds, so the discard path is the normal one. A
    // caller that assumed `onDiscard` could only run later read a `late` local
    // that `schedule` had not returned into yet and threw, which killed the
    // loop requesting the rest of the panel and the retry meant to recover it.
    final queue = DenseThumbnailQueue(maxPending: 1);
    final blocked = Completer<void>();
    addTearDown(() => blocked.complete());

    // Occupy every worker so nothing drains, then fill the one pending slot.
    for (var i = 0; i < 32; i++) {
      queue.schedule(() => blocked.future);
    }

    var returned = false;
    var discardedSynchronously = false;
    queue.schedule(
      () async {},
      onDiscard: () => discardedSynchronously = !returned,
    );
    returned = true;

    expect(discardedSynchronously, isTrue, reason: 'onDiscard must run before schedule returns');
  });

  test('a request that fits is not discarded', () {
    final queue = DenseThumbnailQueue(maxPending: 8);
    var discarded = false;
    final handle = queue.schedule(() async {}, onDiscard: () => discarded = true);
    expect(discarded, isFalse);
    // Cancelling explicitly must not fire the discard callback either: the
    // owning panel is tearing down and has nothing left to reconcile.
    handle.cancel();
    expect(discarded, isFalse);
  });
}
