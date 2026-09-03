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
import 'package:flutter/scheduler.dart';
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
typedef PanelState = ({Object key, ui.Image? atlas, int loose, int cells, bool complete, bool onScreen, int upgrade, int merged, int pending});

List<PanelState> _panels(WidgetTester tester) => find
    .byType(CustomPaint)
    .evaluate()
    .where((element) => (element.widget as CustomPaint).painter.runtimeType.toString() == '_DenseAssetRowPainter')
    .map((element) {
      final painter = (element.widget as CustomPaint).painter!;
      // Panels held in the sliver's cache extent are mounted but deliberately
      // not upgraded - queueing thousands of cells nobody can see would bury
      // the ones they can. Separating them matters: an unfinished panel off
      // screen is the design working, and one on screen is the bug.
      final box = element.renderObject as RenderBox?;
      final onScreen =
          box != null &&
          box.attached &&
          box.hasSize &&
          (box.localToGlobal(Offset.zero) & box.size).overlaps(Offset.zero & (tester.view.physicalSize / 3));
      final dynamic p = painter;
      final keys = p.assetKeys as List<Object?>;
      final images = p.images as List<Object?>;
      return (
        key: keys.isEmpty ? painter as Object : keys.first as Object,
        atlas: p.atlas as ui.Image?,
        // Thumbnails resolved but not yet folded into the atlas.
        loose: images.where((image) => image != null).length,
        cells: keys.length,
        // Every cell carries a real photo. A panel that never reaches this is
        // one where some tiles stay on their blurry preview indefinitely, which
        // is what "parts still don't load properly" looks like from the code.
        complete: p.atlasHidesPlaceholder as bool,
        onScreen: onScreen,
        upgrade: p.upgradeCells as int,
        merged: p.mergedCells as int,
        pending: p.pendingCells as int,
      );
    })
    .toList(growable: false);

Future<void> _realDelay(WidgetTester tester, Duration duration) async {
  await tester.runAsync(() => Future<void>.delayed(duration));
  await tester.pump();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // One server and one store for the whole file. `StoreService` is a singleton
  // and the endpoint lives in its cache, so tearing this down per test left the
  // next test pointing at a closed port - every thumbnail then failed and the
  // run reported an app problem that was entirely the harness's doing.
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
    testWidgets(
      'dense panels do not lose resolved thumbnails while loading at $columnCount columns',
      (tester) async {
        tester.view.devicePixelRatio = 3;
        tester.view.physicalSize = const Size(1080, 2400);
        addTearDown(tester.view.reset);

        final servedBefore = served;

        final service = _service(6000, assetsPerBucket: 500);
        addTearDown(service.dispose);

        // Frame cost measured while thumbnails are actually being fetched,
        // which is the only time the loading pipeline competes with drawing.
        // The perf harness cannot see this: it has no server, so its queue is
        // idle and any change to how hard that queue works is invisible there.
        final frames = <FrameTiming>[];
        void collect(List<FrameTiming> timings) => frames.addAll(timings);
        binding.addTimingsCallback(collect);
        addTearDown(() => binding.removeTimingsCallback(collect));

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

        // The reported symptom, as a check: a panel that is mounted, sized and
        // painting its placeholder colour but holding no texture at all. Screenshot
        // evidence showed whole screens of these, and every one of them is a panel
        // whose retry was skipped. Give the grid a settling window, then insist.
        for (var step = 0; step < 60; step++) {
          final stranded = _panels(tester).where((panel) => panel.atlas == null).length;
          if (stranded == 0) {
            break;
          }
          await _realDelay(tester, const Duration(milliseconds: 100));
        }
        final stranded = _panels(tester).where((panel) => panel.atlas == null).toList();

    // How much of the screen actually finished, not just how much has a
    // texture. Settle generously first: this asks whether it ever finishes, not
    // how quickly.
    for (var step = 0; step < 60; step++) {
      await _realDelay(tester, const Duration(milliseconds: 100));
      if (_panels(tester).where((panel) => panel.onScreen).every((panel) => panel.complete)) {
        break;
      }
    }
    final settled = _panels(tester);
    final visible = settled.where((panel) => panel.onScreen).toList();
    final complete = visible.where((panel) => panel.complete).length;
    final offScreenIncomplete = settled.where((panel) => !panel.onScreen && !panel.complete).length;
    final cells = visible.fold<int>(0, (sum, panel) => sum + panel.cells);

        print('GRIDFLICK ===== real thumbnails, $columnCount columns =====');
        print('GRIDFLICK panels stranded without atlas: ${stranded.length} of ${_panels(tester).length}');
    print('GRIDFLICK on-screen panels loaded      : $complete of ${visible.length}  ($cells cells)');
    print('GRIDFLICK off-screen not loaded         : $offScreenIncomplete of ${settled.length - visible.length} (expected)');
    for (final panel in visible.where((panel) => !panel.complete)) {
      // upgrade = cells this panel wants sharp, merged = cells it has, pending
      // = cells still in flight. A stuck panel with pending 0 and merged short
      // of upgrade is one that has stopped asking; pending above 0 is one still
      // waiting on requests that never land.
      print(
        'GRIDFLICK   unfinished panel: upgrade ${panel.upgrade} merged ${panel.merged} '
        'pending ${panel.pending} loose ${panel.loose} cells ${panel.cells}',
      );
    }
        print('GRIDFLICK thumbnail requests served    : ${served - servedBefore}');
        print('GRIDFLICK peak loose images on screen  : $peakLoose');
        print('GRIDFLICK atlas changes                : $atlasChanges');
        print('GRIDFLICK merges (loose -> new atlas)  : $merges');
        print('GRIDFLICK REGRESSIONS (lost, no atlas) : $regressions');
    final raster = frames.map((f) => f.rasterDuration.inMicroseconds / 1000).toList()..sort();
    final work =
        frames.map((f) => (f.buildDuration.inMicroseconds + f.rasterDuration.inMicroseconds) / 1000).toList()..sort();
    double pct(List<double> v, double p) => v.isEmpty ? 0 : v[(v.length * p).clamp(0, v.length - 1).floor()];
    print(
      'GRIDFLICK frames while loading         : ${frames.length}  raster p50/p95 '
      '${pct(raster, .5).toStringAsFixed(1)}/${pct(raster, .95).toStringAsFixed(1)} ms  '
      'work p50/p95 ${pct(work, .5).toStringAsFixed(1)}/${pct(work, .95).toStringAsFixed(1)} ms',
    );
        print('GRIDFLICK ===== end =====');

        expect(tester.takeException(), isNull);
        expect(
          stranded,
          isEmpty,
          reason:
              'every mounted panel must end up with a texture; a panel with none is '
              'the flat placeholder-coloured block seen in the bug reports',
        );
        expect(regressions, 0, reason: 'a cell must never lose a thumbnail it already resolved');
      },
      timeout: const Timeout(Duration(minutes: 6)),
    );
  }
}
