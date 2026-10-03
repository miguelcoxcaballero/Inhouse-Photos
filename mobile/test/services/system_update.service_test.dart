import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/services/system_update.service.dart';

void main() {
  final url = Uri.parse('https://photos.example.com/inhouse-manager/v1/system-update');

  Map<String, dynamic> status({String phase = 'idle'}) => {
    'CurrentVersion': '3.1.95',
    'LatestVersion': '3.1.96',
    'Available': true,
    'Phase': phase,
    'Progress': 42,
    'Notes': 'Store uploads before processing them.',
  };

  test('system update uses only the saved public HTTPS origin', () {
    expect(SystemUpdateService.urlForEndpoint('https://photos.example.com/api?ignored=1'), url);
    for (final endpoint in [
      null,
      'http://photos.example.com/api',
      'https://user:pass@photos.example.com/api',
      'https://photos.example.com:8443/api',
      '/api',
    ]) {
      expect(SystemUpdateService.urlForEndpoint(endpoint), isNull, reason: '$endpoint');
    }
  });

  test('reads authenticated public version and progress with optional recovery flags', () async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url, url);
      expect(request.headers['authorization'], 'Bearer admin-token');
      expect(request.headers['cache-control'], 'no-store');
      return http.Response(jsonEncode(status(phase: 'downloading')), 200);
    });
    addTearDown(client.close);

    final value = await SystemUpdateService(client).check(url, 'admin-token');

    expect(value.currentVersion, '3.1.95');
    expect(value.latestVersion, '3.1.96');
    expect(value.available, isTrue);
    expect(value.phase, 'downloading');
    expect(value.progress, 42);
    expect(value.notes, contains('before processing'));
    expect(value.recoveryRequired, isFalse);
    expect(value.requiresLocalRecovery, isFalse);
    expect(value.busy, isFalse);
    expect(value.stage, isEmpty);
    expect(value.stageElapsedSeconds, 0);
  });

  test('stage diagnostics accept either JSON casing without changing update progress', () async {
    for (final pascalFields in [true, false]) {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            ...status(phase: 'installing'),
            pascalFields ? 'Stage' : 'stage': 'image',
            pascalFields ? 'StageElapsedSeconds' : 'stageElapsedSeconds': 45,
          }),
          200,
        ),
      );
      addTearDown(client.close);

      final value = await SystemUpdateService(client).check(url, 'admin-token');

      expect(value.stage, 'image');
      expect(value.stageElapsedSeconds, 45);
      expect(value.phase, 'installing');
      expect(value.progress, 42);
    }
  });

  test('accepts camelCase status and both recovery flag casings', () async {
    for (final pascalFlags in [true, false]) {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'currentVersion': '3.1.95',
            'latestVersion': '3.1.96',
            'available': true,
            'phase': 'error',
            'progress': 120,
            'error': 'Recovery must finish on the PC.',
            pascalFlags ? 'RecoveryRequired' : 'recoveryRequired': true,
            pascalFlags ? 'RequiresLocalRecovery' : 'requiresLocalRecovery': true,
            pascalFlags ? 'Busy' : 'busy': true,
          }),
          200,
        ),
      );
      addTearDown(client.close);

      final value = await SystemUpdateService(client).check(url, 'admin-token');

      expect(value.recoveryRequired, isTrue);
      expect(value.requiresLocalRecovery, isTrue);
      expect(value.busy, isTrue);
      expect(value.progress, 100);
      expect(value.error, contains('PC'));
    }
  });

  test('missing system route supports legacy manager bootstrap', () async {
    final client = MockClient((_) async => http.Response('', 404));
    addTearDown(client.close);

    expect(
      () => SystemUpdateService(client).check(url, 'admin-token'),
      throwsA(isA<SystemUpdateException>().having((error) => error.unsupported, 'unsupported', isTrue)),
    );
  });

  test('HTML during API restart remains a connection failure', () async {
    final client = MockClient(
      (_) async => http.Response('<html>503 Service Unavailable</html>', 503, headers: {'content-type': 'text/html'}),
    );
    addTearDown(client.close);

    expect(
      () => SystemUpdateService(client).check(url, 'admin-token'),
      throwsA(
        isA<SystemUpdateException>()
            .having((error) => error.unsupported, 'unsupported', isFalse)
            .having((error) => error.authentication, 'authentication', isFalse),
      ),
    );
  });

  test('HTML photo app on a missing route is unsupported rather than successful', () async {
    final client = MockClient(
      (_) async => http.Response('<html>Inhouse Photos</html>', 200, headers: {'content-type': 'text/html'}),
    );
    addTearDown(client.close);

    expect(
      () => SystemUpdateService(client).check(url, 'admin-token'),
      throwsA(isA<SystemUpdateException>().having((error) => error.unsupported, 'unsupported', isTrue)),
    );
  });

  test('administrator rejection is distinct from restart and unsupported states', () async {
    final client = MockClient((_) async => http.Response('{"message":"Sign in again as administrator"}', 401));
    addTearDown(client.close);

    expect(
      () => SystemUpdateService(client).check(url, 'admin-token'),
      throwsA(
        isA<SystemUpdateException>()
            .having((error) => error.authentication, 'authentication', isTrue)
            .having((error) => error.unsupported, 'unsupported', isFalse),
      ),
    );
  });

  test('starts one fixed operation without a phone-supplied version or installer URL', () async {
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url, url);
      expect(request.body, isEmpty);
      expect(request.headers['authorization'], 'Bearer admin-token');
      return http.Response('', 202);
    });
    addTearDown(client.close);

    await SystemUpdateService(client).start(url, 'admin-token');
  });

  test('missing administrator credentials prevent both reads and changes', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('', 401);
    });
    addTearDown(client.close);
    final service = SystemUpdateService(client);

    for (final operation in [() => service.check(url, '  '), () => service.start(url, '')]) {
      await expectLater(
        operation,
        throwsA(isA<SystemUpdateException>().having((error) => error.authentication, 'authentication', isTrue)),
      );
    }
    expect(requests, 0);
  });

  test('busy PC rejection retains the reason without claiming an update started', () async {
    final client = MockClient((_) async => http.Response('{"message":"PC busy with backup"}', 409));
    addTearDown(client.close);

    expect(
      () => SystemUpdateService(client).start(url, 'admin-token'),
      throwsA(
        isA<SystemUpdateException>()
            .having((error) => error.message, 'message', 'PC busy with backup')
            .having((error) => error.uncertain, 'uncertain', isFalse),
      ),
    );
  });

  test('lost POST response is not automatically sent again', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      throw http.ClientException('Response lost', request.url);
    });
    addTearDown(client.close);

    await expectLater(
      () => SystemUpdateService(client).start(url, 'admin-token'),
      throwsA(
        isA<SystemUpdateException>()
            .having((error) => error.message, 'message', contains('confirmed'))
            .having((error) => error.uncertain, 'uncertain', isTrue),
      ),
    );
    expect(requests, 1);
  });

  test('malformed response cannot expose an available system update', () async {
    final client = MockClient((_) async => http.Response('{"Available":true}', 200));
    addTearDown(client.close);

    expect(() => SystemUpdateService(client).check(url, 'admin-token'), throwsA(isA<SystemUpdateException>()));
  });
}
