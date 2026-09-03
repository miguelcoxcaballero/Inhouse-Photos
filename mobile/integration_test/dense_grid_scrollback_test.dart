// Measures what scrolling back over ground already covered actually costs.
//
// The report is that going up and down "reloads everything". That is a claim
// about caching, so it is answered by counting: thumbnails refetched over the
// wire, atlases found in memory, atlases restored from disk, and atlases built
// from scratch. Scrolling back over panels already seen should serve them from
// memory or disk and fetch nothing.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/timeline_config.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:integration_test/integration_test.dart';
import 'package:thumbhash/thumbhash.dart' as thumbhash;

import '../test/widget_tester_extensions.dart';

String _thumbHash(int seed) {
  final rgba = Uint8List.fromList([
    for (var index = 0; index < 16; index++) ...[
      (seed * 31 + index * 13) % 256,
      (seed * 17 + index * 29) % 256,
      (seed * 47 + index * 7) % 256,
      255,
    ],
  ]);
  return base64Encode(thumbhash.rgbaToThumbHash(4, 4, rgba));
}

Future<List<Uint8List>> _thumbnailBytes() async {
  final images = <Uint8List>[];
  for (var variant = 0; variant < 8; variant++) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = 160.0;
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, size, size),
      Paint()..color = Color.fromARGB(255, (variant * 31) % 256, (variant * 67) % 256, (variant * 97) % 256),
    );
    for (var i = 0; i < 8; i++) {
      canvas.drawCircle(
        Offset(size * ((i * 7) % 10) / 10, size * ((i * 3) % 10) / 10),
        6 + i.toDouble(),
        Paint()..color = Color.fromARGB(255, (i * 40) % 256, 255 - (i * 20) % 256, (variant * 13) % 256),
      );
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    picture.dispose();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    images.add(data!.buffer.asUint8List());
  }
  return images;
}

TimelineService _service(int assetCount, {required int assetsPerBucket}) {
  final now = DateTime(2026, 8, 25);
  final assets = List<BaseAsset>.generate(
    assetCount,
    (index) => RemoteAsset(
      id: 'remote-$index',
      name: 'photo-$index.jpg',
      ownerId: 'owner',
      checksum: 'checksum-$index',
      type: AssetType.image,
      createdAt: now.subtract(Duration(minutes: index)),
      updatedAt: now,
      width: 4032,
      height: 3024,
      thumbHash: _thumbHash(index),
      isEdited: false,
    ),
    growable: false,
  );
  final bucketCount = (assetCount / assetsPerBucket).ceil();
  return TimelineService((
    assetSource: (offset, count) async => assets.skip(offset).take(count).toList(growable: false),
    bucketSource: () => Stream.value(
      List<Bucket>.generate(
        bucketCount,
        (index) => TimeBucket(
          date: now.subtract(Duration(days: index)),
          assetCount: math.min(assetsPerBucket, assetCount - (index * assetsPerBucket)),
        ),
        growable: false,
      ),
    ),
    origin: TimelineOrigin.main,
  ));
}

Future<void> _realDelay(WidgetTester tester, Duration duration) async {
  await tester.runAsync(() => Future<void>.delayed(duration));
  await tester.pump();
}

