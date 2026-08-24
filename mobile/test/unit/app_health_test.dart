import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/log.model.dart';
import 'package:immich_mobile/utils/app_health.dart';

void main() {
  group('redactServerEndpoint', () {
    test('keeps only the public origin', () {
      expect(redactServerEndpoint('https://photos.example.com/api?token=secret#private'), 'https://photos.example.com');
      expect(redactServerEndpoint('http://192.168.1.2:2283/api'), 'http://192.168.1.2:2283');
    });

    test('does not echo malformed input', () {
      expect(redactServerEndpoint('secret-token-without-a-host'), 'Configured endpoint is invalid');
      expect(redactServerEndpoint(null), 'Not configured');
    });
  });

  test('summarizes warning and severe logs without exporting their content', () {
    final now = DateTime(2026);
    final summary = summarizeLogHealth([
      LogMessage(message: 'one', level: LogLevel.info, createdAt: now),
      LogMessage(message: 'two', level: LogLevel.warning, createdAt: now),
      LogMessage(message: 'three', level: LogLevel.severe, createdAt: now),
      LogMessage(message: 'four', level: LogLevel.shout, createdAt: now),
    ]);

    expect(summary.warnings, 1);
    expect(summary.severe, 2);
  });

  test('diagnostic report contains health totals but no credential fields', () {
    final report = buildAppHealthReport(
      appVersion: '3.1.54',
      buildNumber: '5112',
      platform: 'Android',
      endpoint: 'https://photos.example.com',
      serverVersion: '2.0.0',
      serverStatus: 'upToDate',
      diskSummary: '10 GiB of 100 GiB',
      backupTotal: 10,
      backupComplete: 8,
      backupRemaining: 2,
      backupErrors: 1,
      imageCacheItems: 20,
      imageCacheBytes: 1024,
      logWarnings: 2,
      logSevere: 1,
      offlineAlbumCount: 3,
      originalBytes: 1000,
      storedBytes: 600,
    );

    expect(report, contains('Bytes saved: 400'));
    expect(report, contains('Offline albums: 3'));
    expect(report.toLowerCase(), isNot(contains('access token:')));
  });
}
