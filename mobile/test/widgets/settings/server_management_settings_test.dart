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
        home: Scaffold(body: ServerManagementSettings(service: ServerManagementService(client))),
      ),
    ),
  );

  http.Response online() => http.Response(
    jsonEncode({
      'Version': '1.2.12',
      'ServerOnline': true,
      'Busy': false,
      'BackupConfigured': true,
      'StartupKnown': true,
      'Disks': [],
    }),
    200,
  );

  testWidgets('failed connection stops checking and recovers automatically when the manager starts', (tester) async {
    var requests = 0;
    final client = MockClient((_) async => ++requests == 1 ? http.Response('', 502) : online());
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
    final client = MockClient((_) async => ++requests == 1 ? online() : http.Response('', 503));
    addTearDown(client.close);
    await open(tester, client);
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(find.byWidgetPredicate((widget) => widget is FilledButton)).onPressed,
      isNotNull,
    );

    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Checking connection…'), findsNothing);
    expect(find.textContaining('Last known status'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byWidgetPredicate((widget) => widget is FilledButton)).onPressed, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('administrator rejection shows a useful message and needs a deliberate retry', (tester) async {
    var requests = 0;
    final client = MockClient((_) async {
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
}
