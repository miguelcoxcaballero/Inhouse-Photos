import 'dart:math' as math;

/// Additive increase/multiplicative decrease for a single backup run.
/// Samples completed transfers rather than guessing throughput from the
/// connection type. The caller owns the actual concurrency gate.
class AdaptiveUploadLimiter {
  AdaptiveUploadLimiter({required this.maximum, required bool isUnmetered})
    : current = math.min(maximum, isUnmetered ? 4 : 2),
      _minimum = math.min(maximum, isUnmetered ? 4 : 2);

  final int maximum;
  final int _minimum;
  int current;
  DateTime? _windowStart;
  int _bytes = 0;
  int _completed = 0;
  int _failed = 0;
  double? _previousBytesPerSecond;

  /// Returns a new limit when a five-second sample has enough observations.
  int? record({required int bytes, required bool success, required DateTime now}) {
    _windowStart ??= now;
    if (success) {
      _bytes += math.max(0, bytes);
      _completed++;
    } else {
      _failed++;
    }
    final elapsed = now.difference(_windowStart!);
    if (elapsed < const Duration(seconds: 5) || _completed + _failed < 4) {
      return null;
    }
    final rate = _bytes / math.max(1, elapsed.inMilliseconds) * 1000;
    if (_failed > 0) {
      current = math.max(_minimum, (current / 2).ceil());
    } else if (_previousBytesPerSecond == null || rate >= _previousBytesPerSecond! * .85) {
      current = math.min(maximum, current + 2);
    } else {
      current = math.max(_minimum, current - 1);
    }
    _previousBytesPerSecond = rate;
    _windowStart = now;
    _bytes = 0;
    _completed = 0;
    _failed = 0;
    return current;
  }
}
