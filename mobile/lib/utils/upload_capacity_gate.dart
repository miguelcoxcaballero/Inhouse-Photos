import 'dart:async';
import 'dart:collection';

/// Bounded server work that can be cancelled without leaving upload workers
/// waiting forever for a compression acknowledgement.
class UploadCapacityGate {
  UploadCapacityGate(this._limit);
  int _limit;
  int get limit => _limit;
  final Queue<Completer<bool>> _waiting = Queue();
  int _held = 0;
  bool _cancelled = false;

  Future<bool> acquire() {
    if (_cancelled) {
      return Future.value(false);
    }
    if (_limit <= 0) {
      return Future.value(true);
    }
    if (_held < _limit) {
      _held++;
      return Future.value(true);
    }
    final waiter = Completer<bool>();
    _waiting.add(waiter);
    return waiter.future;
  }

  void release() {
    if (_cancelled || _limit <= 0) {
      return;
    }
    if (_held > 0) {
      _held--;
    }
    _wakeWaiting();
  }

  /// Change concurrency without discarding in-flight requests. When lowering
  /// the limit, existing uploads finish normally and new ones wait.
  void updateLimit(int limit) {
    if (_cancelled || _limit <= 0 || limit < 1) {
      return;
    }
    _limit = limit;
    _wakeWaiting();
  }

  void _wakeWaiting() {
    while (_waiting.isNotEmpty && _held < _limit) {
      _held++;
      _waiting.removeFirst().complete(true);
    }
  }

  void cancel() {
    _cancelled = true;
    while (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete(false);
    }
  }
}
