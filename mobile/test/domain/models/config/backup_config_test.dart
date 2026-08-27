import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/config/backup_config.dart';

void main() {
  group('Backup transfer plan', () {
    test('defaults to maximum throughput', () {
      expect(const BackupConfig().speed, BackupSpeedMode.maximum);
    });

    test('maximum saturates unmetered networks with bounded queues', () {
      final plan = BackupSpeedMode.maximum.transferPlan(isUnmetered: true, itemCount: 1000);

      expect(plan.preparationWorkers, 8);
      expect(plan.uploadWorkers, 24);
      expect(plan.acknowledgementWorkers, 6);
      expect(plan.preparedQueueCapacity, 64);
      expect(plan.acknowledgementQueueCapacity, 64);
    });

    test('maximum remains conservative on metered networks', () {
      final plan = BackupSpeedMode.maximum.transferPlan(isUnmetered: false, itemCount: 1000);

      expect(plan.preparationWorkers, 4);
      expect(plan.uploadWorkers, 12);
      expect(plan.acknowledgementWorkers, 3);
      expect(plan.preparedQueueCapacity, 36);
      expect(plan.acknowledgementQueueCapacity, 48);
    });

    test('balanced and fast scale on unmetered networks', () {
      final balanced = BackupSpeedMode.balanced.transferPlan(isUnmetered: true, itemCount: 100);
      final fast = BackupSpeedMode.fast.transferPlan(isUnmetered: true, itemCount: 100);

      expect((balanced.preparationWorkers, balanced.uploadWorkers, balanced.acknowledgementWorkers), (4, 6, 2));
      expect((fast.preparationWorkers, fast.uploadWorkers, fast.acknowledgementWorkers), (6, 12, 3));
    });

    test('never starts more workers than assets', () {
      final plan = BackupSpeedMode.maximum.transferPlan(isUnmetered: true, itemCount: 2);

      expect(plan.preparationWorkers, 2);
      expect(plan.uploadWorkers, 2);
      expect(plan.acknowledgementWorkers, 2);
      expect(plan.preparedQueueCapacity, 6);
      expect(plan.acknowledgementQueueCapacity, 8);
    });

    test('empty libraries produce an empty plan', () {
      expect(BackupSpeedMode.maximum.transferPlan(isUnmetered: true, itemCount: 0), same(BackupTransferPlan.empty));
    });
  });
}
