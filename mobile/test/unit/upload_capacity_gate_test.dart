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
  test('original-quality uploads are unrestricted but still cancellable', () async {
    final gate = UploadCapacityGate(0);
    expect(await gate.acquire(), isTrue);
    expect(await gate.acquire(), isTrue);
    gate.cancel();
    expect(await gate.acquire(), isFalse);
  });
}
