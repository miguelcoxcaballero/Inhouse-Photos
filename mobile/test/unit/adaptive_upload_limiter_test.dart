import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/adaptive_upload_limiter.dart';

void main() {
  test('starts with four Wi-Fi uploads and ramps up after a healthy sample', () {
    final limiter = AdaptiveUploadLimiter(maximum: 24, isUnmetered: true);
    final start = DateTime.utc(2026);
    expect(limiter.current, 4);
    for (var i = 0; i < 3; i++) {
      expect(limiter.record(bytes: 1000, success: true, now: start.add(Duration(seconds: i))), isNull);
    }
    expect(limiter.record(bytes: 1000, success: true, now: start.add(const Duration(seconds: 5))), 6);
  });

  test('backs off on errors but never drops below the safe starting limit', () {
    final limiter = AdaptiveUploadLimiter(maximum: 12, isUnmetered: false);
    final start = DateTime.utc(2026);
    expect(limiter.current, 2);
    for (var i = 0; i < 3; i++) {
      limiter.record(bytes: 1000, success: true, now: start.add(Duration(seconds: i)));
    }
    expect(limiter.record(bytes: 0, success: false, now: start.add(const Duration(seconds: 5))), 2);
  });
}
