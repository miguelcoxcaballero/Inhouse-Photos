import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/services/pairing.service.dart';

void main() {
  final inviteValue = List.filled(43, 'A').join();
  final claimToken = List.filled(43, 'B').join();
  const alternateOrigin = 'https://photos.example.com';
  final globalLink = '$pairingServerOrigin/vincular#origin=${Uri.encodeComponent(alternateOrigin)}&invite=$inviteValue';
  final invite = PairingInvite.parse(globalLink)!;

  group('PairingInvite.parse', () {
    test('accepts validated HTTPS origins and the custom-scheme fallback', () {
      expect(PairingInvite.parse('$pairingServerOrigin/vincular#invite=$inviteValue')?.invite, inviteValue);
      expect(PairingInvite.parse('$alternateOrigin/vincular#invite=$inviteValue')?.origin.toString(), alternateOrigin);
      expect(PairingInvite.parse(globalLink)?.origin.toString(), alternateOrigin);
      expect(
        PairingInvite.parse('$alternateOrigin:443/vincular#invite=$inviteValue')?.origin.toString(),
        alternateOrigin,
      );
      expect(
        PairingInvite.parse('inhousephotos://vincular?invite=$inviteValue')?.origin.toString(),
        pairingServerOrigin,
      );
      final fallback = Uri(
        scheme: 'inhousephotos',
        host: 'vincular',
        queryParameters: {'origin': alternateOrigin, 'invite': inviteValue},
      );
      expect(PairingInvite.parse(fallback.toString())?.origin.toString(), alternateOrigin);
    });

    test('rejects unsafe schemes, ports, origins, and ambiguous payloads', () {
      expect(PairingInvite.parse('$pairingServerOrigin/vincular?invite=$inviteValue'), isNull);
      expect(PairingInvite.parse('$alternateOrigin/vincular?#invite=$inviteValue'), isNull);
      expect(PairingInvite.parse('http://fotos.miguelcoxcaballero.com/vincular#invite=$inviteValue'), isNull);
      expect(PairingInvite.parse('https://user@photos.example.com/vincular#invite=$inviteValue'), isNull);
      expect(PairingInvite.parse('https://photos.example.com:8443/vincular#invite=$inviteValue'), isNull);
      expect(PairingInvite.parse('https://photos.example.com/other#invite=$inviteValue'), isNull);
      expect(
        PairingInvite.parse(
          '$alternateOrigin/vincular#origin=${Uri.encodeComponent(alternateOrigin)}&invite=$inviteValue',
        ),
        isNull,
      );
      expect(PairingInvite.parse('$pairingServerOrigin/vincular#origin=bad&invite=$inviteValue'), isNull);
      expect(
        PairingInvite.parse(
          '$pairingServerOrigin/vincular#origin=${Uri.encodeComponent('http://photos.example.com')}&invite=$inviteValue',
        ),
        isNull,
      );
      expect(PairingInvite.parse('$pairingServerOrigin/vincular#origin=%ZZ&invite=$inviteValue'), isNull);
      expect(
        PairingInvite.parse(
          '$pairingServerOrigin/vincular#origin=${Uri.encodeComponent(alternateOrigin)}&invite=$inviteValue&extra=1',
        ),
        isNull,
      );
      expect(PairingInvite.parse('$pairingServerOrigin/vincular#invite=$inviteValue&next=evil'), isNull);
      expect(PairingInvite.parse('$pairingServerOrigin/vincular#invite=short'), isNull);
      expect(PairingInvite.parse(' $pairingServerOrigin/vincular#invite=$inviteValue'), isNull);
      expect(PairingInvite.parse('inhousephotos://vincular?invite=$inviteValue#extra'), isNull);
      expect(PairingInvite.parse('inhousephotos://vincular?invite=$inviteValue#'), isNull);
      expect(
        PairingInvite.parse(
          'inhousephotos://vincular?origin=https%3A%2F%2Fphotos.example.com%2Fapi&invite=$inviteValue',
        ),
        isNull,
      );
      expect(
        PairingInvite.parse('inhousephotos://vincular?origin=http%3A%2F%2Fphotos.example.com&invite=$inviteValue'),
        isNull,
      );
      expect(
        PairingInvite.parse(
          'inhousephotos://vincular?origin=https%3A%2F%2Fphotos.example.com%3A8443&invite=$inviteValue',
        ),
        isNull,
      );
      expect(
        PairingInvite.parse(
          'inhousephotos://vincular?origin=https%3A%2F%2Fphotos.example.com&invite=$inviteValue&invite=$inviteValue',
        ),
        isNull,
      );
    });
  });

  test('claims and confirms with secrets only in POST JSON bodies', () async {
    final actions = <String>[];
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.origin, alternateOrigin);
      expect(request.url.hasQuery, isFalse);
      expect(request.url.hasFragment, isFalse);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['invite'], inviteValue);
      final action = request.url.pathSegments.last;
      actions.add(action);
      switch (action) {
        case 'claim':
          expect(body['deviceName'], 'Test phone');
          return http.Response(
            jsonEncode({
              'claimToken': claimToken,
              'code': '123456',
              'accountName': 'Test Person',
              'accountEmail': 'person@example.com',
              'pcDeviceName': 'Chrome on Windows',
              'expiresAt': '2099-01-01T00:00:00.000Z',
            }),
            201,
          );
        case 'phone-confirm':
          expect(body['claimToken'], claimToken);
          expect(body['code'], '123456');
          return http.Response(jsonEncode({'status': 'phone-confirmed', 'expiresAt': '2099-01-01T00:00:00.000Z'}), 200);
        case 'phone-status':
          expect(body['claimToken'], claimToken);
          return http.Response(jsonEncode({'status': 'ready', 'expiresAt': '2099-01-01T00:00:00.000Z'}), 200);
        case 'redeem':
          expect(body['claimToken'], claimToken);
          return http.Response(jsonEncode({'accessToken': 'fresh-session-token'}), 200);
      }
      return http.Response('', 404);
    });

    final service = PairingService(client);
    final claim = await service.claim(invite, deviceName: 'Test phone');
    expect(claim.code, '123456');
    expect(claim.accountEmail, 'person@example.com');
    expect(claim.pcDeviceName, 'Chrome on Windows');
    expect((await service.confirm(invite, claim)).status, 'phone-confirmed');
    expect((await service.status(invite, claim)).status, 'ready');
    expect(await service.redeem(invite, claim), 'fresh-session-token');
    expect(actions, ['claim', 'phone-confirm', 'phone-status', 'redeem']);
    client.close();
  });

  test('never includes server error bodies in pairing errors', () async {
    final client = MockClient((_) async => http.Response('secret response content', 400));
    final service = PairingService(client);
    await expectLater(
      service.claim(invite),
      throwsA(isA<PairingException>().having((error) => error.message, 'message', isNot(contains('secret')))),
    );
    client.close();
  });
}
