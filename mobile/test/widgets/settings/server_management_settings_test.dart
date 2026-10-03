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
import 'package:immich_mobile/services/system_update.service.dart';
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
  const latestVersion = '3.1.97';
  const systemPath = '/inhouse-manager/v1/system-update';
  const managerPath = '/inhouse-manager/v1/update';
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

  Future<void> open(WidgetTester tester, http.Client client) {
    final initialTime = tester.binding.clock.now();
    return tester.pumpWidget(
      ProviderScope(
        overrides: [authProvider.overrideWith((ref) => _AdminNotifier())],
        child: MaterialApp(
          home: Scaffold(
            body: ServerManagementSettings(
              service: ServerManagementService(client),
              managerUpdateService: ManagerUpdateService(client),
              runtimeUpdateService: RuntimeUpdateService(client),
              systemUpdateService: SystemUpdateService(client),
              updateElapsed: () => tester.binding.clock.now().difference(initialTime),
            ),
          ),
        ),
      ),
    );
  }

  http.Response online({String version = '1.2.16', bool busy = false, bool backupRunning = false}) => http.Response(
    jsonEncode({
      'Version': version,
      'ServerOnline': true,
      'Busy': busy,
      'BackupRunning': backupRunning,
      'BackupConfigured': true,
      'StartupKnown': true,
      'Disks': [],
    }),
    200,
  );

  http.Response updateStatus({
    String current = '3.1.95',
    String latest = latestVersion,
    bool available = false,
    String phase = 'idle',
    int progress = 0,
    String error = '',
    bool recoveryRequired = false,
    bool requiresLocalRecovery = false,
    bool busy = false,
    String stage = '',
    int stageElapsedSeconds = 0,
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
      'RequiresLocalRecovery': requiresLocalRecovery,
      'Busy': busy,
      'Stage': stage,
      'StageElapsedSeconds': stageElapsedSeconds,
    }),
    200,
  );

  http.Response noUpdate(http.Request request) => updateStatus(current: latestVersion);

  Finder button(String label) => find.ancestor(of: find.text(label), matching: find.byType(FilledButton));

  Future<void> confirmUpdate(WidgetTester tester) async {
    await tester.tap(button('Update'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Update')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

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
    expect(find.text('PC unavailable'), findsOneWidget);
    expect(find.textContaining('offline or restarting'), findsOneWidget);

    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(find.text('Server online'), findsOneWidget);
    expect(find.text('PC unavailable'), findsNothing);
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

  testWidgets('one public update bootstraps an old manager and follows the PC through completion', (tester) async {
    var started = false;
    var completed = false;
    var managerPosts = 0;
    var systemPosts = 0;
    var checksAfterPost = 0;
    final client = MockClient((request) async {
      expect(request.headers['authorization'], 'Bearer administrator-token');
      switch (request.url.path) {
        case '/inhouse-manager/v1/status':
          return online();
        case systemPath:
          if (request.method == 'POST') {
            systemPosts++;
            return http.Response('', 202);
          }
          if (!started) {
            return http.Response('', 404);
          }
          checksAfterPost++;
          if (checksAfterPost == 1) {
            return http.Response('<html>503 Service Unavailable</html>', 503);
          }
          return updateStatus(
            current: completed ? latestVersion : '3.1.95',
            phase: completed ? 'completed' : 'downloading',
            progress: completed ? 100 : 60,
          );
        case managerPath:
          if (request.method == 'POST') {
            expect(request.body, isEmpty);
            managerPosts++;
            started = true;
            return http.Response('', 202);
          }
          // An old manager can have cached an internal-version manifest. It
          // must still present the app's single public update/version.
          return updateStatus(current: '1.2.16', latest: '1.2.16');
        case '/inhouse-manager/v1/runtime-update':
          expect(request.method, 'GET');
          return http.Response('', 404);
        default:
          fail('Unexpected request ${request.method} ${request.url}');
      }
    });
    addTearDown(client.close);
    await open(tester, client);
    await tester.pumpAndSettle();

    expect(find.text('Update'), findsOneWidget);
    expect(find.textContaining(latestVersion), findsOneWidget);
    expect(find.textContaining('1.2.16'), findsNothing);
    expect(find.textContaining('1.2.17'), findsNothing);
    expect(find.text('Update Windows manager'), findsNothing);
    expect(find.text('Update server engine'), findsNothing);

    await confirmUpdate(tester);
    expect(managerPosts, 1);
    expect(systemPosts, 0);
    completed = true;
    for (var attempt = 0; attempt < 5 && checksAfterPost < 2; attempt++) {
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    expect(checksAfterPost, greaterThanOrEqualTo(2));
    expect(find.textContaining('Up to date'), findsOneWidget);
    expect(find.textContaining(latestVersion), findsOneWidget);
    expect(managerPosts, 1);
    expect(systemPosts, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('one system update survives API restart and confirms the public running version', (tester) async {
    var started = false;
    var posts = 0;
    var checksAfterPost = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/status')) {
        return online();
      }
      expect(request.url.path, systemPath);
      if (request.method == 'POST') {
        expect(request.body, isEmpty);
        expect(request.headers['authorization'], 'Bearer administrator-token');
        started = true;
        posts++;
        return http.Response('', 202);
      }
      if (!started) {
        return updateStatus(available: true);
      }
      switch (checksAfterPost++) {
        case 0:
          return updateStatus(phase: 'downloading', progress: 25);
        case 1:
          return updateStatus(phase: 'restarting', progress: 90);
        case 2:
          return http.Response('<html>503 Service Unavailable</html>', 503);
        default:
          return updateStatus(current: latestVersion, phase: 'completed', progress: 100);
      }
    });
    addTearDown(client.close);
    await open(tester, client);
    await tester.pumpAndSettle();

    await confirmUpdate(tester);
    expect(posts, 1);
    expect(find.textContaining('25%'), findsOneWidget);
    for (var attempt = 0; attempt < 8 && checksAfterPost < 4; attempt++) {
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    expect(checksAfterPost, greaterThanOrEqualTo(4));
    expect(find.textContaining('Up to date'), findsOneWidget);
    expect(find.textContaining(latestVersion), findsOneWidget);
    expect(posts, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('accepted update stays pending while the old public version is running', (tester) async {
    var posts = 0;
    var completed = false;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/status')) {
        return online();
      }
      expect(request.url.path, systemPath);
      if (request.method == 'POST') {
        posts++;
        return http.Response('', 202);
      }
      return updateStatus(
        current: completed ? latestVersion : '3.1.95',
        available: posts == 0,
        phase: posts == 0 ? 'idle' : 'completed',
        progress: posts == 0 ? 0 : 100,
      );
    });
    addTearDown(client.close);
    await open(tester, client);
    await tester.pumpAndSettle();
    await confirmUpdate(tester);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 100));

    expect(posts, 1);
    expect(find.textContaining('Up to date'), findsNothing);
    if (button('Update').evaluate().isNotEmpty) {
      expect(tester.widget<FilledButton>(button('Update')).onPressed, isNull);
    }

    completed = true;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.textContaining('Up to date'), findsOneWidget);
    expect(posts, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('lost system POST is resolved with read-only polling and never retried', (tester) async {
    var started = false;
    var completed = false;
    var posts = 0;
    var checksAfterPost = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/status')) {
        return online();
      }
      expect(request.url.path, systemPath);
      if (request.method == 'POST') {
        started = true;
        posts++;
        throw http.ClientException('Response lost after PC accepted update', request.url);
      }
      if (started) {
        checksAfterPost++;
      }
      return updateStatus(
        current: completed ? latestVersion : '3.1.95',
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
    });
    addTearDown(client.close);
    await open(tester, client);
    await tester.pumpAndSettle();
    await confirmUpdate(tester);

    expect(posts, 1);
    expect(checksAfterPost, greaterThan(0));
    expect(find.textContaining('25%'), findsOneWidget);
    completed = true;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.textContaining('Up to date'), findsOneWidget);
    expect(checksAfterPost, greaterThanOrEqualTo(2));
    expect(posts, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('interrupted system update allows recovery and blocks backups until completion', (tester) async {
    var started = false;
    var completed = false;
    var posts = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/status')) {
        return online();
      }
      expect(request.url.path, systemPath);
      if (request.method == 'POST') {
        expect(request.body, isEmpty);
        started = true;
        posts++;
        return http.Response('', 202);
      }
      return updateStatus(
        current: completed ? latestVersion : '3.1.95',
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
        error: started ? '' : 'The update was interrupted. Update to finish.',
        recoveryRequired: !completed,
      );
    });
    addTearDown(client.close);
    await open(tester, client);
    await tester.pumpAndSettle();

    expect(tester.widget<FilledButton>(button('Back up now')).onPressed, isNull);
    expect(tester.widget<FilledButton>(button('Update')).onPressed, isNotNull);
    await confirmUpdate(tester);
    expect(posts, 1);
    expect(find.textContaining('25%'), findsOneWidget);
    expect(tester.widget<FilledButton>(button('Back up now')).onPressed, isNull);

    completed = true;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.textContaining('Up to date'), findsOneWidget);
    expect(tester.widget<FilledButton>(button('Back up now')).onPressed, isNotNull);
    expect(posts, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('recovery requiring the PC opens instructions without a remote update request', (tester) async {
    var posts = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/status')) {
        return online();
      }
      expect(request.url.path, systemPath);
      if (request.method == 'POST') {
        posts++;
      }
      return updateStatus(
        available: true,
        phase: 'error',
        error: 'Open Inhouse Photos on your PC to finish recovery.',
        recoveryRequired: true,
        requiresLocalRecovery: true,
      );
    });
    addTearDown(client.close);
    await open(tester, client);
    await tester.pumpAndSettle();

    expect(tester.widget<FilledButton>(button('Update')).onPressed, isNotNull);
    await tester.tap(button('Update'));
    await tester.pumpAndSettle();
    expect(find.text('Finish the update on your PC'), findsOneWidget);
    expect(posts, 0);
    expect(tester.widget<FilledButton>(button('Back up now')).onPressed, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('legacy interrupted update opens PC recovery without trying either updater again', (tester) async {
    var posts = 0;
    var runtimeReads = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        posts++;
        return http.Response('', 202);
      }
      switch (request.url.path) {
        case '/inhouse-manager/v1/status':
          return online(version: '1.2.17');
        case systemPath:
          return http.Response('', 404);
        case managerPath:
          return updateStatus(current: '1.2.17', latest: '1.2.17');
        case '/inhouse-manager/v1/runtime-update':
          runtimeReads++;
          return updateStatus(
            current: '3.1.0-storage-saver',
            latest: '3.1.0-durable-upload',
            available: true,
            phase: 'error',
            error: 'An interrupted runtime transaction needs recovery.',
            recoveryRequired: true,
          );
        default:
          fail('Unexpected request ${request.method} ${request.url}');
      }
    });
    addTearDown(client.close);
    await open(tester, client);
    await tester.pumpAndSettle();

    expect(runtimeReads, greaterThan(0));
    expect(find.text('Update'), findsOneWidget);
    expect(find.textContaining('1.2.17'), findsNothing);
    expect(find.textContaining('3.1.0-storage-saver'), findsNothing);
    expect(tester.widget<FilledButton>(button('Back up now')).onPressed, isNull);
    await tester.tap(button('Update'));
    await tester.pumpAndSettle();
    expect(find.text('Finish the update on your PC'), findsOneWidget);
    expect(posts, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('busy PC blocks updates while keeping backup cancellation available', (tester) async {
    var cancelled = false;
    var cancels = 0;
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/inhouse-manager/v1/status':
          return online(busy: !cancelled, backupRunning: !cancelled);
        case systemPath:
          expect(request.method, 'GET');
          return updateStatus(available: true, busy: !cancelled);
        case '/inhouse-manager/v1/status/backup/cancel':
          expect(request.method, 'POST');
          cancelled = true;
          cancels++;
          return http.Response('', 202);
        default:
          fail('Unexpected request ${request.method} ${request.url}');
      }
    });
    addTearDown(client.close);
    await open(tester, client);
    await tester.pumpAndSettle();

    expect(tester.widget<FilledButton>(button('Update')).onPressed, isNull);
    expect(tester.widget<FilledButton>(button('Stop backup')).onPressed, isNotNull);
    await tester.tap(button('Stop backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Continue')));
    await tester.pumpAndSettle();

    expect(cancels, 1);
    expect(tester.widget<FilledButton>(button('Back up now')).onPressed, isNotNull);
    expect(tester.widget<FilledButton>(button('Update')).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('definite update refusal permits a deliberate retry without staying pending', (tester) async {
    var posts = 0;
    var readsAfterPost = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/status')) {
        return online();
      }
      expect(request.url.path, systemPath);
      if (request.method == 'POST') {
        posts++;
        return http.Response('{"message":"PC busy with backup"}', 409);
      }
      if (posts > 0) {
        readsAfterPost++;
      }
      return updateStatus(available: true);
    });
    addTearDown(client.close);
    await open(tester, client);
    await tester.pumpAndSettle();
    await confirmUpdate(tester);
    await tester.pumpAndSettle();

    expect(posts, 1);
    expect(readsAfterPost, greaterThan(0));
    expect(find.textContaining('Updating Inhouse Photos'), findsNothing);
    expect(tester.widget<FilledButton>(button('Update')).onPressed, isNotNull);
    expect(tester.widget<FilledButton>(button('Back up now')).onPressed, isNotNull);
    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(posts, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unchanged installing status exposes a read-only recovery check before a deliberate resume', (
    tester,
  ) async {
    var phase = 'installing';
    var posts = 0;
    var reads = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/status')) {
        return online(busy: phase != 'error');
      }
      expect(request.url.path, systemPath);
      if (request.method == 'POST') {
        posts++;
        phase = 'downloading';
        return http.Response('', 202);
      }
      reads++;
      return updateStatus(
        available: phase == 'error',
        phase: phase,
        progress: phase == 'downloading' ? 25 : 80,
        busy: phase != 'error',
        recoveryRequired: phase == 'error',
      );
    });
    addTearDown(client.close);
    await open(tester, client);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.widget<FilledButton>(button('Update')).onPressed, isNull);
    await tester.pump(const Duration(minutes: 5, seconds: 1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<FilledButton>(button('Update')).onPressed, isNotNull);
    expect(find.textContaining('progress could not be confirmed'), findsOneWidget);
    expect(find.textContaining('Up to date'), findsNothing);
    expect(tester.widget<FilledButton>(button('Back up now')).onPressed, isNull);

    final readsBeforeCheck = reads;
    await tester.tap(button('Update'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(reads, greaterThan(readsBeforeCheck));
    expect(posts, 0);
    expect(find.text('Update not confirmed'), findsOneWidget);
    Navigator.of(tester.element(find.byType(AlertDialog))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The first tap checks recovery without repeating installation. A fresh
    // backend error can allow a later, deliberate resume after confirmation.
    phase = 'error';
    await tester.tap(button('Update'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(posts, 0);
    if (find.byType(AlertDialog).evaluate().isNotEmpty) {
      Navigator.of(tester.element(find.byType(AlertDialog))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(button('Update')).onPressed, isNotNull);
    await confirmUpdate(tester);
    expect(posts, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('lost connection after installing exposes a read-only check instead of staying pending forever', (
    tester,
  ) async {
    var disconnected = false;
    var posts = 0;
    var reads = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/status')) {
        return online(busy: true);
      }
      expect(request.url.path, systemPath);
      if (request.method == 'POST') {
        posts++;
        return http.Response('', 202);
      }
      reads++;
      if (disconnected) {
        return http.Response('<html>502 Bad Gateway</html>', 502);
      }
      return updateStatus(phase: 'installing', progress: 80, busy: true);
    });
    addTearDown(client.close);
    await open(tester, client);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    disconnected = true;
    await tester.pump(const Duration(minutes: 2, seconds: 4));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<FilledButton>(button('Update')).onPressed, isNotNull);
    expect(find.textContaining('Up to date'), findsNothing);
    expect(tester.widget<FilledButton>(button('Back up now')).onPressed, isNull);
    final readsBeforeCheck = reads;
    await tester.tap(button('Update'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(reads, greaterThan(readsBeforeCheck));
    expect(posts, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('advancing installation progress resets the stale update threshold', (tester) async {
    var progress = 60;
    var posts = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/status')) {
        return online(busy: true);
      }
      expect(request.url.path, systemPath);
      if (request.method == 'POST') {
        posts++;
        return http.Response('', 202);
      }
      return updateStatus(phase: 'installing', progress: progress, busy: true);
    });
    addTearDown(client.close);
    await open(tester, client);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(minutes: 4));

    progress = 80;
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(minutes: 2));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<FilledButton>(button('Update')).onPressed, isNull);
    expect(find.textContaining('progress could not be confirmed'), findsNothing);
    await tester.pump(const Duration(minutes: 3, seconds: 5));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<FilledButton>(button('Update')).onPressed, isNotNull);
    expect(find.textContaining('progress could not be confirmed'), findsOneWidget);
    expect(posts, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a new installation stage resets the timeout while elapsed heartbeats do not', (tester) async {
    var stage = 'image';
    var stageStarted = tester.binding.clock.now();
    var posts = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/status')) {
        return online(busy: true);
      }
      expect(request.url.path, systemPath);
      if (request.method == 'POST') {
        posts++;
        return http.Response('', 202);
      }
      return updateStatus(
        phase: 'installing',
        progress: 80,
        busy: true,
        stage: stage,
        stageElapsedSeconds: tester.binding.clock.now().difference(stageStarted).inSeconds,
      );
    });
    addTearDown(client.close);
    await open(tester, client);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Preparing server components'), findsOneWidget);
    await tester.pump(const Duration(minutes: 4));

    stage = 'queues';
    stageStarted = tester.binding.clock.now();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(minutes: 2));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Checking pending processing'), findsOneWidget);
    expect(tester.widget<FilledButton>(button('Update')).onPressed, isNull);
    expect(find.textContaining('progress could not be confirmed'), findsNothing);

    // StageElapsedSeconds continues increasing on every successful status
    // read. It is a heartbeat, so it cannot make unchanged progress look new.
    await tester.pump(const Duration(minutes: 3, seconds: 5));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<FilledButton>(button('Update')).onPressed, isNotNull);
    expect(find.textContaining('progress could not be confirmed'), findsOneWidget);
    expect(posts, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final changedKey in [StoreKey.serverEndpoint, StoreKey.accessToken]) {
    testWidgets('update confirmation is invalidated when $changedKey changes', (tester) async {
      var posts = 0;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/status')) {
          return online();
        }
        expect(request.url.path, systemPath);
        if (request.method == 'POST') {
          posts++;
          return http.Response('', 202);
        }
        return updateStatus(available: true);
      });
      addTearDown(client.close);
      await open(tester, client);
      await tester.pumpAndSettle();
      await tester.tap(button('Update'));
      await tester.pumpAndSettle();

      await tester.runAsync(
        () => store.put(
          changedKey,
          changedKey == StoreKey.serverEndpoint ? 'https://another-server.example.com/api' : 'different-user-token',
        ),
      );
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Update')));
      await tester.pumpAndSettle();

      expect(posts, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
