// Reproduces the dense grid with *real* thumbnails loading, to see whether
// cells visibly go backwards while a panel resolves.
//
// The perf harness next door drives synthetic assets whose thumbnail provider
// never resolves, so the blur-to-sharp transitions - which is where flickering
// was reported - never run there at all. Here the timeline is pointed at a
// throwaway HTTP server inside the test process, so `RemoteImageProvider` does
// a real fetch, a real decode and a real composite. Still no account, no
// network and no Immich server involved.
//
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/dense_grid_flicker_test.dart --profile -d <id>
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

/// A few distinct PNGs, served as thumbnails.
///
/// Encoded once through the engine so the decode path downstream is a real
/// image decode rather than anything synthetic.
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
    // Some structure, so a blurry placeholder and a sharp thumbnail differ.
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

/// One dense panel's currently visible state.
typedef PanelState = ({Object key, ui.Image? atlas, int loose, int cells});

List<PanelState> _panels(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((paint) => paint.painter)
    .where((painter) => painter.runtimeType.toString() == '_DenseAssetRowPainter')
    .map((painter) {
      final dynamic p = painter;
      final keys = p.assetKeys as List<Object?>;
      final images = p.images as List<Object?>;
      return (
        key: keys.isEmpty ? painter as Object : keys.first as Object,
        atlas: p.atlas as ui.Image?,
        loose: images.where((image) => image != null).length,
        cells: keys.length,
      );
    })
    .toList(growable: false);

Future<void> _realDelay(WidgetTester tester, Duration duration) async {
  await tester.runAsync(() => Future<void>.delayed(duration));
  await tester.pump();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('dense panels do not lose resolved thumbnails while loading', (tester) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1080, 2400);
    addTearDown(tester.view.reset);

    late HttpServer server;
    late List<Uint8List> bytes;
    var served = 0;

    await tester.runAsync(() async {
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

      final db = Drift(DatabaseConnection(NativeDatabase.memory()));
      await StoreService.init(storeRepository: DriftStoreRepository(db));
      await Store.put(StoreKey.serverEndpoint, 'http://127.0.0.1:${server.port}/api');
      await Store.put(StoreKey.accessToken, 'integration-test');
      addTearDown(() async {
        await server.close(force: true);
        await db.close();
      });
    });

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
        appConfigProvider.overrideWithValue(const AppConfig(timeline: TimelineConfig(tilesPerRow: 48))),
      ],
      settle: false,
    );

    // A cell that has a real thumbnail must never go back to showing the blurry
    // placeholder. Loose images dropping while the atlas is unchanged means
    // exactly that: the thumbnails were released without a new texture
    // containing them taking their place.
    var regressions = 0;
    var merges = 0;
    var atlasChanges = 0;
    final lastLoose = <Object, int>{};
    final lastAtlas = <Object, ui.Image?>{};

    void sample() {
      for (final panel in _panels(tester)) {
        final hadLoose = lastLoose[panel.key];
        final hadAtlas = lastAtlas.containsKey(panel.key) ? lastAtlas[panel.key] : null;
        final atlasChanged = lastAtlas.containsKey(panel.key) && !identical(hadAtlas, panel.atlas);
        if (atlasChanged) {
          atlasChanges++;
        }
        if (hadLoose != null && panel.loose < hadLoose) {
          if (atlasChanged) {
            merges++;
          } else {
            regressions++;
          }
        }
        lastLoose[panel.key] = panel.loose;
        lastAtlas[panel.key] = panel.atlas;
      }
    }

    var peakLoose = 0;
    for (var step = 0; step < 80; step++) {
      await _realDelay(tester, const Duration(milliseconds: 50));
      sample();
      final loose = _panels(tester).fold<int>(0, (sum, panel) => sum + panel.loose);
      peakLoose = math.max(peakLoose, loose);
    }

    for (var fling = 0; fling < 4; fling++) {
      await tester.fling(find.byType(Timeline), const Offset(0, -900), 2400);
      for (var step = 0; step < 16; step++) {
        await _realDelay(tester, const Duration(milliseconds: 50));
        sample();
        final loose = _panels(tester).fold<int>(0, (sum, panel) => sum + panel.loose);
        peakLoose = math.max(peakLoose, loose);
      }
    }

    print('GRIDFLICK ===== real thumbnails, 48 columns =====');
    print('GRIDFLICK thumbnail requests served    : $served');
    print('GRIDFLICK peak loose images on screen  : $peakLoose');
    print('GRIDFLICK atlas changes                : $atlasChanges');
    print('GRIDFLICK merges (loose -> new atlas)  : $merges');
    print('GRIDFLICK REGRESSIONS (lost, no atlas) : $regressions');
    print('GRIDFLICK ===== end =====');

    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 6)));
}
