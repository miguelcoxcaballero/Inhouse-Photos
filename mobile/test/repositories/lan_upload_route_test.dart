import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/repositories/lan_upload_route.dart';

void main() {
  final origin = Uri.parse('https://fotos.miguelcoxcaballero.com/');
  late Directory cache;

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('inhouse-route-test-');
  });
  tearDown(() async {
    await cache.delete(recursive: true);
  });

  Map<String, Object> hint(List<Map<String, Object>> routes) => {'origin': origin.toString(), 'routes': routes};

  LanUploadRouteResolver resolver(Object document, bool Function(LanUploadRoute) probe) => LanUploadRouteResolver(
    hintClient: MockClient((request) async {
      expect(request.url, origin.resolve('/descargas/lan.json'));
      expect(request.followRedirects, isFalse);
      return http.Response(jsonEncode(document), 200);
    }),
    probe: (route) async => probe(route),
    cacheDirectory: () async => cache,
  );

  test('discovers at the public root even when the saved API endpoint ends in /api', () {
    final discovered = LanUploadRouteResolver.publicOriginForApiEndpoint('https://fotos.miguelcoxcaballero.com/api');
    expect(discovered, origin);
  });

  test('accepts only a private LAN address for the current HTTPS origin', () {
    final route = LanUploadRoute.fromHint(origin, {
      'origin': 'https://fotos.miguelcoxcaballero.com',
      'ipv4': '192.168.1.237',
      'port': 443,
    });
    expect(route, isNotNull);
    expect(route!.address.address, '192.168.1.237');
  });

  test('rejects a different origin, public address and insecure endpoint', () {
    for (final hint in [
      {'origin': 'https://other.example.com', 'ipv4': '192.168.1.237', 'port': 443},
      {'origin': 'https://fotos.miguelcoxcaballero.com', 'ipv4': '8.8.8.8', 'port': 443},
      {'origin': 'https://fotos.miguelcoxcaballero.com', 'ipv4': '127.0.0.1', 'port': 443},
      {'origin': 'https://fotos.miguelcoxcaballero.com', 'ipv4': '192.168.1.237', 'port': 2283},
    ]) {
      expect(LanUploadRoute.fromHint(origin, hint), isNull);
    }
    expect(
      LanUploadRoute.fromHint(Uri.parse('http://fotos.miguelcoxcaballero.com/'), {
        'origin': 'http://fotos.miguelcoxcaballero.com',
        'ipv4': '192.168.1.237',
        'port': 443,
      }),
      isNull,
    );
  });

  test('prefers USB only after its direct HTTPS probe succeeds', () async {
    final document = hint([
      {'ipv4': '192.168.1.237', 'port': 443, 'kind': 'lan', 'linkMbps': 1000},
      {'ipv4': '192.168.42.10', 'port': 443, 'kind': 'usb', 'linkMbps': 480},
    ]);
    final routes = await resolver(document, (_) => true).resolveAll(origin);
    expect(routes.map((route) => route.kind), [UploadTransport.usb, UploadTransport.lan]);
    expect(routes.first.isUsb, isTrue);
    expect(routes.first.linkMbps, 480);
    final fallback = await resolver(document, (route) => !route.isUsb).resolve(origin);
    expect(fallback?.kind, UploadTransport.lan);
  });

  test('rejects more than eight routes rather than spawning arbitrary probes', () async {
    var probes = 0;
    final oversized = hint(List.generate(9, (index) => {'ipv4': '192.168.1.${index + 1}', 'port': 443, 'kind': 'usb'}));
    expect(
      await resolver(oversized, (_) {
        probes++;
        return true;
      }).resolveAll(origin),
      isEmpty,
    );
    expect(probes, 0);
  });

  test('rejects forged origins, addresses and unknown cable labels', () async {
    var probes = 0;
    final wrongOrigin = {
      'origin': 'https://attacker.example',
      'routes': [
        {'ipv4': '192.168.1.237', 'port': 443, 'kind': 'usb'},
      ],
    };
    expect(
      await resolver(wrongOrigin, (_) {
        probes++;
        return true;
      }).resolveAll(origin),
      isEmpty,
    );
    final badAddresses = hint([
      {'ipv4': '8.8.8.8', 'port': 443, 'kind': 'usb'},
      {'ipv4': '127.0.0.1', 'port': 443, 'kind': 'usb'},
      {'ipv4': '192.168.1.237', 'port': 2283, 'kind': 'usb'},
      {'ipv4': '192.168.1.237', 'port': 443, 'kind': 'charging'},
    ]);
    expect(
      await resolver(badAddresses, (_) {
        probes++;
        return true;
      }).resolveAll(origin),
      isEmpty,
    );
    expect(probes, 0);
  });

  test('enforces the 8 KiB streamed hint size bound', () async {
    final oversized = {'origin': origin.toString(), 'ipv4': '192.168.1.237', 'port': 443, 'padding': 'a' * 8192};
    expect(await resolver(oversized, (_) => true).resolveAll(origin), isEmpty);
  });

  test('a trickling hint has a total deadline and releases its response stream', () async {
    final response = StreamController<List<int>>();
    var cancelled = false;
    response.onCancel = () => cancelled = true;
    final trickle = Timer.periodic(const Duration(milliseconds: 20), (_) => response.add([32]));
    try {
      final slow = LanUploadRouteResolver(
        hintClient: MockClient.streaming((_, __) async => http.StreamedResponse(response.stream, 200)),
        hintFetchTimeout: const Duration(milliseconds: 100),
        cacheDirectory: () async => cache,
      );
      expect(await slow.resolveAll(origin).timeout(const Duration(seconds: 1)), isEmpty);
      expect(cancelled, isTrue);
    } finally {
      trickle.cancel();
      await response.close();
    }
  });

  test('cached private addresses work offline after a new TLS probe, even after restart', () async {
    final document = hint([
      {'ipv4': '192.168.42.10', 'port': 443, 'kind': 'usb'},
    ]);
    expect((await resolver(document, (_) => true).resolve(origin))?.isUsb, isTrue);
    var probes = 0;
    final offline = LanUploadRouteResolver(
      hintClient: MockClient((_) async => throw const SocketException('Internet unavailable')),
      probe: (_) async {
        probes++;
        return true;
      },
      cacheDirectory: () async => cache,
    );
    expect((await offline.resolve(origin))?.isUsb, isTrue);
    expect(probes, 1);
    final failedTls = LanUploadRouteResolver(
      hintClient: MockClient((_) async => throw const SocketException('Internet unavailable')),
      probe: (_) async => false,
      cacheDirectory: () async => cache,
    );
    expect(await failedTls.resolve(origin), isNull);
    for (final file in cache.listSync().whereType<File>()) {
      expect(file.readAsStringSync(), isNot(contains('Bearer')));
    }
  });
}
