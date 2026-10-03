import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/services/server_management.service.dart';

void main() {
  const endpoint = 'https://fotos.example.com/api';
  final url = ServerManagementService.urlForEndpoint(endpoint)!;

  test('only an HTTPS server origin can be managed', () {
    expect(url.toString(), 'https://fotos.example.com/inhouse-manager/v1/status');
    expect(ServerManagementService.urlForEndpoint('http://fotos.example.com/api'), isNull);
    expect(ServerManagementService.urlForEndpoint('https://user:pass@fotos.example.com/api'), isNull);
  });

  test('status is read using the administrator bearer token', () async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url, url);
      expect(request.headers['authorization'], 'Bearer administrator-token');
      return http.Response(
        jsonEncode({
          'Version': '1.2.12',
          'ServerOnline': true,
          'Busy': false,
          'Operation': '',
          'Progress': '',
          'Error': '',
          'BackupDestination': 'E:\\',
          'BackupConfigured': true,
          'BackupRunning': false,
          'BackupPresent': true,
          'BackupCompletedUtc': '2026-09-29T17:00:00Z',
          'WeeklyBackupEnabled': true,
          'NextBackupUtc': '2026-10-04T03:00:00Z',
          'StartupEnabled': true,
          'StartupKnown': true,
          'Disks': [
            {
              'Root': 'E:\\',
              'Name': 'Backup',
              'Total': 1000,
              'Free': 800,
              'IsLibrary': false,
              'IsBackup': true,
              'CanUseForBackup': true,
            },
          ],
        }),
        200,
      );
    });
    final status = await ServerManagementService(client).read(url, 'administrator-token');
    expect(status.backupPresent, isTrue);
    expect(status.disks.single.free, 800);
    client.close();
  });

  test('engine status is optional and preserves older manager backup status', () {
    final status = ServerManagementStatus.fromJson({
      'Version': '1.2.16',
      'ServerOnline': true,
      'Busy': false,
      'Disks': [],
      'BackupConfigured': true,
    });
    expect(status.runtimeUpdate, isNull);
    expect(status.backupConfigured, isTrue);

    final recovery = ServerManagementStatus.fromJson({
      'Version': '1.2.17',
      'ServerOnline': true,
      'Busy': false,
      'Disks': [],
      'BackupConfigured': true,
      'RuntimeUpdate': {
        'CurrentVersion': '3.1.0',
        'LatestVersion': '3.1.0-durable-upload',
        'Available': true,
        'Phase': 'error',
        'Progress': 70,
        'RecoveryRequired': true,
      },
    });
    expect(recovery.runtimeUpdate?.recoveryRequired, isTrue);
    expect(recovery.runtimeUpdate?.phase, 'error');
    expect(recovery.backupConfigured, isTrue);
  });

  test('an incompatible optional engine status does not hide existing backup management', () {
    final status = ServerManagementStatus.fromJson({
      'Version': '1.2.17',
      'ServerOnline': true,
      'Busy': false,
      'Disks': [],
      'BackupConfigured': true,
      'RuntimeUpdate': {'Available': true},
    });
    expect(status.runtimeUpdate, isNull);
    expect(status.backupConfigured, isTrue);
  });

  test('actions have fixed paths, no arbitrary commands or payloads', () async {
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.body, isEmpty);
      expect(request.url.toString(), 'https://fotos.example.com/inhouse-manager/v1/status/backup/start');
      return http.Response('{"message":"Action accepted"}', 202);
    });
    await ServerManagementService(client).act(url, 'administrator-token', ServerManagementAction.startBackup);
    client.close();
  });

  test('backup drive is restricted to a Windows drive letter', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/inhouse-manager/v1/status/backup/destination/E');
      return http.Response('{}', 202);
    });
    final service = ServerManagementService(client);
    await service.selectBackupDrive(url, 'administrator-token', 'E:\\');
    expect(
      () => service.selectBackupDrive(url, 'administrator-token', r'..\\..\\C:\\'),
      throwsA(isA<ServerManagementException>()),
    );
    client.close();
  });

  test('a missing route and a web-app fallback identify unpublished management', () async {
    for (final response in [
      http.Response('{"message":"Not found"}', 404),
      http.Response('<!doctype html><html>Photo web app</html>', 200, headers: {'content-type': 'text/html'}),
    ]) {
      final client = MockClient((_) async => response);
      await expectLater(
        ServerManagementService(client).read(url, 'administrator-token'),
        throwsA(
          isA<ServerManagementException>()
              .having((error) => error.failure, 'reason', ServerManagementFailure.notPublished)
              .having((error) => error.message, 'next step', contains('Open or update')),
        ),
      );
      client.close();
    }
  });

  test('proxy outages can be retried without treating them as sign-in failures', () async {
    for (final code in [502, 503, 504]) {
      final client = MockClient((_) async => http.Response('', code));
      await expectLater(
        ServerManagementService(client).read(url, 'administrator-token'),
        throwsA(
          isA<ServerManagementException>()
              .having((error) => error.failure, 'reason', ServerManagementFailure.unavailable)
              .having((error) => error.canRetry, 'automatic retry', isTrue),
        ),
      );
      client.close();
    }
  });

  test('expired sign-in and rejected bridge configuration do not auto-retry', () async {
    for (final entry in {
      401: ServerManagementFailure.authentication,
      403: ServerManagementFailure.configuration,
    }.entries) {
      final client = MockClient((_) async => http.Response('{"message":"Forbidden"}', entry.key));
      await expectLater(
        ServerManagementService(client).read(url, 'administrator-token'),
        throwsA(
          isA<ServerManagementException>()
              .having((error) => error.failure, 'reason', entry.value)
              .having((error) => error.canRetry, 'automatic retry', isFalse),
        ),
      );
      client.close();
    }
  });

  test('invalid status data is not fabricated or classified as a network outage', () async {
    for (final body in ['{}', '{"Version":123}', 'not JSON']) {
      final client = MockClient((_) async => http.Response(body, 200));
      await expectLater(
        ServerManagementService(client).read(url, 'administrator-token'),
        throwsA(
          isA<ServerManagementException>().having(
            (error) => error.failure,
            'reason',
            ServerManagementFailure.invalidResponse,
          ),
        ),
      );
      client.close();
    }
  });

  test('an empty token is rejected before a management request is sent', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('{}', 200);
    });
    final service = ServerManagementService(client);
    await expectLater(service.read(url, ' '), throwsA(isA<ServerManagementException>()));
    await expectLater(
      service.act(url, '', ServerManagementAction.startBackup),
      throwsA(isA<ServerManagementException>()),
    );
    expect(requests, 0);
    client.close();
  });

  test('a hanging status request has a bounded, retryable timeout', () async {
    final pending = Completer<http.Response>();
    final client = MockClient((_) => pending.future);
    await expectLater(
      ServerManagementService(client, readTimeout: const Duration(milliseconds: 10)).read(url, 'administrator-token'),
      throwsA(
        isA<ServerManagementException>()
            .having((error) => error.failure, 'reason', ServerManagementFailure.timeout)
            .having((error) => error.canRetry, 'automatic retry', isTrue),
      ),
    );
    pending.complete(http.Response('{}', 200));
    client.close();
  });

  test('failed actions are sent once and are explicitly unconfirmed', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('', 503);
    });
    await expectLater(
      ServerManagementService(client).act(url, 'administrator-token', ServerManagementAction.startBackup),
      throwsA(isA<ServerManagementException>().having((error) => error.message, 'result', contains('not confirmed'))),
    );
    expect(requests, 1);
    client.close();
  });
}
