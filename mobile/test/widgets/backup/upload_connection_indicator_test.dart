import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/repositories/lan_upload_route.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/widgets/backup/upload_connection_indicator.dart';

void main() {
  final origin = Uri.parse('https://fotos.miguelcoxcaballero.com/');
  Future<void> showIndicator(WidgetTester tester, LanUploadRoute? route, {double? rate, double textScale = 1}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [activeUploadRouteProvider.overrideWith((ref) => route)],
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: Scaffold(
              appBar: AppBar(
                title: const Text('Upload Details'),
                actions: [UploadConnectionIndicator(readBytesPerSecond: () => rate)],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('shows verified USB cable and real measured rate', (tester) async {
    await showIndicator(
      tester,
      LanUploadRoute(origin: origin, address: InternetAddress('192.168.42.50'), port: 443, kind: UploadTransport.usb),
      rate: 10 * 1024 * 1024,
    );
    expect(find.byIcon(Icons.cable_rounded), findsOneWidget);
    expect(find.text('USB cable'), findsOneWidget);
    expect(find.text('↑ 10 MiB/s'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('no verified USB route never claims cable transfers', (tester) async {
    await showIndicator(tester, null);
    expect(find.text('Internet'), findsOneWidget);
    expect(find.text('Idle'), findsOneWidget);
    expect(find.byIcon(Icons.cable_rounded), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('explains measured speed and physical 100 Mbps LAN bottleneck', (tester) async {
    await showIndicator(
      tester,
      LanUploadRoute(origin: origin, address: InternetAddress('192.168.1.237'), port: 443, linkMbps: 100),
    );
    await tester.tap(find.byType(UploadConnectionIndicator));
    await tester.pumpAndSettle();
    expect(find.text('PC network link: 100 Mb/s'), findsOneWidget);
    expect(find.textContaining('Gigabit port'), findsOneWidget);
    expect(find.textContaining('Prepare USB'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('compact indicator fits large accessibility text', (tester) async {
    await showIndicator(tester, null, rate: 200 * 1024 * 1024, textScale: 1.5);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
