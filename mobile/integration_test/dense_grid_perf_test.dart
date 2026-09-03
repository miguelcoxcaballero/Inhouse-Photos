// Runs the real dense timeline on a device and reports what a scroll costs.
//
// Deliberately server-free: the timeline is fed a synthetic TimelineService, so
// this measures the grid itself rather than sync, auth or the network. Run with
//   flutter test integration_test/dense_grid_perf_test.dart --profile -d <id>
// and read the GRIDPERF lines. Profile mode matters - the test runner's JIT
// understates every ratio here by roughly half.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/timeline_config.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
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
      // Distinct hashes: one repeated hash would make the per-asset cell cache
      // look perfect for reasons no real library would reproduce.
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

/// Every dense panel currently mounted.
///
/// Keyed by the first asset in the panel rather than by the painter, because a
/// CustomPainter is a fresh object on every build - keying on it would report
/// zero atlas changes no matter what the panel did.
List<({Object key, ui.Image? atlas, int loose})> _panels(WidgetTester tester) => tester
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
        // Thumbnails resolved but not yet folded into the atlas. Each one is a
        // separate texture the raster thread draws on every single frame.
        loose: images.where((image) => image != null).length,
      );
    })
    .toList(growable: false);

Future<void> _realDelay(WidgetTester tester, Duration duration) async {
  await tester.runAsync(() => Future<void>.delayed(duration));
  await tester.pump();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 18 is the level the reported screenshot was taken at, and it is not just a
  // point between the other two: there the composite atlas is 80px cells built
  // by upscaling a 32px ThumbHash atlas, while at 48 the two sizes are equal.
  for (final columnCount in [12, 18, 48]) {
    testWidgets('dense grid scroll at $columnCount columns', (tester) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = const Size(1080, 2400);
      addTearDown(tester.view.reset);

      final service = _service(6000, assetsPerBucket: 500);
      addTearDown(service.dispose);

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

      // How long until the first screenful actually has textures. This is the
      // "previews are not instant" complaint, measured.
      final firstPaint = Stopwatch()..start();
      var settledAt = Duration.zero;
      for (var step = 0; step < 60; step++) {
        await _realDelay(tester, const Duration(milliseconds: 100));
        final panels = _panels(tester);
        if (panels.isNotEmpty && panels.every((panel) => panel.atlas != null)) {
          settledAt = firstPaint.elapsed;
          break;
        }
      }
      firstPaint.stop();

      // Atlas identity per panel, sampled while scrolling. A panel that swaps
      // its texture repeatedly is a panel that visibly changes under the finger.
      final swapsByPanel = <Object, int>{};
      final lastAtlas = <Object, ui.Image?>{};
      final looseSamples = <int>[];
      void sampleAtlases() {
        var loose = 0;
        for (final panel in _panels(tester)) {
          if (lastAtlas.containsKey(panel.key) && !identical(lastAtlas[panel.key], panel.atlas)) {
            swapsByPanel[panel.key] = (swapsByPanel[panel.key] ?? 0) + 1;
          }
          lastAtlas[panel.key] = panel.atlas;
          loose += panel.loose;
        }
        looseSamples.add(loose);
      }

      frames.clear();
      for (var fling = 0; fling < 6; fling++) {
        await tester.fling(find.byType(Timeline), const Offset(0, -900), 2400);
        for (var step = 0; step < 12; step++) {
          await _realDelay(tester, const Duration(milliseconds: 60));
          sampleAtlases();
        }
      }

      final build = frames.map((f) => f.buildDuration.inMicroseconds / 1000).toList()..sort();
      final raster = frames.map((f) => f.rasterDuration.inMicroseconds / 1000).toList()..sort();
      // Work per frame, not totalSpan: totalSpan includes vsync overhead and so
      // sits near the refresh interval even for frames produced well inside
      // budget, which would report almost every frame as janky.
      final work = frames
          .map((f) => (f.buildDuration.inMicroseconds + f.rasterDuration.inMicroseconds) / 1000)
          .toList();
      double pct(List<double> values, double p) => values.isEmpty ? 0 : values[(values.length * p).clamp(0, values.length - 1).floor()];
      // Taken from the display rather than assumed. A 120Hz panel gives 8.3ms
      // per frame, not 16.7 - measuring against the wrong one calls a frame
      // comfortable when it has already missed.
      final refreshRate = tester.view.display.refreshRate;
      final budgetMs = 1000 / refreshRate;
      final janky = work.where((ms) => ms > budgetMs).length;
      final swaps = swapsByPanel.values.fold<int>(0, (a, b) => a + b);

      print('GRIDPERF ===== $columnCount columns =====');
      print('GRIDPERF first full screen of atlases : ${settledAt.inMilliseconds} ms');
      print('GRIDPERF frames measured              : ${frames.length}');
      print('GRIDPERF build  p50/p95/p99 ms        : ${pct(build, .5).toStringAsFixed(1)} / ${pct(build, .95).toStringAsFixed(1)} / ${pct(build, .99).toStringAsFixed(1)}');
      print('GRIDPERF raster p50/p95/p99 ms        : ${pct(raster, .5).toStringAsFixed(1)} / ${pct(raster, .95).toStringAsFixed(1)} / ${pct(raster, .99).toStringAsFixed(1)}');
      final sortedWork = [...work]..sort();
      print('GRIDPERF build+raster p50/p95/p99 ms  : ${pct(sortedWork, .5).toStringAsFixed(1)} / ${pct(sortedWork, .95).toStringAsFixed(1)} / ${pct(sortedWork, .99).toStringAsFixed(1)}');
      print('GRIDPERF display                      : ${refreshRate.toStringAsFixed(0)} Hz, ${budgetMs.toStringAsFixed(1)} ms per frame');
      print('GRIDPERF frames over budget           : $janky (${frames.isEmpty ? 0 : (janky * 100 / frames.length).round()}%)');
      looseSamples.sort();
      print('GRIDPERF atlas swaps during scroll    : $swaps across ${swapsByPanel.length} panels');
      print('GRIDPERF loose images/frame p50/max   : ${pct(looseSamples.map((v) => v.toDouble()).toList(), .5).toStringAsFixed(0)} / ${looseSamples.isEmpty ? 0 : looseSamples.last}');
      print('GRIDPERF panels mounted at end        : ${_panels(tester).length}');
      print('GRIDPERF ===== end $columnCount =====');

      expect(tester.takeException(), isNull);
    }, timeout: const Timeout(Duration(minutes: 5)));
  }

  // A deterministic sweep, repeated, so the spread is visible instead of being
  // guessed at. `fling` was the wrong instrument: its physics and settling time
  // differ every run, which put single-run differences of 30-50% inside the
  // noise and made small changes unmeasurable. Fixed-size drags pumped at a
  // fixed interval remove that, and repeating within one app launch removes
  // start-up variance too, so the numbers below can be compared to each other.
  testWidgets('deterministic scroll sweep at 18 columns', (tester) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1080, 2400);
    addTearDown(tester.view.reset);

    final service = _service(6000, assetsPerBucket: 500);
    addTearDown(service.dispose);

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
        appConfigProvider.overrideWithValue(const AppConfig(timeline: TimelineConfig(tilesPerRow: 18))),
      ],
      settle: false,
    );
    for (var step = 0; step < 40; step++) {
      await _realDelay(tester, const Duration(milliseconds: 100));
    }

    double median(List<double> values) {
      if (values.isEmpty) {
        return 0;
      }
      final sorted = [...values]..sort();
      return sorted[sorted.length ~/ 2];
    }

    final sweepRaster = <double>[];
    final sweepWork = <double>[];
    // Background preview generation stands aside whenever this is true. The
    // unit tests prove it obeys the signal; this checks the signal actually
    // fires while somebody is scrolling, which is the only thing that makes
    // obeying it worth anything.
    var busySamples = 0;
    var totalSamples = 0;
    for (var sweep = 0; sweep < 6; sweep++) {
      frames.clear();
      for (var step = 0; step < 45; step++) {
        await tester.drag(find.byType(Timeline), const Offset(0, -140));
        await tester.pump(const Duration(milliseconds: 16));
        if (denseGridIsResolvingThumbnails()) {
          busySamples++;
        }
        totalSamples++;
      }
      await _realDelay(tester, const Duration(milliseconds: 300));
      sweepRaster.add(median(frames.map((f) => f.rasterDuration.inMicroseconds / 1000).toList()));
      sweepWork.add(
        median(
          frames.map((f) => (f.buildDuration.inMicroseconds + f.rasterDuration.inMicroseconds) / 1000).toList(),
        ),
      );
    }

    String fmt(List<double> v) => v.map((x) => x.toStringAsFixed(1)).join(' ');
    // The first sweep pays for everything that only happens once - worker
    // isolates starting, caches filling - and runs about twice the rest. Mixing
    // it in is what made earlier numbers look noisier than the app actually is,
    // so it is reported separately rather than averaged away.
    final steady = sweepRaster.skip(1).toList();
    final steadyWork = sweepWork.skip(1).toList();
    final spread = steady.reduce(math.max) - steady.reduce(math.min);
    print('GRIDSWEEP raster medians per sweep : ${fmt(sweepRaster)}');
    print('GRIDSWEEP work medians per sweep   : ${fmt(sweepWork)}');
    print('GRIDSWEEP warm-up sweep (excluded) : ${sweepRaster.first.toStringAsFixed(2)} ms');
    print('GRIDSWEEP steady raster median     : ${median(steady).toStringAsFixed(2)} ms');
    print('GRIDSWEEP steady work median       : ${median(steadyWork).toStringAsFixed(2)} ms');
    print('GRIDSWEEP steady spread            : ${spread.toStringAsFixed(2)} ms');
    print(
      'GRIDSWEEP display                  : ${tester.view.display.refreshRate.toStringAsFixed(0)} Hz, '
      '${(1000 / tester.view.display.refreshRate).toStringAsFixed(1)} ms per frame',
    );
    print('GRIDSWEEP => a change must beat that spread to be believable');
    print('GRIDSWEEP grid busy during scroll   : $busySamples/$totalSamples samples');

    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 6)));
}
