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

TimelineService _service(int assetCount, {required int assetsPerBucket, int seed = 0}) {
  // Content the grid caches is keyed by what is in it, so two tests built
  // from the same assets share cache entries and the second one measures the
  // first one's work. `seed` shifts the identity of every asset so a test that
  // means to be cold really is.
  final now = DateTime(2026, 8, 25);
  final assets = List<BaseAsset>.generate(
    assetCount,
    (index) => RemoteAsset(
      id: 'remote-${seed}s$index',
      name: 'photo-${seed}s$index.jpg',
      ownerId: 'owner',
      checksum: 'checksum-${seed}s$index',
      type: AssetType.image,
      createdAt: now.subtract(Duration(minutes: index)),
      updatedAt: now,
      width: 4032,
      height: 3024,
      thumbHash: _thumbHash(index + seed * 7919),
      isEdited: false,
    ),
    growable: false,
  );
  final bucketCount = (assetCount / assetsPerBucket).ceil();
  return TimelineService((
    assetSource: (offset, count) async => assets.skip(offset).take(count).toList(growable: false),
    assetSourceAfter: null,
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

/// Per-panel state, keyed so a panel can be followed over time.
/// Share of on-screen cells currently carrying a real photo.
///
/// The per-panel `sharp` flag is all-or-nothing over roughly a hundred and
/// fifty photos, so it reports the arrival of the slowest one and calls that
/// the moment the screen stops looking blurry. What a person actually sees is
/// this: how much of the screen is real, over time.
({int merged, int wanted}) _cellProgress(WidgetTester tester) {
  var merged = 0;
  var wanted = 0;
  for (final painter in tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((paint) => paint.painter)
      .where((painter) => painter.runtimeType.toString() == '_DenseAssetRowPainter')) {
    final dynamic p = painter;
    merged += p.mergedCells as int;
    wanted += p.upgradeCells as int;
  }
  return (merged: merged, wanted: wanted);
}

List<({Object key, bool hasAtlas, bool sharp})> _panelStates(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((paint) => paint.painter)
    .where((painter) => painter.runtimeType.toString() == '_DenseAssetRowPainter')
    .map((painter) {
      final dynamic p = painter;
      final keys = p.assetKeys as List<Object?>;
      return (
        key: keys.isEmpty ? painter as Object : keys.first as Object,
        hasAtlas: p.atlas != null,
        sharp: p.atlasHidesPlaceholder as bool,
      );
    })
    .toList(growable: false);

int _panelCount(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((paint) => paint.painter)
    .where((painter) => painter.runtimeType.toString() == '_DenseAssetRowPainter')
    .length;

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
  // Counting requests alone cannot tell repeated work from work that simply had
  // not happened yet: a panel flung past unfinished leaves cells nobody ever
  // fetched, and those look identical to a cache failure in a plain total. What
  // answers "does going back redo work" is how often the same photo is asked for
  // twice, so the path of each request is remembered.
  final servedPaths = <String>{};
  var servedAgain = 0;

  setUpAll(() async {
    bytes = await _thumbnailBytes();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      served++;
      if (!servedPaths.add(request.uri.path)) {
        servedAgain++;
      }
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

  testWidgets('a restart with a warm disk restores instead of rebuilding', (tester) async {
    // The cold-start complaint, measured for the first time. Every previous
    // measurement reported zero disk hits, and that was the harness lying:
    // `flutter drive` uninstalls the app between runs, so the disk cache was
    // wiped before each one. It could never have hit.
    //
    // This keeps the process, drops exactly what the OS drops under memory
    // pressure - the in-memory textures and queues - and rebuilds the grid. The
    // disk cache survives, so this is what opening the app again should feel
    // like.
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1080, 2400);
    addTearDown(tester.view.reset);

    final service = _service(6000, assetsPerBucket: 500);
    addTearDown(service.dispose);

    Future<void> show() => tester.pumpConsumerWidget(
      const Timeline(
        withScrubber: false,
        readOnly: true,
        appBar: SliverToBoxAdapter(child: SizedBox.shrink()),
        bottomSheet: null,
      ),
      overrides: [
        timelineServiceProvider.overrideWithValue(service),
        appConfigProvider.overrideWithValue(const AppConfig(timeline: TimelineConfig(tilesPerRow: 18))),
      ],
      settle: false,
    );

    await show();
    // Long settle so panels finish and get written to disk; writes are paced.
    for (var step = 0; step < 90; step++) {
      await _realDelay(tester, const Duration(milliseconds: 100));
    }
    final servedFirst = served;
    final firstRun = DenseGridStats.summary();

    // The restart.
    releaseDenseTimelineMemory();
    await tester.pumpWidget(const SizedBox.shrink());
    await _realDelay(tester, const Duration(milliseconds: 300));
    DenseGridStats.reset();
    final servedBeforeRestart = served;

    await show();
    final settle = Stopwatch()..start();
    for (var step = 0; step < 60; step++) {
      await _realDelay(tester, const Duration(milliseconds: 100));
      final panels = _panelsWithAtlas(tester);
      if (panels > 0 && panels == _panelCount(tester)) {
        break;
      }
    }
    settle.stop();

    print('GRIDCOLD first run                    : $firstRun');
    print('GRIDCOLD first run fetched            : $servedFirst');
    print('GRIDCOLD after restart                : ${DenseGridStats.summary()}');
    print('GRIDCOLD after restart refetched      : ${served - servedBeforeRestart}');
    print('GRIDCOLD time to a full screen        : ${settle.elapsedMilliseconds} ms');

    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('how long a panel shows blurry before it is sharp', (tester) async {
    // The complaint, stated as a number: photos appear blurry and take about a
    // second to sharpen, on opening the app and while scrolling. This follows
    // each panel from the moment it has any texture to the moment every cell in
    // it carries a real photo, on a warm disk - which is what opening the app
    // again actually looks like.
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1080, 2400);
    addTearDown(tester.view.reset);

    final service = _service(6000, assetsPerBucket: 500);
    addTearDown(service.dispose);

    Future<void> show() => tester.pumpConsumerWidget(
      const Timeline(
        withScrubber: false,
        readOnly: true,
        appBar: SliverToBoxAdapter(child: SizedBox.shrink()),
        bottomSheet: null,
      ),
      overrides: [
        timelineServiceProvider.overrideWithValue(service),
        appConfigProvider.overrideWithValue(const AppConfig(timeline: TimelineConfig(tilesPerRow: 18))),
      ],
      settle: false,
    );

    // First visit, so the disk has something to restore from next time.
    await show();
    for (var step = 0; step < 90; step++) {
      await _realDelay(tester, const Duration(milliseconds: 100));
    }
    print('GRIDBLUR first visit                  : ${DenseGridStats.summary()}');

    // Reopen: drop what the OS drops, keep the disk.
    releaseDenseTimelineMemory();
    await tester.pumpWidget(const SizedBox.shrink());
    await _realDelay(tester, const Duration(milliseconds: 300));
    DenseGridStats.reset();

    final clock = Stopwatch()..start();
    final firstTexture = <Object, int>{};
    final becameSharp = <Object, int>{};
    await show();
    for (var step = 0; step < 100; step++) {
      await _realDelay(tester, const Duration(milliseconds: 50));
      for (final panel in _panelStates(tester)) {
        if (panel.hasAtlas) {
          firstTexture.putIfAbsent(panel.key, () => clock.elapsedMilliseconds);
        }
        if (panel.sharp) {
          becameSharp.putIfAbsent(panel.key, () => clock.elapsedMilliseconds);
        }
      }
      // Only stop once the screen has settled at its full panel count and all
      // of them are sharp; stopping at the first sharp panel measured one
      // panel and called it the answer.
      final mounted = _panelCount(tester);
      if (mounted > 0 && firstTexture.length >= mounted && becameSharp.length >= mounted && step > 12) {
        break;
      }
    }
    clock.stop();

    final gaps = <int>[];
    for (final entry in becameSharp.entries) {
      final blurAt = firstTexture[entry.key];
      if (blurAt != null) {
        gaps.add(entry.value - blurAt);
      }
    }
    gaps.sort();
    final neverSharp = firstTexture.length - becameSharp.length;

    print('GRIDBLUR reopen                       : ${DenseGridStats.summary()}');
    print('GRIDBLUR panels that showed a texture : ${firstTexture.length}');
    print('GRIDBLUR first texture at             : ${firstTexture.values.isEmpty ? -1 : firstTexture.values.reduce(math.min)} ms');
    print('GRIDBLUR blurry-to-sharp median/worst : '
        '${gaps.isEmpty ? -1 : gaps[gaps.length ~/ 2]} / ${gaps.isEmpty ? -1 : gaps.last} ms');
    print('GRIDBLUR panels still not sharp       : $neverSharp');

    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('how much of the screen is real photos, over time, after scrolling', (tester) async {
    // What the complaint is actually about. After a fling lands, how quickly
    // does the screen stop being blurry - measured as the share of visible
    // cells carrying a real photo rather than as the arrival of the slowest
    // photo on screen.
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1080, 2400);
    addTearDown(tester.view.reset);

    final service = _service(6000, assetsPerBucket: 500, seed: 337);
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
        appConfigProvider.overrideWithValue(const AppConfig(timeline: TimelineConfig(tilesPerRow: 18))),
      ],
      settle: false,
    );
    for (var step = 0; step < 40; step++) {
      await _realDelay(tester, const Duration(milliseconds: 100));
    }

    // Three separate landings, each measured from the moment the fling is over,
    // so the numbers are per-arrival rather than averaged over a long gesture.
    for (var landing = 0; landing < 3; landing++) {
      DenseGridStats.reset();
      await tester.fling(find.byType(Timeline), const Offset(0, -760), 1800);
      final clock = Stopwatch()..start();
      final marks = <int, int>{};
      var last = (merged: 0, wanted: 0);
      for (var step = 0; step < 100; step++) {
        await _realDelay(tester, const Duration(milliseconds: 50));
        last = _cellProgress(tester);
        if (last.wanted == 0) {
          continue;
        }
        final percent = last.merged * 100 ~/ last.wanted;
        for (final threshold in [50, 75, 90, 99]) {
          if (percent >= threshold) {
            marks.putIfAbsent(threshold, () => clock.elapsedMilliseconds);
          }
        }
        if (marks.containsKey(99)) {
          break;
        }
      }
      clock.stop();
      String at(int threshold) => marks[threshold] == null ? 'not reached' : '${marks[threshold]} ms';
      print(
        'GRIDREAL landing $landing: 50% ${at(50)} | 75% ${at(75)} | 90% ${at(90)} '
        '| 99% ${at(99)} | ended ${last.merged}/${last.wanted} cells',
      );
      print('GRIDREAL landing $landing cost: ${DenseGridStats.summary()}');
    }

    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('how long a panel scrolled into shows blurry before it is sharp', (tester) async {
    // The other half of the complaint - "same when scrolling" - which the
    // reopen measurement does not cover. Opening the app lands on panels the
    // disk may already hold; scrolling forward reaches panels nothing has ever
    // built, and the honest question is how long those show blurry, and whether
    // scrolling back over them is instant the way reopening now is.
    //
    // Panels are followed by key across the whole gesture, so a panel that
    // scrolls off and returns is the same panel, and three moments are recorded
    // for each: mounted, first texture of any kind, and every cell sharp.
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1080, 2400);
    addTearDown(tester.view.reset);

    // A library no other test in this run has touched, so the outbound leg is
    // measuring panels being built for the first time rather than panels an
    // earlier test already cached.
    final service = _service(6000, assetsPerBucket: 500, seed: 991);
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
        appConfigProvider.overrideWithValue(const AppConfig(timeline: TimelineConfig(tilesPerRow: 18))),
      ],
      settle: false,
    );

    // Settle the first screen, so the measurement below is about scrolling and
    // not about the cold start that the reopen test already measures.
    for (var step = 0; step < 40; step++) {
      await _realDelay(tester, const Duration(milliseconds: 100));
    }

    final clock = Stopwatch()..start();
    final mountedAt = <Object, int>{};
    final textureAt = <Object, int>{};
    final sharpAt = <Object, int>{};
    // Panels that existed before the gesture started are excluded: they are
    // already resolved and would report a gap of zero for the wrong reason.
    final preexisting = <Object>{for (final panel in _panelStates(tester)) panel.key};

    void sample() {
      for (final panel in _panelStates(tester)) {
        if (preexisting.contains(panel.key)) {
          continue;
        }
        mountedAt.putIfAbsent(panel.key, () => clock.elapsedMilliseconds);
        if (panel.hasAtlas) {
          textureAt.putIfAbsent(panel.key, () => clock.elapsedMilliseconds);
        }
        if (panel.sharp) {
          sharpAt.putIfAbsent(panel.key, () => clock.elapsedMilliseconds);
        }
      }
    }

    // A panel that never turned sharp is two different things, and only one of
    // them is a bug: a panel still on screen at the end that is not sharp is
    // stuck, while a panel that scrolled past before it finished says nothing
    // except that it was scrolled past. They are counted apart.
    ({List<int> blank, List<int> gap, int stuck, int scrolledPast}) report() {
      final onScreen = {for (final panel in _panelStates(tester)) panel.key};
      final blank = <int>[];
      final gap = <int>[];
      var stuck = 0;
      var scrolledPast = 0;
      for (final key in mountedAt.keys) {
        final texture = textureAt[key];
        final sharp = sharpAt[key];
        if (texture != null) {
          blank.add(texture - mountedAt[key]!);
        }
        if (texture != null && sharp != null) {
          gap.add(math.max(0, sharp - texture));
        } else if (onScreen.contains(key)) {
          stuck++;
        } else {
          scrolledPast++;
        }
      }
      blank.sort();
      gap.sort();
      return (blank: blank, gap: gap, stuck: stuck, scrolledPast: scrolledPast);
    }

    void printReport(String label, ({List<int> blank, List<int> gap, int stuck, int scrolledPast}) r) {
      String stat(List<int> values) =>
          values.isEmpty ? 'n/a' : '${values[values.length ~/ 2]} / ${values.last} ms';
      print('GRIDSCROLL $label panels                 : ${mountedAt.length}');
      print('GRIDSCROLL $label blank-to-texture med/max: ${stat(r.blank)}');
      print('GRIDSCROLL $label blurry-to-sharp med/max : ${stat(r.gap)}');
      print('GRIDSCROLL $label sharp panels            : ${r.gap.length}');
      print('GRIDSCROLL $label stuck on screen         : ${r.stuck}');
      print('GRIDSCROLL $label scrolled past unfinished: ${r.scrolledPast}');
    }

    // Held still after the last fling, so "stuck" means a panel a person would
    // be sitting there looking at, not one still catching up mid-gesture.
    Future<void> settle() async {
      for (var step = 0; step < 40; step++) {
        await _realDelay(tester, const Duration(milliseconds: 100));
        sample();
      }
    }

    // Forward into ground nothing has built yet.
    const screens = 3;
    final servedBeforeOutbound = served;
    DenseGridStats.reset();
    for (var i = 0; i < screens; i++) {
      await tester.fling(find.byType(Timeline), const Offset(0, -760), 1800);
      for (var step = 0; step < 24; step++) {
        await _realDelay(tester, const Duration(milliseconds: 50));
        sample();
      }
    }
    await settle();
    final outbound = report();
    printReport('new content ', outbound);
    print('GRIDSCROLL new content  fetched          : ${served - servedBeforeOutbound}');
    print('GRIDSCROLL new content  cache            : ${DenseGridStats.summary()}');

    // Back over exactly that ground, then forward over it again. Panels here
    // have been built once already, so anything other than an instant texture
    // is the cache failing rather than work that had to happen.
    final servedBeforeReturn = served;
    final repeatsBeforeReturn = servedAgain;
    DenseGridStats.reset();
    final returnClockBase = clock.elapsedMilliseconds;
    mountedAt.clear();
    textureAt.clear();
    sharpAt.clear();
    preexisting
      ..clear()
      ..addAll([for (final panel in _panelStates(tester)) panel.key]);
    for (final direction in [760.0, -760.0]) {
      for (var i = 0; i < screens; i++) {
        await tester.fling(find.byType(Timeline), Offset(0, direction), 1800);
        for (var step = 0; step < 24; step++) {
          await _realDelay(tester, const Duration(milliseconds: 50));
          sample();
        }
      }
    }
    await settle();
    clock.stop();
    printReport('seen before ', report());
    print('GRIDSCROLL seen before  requests          : ${served - servedBeforeReturn}');
    print('GRIDSCROLL seen before  same photo twice   : ${servedAgain - repeatsBeforeReturn}');
    print('GRIDSCROLL seen before  cache            : ${DenseGridStats.summary()}');
    print('GRIDSCROLL return leg took               : ${clock.elapsedMilliseconds - returnClockBase} ms');

    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
