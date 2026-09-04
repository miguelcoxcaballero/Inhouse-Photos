// Whether the thing being measured is the app or the test's own server.
//
// The loading tests serve real thumbnails from a Dart `HttpServer` bound inside
// the app process, which means it runs on the same isolate as the grid it is
// feeding. Every client-side candidate for the fill rate has now been measured
// and found to have headroom - the scheduler, the native decode pool, the
// per-cell image, the platform channel - which leaves the fetch, and the fetch
// goes here. So before drawing any conclusion about the app from a fill rate,
// this measures what the harness itself can serve.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<Uint8List> _thumbnail() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const size = 160.0;
  canvas.drawRect(const Rect.fromLTWH(0, 0, size, size), Paint()..color = const Color(0xFF3355AA));
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.toInt(), size.toInt());
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('how many thumbnails the harness server can actually serve', (tester) async {
    await tester.runAsync(() async {
      final bytes = await _thumbnail();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(
        server.forEach((request) {
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(bytes);
          request.response.close();
        }),
      );
      final client = HttpClient()..maxConnectionsPerHost = 64;
      final url = Uri.parse('http://${server.address.address}:${server.port}/thumb');

      Future<void> fetch() async {
        final request = await client.getUrl(url);
        final response = await request.close();
        await response.drain<void>();
      }

      await fetch();
      const requests = 800;
      for (final inFlight in [8, 32]) {
        final clock = Stopwatch()..start();
        var issued = 0;
        while (issued < requests) {
          final batch = <Future<void>>[];
          for (var i = 0; i < inFlight && issued + i < requests; i++) {
            batch.add(fetch());
          }
          await Future.wait(batch);
          issued += batch.length;
        }
        clock.stop();
        print(
          'SRVCOST $requests requests, $inFlight at a time: ${clock.elapsedMilliseconds} ms '
          '(${(requests * 1000 / clock.elapsedMilliseconds).toStringAsFixed(0)}/sec)',
        );
      }

      client.close(force: true);
      await server.close(force: true);
    });
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
