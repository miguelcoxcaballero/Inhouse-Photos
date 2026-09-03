import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/timeline_config.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment_builder.dart';
import 'package:immich_mobile/presentation/widgets/timeline/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.state.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_layout_transition.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:thumbhash/thumbhash.dart' as thumbhash;

class _FrozenBucketService implements TimelineService {
  final _controller = StreamController<List<Bucket>>.broadcast();

  @override
  Stream<List<Bucket>> Function() get watchBuckets =>
      () => _controller.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EmptyBucketService implements TimelineService {
  const _EmptyBucketService();

  @override
  Stream<List<Bucket>> Function() get watchBuckets =>
      () => Stream.value(const []);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CountingBucketService implements TimelineService {
  int watchCount = 0;
  final _controller = StreamController<List<Bucket>>.broadcast();

  void emit(List<Bucket> buckets) => _controller.add(buckets);

  @override
  Stream<List<Bucket>> Function() get watchBuckets => () {
    watchCount++;
    return _controller.stream;
  };

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('pinch thresholds are symmetrical and responsive around the active column count', () {
    expect(calculateTimelineColumnCount(scaleFactor: 3.39, gestureStartScaleFactor: 3), 4);
    expect(calculateTimelineColumnCount(scaleFactor: 3.41, gestureStartScaleFactor: 3), 3);
    expect(calculateTimelineColumnCount(scaleFactor: 2.61, gestureStartScaleFactor: 3), 4);
    expect(calculateTimelineColumnCount(scaleFactor: 2.59, gestureStartScaleFactor: 3), 5);
    expect(kTimelinePinchSensitivity, 1.25);
  });

  test('the gallery exposes every continuous zoom level up to 48 columns', () {
    expect(normalizeTimelineTilesPerRow(0), 2);
    expect(normalizeTimelineTilesPerRow(1), 2);
    for (var columns = 2; columns <= 6; columns++) {
      expect(normalizeTimelineTilesPerRow(columns), columns);
    }
    expect(timelineTilesPerRowSteps, [2, 3, 4, 5, 6, 12, 18, 24, 36, 48]);
    expect(normalizeTimelineTilesPerRow(10), 12);
    expect(normalizeTimelineTilesPerRow(12), 12);
    expect(normalizeTimelineTilesPerRow(48), 48);

    expect(calculateTimelineColumnCount(scaleFactor: 0.15, gestureStartScaleFactor: 1), 48);
    expect(calculateTimelineColumnCount(scaleFactor: 5, gestureStartScaleFactor: 5), 2);
    expect(timelineScaleFactorForColumnCount(48), 0.22);
    expect(usesBatchedTimelineGrid(6), isFalse);
    expect(usesBatchedTimelineGrid(12), isTrue);
  });

  test('zooming is treated as active timeline interaction', () {
    expect(const TimelineState(isZooming: true).isInteracting, isTrue);
    expect(const TimelineState().isInteracting, isFalse);
  });

  test('the largest grid batches rows and keeps compact year headers in the same timeline', () {
    final segment =
        FixedSegmentBuilder(
              buckets: [TimeBucket(date: DateTime(2026, 8, 14), assetCount: 14)],
              tileHeight: 64,
              columnCount: 48,
              spacing: 0,
            ).generate().single
            as FixedSegment;

    expect(segment.lastIndex - segment.firstIndex, 1);
    expect(segment.rowsPerChild, 4);
    expect(segment.batchedGrid, isTrue);
    expect(segment.endOffset - segment.gridOffset, 64);
    expect(segment.header, HeaderType.year);
  });

  test('batched levels bound database work and retain crisp physical pixels', () {
    expect(denseTimelineAssetChunkSize(columnCount: 48, viewportHeight: 800, tileExtent: 8.34), 2048);
    expect(denseTimelineAssetChunkSize(columnCount: 24, viewportHeight: 800, tileExtent: 16.67), 2048);
    expect(denseTimelineAssetChunkSize(columnCount: 12, viewportHeight: 0, tileExtent: 32), 1024);
    // A 26-pixel tile is below the cap, so it renders at three quarters and is
    // scaled up: at that size the softening is not what costs, the thousands of
    // full-resolution thumbnails are. A 54-pixel tile is above it and keeps
    // every pixel it displays.
    expect(denseTimelineTargetPixels(tileExtent: 8.34, devicePixelRatio: 3), 20);
    expect(denseTimelineTargetPixels(tileExtent: 18, devicePixelRatio: 3), 54);
    expect(batchedGridMetadataCellPixels, 32);
    expect(batchedGridDiskCacheLimitBytes, 256 * 1024 * 1024);
  });

  test('batched levels collapse many photo rows into a bounded number of sliver children', () {
    final segment =
        FixedSegmentBuilder(
              buckets: [TimeBucket(date: DateTime(2026), assetCount: 5000)],
              tileHeight: 8,
              columnCount: 48,
              spacing: 0,
            ).generate().single
            as FixedSegment;

    expect(segment.rowsPerChild, 4);
    expect(segment.lastIndex - segment.firstIndex, 27);
    expect(segment.endOffset - segment.gridOffset, 105 * 8);
  });

  test('batched metadata atlas fills hashed cells and keeps missing cells transparent', () {
    final source = Uint8List.fromList([
      for (var index = 0; index < 16; index++) ...[index * 12, 180 - index * 7, 60 + index * 5, 255],
    ]);
    final hash = base64Encode(thumbhash.rgbaToThumbHash(4, 4, source));
    final atlas = buildDenseThumbhashAtlasPixels([hash, null], 8);

    expect(atlas, hasLength(8 * 16 * 4));
    expect([
      for (var y = 0; y < 8; y++)
        for (var x = 0; x < 8; x++) atlas[(y * 16 + x) * 4 + 3],
    ], everyElement(255));
    expect([
      for (var y = 0; y < 8; y++)
        for (var x = 8; x < 16; x++) atlas[(y * 16 + x) * 4 + 3],
    ], everyElement(0));
  });

  test('the cached texture never bakes a theme colour into its empty cells', () {
    // The texture is persisted to disk and its identity does not include the
    // palette, so a colour baked here would outlive the theme that produced it
    // and reappear under a different one. Empty cells stay transparent and the
    // painter fills them live instead.
    final atlas = buildDenseThumbhashAtlasPixels([null, null], 4);

    expect(atlas, hasLength(4 * 8 * 4));
    expect(atlas, everyElement(0));
  });

  test('the ThumbHash fallback texture never grows past its own level of detail', () {
    // A ThumbHash carries a handful of DCT coefficients. Expanding it to a
    // 3x phone cell costs sixteen times the memory for no extra information,
    // while the real thumbnails still composite at full physical resolution.
    expect(denseTimelineTargetPixels(tileExtent: 35.8, devicePixelRatio: 3), 108);
    expect(denseTimelineMetadataPixels(108), batchedGridMetadataCellPixels);
    expect(denseTimelineMetadataPixels(batchedGridMetadataCellPixels), batchedGridMetadataCellPixels);
  });

  test('a hashed cell is opaque while an unhashed one is left for the painter', () {
    final source = Uint8List.fromList([
      for (var index = 0; index < 16; index++) ...[index * 9, 200 - index * 6, 40 + index * 4, 255],
    ]);
    final hash = base64Encode(thumbhash.rgbaToThumbHash(4, 4, source));
    final atlas = buildDenseThumbhashAtlasPixels([hash, null], 8);

    final hashedAlpha = [
      for (var y = 0; y < 8; y++)
        for (var x = 0; x < 8; x++) atlas[(y * 16 + x) * 4 + 3],
    ];
    final emptyAlpha = [
      for (var y = 0; y < 8; y++)
        for (var x = 8; x < 16; x++) atlas[(y * 16 + x) * 4 + 3],
    ];
    expect(hashedAlpha, everyElement(255));
    expect(emptyAlpha, everyElement(0), reason: 'the painter owns this cell, not the cache');
  });

  test('the chunk cache sizes itself from the viewport it has to cover', () {
    // 48 columns on a tall phone keeps roughly three viewports of assets
    // mounted. A fixed residency was either wasteful at three columns or far
    // too small here, and too small meant chunks were evicted while still
    // needed and re-read through the service's single mutex.
    const viewportHeight = 743.0;
    for (final (columnCount, tileExtent) in [(48, 8.57), (24, 17.1), (12, 34.3), (3, 137.0)]) {
      final chunkSize = denseTimelineAssetChunkSize(
        columnCount: columnCount,
        viewportHeight: viewportHeight,
        tileExtent: tileExtent,
      );
      final mounted = ((viewportHeight * 3) / tileExtent).ceil() * columnCount;
      final residentAssets = math.max(4, (mounted / chunkSize).ceil() + 2) * chunkSize;
      expect(
        residentAssets,
        greaterThanOrEqualTo(mounted),
        reason: '$columnCount columns must keep its whole mounted range addressable',
      );
    }
  });

  test('turning grouping off collapses the day buckets into one continuous grid', () {
    final days = [
      TimeBucket(date: DateTime(2026, 8, 14), assetCount: 7),
      TimeBucket(date: DateTime(2026, 8, 13), assetCount: 3),
      TimeBucket(date: DateTime(2026, 8, 12), assetCount: 11),
    ];

    final collapsed = collapseTimelineBuckets(days);

    expect(collapsed, hasLength(1));
    expect(collapsed.single.assetCount, 21, reason: 'every asset, local ones included, stays in the grid');
    expect(collapsed.single, isNot(isA<TimeBucket>()), reason: 'nothing left to draw a date header from');
    expect(collapseTimelineBuckets(const []), isEmpty);
    expect(collapseTimelineBuckets([const Bucket(assetCount: 0)]), isEmpty);
  });

  test('an ungrouped timeline builds one headerless segment', () {
    final segments = FixedSegmentBuilder(
      buckets: collapseTimelineBuckets([
        TimeBucket(date: DateTime(2026, 8, 14), assetCount: 100),
        TimeBucket(date: DateTime(2026, 8, 13), assetCount: 44),
      ]),
      tileHeight: 10,
      columnCount: 48,
      spacing: 0,
    ).generate();

    expect(segments, hasLength(1));
    expect(segments.single.header, HeaderType.none);
    expect(segments.single.headerExtent, 0);
    // 144 assets over 48 columns is three rows, with no day boundary able to
    // break a row part way across.
    expect(segments.single.endOffset - segments.single.gridOffset, 3 * 10);

    // Child keys must still be unique without a date to build them from.
    final keys = [
      for (var index = segments.single.firstIndex; index <= segments.single.lastIndex; index++)
        segments.single.childKey(index),
    ];
    expect(keys.toSet(), hasLength(keys.length));
  });

  test('the thumbnail scheduler drops work rather than blocking, so panels must retry', () {
    // The queue sheds its newest work once full and reports it as finished, so
    // a panel can be told every cell is done while none of them resolved. A
    // panel that gave up after a fixed number of attempts therefore stayed a
    // placeholder for as long as it remained on screen. This documents the
    // shedding behaviour that makes an unbounded, backed-off retry necessary.
    final queue = DenseTimelineTaskQueue(1, maxPending: 1);
    final blocked = Completer<void>();
    final active = queue.schedule(() => blocked.future);
    final queued = queue.schedule(() async {});
    final shed = queue.schedule(() async {}, priority: 900);

    expect(shed, throwsA(isA<Object>()));
    blocked.complete();
    expect(active, completes);
    expect(queued, completes);
  });

  test('a dense panel always paints the cells it occupies', () {
    // A panel reserves its full layout extent before it has any texture. When
    // the painter drew nothing for that state the timeline showed holes several
    // screens tall while scrolling, so the occupied cells must be fillable.
    final rects = denseTimelineOccupiedRects(
      itemCount: 100,
      columnCount: 48,
      tileExtent: 10,
      containerWidth: 480,
      textDirection: TextDirection.ltr,
    );

    expect(rects, hasLength(2));
    expect(rects.first, const Rect.fromLTWH(0, 0, 480, 20), reason: 'two full rows of 48');
    expect(rects.last, const Rect.fromLTWH(0, 20, 40, 10), reason: 'the remaining four cells only');
    expect(rects.map((r) => r.width * r.height).reduce((a, b) => a + b), 100 * 10 * 10);
  });

  test('an exactly filled panel has no partial row and an empty one paints nothing', () {
    expect(
      denseTimelineOccupiedRects(
        itemCount: 96,
        columnCount: 48,
        tileExtent: 10,
        containerWidth: 480,
        textDirection: TextDirection.ltr,
      ),
      [const Rect.fromLTWH(0, 0, 480, 20)],
    );
    expect(
      denseTimelineOccupiedRects(
        itemCount: 0,
        columnCount: 48,
        tileExtent: 10,
        containerWidth: 480,
        textDirection: TextDirection.ltr,
      ),
      isEmpty,
    );
  });

  test('a right-to-left panel fills its partial row from the right edge', () {
    final rects = denseTimelineOccupiedRects(
      itemCount: 100,
      columnCount: 48,
      tileExtent: 10,
      containerWidth: 600,
      textDirection: TextDirection.rtl,
    );

    expect(rects.first, const Rect.fromLTWH(120, 0, 480, 20));
    expect(rects.last, const Rect.fromLTWH(560, 20, 40, 10));
  });

  test('a reshuffle that keeps the length and total height still invalidates the layout', () {
    List<Segment> build(int newestCount, int olderCount) => FixedSegmentBuilder(
      buckets: [
        TimeBucket(date: DateTime(2026, 8, 14), assetCount: newestCount),
        TimeBucket(date: DateTime(2026, 8, 13), assetCount: olderCount),
      ],
      tileHeight: 10,
      columnCount: 12,
      spacing: 0,
    ).generate();

    final before = build(96, 48);
    final after = build(48, 96);

    // The old comparison looked only at the list length and the final offset,
    // both of which survive this reshuffle, so the sliver kept positioning
    // children with stale geometry while the delegate built the new ones.
    expect(before, hasLength(after.length));
    expect(before.last.endOffset, after.last.endOffset);
    expect(before.equals(after), isFalse, reason: 'the segments genuinely moved');
    expect(before.equals(before), isTrue);
    expect(before.equals([...before]), isTrue, reason: 'equal content must not force a relayout');
  });

  test('segment lookups binary search without changing their contract', () {
    final segments = FixedSegmentBuilder(
      buckets: [
        for (var day = 0; day < 40; day++)
          TimeBucket(
            date: DateTime(2026, 8, 20).subtract(Duration(days: day)),
            assetCount: 7 + (day * 3),
          ),
      ],
      tileHeight: 10,
      columnCount: 12,
      spacing: 0,
    ).generate();

    Segment? linearByIndex(int index) => segments.where((s) => s.containsIndex(index)).firstOrNull;
    Segment? linearByOffset(double offset) =>
        segments.where((s) => s.isWithinOffset(offset)).firstOrNull ?? segments.last;

    for (var index = -3; index <= segments.last.lastIndex + 3; index++) {
      expect(segments.findByIndex(index), same(linearByIndex(index)), reason: 'index $index');
    }
    final end = segments.last.endOffset;
    for (var step = 0; step <= 200; step++) {
      final offset = (end + 40) * step / 200;
      expect(segments.findByOffset(offset), same(linearByOffset(offset)), reason: 'offset $offset');
    }
  });

  test('dense child keys are unique across the whole timeline', () {
    final segments = FixedSegmentBuilder(
      buckets: [
        for (var day = 0; day < 120; day++)
          TimeBucket(
            date: DateTime(2026, 8, 20).subtract(Duration(days: day)),
            assetCount: 5 + day,
          ),
      ],
      tileHeight: 8,
      columnCount: 48,
      spacing: 0,
    ).generate();

    final total = segments.fold<int>(0, (sum, s) => sum + (s.lastIndex - s.firstIndex + 1));
    // A collision would silently overwrite an entry and hand the sliver the
    // wrong index for an existing child.
    expect(segments.childIndexesByKey(), hasLength(total));
  });

  test('every dense cell is upgraded to a real thumbnail, including the densest levels', () {
    // 3.1.59 only upgraded cells above a 48px threshold, which on a 1440px
    // display left 36 and 48 columns permanently showing a ThumbHash smear.
    // A ThumbHash carries a handful of DCT coefficients, so it is never a
    // substitute for real pixels at any level a person actually browses.
    for (final screenWidth in [1080.0, 1440.0]) {
      for (final devicePixelRatio in [2.0, 3.0, 3.5]) {
        for (final columnCount in timelineTilesPerRowSteps.where((count) => count > 6)) {
          final targetPixels = denseTimelineTargetPixels(
            tileExtent: screenWidth / devicePixelRatio / columnCount,
            devicePixelRatio: devicePixelRatio,
          );
          expect(
            denseTimelineNeedsThumbnailUpgrade(targetPixels),
            isTrue,
            reason: '$columnCount columns on ${screenWidth}px/$devicePixelRatio must not stay on the fallback',
          );
        }
      }
    }
  });

  test('the fallback texture stays small even when the cell is much larger', () {
    // The fallback is upscaled by the painter rather than decoded at cell size:
    // expanding a ThumbHash to a 120px cell costs 16x the memory and isolate
    // transfer for no additional detail.
    expect(denseTimelineMetadataPixels(denseTimelineTargetPixels(tileExtent: 40, devicePixelRatio: 3)), 32);
    // The same at every zoom level, including the densest, where the cell is
    // smaller than this. Decoded previews are cached per photo at this size, so
    // one size means one cache shared by every zoom; making the densest level
    // 30px instead made it the one zoom that shared nothing, and entering or
    // leaving it re-decoded every preview on screen.
    expect(denseTimelineMetadataPixels(denseTimelineTargetPixels(tileExtent: 8.6, devicePixelRatio: 3.5)), 32);
    expect(denseTimelineMetadataPixels(denseTimelineTargetPixels(tileExtent: 40, devicePixelRatio: 3)), 32);
  });

  test('dense atlas scheduling keeps centre-visible panels ahead of distant queued work', () async {
    final queue = DenseTimelineTaskQueue(1, maxPending: 2);
    final releaseActive = Completer<void>();
    final executionOrder = <String>[];

    final active = queue.schedule(() async {
      await releaseActive.future;
      executionOrder.add('active');
    });
    final distant = queue.schedule(() async => executionOrder.add('distant'), priority: 900);
    final distantWasDiscarded = expectLater(distant, throwsA(isA<Object>()));
    final nearby = queue.schedule(() async => executionOrder.add('nearby'), priority: 120);
    final centre = queue.schedule(() async => executionOrder.add('centre'), priority: 0);

    await distantWasDiscarded;
    releaseActive.complete();
    await Future.wait([active, nearby, centre]);

    expect(executionOrder, ['active', 'centre', 'nearby']);
  });

  test('dense day buckets preserve stable asset offsets inside the same timeline', () {
    final segments = FixedSegmentBuilder(
      buckets: [
        TimeBucket(date: DateTime(2026, 8, 14), assetCount: 2),
        TimeBucket(date: DateTime(2026, 7, 3), assetCount: 3),
        TimeBucket(date: DateTime(2025, 12, 1), assetCount: 1),
      ],
      tileHeight: 24,
      columnCount: 12,
      spacing: 0,
    ).generate();

    expect(segments, hasLength(3));
    expect(segments.first.header, HeaderType.year);
    expect(segments[1].header, HeaderType.none);
    expect(segments[1].firstAssetIndex, 2);
    expect(segments.last.header, HeaderType.year);
    expect(segments.last.firstAssetIndex, 5);
  });

  test('dense day rows keep their sliver identity when an earlier day grows', () {
    List<Segment> build(int newestDayCount) => FixedSegmentBuilder(
      buckets: [
        TimeBucket(date: DateTime(2026, 8, 14), assetCount: newestDayCount),
        TimeBucket(date: DateTime(2026, 8, 13), assetCount: 3),
      ],
      tileHeight: 24,
      columnCount: 12,
      spacing: 0,
    ).generate();

    final before = build(1);
    final after = build(120);
    final beforeRow = before[1].gridIndex;
    final afterRow = after[1].gridIndex;
    final stableKey = before[1].childKey(beforeRow);

    expect(afterRow, isNot(beforeRow), reason: 'the global sliver index must actually have shifted');
    expect(after[1].childKey(afterRow), stableKey);
    expect(before.childIndexesByKey()[stableKey], beforeRow);
    expect(after.childIndexesByKey()[stableKey], afterRow);
  });

  test('asset transition moves and resizes a tile into its new grid rectangle', () {
    const previous = Rect.fromLTWH(0, 100, 100, 100);
    const current = Rect.fromLTWH(120, 220, 80, 80);

    expect(calculateTimelineAssetTransitionRect(previousRect: previous, currentRect: current, progress: 0), previous);
    expect(calculateTimelineAssetTransitionRect(previousRect: previous, currentRect: current, progress: 1), current);
  });

  testWidgets('batched marker exposes visible per-photo rectangles without per-photo widgets', (tester) async {
    const keys = <Object>['a', 'b', 'c', 'd', 'e', 'f'];
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 120,
            height: 80,
            child: TimelineDenseAssetLayoutMarker(
              assetKeys: keys,
              columnCount: 3,
              tileExtent: 40,
              textDirection: TextDirection.ltr,
              child: SizedBox.expand(),
            ),
          ),
        ),
      ),
    );

