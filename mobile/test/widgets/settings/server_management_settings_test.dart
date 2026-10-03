import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/models/auth/auth_state.model.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/services/manager_update.service.dart';
import 'package:immich_mobile/services/runtime_update.service.dart';
import 'package:immich_mobile/services/server_management.service.dart';
import 'package:immich_mobile/widgets/settings/server_management_settings.dart';

class _AdminNotifier extends StateNotifier<AuthState> implements AuthNotifier {
  _AdminNotifier()
    : super(
        const AuthState(
          deviceId: 'phone',
          userId: 'admin',
          userEmail: 'admin@example.com',
          isAuthenticated: true,
          name: 'Admin',
          isAdmin: true,
          profileImagePath: '',
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  late Drift db;
  late StoreService store;

  setUpAll(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.init(storeRepository: DriftStoreRepository(db));
  });

  setUp(() async {
    await store.clear();
    await store.put(StoreKey.serverEndpoint, 'https://photos.example.com/api');
    await store.put(StoreKey.accessToken, 'administrator-token');
  });

  tearDownAll(() async {
    await store.dispose();
    await db.close();
  });

  Future<void> open(WidgetTester tester, http.Client client) => tester.pumpWidget(
    ProviderScope(
      overrides: [authProvider.overrideWith((ref) => _AdminNotifier())],
      child: MaterialApp(
        home: Scaffold(
          body: ServerManagementSettings(
            service: ServerManagementService(client),
            managerUpdateService: ManagerUpdateService(client),
            runtimeUpdateService: RuntimeUpdateService(client),
          ),
        ),
      ),
    ),
  );

  http.Response online({String version = '1.2.16'}) => http.Response(
    jsonEncode({
      'Version': version,
      'ServerOnline': true,
      'Busy': false,
      'BackupConfigured': true,
      'StartupKnown': true,
      'Disks': [],
    }),
    200,
  );

  http.Response updateStatus({
    required String current,
    required String latest,
    bool available = false,
    String phase = 'idle',
    int progress = 0,
    String error = '',
    bool recoveryRequired = false,
  }) => http.Response(
    jsonEncode({
      'CurrentVersion': current,
      'LatestVersion': latest,
      'Available': available,
      'Phase': phase,
      'Progress': progress,
      'Error': error,
      'Notes': '',
      'RecoveryRequired': recoveryRequired,
    }),
    200,
  );

  http.Response noUpdate(http.Request request) => updateStatus(
    current: request.url.path.endsWith('/runtime-update') ? '3.1.0' : '1.2.16',
    latest: request.url.path.endsWith('/runtime-update') ? '3.1.0' : '1.2.16',
  );

  Finder button(String label) => find.ancestor(of: find.text(label), matching: find.byType(FilledButton));

  testWidgets('failed connection stops checking and recovers automatically when the manager starts', (tester) async {
    var requests = 0;
    final client = MockClient((request) async {
      if (!request.url.path.endsWith('/status')) {
        return noUpdate(request);
      }
      return ++requests == 1 ? http.Response('', 502) : online();
    });
    addTearDown(client.close);
    await open(tester, client);
    await tester.pumpAndSettle();

    expect(find.text('Checking connection…'), findsNothing);
    expect(find.text('Windows manager unavailable'), findsOneWidget);
    expect(find.textContaining('offline or restarting'), findsOneWidget);

    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(find.text('Server online'), findsOneWidget);
    expect(find.text('Windows manager unavailable'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('last known data remains visible but cannot change the PC after a disconnect', (tester) async {
    var requests = 0;
    final client = MockClient((request) async {
      if (!request.url.path.endsWith('/status')) {
        return noUpdate(request);
      }
      return ++requests == 1 ? online() : http.Response('', 503);
    });
    addTearDown(client.close);
    await open(tester, client);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(button('Back up now')).onPressed, isNotNull);

    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Checking connection…'), findsNothing);
    expect(find.textContaining('Last known status'), findsOneWidget);
    expect(tester.widget<FilledButton>(button('Back up now')).onPressed, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('administrator rejection shows a useful message and needs a deliberate retry', (tester) async {
    var requests = 0;
    final client = MockClient((request) async {
      if (!request.url.path.endsWith('/status')) {
        return noUpdate(request);
      }
      requests++;
      return http.Response('{"message":"Administrator sign-in required"}', 401);
    });
    addTearDown(client.close);
    await open(tester, client);
    await tester.pumpAndSettle();
    expect(find.text('Checking connection…'), findsNothing);
    expect(find.textContaining('Sign in again'), findsOneWidget);
    await tester.pump(const Duration(minutes: 2));
    expect(requests, 1);
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(requests, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('old manager can be updated from this screen before enabling an engine update', (tester) async {
    var managerStarted = false;
    var engineStarts = 0;
    var reconnects = 0;
    var engineChecks = 0;
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add('${request.method} ${request.url.path}');
      expect(request.headers['authorization'], 'Bearer administrator-token');
      switch (request.url.path) {
        case '/inhouse-manager/v1/status':
          if (managerStarted && reconnects++ == 0) {
            return http.Response('', 502);
          }
          return online(version: managerStarted ? '1.2.17' : '1.2.16');
        case '/inhouse-manager/v1/update':
          if (request.method == 'POST') {
            expect(request.body, isEmpty);
            managerStarted = true;
            return http.Response('', 202);
          }
          return updateStatus(
            current: managerStarted ? '1.2.17' : '1.2.16',
            latest: '1.2.17',
            available: !managerStarted,
            phase: managerStarted ? 'completed' : 'idle',
            progress: managerStarted ? 100 : 0,
          );
        case '/inhouse-manager/v1/runtime-update':
          if (request.method == 'POST') {
            engineStarts++;
            return http.Response('', 202);
          }
          engineChecks++;
          if (!managerStarted || reconnects <= 1) {
            return http.Response('', 404);
          }
          return updateStatus(current: '3.1.0', latest: '3.1.0-durable-upload', available: true);
        default:
          fail('Unexpected request ${request.method} ${request.url}');
      }
    });
    addTearDown(client.close);
    await open(tester, client);
    await tester.pumpAndSettle();

    expect(find.text('Update Windows manager'), findsOneWidget);
    expect(find.textContaining('Update Windows manager'), findsWidgets);
    expect(find.text('Update server engine'), findsNothing);
    expect(engineChecks, greaterThan(0));

    await tester.tap(button('Update Windows manager'));
    await tester.pumpAndSettle();
    expect(managerStarted, isFalse);
    expect(engineStarts, 0);
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(managerStarted, isTrue);

    // The Windows manager temporarily disappears while the installer restarts
    // it. The engine button becomes usable only after a successful reconnect.
    for (var attempt = 0; attempt < 8 && reconnects < 2; attempt++) {
      await tester.pump(const Duration(seconds: 15));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(reconnects, greaterThanOrEqualTo(2));
    expect(find.textContaining('1.2.17'), findsWidgets);
    expect(tester.widget<FilledButton>(button('Update server engine')).onPressed, isNotNull);
    expect(engineStarts, 0);
    expect(requests.where((request) => request == 'POST /inhouse-manager/v1/update'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('engine update continues through a restart and confirms the running version', (tester) async {
    var started = false;
    var posts = 0;
    var checksAfterStart = 0;
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/inhouse-manager/v1/status':
          return online(version: '1.2.17');
        case '/inhouse-manager/v1/update':
          return updateStatus(current: '1.2.17', latest: '1.2.17');
        case '/inhouse-manager/v1/runtime-update':
          if (request.method == 'POST') {
            expect(request.body, isEmpty);
            expect(request.headers['authorization'], 'Bearer administrator-token');
            started = true;
            posts++;
            return http.Response('', 202);
          }
          if (!started) {
            return updateStatus(current: '3.1.0', latest: '3.1.0-durable-upload', available: true);
          }
          switch (checksAfterStart++) {
            case 0:
              return updateStatus(current: '3.1.0', latest: '3.1.0-durable-upload', phase: 'downloading', progress: 25);
            case 1:
              return updateStatus(current: '3.1.0', latest: '3.1.0-durable-upload', phase: 'restarting', progress: 90);
            case 2:
              return http.Response('', 502);
            default:
              return updateStatus(
                current: '3.1.0-durable-upload',
                latest: '3.1.0-durable-upload',
                phase: 'completed',
                progress: 100,
              );
          }
        default:
          fail('Unexpected request ${request.method} ${request.url}');
      }
    });
    addTearDown(client.close);
    await open(tester, client);
    await tester.pumpAndSettle();

    await tester.tap(button('Update server engine'));
    await tester.pumpAndSettle();
    expect(posts, 0);
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(posts, 1);
    expect(find.textContaining('25%'), findsWidgets);

    for (var attempt = 0; attempt < 10 && checksAfterStart < 4; attempt++) {
      await tester.pump(const Duration(seconds: 15));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(checksAfterStart, greaterThanOrEqualTo(4));
    expect(find.textContaining('3.1.0-durable-upload'), findsWidgets);
    expect(posts, 1);
    expect(find.text('Update server engine'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('accepted engine update stays pending until the new version is running', (tester) async {
    var posts = 0;
    var updated = false;
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/inhouse-manager/v1/status':
          return online(version: '1.2.17');
        case '/inhouse-manager/v1/update':
          return updateStatus(current: '1.2.17', latest: '1.2.17');
        case '/inhouse-manager/v1/runtime-update':
          if (request.method == 'POST') {
            posts++;
            return http.Response('', 202);
          }
          return updateStatus(
            current: updated ? '3.1.0-durable-upload' : '3.1.0',
            latest: '3.1.0-durable-upload',
            available: posts == 0,
            phase: posts > 0 ? 'completed' : 'idle',
            progress: posts > 0 ? 100 : 0,
          );
        default:
          fail('Unexpected request ${request.method} ${request.url}');
      }
    });
    addTearDown(client.close);
    await open(tester, client);
    await tester.pumpAndSettle();

    await tester.tap(button('Update server engine'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 15));
    await tester.pump(const Duration(milliseconds: 100));

    // POST 202 and even a "completed" phase are insufficient if the manager
    // still reports the previous running image.
    expect(posts, 1);
    expect(find.text('Update server engine'), findsNothing);
    expect(find.textContaining('Server engine updated'), findsNothing);

    updated = true;
    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(find.textContaining('3.1.0-durable-upload'), findsWidgets);
    expect(posts, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('lost manager update response is resolved by status checks without a second POST', (tester) async {
    var started = false;
    var completed = false;
    var posts = 0;
    var managerChecksAfterPost = 0;
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/inhouse-manager/v1/status':
          return online(version: completed ? '1.2.17' : '1.2.16');
        case '/inhouse-manager/v1/update':
          if (request.method == 'POST') {
            expect(request.body, isEmpty);
            started = true;
            posts++;
            throw http.ClientException('Connection closed after PC accepted update', request.url);
          }
          if (started) {
            managerChecksAfterPost++;
          }
          return updateStatus(
            current: completed ? '1.2.17' : '1.2.16',
            latest: '1.2.17',
            available: !started,
            phase: completed
                ? 'completed'
                : started
                ? 'downloading'
                : 'idle',
            progress: completed
                ? 100
                : started
                ? 25
                : 0,
          );
        case '/inhouse-manager/v1/runtime-update':
          expect(request.method, 'GET');
          return noUpdate(request);
        default:
          fail('Unexpected request ${request.method} ${request.url}');
      }
    });
    addTearDown(client.close);
    await open(tester, client);
    await tester.pumpAndSettle();

    await tester.tap(button('Update Windows manager'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(posts, 1);
    expect(managerChecksAfterPost, greaterThan(0));
    expect(find.textContaining('Downloading Windows manager'), findsOneWidget);
    expect(find.textContaining('25%'), findsOneWidget);
    expect(find.text('Update Windows manager'), findsNothing);

    completed = true;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(find.textContaining('1.2.17'), findsWidgets);
    expect(managerChecksAfterPost, greaterThanOrEqualTo(2));
    expect(posts, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('interrupted engine update blocks PC changes until recovery completes', (tester) async {
    // Keep the recovery actions and backup controls in the viewport together;
    // this test checks their shared state rather than scrolling behavior.
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var started = false;
    var completed = false;
    var posts = 0;
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/inhouse-manager/v1/status':
          // Recovery is not a running PC operation, so the engine resume
          // action must remain available even while other changes are blocked.
          return online(version: '1.2.17');
        case '/inhouse-manager/v1/update':
          return updateStatus(current: '1.2.17', latest: '1.2.18', available: true);
        case '/inhouse-manager/v1/runtime-update':
          if (request.method == 'POST') {
            expect(request.body, isEmpty);
            started = true;
            posts++;
            return http.Response('', 202);
          }
          return updateStatus(
            current: completed ? '3.1.0-durable-upload' : '3.1.0',
            latest: '3.1.0-durable-upload',
            available: !started,
            phase: completed
                ? 'completed'
                : started
                ? 'downloading'
                : 'error',
            progress: completed
                ? 100
                : started
                ? 25
                : 0,
            error: started ? '' : 'The update was interrupted. Resume it to finish.',
            recoveryRequired: !completed,
          );
        default:
          fail('Unexpected request ${request.method} ${request.url}');
      }
    });
    addTearDown(client.close);
    await open(tester, client);
    await tester.pumpAndSettle();

    expect(tester.widget<FilledButton>(button('Back up now')).onPressed, isNull);
    expect(tester.widget<FilledButton>(button('Update Windows manager')).onPressed, isNull);
    expect(tester.widget<FilledButton>(button('Resume server engine update')).onPressed, isNotNull);
    expect(find.textContaining('interrupted'), findsOneWidget);

    await tester.tap(button('Resume server engine update'));
    await tester.pumpAndSettle();
    expect(posts, 0);
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(posts, 1);
    expect(find.textContaining('25%'), findsOneWidget);
    expect(tester.widget<FilledButton>(button('Back up now')).onPressed, isNull);
    expect(tester.widget<FilledButton>(button('Update Windows manager')).onPressed, isNull);

    completed = true;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(find.textContaining('3.1.0-durable-upload'), findsWidgets);
    expect(find.text('Resume server engine update'), findsNothing);
    expect(tester.widget<FilledButton>(button('Back up now')).onPressed, isNotNull);
    expect(tester.widget<FilledButton>(button('Update Windows manager')).onPressed, isNotNull);
    expect(posts, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
