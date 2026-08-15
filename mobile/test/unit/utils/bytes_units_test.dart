import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

void main() {
  group('calculateStorageSavingsPercent', () {
    test('shows the reduction achieved by a prepared upload', () {
      expect(calculateStorageSavingsPercent(2900, 1700), 41);
    });

    test('shows zero when Storage saver keeps the original', () {
      expect(calculateStorageSavingsPercent(1000, 1000), 0);
      expect(calculateStorageSavingsPercent(1000, 1100), 0);
    });

    test('waits until both sizes are known', () {
      expect(calculateStorageSavingsPercent(1000, 0), isNull);
      expect(calculateStorageSavingsPercent(0, 500), isNull);
    });
  });
}