    final marker = tester.renderObject<RenderTimelineDenseAssetLayoutMarker>(
      find.byType(TimelineDenseAssetLayoutMarker),
    );
    final visible = <Object, Rect>{};
    marker.collectVisibleAssetRects(const Rect.fromLTWH(0, 0, 120, 40), visible);

    expect(visible.keys, unorderedEquals(const ['a', 'b', 'c']));
    expect(visible['b'], const Rect.fromLTWH(40, 0, 40, 40));
  });

  testWidgets('dense settings stay in the one continuous timeline', (tester) async {
    TimelineArgs? probed;
    final probe = Consumer(
      builder: (_, ref, __) {
        probed = ref.watch(timelineArgsProvider);
        return const SizedBox.shrink();
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          timelineServiceProvider.overrideWithValue(_FrozenBucketService()),
          appConfigProvider.overrideWithValue(const AppConfig(timeline: TimelineConfig(tilesPerRow: 48))),
        ],
        child: MaterialApp(
          home: Timeline(withScrubber: false, readOnly: true, showStorageIndicator: true, loadingWidget: probe),
        ),
      ),
    );
    await tester.pump();

    expect(probed?.columnCount, 48);
    expect(probed?.spacing, 0);
    expect(probed?.showStorageIndicator, isFalse);
  });

  testWidgets('timeline args follow constraints after a zero-sized first frame while loading', (tester) async {
    tester.view.physicalSize = Size.zero;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    TimelineArgs? probed;
    final probe = Consumer(
      builder: (_, ref, __) {
        probed = ref.watch(timelineArgsProvider);
        return const SizedBox.shrink();
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          timelineServiceProvider.overrideWithValue(_FrozenBucketService()),
          appConfigProvider.overrideWithValue(const AppConfig()),
        ],
        child: MaterialApp(home: Timeline(withScrubber: false, readOnly: true, loadingWidget: probe)),
      ),
    );
    await tester.pump();
    expect(probed?.maxWidth, 0);

    tester.view.physicalSize = const Size(1206, 2622);
    await tester.pump();
    await tester.pump();
    expect(probed?.maxWidth, 402);
  });

  testWidgets('timeline args follow constraints after buckets resolve', (tester) async {
    tester.view.physicalSize = Size.zero;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    TimelineArgs? probed;
    final probe = SliverToBoxAdapter(
      child: Consumer(
        builder: (_, ref, __) {
          probed = ref.watch(timelineArgsProvider);
          return const SizedBox.shrink();
        },
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          timelineServiceProvider.overrideWithValue(const _EmptyBucketService()),
          appConfigProvider.overrideWithValue(const AppConfig()),
        ],
        child: MaterialApp(
          home: Timeline(
            withScrubber: false,
            readOnly: true,
            appBar: const SliverToBoxAdapter(child: SizedBox.shrink()),
            topSliverWidget: probe,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    tester.view.physicalSize = const Size(1206, 2622);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(probed?.maxWidth, 402);
  });

  testWidgets('layout-only changes reuse the active photo bucket stream', (tester) async {
    final service = _CountingBucketService();
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(1206, 2622);
    addTearDown(tester.view.reset);

    TimelineArgs? probed;
    final probe = Consumer(
      builder: (_, ref, __) {
        probed = ref.watch(timelineArgsProvider);
        return const SizedBox.shrink();
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          timelineServiceProvider.overrideWithValue(service),
          appConfigProvider.overrideWithValue(const AppConfig()),
        ],
        child: MaterialApp(home: Timeline(withScrubber: false, readOnly: true, loadingWidget: probe)),
      ),
    );
    await tester.pump();

    final initialSubscriptions = service.watchCount;
    final initialWidth = probed!.maxWidth;
    expect(initialSubscriptions, greaterThan(0));

    tester.view.physicalSize = const Size(1000, 2000);
    await tester.pump();
    await tester.pump();

    expect(probed!.maxWidth, lessThan(initialWidth));
    expect(service.watchCount, initialSubscriptions);
  });

  testWidgets('column changes never resubscribe or show the loading screen', (tester) async {
    final service = _CountingBucketService();
    final columnsProvider = StateProvider<int>((_) => 4);
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(1206, 2622);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          timelineServiceProvider.overrideWithValue(service),
          appConfigProvider.overrideWith(
            (ref) => AppConfig(timeline: TimelineConfig(tilesPerRow: ref.watch(columnsProvider))),
          ),
        ],
        child: const MaterialApp(
          home: Timeline(
            withScrubber: false,
            readOnly: true,
            appBar: SliverToBoxAdapter(child: SizedBox.shrink()),
            loadingWidget: SizedBox(key: Key('timeline-loading')),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('timeline-loading')), findsOneWidget);

    service.emit(const []);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('timeline-loading')), findsNothing);
    final subscriptionsBeforeZoom = service.watchCount;

    final container = ProviderScope.containerOf(tester.element(find.byType(Timeline)));
    container.read(columnsProvider.notifier).state = 6;
    await tester.pump();

    expect(find.byKey(const Key('timeline-loading')), findsNothing);
    expect(service.watchCount, subscriptionsBeforeZoom);
    expect(find.byType(TimelineLayoutTransitionScope), findsOneWidget);
  });
}
