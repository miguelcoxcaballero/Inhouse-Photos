import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/upload_capacity_gate.dart';

void main() {
  test('cancellation wakes all blocked uploads without acquiring permits', () async {
    final gate = UploadCapacityGate(1);
    expect(await gate.acquire(), isTrue);
    final blocked = [gate.acquire(), gate.acquire(), gate.acquire()];
    gate.cancel();
    expect(await Future.wait(blocked), everyElement(isFalse));
    gate.release();
    expect(await gate.acquire(), isFalse);
  });
  test('release hands a permit to the next waiting upload', () async {
    final gate = UploadCapacityGate(1);
    expect(await gate.acquire(), isTrue);
    final second = gate.acquire();
    gate.release();
    expect(await second, isTrue);
    gate.release();
    expect(await gate.acquire(), isTrue);
  });
  test('lowering concurrency lets in-flight uploads finish before waking waiters', () async {
    final gate = UploadCapacityGate(2);
    expect(await gate.acquire(), isTrue);
    expect(await gate.acquire(), isTrue);
    final waiting = gate.acquire();
    var woke = false;
    unawaited(waiting.then((_) => woke = true));
    gate.updateLimit(1);
    gate.release();
    await Future<void>.delayed(Duration.zero);
    expect(woke, isFalse);
    gate.release();
    expect(await waiting, isTrue);
    gate.release();
  });
  test('original-quality uploads are unrestricted but still cancellable', () async {
    final gate = UploadCapacityGate(0);
    expect(await gate.acquire(), isTrue);
    expect(await gate.acquire(), isTrue);
    gate.cancel();
    expect(await gate.acquire(), isFalse);
  });
}
