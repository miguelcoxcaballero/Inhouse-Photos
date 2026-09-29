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
}
