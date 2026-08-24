import 'dart:async';
import 'dart:convert';
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
    expect(denseTimelineTargetPixels(tileExtent: 8.34, devicePixelRatio: 3), 32);
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
