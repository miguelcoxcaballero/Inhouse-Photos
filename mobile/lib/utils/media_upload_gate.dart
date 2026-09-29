import 'dart:async';
import 'dart:collection';

/// Keeps a large video from competing with dozens of other uploads for the
/// same upstream connection. Photos still use the adaptive parallel limit.
/// Once a video is waiting, the current photo batch drains before it starts;
/// video and photo batches then alternate so neither kind can starve.
class MediaUploadGate {
  MediaUploadGate(this._photoLimit) : assert(_photoLimit > 0);

  int _photoLimit;
  int _activePhotos = 0;
  bool _activeVideo = false;
  bool _cancelled = false;
  bool _preferVideo = true;
  final Queue<Completer<bool>> _waitingPhotos = Queue<Completer<bool>>();
  final Queue<Completer<bool>> _waitingVideos = Queue<Completer<bool>>();

  Future<bool> acquire({required bool isVideo}) {
    if (_cancelled) {
      return Future.value(false);
    }
    final waiter = Completer<bool>();
    (isVideo ? _waitingVideos : _waitingPhotos).addLast(waiter);
    _wakeWaiting();
    return waiter.future;
  }

  void release({required bool isVideo}) {
    if (isVideo) {
      _activeVideo = false;
    } else if (_activePhotos > 0) {
      _activePhotos--;
    }
    _wakeWaiting();
  }

  void updatePhotoLimit(int limit) {
    if (_cancelled || limit < 1) {
      return;
    }
    _photoLimit = limit;
    _wakeWaiting();
  }

  void _wakeWaiting() {
    if (_cancelled || _activeVideo) {
      return;
    }
    // Never start another photo while a video is waiting for the current
    // batch to finish. This guarantees the video eventually gets bandwidth.
    if (_activePhotos > 0 && _waitingVideos.isNotEmpty) {
      return;
    }
    if (_activePhotos == 0 && _waitingVideos.isNotEmpty && (_preferVideo || _waitingPhotos.isEmpty)) {
      _activeVideo = true;
      _preferVideo = false;
      _waitingVideos.removeFirst().complete(true);
      return;
    }
    if (_waitingPhotos.isNotEmpty) {
      _preferVideo = true;
      while (_waitingPhotos.isNotEmpty && _activePhotos < _photoLimit) {
        _activePhotos++;
        _waitingPhotos.removeFirst().complete(true);
      }
    }
  }

  void cancel() {
    _cancelled = true;
    for (final queue in [_waitingPhotos, _waitingVideos]) {
      while (queue.isNotEmpty) {
        queue.removeFirst().complete(false);
      }
    }
  }
}