int _panelsWithAtlas(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((paint) => paint.painter)
    .where((painter) => painter.runtimeType.toString() == '_DenseAssetRowPainter')
    .where((painter) => (painter as dynamic).atlas != null)
    .length;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late List<Uint8List> bytes;
  late Drift db;
  var served = 0;

  setUpAll(() async {
    bytes = await _thumbnailBytes();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      served++;
      final body = bytes[served % bytes.length];
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('image', 'png')
        ..add(body);
      await request.response.close().catchError((_) {});
    });
    db = Drift(DatabaseConnection(NativeDatabase.memory()));
    await StoreService.init(storeRepository: DriftStoreRepository(db));
    await Store.put(StoreKey.serverEndpoint, 'http://127.0.0.1:${server.port}/api');
    await Store.put(StoreKey.accessToken, 'integration-test');
  });

  tearDownAll(() async {
    await server.close(force: true);
    await db.close();
  });

  for (final columnCount in [18, 48]) {
    testWidgets('scrolling back over seen panels is served from cache at $columnCount columns', (tester) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = const Size(1080, 2400);
      addTearDown(tester.view.reset);

      final service = _service(6000, assetsPerBucket: 500);
      addTearDown(service.dispose);

      await tester.pumpConsumerWidget(
        const Timeline(
          withScrubber: false,
          readOnly: true,
          appBar: SliverToBoxAdapter(child: SizedBox.shrink()),
          bottomSheet: null,
        ),
        overrides: [
          timelineServiceProvider.overrideWithValue(service),
          appConfigProvider.overrideWithValue(AppConfig(timeline: TimelineConfig(tilesPerRow: columnCount))),
        ],
        settle: false,
      );

      // Let the first screens settle so the outbound leg is not measuring a
      // cold start.
      for (var step = 0; step < 40; step++) {
        await _realDelay(tester, const Duration(milliseconds: 100));
      }
      DenseGridStats.reset();

      // Outbound: three screens down, settling at each stop so every panel
      // passed over gets a chance to finish and be cached.
      //
      // Also samples the signal that background preview generation yields to.
      // This is the harness where it can be checked at all: thumbnails here are
      // really fetched, so the queue is really occupied. In the perf harness
      // there is no server, requests fail instantly and the signal never fires,
      // which says nothing about the app.
      var busySamples = 0;
      var totalSamples = 0;
      const screens = 3;
      for (var i = 0; i < screens; i++) {
        await tester.fling(find.byType(Timeline), const Offset(0, -760), 1800);
        for (var step = 0; step < 20; step++) {
          await _realDelay(tester, const Duration(milliseconds: 100));
          if (denseGridIsResolvingThumbnails()) {
            busySamples++;
          }
          totalSamples++;
        }
      }

      final servedAfterOutbound = served;
      final outbound = DenseGridStats.summary();
      DenseGridStats.reset();

      // Back over exactly the same ground.
      for (var i = 0; i < screens; i++) {
        await tester.fling(find.byType(Timeline), const Offset(0, 760), 1800);
        for (var step = 0; step < 20; step++) {
          await _realDelay(tester, const Duration(milliseconds: 100));
        }
      }

      final refetched = served - servedAfterOutbound;
      final withAtlas = _panelsWithAtlas(tester);

      print('GRIDBACK ===== $columnCount columns =====');
      print('GRIDBACK thumbnails fetched outbound  : $servedAfterOutbound');
      print('GRIDBACK thumbnails refetched on back : $refetched');
      print('GRIDBACK cache on the way out         : $outbound');
      print('GRIDBACK cache on the way back        : ${DenseGridStats.summary()}');
      print('GRIDBACK panels showing a texture     : $withAtlas');
      print('GRIDBACK grid busy while loading      : $busySamples/$totalSamples samples');
      print('GRIDBACK ===== end $columnCount =====');

      expect(tester.takeException(), isNull);
    }, timeout: const Timeout(Duration(minutes: 8)));
  }

  testWidgets('changing zoom reuses what is already loaded', (tester) async {
    // "When changing the grid size everything has to reload again". Counted
    // rather than judged: settle at one zoom, switch, and see how many photos
    // have to be fetched over the wire a second time.
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1080, 2400);
    addTearDown(tester.view.reset);

    final service = _service(6000, assetsPerBucket: 500);
    addTearDown(service.dispose);

    Future<void> show(int columnCount) => tester.pumpConsumerWidget(
      const Timeline(
        withScrubber: false,
        readOnly: true,
        appBar: SliverToBoxAdapter(child: SizedBox.shrink()),
        bottomSheet: null,
      ),
      overrides: [
        timelineServiceProvider.overrideWithValue(service),
        appConfigProvider.overrideWithValue(AppConfig(timeline: TimelineConfig(tilesPerRow: columnCount))),
      ],
      settle: false,
    );

    // 18 and 24 columns want 60px and 45px cells on this screen, and both round
    // to a 64px fetch, so this is the pair quantising is supposed to make free.
    await show(18);
    for (var step = 0; step < 45; step++) {
      await _realDelay(tester, const Duration(milliseconds: 100));
    }
    final afterFirst = served;

    await show(24);
    for (var step = 0; step < 45; step++) {
      await _realDelay(tester, const Duration(milliseconds: 100));
    }
    final refetchedOnZoom = served - afterFirst;

    // And back again, where everything was already loaded once.
    final beforeReturn = served;
    await show(18);
    for (var step = 0; step < 45; step++) {
      await _realDelay(tester, const Duration(milliseconds: 100));
    }

    print('GRIDZOOM fetched at 18 columns        : $afterFirst');
    print('GRIDZOOM refetched changing to 24     : $refetchedOnZoom');
    print('GRIDZOOM refetched returning to 18    : ${served - beforeReturn}');

    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 8)));
}
