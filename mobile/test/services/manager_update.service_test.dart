import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/services/manager_update.service.dart';

void main() {
  test('manager update URL stays on the saved HTTPS server origin', () {
    expect(
      ManagerUpdateService.urlForEndpoint('https://fotos.example.com/api').toString(),
      'https://fotos.example.com/inhouse-manager/v1/update',
    );
    expect(ManagerUpdateService.urlForEndpoint('http://fotos.example.com/api'), isNull);
    expect(ManagerUpdateService.urlForEndpoint('https://user:pass@fotos.example.com/api'), isNull);
  });

  test('checks version with bearer token and parses update progress', () async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.headers['authorization'], 'Bearer test-token');
      return http.Response(
        jsonEncode({
          'CurrentVersion': '1.2.8',
          'LatestVersion': '1.2.9',
          'Available': true,
          'Phase': 'downloading',
          'Progress': 42,
          'Error': '',
        }),
        200,
      );
    });
    final service = ManagerUpdateService(client);
    final status = await service.check(Uri.parse('https://fotos.example.com/inhouse-manager/v1/update'), 'test-token');
    expect(status.available, isTrue);
    expect(status.progress, 42);
    expect(status.latestVersion, '1.2.9');
    client.close();
  });

  test('remote update sends no arbitrary version or installer URL', () async {
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.body, isEmpty);
      expect(request.headers['authorization'], 'Bearer admin-token');
      return http.Response('{}', 202);
    });
    await ManagerUpdateService(
      client,
    ).start(Uri.parse('https://fotos.example.com/inhouse-manager/v1/update'), 'admin-token');
    client.close();
  });

  test('server refusal is shown without claiming the photo server is down', () async {
    final client = MockClient((_) async => http.Response('{"message":"PC busy with backup"}', 409));
    expect(
      () => ManagerUpdateService(client).start(Uri.parse('https://fotos.example.com/inhouse-manager/v1/update'), 't'),
      throwsA(isA<ManagerUpdateException>().having((e) => e.message, 'message', 'PC busy with backup')),
    );
    client.close();
  });
}
