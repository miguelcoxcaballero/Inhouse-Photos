import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/upload_speed_calculator.dart';

void main() {
  final start = DateTime.utc(2026, 9, 29);

  test('sums concurrent traffic and retains completed transfers in the measurement window', () {
    final tracker = AggregateUploadSpeed();
    tracker.update('photo-a', 100, start);
    tracker.update('photo-b', 200, start);
    tracker.update('photo-a', 1100, start.add(const Duration(seconds: 1)));
    tracker.update('photo-b', 2200, start.add(const Duration(seconds: 1)));

    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 1))), 3000);
    tracker.remove('photo-a');
    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 1))), 3000);
    tracker.remove('photo-b');
    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 1))), 3000);
    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 5))), isNull);
  });

  test('a stream of small completed photos contributes the whole recent throughput', () {
    final tracker = AggregateUploadSpeed();
    for (var i = 0; i < 10; i++) {
      final task = 'photo-$i';
      tracker.update(task, 0, start.add(Duration(milliseconds: i * 100)));
      tracker.update(task, 1000, start.add(Duration(milliseconds: i * 100 + 100)));
      tracker.remove(task);
    }

    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 1))), 10000);
    tracker.update('photo-next', 0, start.add(const Duration(seconds: 1)));
    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 1))), 10000);
    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 5))), 0);
  });

  test('stalled uploads fall to zero instead of showing a stale speed', () {
    final tracker = AggregateUploadSpeed();
    tracker.update('video', 0, start);
    tracker.update('video', 3000, start.add(const Duration(seconds: 1)));
    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 1))), 3000);
    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 5))), 0);
  });

  test('a retry resets its baseline while retaining genuine bytes from the previous attempt', () {
    final tracker = AggregateUploadSpeed();
    tracker.update('video', 0, start);
    tracker.update('video', 3000, start.add(const Duration(seconds: 1)));
    tracker.update('video', 100, start.add(const Duration(seconds: 2)));
    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 2))), 1500);
    tracker.update('video', 1100, start.add(const Duration(seconds: 3)));
    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 3))), closeTo(4000 / 3, .001));
    tracker.update('video', 2100, start.add(const Duration(seconds: 5)));
    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 5))), closeTo(2000 / 3, .001));
  });

  test('new transfers do not inherit an inflated denominator from completed tasks', () {
    final tracker = AggregateUploadSpeed();
    tracker.update('first', 0, start);
    tracker.update('first', 3000, start.add(const Duration(seconds: 1)));
    tracker.remove('first');
    tracker.update('second', 0, start.add(const Duration(milliseconds: 1100)));
    tracker.update('second', 3000, start.add(const Duration(seconds: 2)));

    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 2))), 3000);
    tracker.remove('second');
    tracker.update('third', 0, start.add(const Duration(seconds: 6)));
    tracker.update('third', 2000, start.add(const Duration(seconds: 7)));
    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 7))), 2000);
  });

  test('cancellation clears recent traffic and the next session starts from a fresh baseline', () {
    final tracker = AggregateUploadSpeed();
    tracker.update('photo', 0, start);
    tracker.update('photo', 3000, start.add(const Duration(seconds: 1)));
    tracker.clear();
    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 1))), isNull);
    tracker.update('photo', 100, start.add(const Duration(seconds: 1)));
    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 1))), 0);
    tracker.update('photo', 1100, start.add(const Duration(seconds: 2)));
    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 2))), 1000);
  });

  test('retained bytes expire during another active transfer without making it idle', () {
    final tracker = AggregateUploadSpeed();
    tracker.update('photo', 0, start);
    tracker.update('photo', 3000, start.add(const Duration(seconds: 1)));
    tracker.remove('photo');
    tracker.update('video', 0, start.add(const Duration(seconds: 2)));

    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 2))), 1500);
    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 5))), 0);
    tracker.remove('video');
    expect(tracker.bytesPerSecond(start.add(const Duration(seconds: 5))), isNull);
  });

  test('formats active speed without pretending idle is a connection benchmark', () {
    expect(formatAggregateUploadSpeed(null), '—');
    expect(formatAggregateUploadSpeed(0), '0 B/s');
    expect(formatAggregateUploadSpeed(512 * 1024), '512 KiB/s');
    expect(formatAggregateUploadSpeed(2.5 * 1024 * 1024), '2.5 MiB/s');
    expect(formatAggregateUploadSpeed(10 * 1024 * 1024), '10 MiB/s');
  });
}
