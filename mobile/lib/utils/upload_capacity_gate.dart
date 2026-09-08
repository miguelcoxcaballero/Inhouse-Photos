import 'dart:async';
import 'dart:collection';

/// Bounded server work that can be cancelled without leaving upload workers
/// waiting forever for a compression acknowledgement.
class UploadCapacityGate {
  UploadCapacityGate(this.limit);
  final int limit;
  final Queue<Completer<bool>> _waiting = Queue();
  int _held = 0;
  bool _cancelled = false;

  Future<bool> acquire() {
    if (_cancelled) {
      return Future.value(false);
    }
    if (limit <= 0) {
      return Future.value(true);
    }
    if (_held < limit) {
      _held++;
      return Future.value(true);
    }
    final waiter = Completer<bool>();
    _waiting.add(waiter);
    return waiter.future;
  }

  void release() {
    if (_cancelled || limit <= 0) {
      return;
    }
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete(true);
    } else if (_held > 0) {
      _held--;
    }
  }

  void cancel() {
    _cancelled = true;
    while (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete(false);
    }
  }
}
