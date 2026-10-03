import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/services/runtime_update.service.dart';

void main() {
  final url = Uri.parse('https://photos.example.com/inhouse-manager/v1/runtime-update');

  test('engine update uses only the saved public HTTPS origin', () {
    expect(RuntimeUpdateService.urlForEndpoint('https://photos.example.com/api?ignored=1'), url);
    for (final endpoint in [
      null,
      'http://photos.example.com/api',
      'https://user:pass@photos.example.com/api',
      'https://photos.example.com:8443/api',
      '/api',
    ]) {
      expect(RuntimeUpdateService.urlForEndpoint(endpoint), isNull, reason: '$endpoint');
    }
  });

  test('reads PascalCase engine version and progress with administrator credentials', () async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url, url);
      expect(request.headers['authorization'], 'Bearer admin-token');
      expect(request.headers['cache-control'], 'no-store');
      return http.Response(
        jsonEncode({
          'CurrentVersion': '3.1.0',
          'LatestVersion': '3.1.0-durable-upload',
          'Available': true,
          'Phase': 'downloading',
          'Progress': 42,
          'Error': '',
          'Notes': 'Store uploads before background processing.',
        }),
        200,
      );
    });
    addTearDown(client.close);

    final status = await RuntimeUpdateService(client).check(url, 'admin-token');

    expect(status.currentVersion, '3.1.0');
    expect(status.latestVersion, '3.1.0-durable-upload');
    expect(status.available, isTrue);
    expect(status.phase, 'downloading');
    expect(status.progress, 42);
    expect(status.error, isEmpty);
    expect(status.notes, contains('background processing'));
  });

  test('accepts camelCase status after restart and clamps progress for display', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'currentVersion': '3.1.0-durable-upload',
          'latestVersion': '3.1.0-durable-upload',
          'available': false,
          'phase': 'completed',
          'progress': 120,
        }),
        200,
      ),
    );
    addTearDown(client.close);

    final status = await RuntimeUpdateService(client).check(url, 'admin-token');

    expect(status.available, isFalse);
    expect(status.phase, 'completed');
    expect(status.progress, 100);
    expect(status.error, isEmpty);
    expect(status.notes, isEmpty);
    expect(status.recoveryRequired, isFalse);
  });

  test('optional recovery flag supports either casing with mixed-case status fields', () async {
    for (final recoveryField in ['RecoveryRequired', 'recoveryRequired']) {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'CurrentVersion': '3.1.0',
            'latestVersion': '3.1.0-durable-upload',
            'Available': true,
            'phase': 'error',
            'Progress': 0,
            recoveryField: true,
          }),
          200,
        ),
      );
      addTearDown(client.close);

      final status = await RuntimeUpdateService(client).check(url, 'admin-token');

      expect(status.recoveryRequired, isTrue, reason: recoveryField);
      expect(status.available, isTrue);
      expect(status.phase, 'error');
    }
  });

  test('old manager without runtime route is explicitly unsupported', () async {
    final client = MockClient((_) async => http.Response('', 404));
    addTearDown(client.close);

    expect(
      () => RuntimeUpdateService(client).check(url, 'admin-token'),
      throwsA(isA<RuntimeUpdateException>().having((error) => error.unsupported, 'unsupported', isTrue)),
    );
  });

  test('temporary restart failure is not confused with an old manager', () async {
    final client = MockClient(
      (_) async =>
          http.Response('<html><body>502 Bad Gateway</body></html>', 502, headers: {'content-type': 'text/html'}),
    );
    addTearDown(client.close);

    expect(
      () => RuntimeUpdateService(client).check(url, 'admin-token'),
      throwsA(isA<RuntimeUpdateException>().having((error) => error.unsupported, 'unsupported', isFalse)),
    );
  });

  test('unpublished runtime route returning the photo web page is unsupported', () async {
    final client = MockClient(
      (_) async =>
          http.Response('<html><body>Inhouse Photos</body></html>', 200, headers: {'content-type': 'text/html'}),
    );
    addTearDown(client.close);

    expect(
      () => RuntimeUpdateService(client).check(url, 'admin-token'),
      throwsA(isA<RuntimeUpdateException>().having((error) => error.unsupported, 'unsupported', isTrue)),
    );
  });

  test('starts engine update with no phone-supplied version, command or download URL', () async {
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url, url);
      expect(request.body, isEmpty);
      expect(request.headers['authorization'], 'Bearer admin-token');
      return http.Response('', 202);
    });
    addTearDown(client.close);

    await RuntimeUpdateService(client).start(url, 'admin-token');
  });

  test('busy PC rejection retains the server message instead of claiming success', () async {
    final client = MockClient((_) async => http.Response('{"message":"PC busy with backup"}', 409));
    addTearDown(client.close);

    expect(
      () => RuntimeUpdateService(client).start(url, 'admin-token'),
      throwsA(isA<RuntimeUpdateException>().having((error) => error.message, 'message', 'PC busy with backup')),
    );
  });

  test('malformed engine response does not produce an available update', () async {
    final client = MockClient((_) async => http.Response('{"Available":true}', 200));
    addTearDown(client.close);

    expect(() => RuntimeUpdateService(client).check(url, 'admin-token'), throwsA(isA<RuntimeUpdateException>()));
  });
}
