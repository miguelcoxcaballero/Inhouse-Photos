import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/services/pairing.service.dart';
import 'package:immich_mobile/widgets/forms/login/pairing_login.dart';

void main() {
  testWidgets('QR scanning is primary and manual sign-in remains available', (tester) async {
    var manualSelected = false;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: PairingLogin(onManual: () => manualSelected = true, onRedeemed: (_, _) async {}),
          ),
        ),
      ),
    );

    expect(find.text('Scan QR code'), findsOneWidget);
    expect(find.text('Use server address and password instead'), findsOneWidget);
    await tester.tap(find.text('Use server address and password instead'));
    expect(manualSelected, isTrue);
  });

  testWidgets('deep link shows the server for confirmation before claiming', (tester) async {
    final invite = PairingInvite.parse(
      '$pairingServerOrigin/vincular#origin=${Uri.encodeComponent('https://photos.example.com')}&invite=${List.filled(43, 'A').join()}',
    )!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [pendingPairingInviteProvider.overrideWith((ref) => invite)],
        child: MaterialApp(
          home: Scaffold(
            body: PairingLogin(onManual: () {}, onRedeemed: (_, _) async {}),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Connect to this server?'), findsOneWidget);
    expect(find.text('https://photos.example.com'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
  });

  testWidgets('claim displays PC, account, and matching code before phone approval', (tester) async {
    final invite = PairingInvite.parse('https://photos.example.com/vincular#invite=${List.filled(43, 'A').join()}')!;
    final client = MockClient((request) async {
      expect(request.url.path, '/api/auth/pairing/claim');
      return http.Response(
        jsonEncode({
          'claimToken': List.filled(43, 'B').join(),
          'code': '123456',
          'accountName': 'Test Person',
          'accountEmail': 'person@example.com',
          'pcDeviceName': 'Chrome on Windows',
          'expiresAt': '2099-01-01T00:00:00.000Z',
        }),
        200,
      );
    });
    addTearDown(client.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pendingPairingInviteProvider.overrideWith((ref) => invite),
          pairingServiceProvider.overrideWith((ref) => PairingService(client)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: PairingLogin(onManual: () {}, onRedeemed: (_, _) async {}),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Server: photos.example.com'), findsOneWidget);
    expect(find.text('Computer: Chrome on Windows'), findsOneWidget);
    expect(find.text('Account: Test Person (person@example.com)'), findsOneWidget);
    expect(find.text('123456'), findsOneWidget);
    expect(find.text('The codes match — approve'), findsOneWidget);
  });

  testWidgets('redeem hands the selected server origin to the auth callback', (tester) async {
    final invite = PairingInvite.parse('https://photos.example.com/vincular#invite=${List.filled(43, 'A').join()}')!;
    final client = MockClient((request) async {
      switch (request.url.pathSegments.last) {
        case 'claim':
          return http.Response(
            jsonEncode({
              'claimToken': List.filled(43, 'B').join(),
              'code': '123456',
              'accountName': 'Test Person',
              'accountEmail': 'person@example.com',
              'pcDeviceName': 'Chrome on Windows',
              'expiresAt': '2099-01-01T00:00:00.000Z',
            }),
            200,
          );
        case 'phone-confirm':
        case 'phone-status':
          return http.Response(jsonEncode({'status': 'ready', 'expiresAt': '2099-01-01T00:00:00.000Z'}), 200);
        case 'redeem':
          return http.Response(jsonEncode({'accessToken': 'fresh-session-token'}), 200);
      }
      return http.Response('', 404);
    });
    addTearDown(client.close);
    Uri? redeemedOrigin;
    String? redeemedToken;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pendingPairingInviteProvider.overrideWith((ref) => invite),
          pairingServiceProvider.overrideWith((ref) => PairingService(client)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: PairingLogin(
              onManual: () {},
              onRedeemed: (token, origin) async {
                redeemedToken = token;
                redeemedOrigin = origin;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('The codes match — approve'));
    for (var index = 0; index < 5 && redeemedOrigin == null; index++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(redeemedToken, 'fresh-session-token');
    expect(redeemedOrigin.toString(), 'https://photos.example.com');
  });
}
