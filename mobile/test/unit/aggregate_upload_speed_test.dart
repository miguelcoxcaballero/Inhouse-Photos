import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/upload_speed_calculator.dart';

void main() {
  final start = DateTime.utc(2026, 9, 29);

  test('sums bytes from concurrent uploads without counting their first progress event', () {
    final tracker = AggregateUploadSpeed();
    tracker.update('photo-a', 100, start);
    tracker.update('photo-b', 200, start);
    tracker.update('photo-a', 1100, start.add(const Duration(seconds: 1)));
    tracker.update('photo-b', 2200, start.add(const Duration(seconds: 1)));

    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 1))), 3000);
    tracker.remove('photo-a');
    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 1))), 2000);
    tracker.remove('photo-b');
    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 1))), isNull);
  });

  test('stalled uploads fall to zero instead of showing a stale speed', () {
    final tracker = AggregateUploadSpeed();
    tracker.update('video', 0, start);
    tracker.update('video', 3000, start.add(const Duration(seconds: 1)));
    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 1))), 3000);
    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 5))), 0);
  });

  test('a retry resets the byte baseline without negative or inflated throughput', () {
    final tracker = AggregateUploadSpeed();
    tracker.update('video', 0, start);
    tracker.update('video', 3000, start.add(const Duration(seconds: 1)));
    tracker.update('video', 100, start.add(const Duration(seconds: 2)));
    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 2))), 0);
    tracker.update('video', 1100, start.add(const Duration(seconds: 3)));
    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 3))), 1000);
  });

  test('formats active speed without pretending idle is a connection benchmark', () {
    expect(formatAggregateUploadSpeed(null), '—');
    expect(formatAggregateUploadSpeed(0), '0 B/s');
    expect(formatAggregateUploadSpeed(512 * 1024), '512 kB/s');
    expect(formatAggregateUploadSpeed(2.5 * 1024 * 1024), '2.5 MB/s');
  });
}
