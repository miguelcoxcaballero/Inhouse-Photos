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
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment_builder.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.state.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_layout_transition.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_zoom_transition.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:thumbhash/thumbhash.dart' as thumbhash;

// A first fetch that never delivers - the state a suspended or storm-starved
// bucket watch is stuck in when the timeline mounts on a zero-sized first frame
class _FrozenBucketService implements TimelineService {
  final _ctrl = StreamController<List<Bucket>>.broadcast();

  @override
  Stream<List<Bucket>> Function() get watchBuckets =>
      () => _ctrl.stream;

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

// Counts how many times the bucket stream is subscribed. Each subscription is a
// fresh photo query, so the count is our proxy for "did the relayout re-run the
// segment query for an input it does not use".
class _CountingBucketService implements TimelineService {
  int watchCount = 0;
  final _ctrl = StreamController<List<Bucket>>.broadcast();

  void emit(List<Bucket> buckets) => _ctrl.add(buckets);

  @override
  Stream<List<Bucket>> Function() get watchBuckets => () {
    watchCount++;
    return _ctrl.stream;
  };

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('pinch thresholds are symmetrical and more responsive around the active column count', () {
    expect(calculateTimelineColumnCount(scaleFactor: 3.39, gestureStartScaleFactor: 3), 4);
    expect(calculateTimelineColumnCount(scaleFactor: 3.41, gestureStartScaleFactor: 3), 3);
    expect(calculateTimelineColumnCount(scaleFactor: 2.61, gestureStartScaleFactor: 3), 4);
    expect(calculateTimelineColumnCount(scaleFactor: 2.59, gestureStartScaleFactor: 3), 5);
    expect(kTimelinePinchSensitivity, 1.25);
  });

  test('zooming is treated as active timeline interaction', () {
    expect(const TimelineState(isZooming: true).isInteracting, isTrue);
    expect(const TimelineState().isInteracting, isFalse);
  });

  testWidgets('retained timeline stays painted until the incoming layout is ready', (tester) async {
    late StateSetter update;
    Object layoutKey = 'old-layout';
    bool ready = true;
    int completedTransitions = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return TimelineRetainedSwitcher(
              layoutKey: layoutKey,
              ready: ready,
              onTransitionComplete: () => completedTransitions++,
              child: ColoredBox(
                color: layoutKey == 'old-layout' ? Colors.red : Colors.blue,
                child: Center(child: Text(layoutKey.toString())),
              ),
            );
          },
        ),
      ),
    );

    update(() {
      layoutKey = 'new-layout';
      ready = false;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('old-layout'), findsOneWidget);
    expect(find.text('new-layout'), findsOneWidget);
    expect(completedTransitions, 0);

    update(() => ready = true);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('old-layout'), findsNothing);
    expect(find.text('new-layout'), findsOneWidget);
    expect(completedTransitions, 1);
  });

  testWidgets('retained timeline hands the primary scroll controller to exactly one layout', (tester) async {
    late StateSetter update;
    final primary = ScrollController();
    final retained = ScrollController();
    addTearDown(primary.dispose);
    addTearDown(retained.dispose);
    Object layoutKey = 0;
    bool useRetainedController = false;
    bool ready = true;

    Widget buildTimeline(ScrollController controller, String label) {
      return ListView(
        controller: controller,
        children: [SizedBox(height: 1200, child: Text(label))],
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return TimelineRetainedSwitcher(
              layoutKey: layoutKey,
              ready: ready,
              child: buildTimeline(useRetainedController ? retained : primary, 'layout-$layoutKey'),
            );
          },
        ),
      ),
    );
    expect(primary.positions, hasLength(1));

    update(() {
      useRetainedController = true;
      ready = false;
    });
    await tester.pump();
    expect(primary.positions, isEmpty);
    expect(retained.positions, hasLength(1));
    final retainedPosition = retained.position;

    update(() {
      layoutKey = 1;
      useRetainedController = false;
    });
    await tester.pump();
    expect(primary.positions, hasLength(1));
    expect(retained.positions, hasLength(1));
    expect(retained.position, same(retainedPosition));

    update(() => ready = true);
    await tester.pumpAndSettle();
    expect(primary.positions, hasLength(1));
    expect(retained.positions, isEmpty);
  });

  testWidgets('dense reflow hands off immediately once target pixels are ready', (tester) async {
    late StateSetter update;
    Object layoutKey = 'old-layout';
    bool ready = true;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return TimelineRetainedSwitcher(
              layoutKey: layoutKey,
              ready: ready,
              animateReveal: false,
              child: Center(child: Text(layoutKey.toString())),
            );
          },
        ),
      ),
    );

    update(() {
      layoutKey = 'new-layout';
      ready = false;
    });
    await tester.pump();
    expect(find.text('old-layout'), findsOneWidget);
    expect(find.text('new-layout'), findsOneWidget);

    update(() => ready = true);
    await tester.pump();

    expect(find.text('old-layout'), findsNothing, reason: 'the ready target becomes the sole reflow surface');
    expect(find.text('new-layout'), findsOneWidget);
  });

  test('pinching farther out enters dense year overview levels', () {
    expect(calculateTimelineColumnCount(scaleFactor: 0.80, gestureStartScaleFactor: 1), 12);
    expect(calculateTimelineColumnCount(scaleFactor: 0.70, gestureStartScaleFactor: 1), 18);
    expect(calculateTimelineColumnCount(scaleFactor: 0.55, gestureStartScaleFactor: 1), 24);
    expect(calculateTimelineColumnCount(scaleFactor: 0.48, gestureStartScaleFactor: 1), 36);
    expect(calculateTimelineColumnCount(scaleFactor: 0.40, gestureStartScaleFactor: 1), 48);
    expect(timelineScaleFactorForColumnCount(12), 0.74);
    expect(timelineScaleFactorForColumnCount(18), 0.62);
    expect(timelineScaleFactorForColumnCount(24), 0.48);
    expect(timelineScaleFactorForColumnCount(36), 0.34);
    expect(timelineScaleFactorForColumnCount(48), 0.22);
  });

  test('year overview removes gutters and expensive per-tile transitions', () {
    expect(isTimelineYearOverview(columnCount: 12), isTrue);
    expect(isTimelineYearOverview(columnCount: 48), isTrue);
    expect(isTimelineYearOverview(columnCount: 24, groupBy: GroupAssetsBy.none), isFalse);
    expect(shouldAnimateTimelineColumnTransition(currentColumns: 6, nextColumns: 12), isFalse);
    expect(shouldAnimateTimelineColumnTransition(currentColumns: 12, nextColumns: 18), isFalse);
    expect(shouldAnimateTimelineColumnTransition(currentColumns: 4, nextColumns: 5), isTrue);
    expect(timelineScrollCacheExtent(maxHeight: 800, yearOverview: true), 400);
    expect(timelineScrollCacheExtent(maxHeight: 800, yearOverview: false), 800);
  });

  test('year overview preloads enough assets for the complete viewport in one shared chunk', () {
    expect(denseTimelineAssetChunkSize(columnCount: 48, viewportHeight: 800, tileExtent: 8.34), 8192);
    expect(denseTimelineAssetChunkSize(columnCount: 24, viewportHeight: 800, tileExtent: 16.67), 8192);
    expect(denseTimelineAssetChunkSize(columnCount: 12, viewportHeight: 0, tileExtent: 32), 1024);
    expect(denseTimelineTargetPixels(tileExtent: 8.34, devicePixelRatio: 3), 32);
    expect(denseTimelineTargetPixels(tileExtent: 18, devicePixelRatio: 3), 54);
  });

  test('extreme year levels use immediate metadata atlases', () {
    expect(usesInstantDenseTimelineAtlas(12), isTrue);
    expect(usesInstantDenseTimelineAtlas(24), isTrue);
    expect(usesInstantDenseTimelineAtlas(36), isTrue);
    expect(usesInstantDenseTimelineAtlas(48), isTrue);
    expect(denseTimelineRowsPerChild(12), 8);
    expect(denseTimelineRowsPerChild(24), 6);
    expect(denseTimelineRowsPerChild(36), 6);
    expect(denseTimelineRowsPerChild(48), 4);
    expect(denseOverviewMetadataCellPixels, 32);
    expect(denseOverviewDiskCacheLimitBytes, 256 * 1024 * 1024);
  });

  test('ultra-dense layout virtualizes many photo rows into each sliver child', () {
    final segment =
        FixedSegmentBuilder(
              buckets: [TimeBucket(date: DateTime(2026), assetCount: 5000)],
              tileHeight: 8,
              columnCount: 48,
              spacing: 0,
              yearOverview: true,
            ).generate().single
            as FixedSegment;

    expect(segment.rowsPerChild, 4);
    expect(segment.lastIndex - segment.firstIndex, 27);
    expect(segment.endOffset - segment.gridOffset, 105 * 8);
  });

  test('dense metadata atlas produces a complete tile and leaves missing hashes transparent', () {
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

    final twoRowAtlas = buildDenseThumbhashAtlasPixels([hash, hash, hash], 4, columnCount: 2);
    expect(twoRowAtlas, hasLength(8 * 8 * 4));
  });

  testWidgets('dense year overview exposes zero-gap metadata-free timeline args', (tester) async {
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
          appConfigProvider.overrideWithValue(const AppConfig(timeline: TimelineConfig(tilesPerRow: 18))),
        ],
        child: MaterialApp(
          home: Timeline(withScrubber: false, readOnly: true, showStorageIndicator: true, loadingWidget: probe),
        ),
      ),
    );
    await tester.pump();

    expect(probed?.yearOverview, isTrue);
    expect(probed?.spacing, 0);
    expect(probed?.showStorageIndicator, isFalse);
  });

  testWidgets('dense thumbnails can share a row repaint layer', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: SizedBox.square(dimension: 24, child: Thumbnail(animate: false, repaintBoundary: false))),
    );

    expect(tester.renderObject(find.byType(Thumbnail)).isRepaintBoundary, isFalse);
  });

  test('year overview keeps stable day segments and preserves asset offsets', () {
    final builder = FixedSegmentBuilder(
      buckets: [
        TimeBucket(date: DateTime(2026, 8, 14), assetCount: 2),
        TimeBucket(date: DateTime(2026, 7, 3), assetCount: 3),
        TimeBucket(date: DateTime(2025, 12, 1), assetCount: 1),
      ],
      tileHeight: 24,
      columnCount: 12,
      yearOverview: true,
    );

    final segments = builder.generate();
    expect(segments, hasLength(3));
    expect(segments.first.header, HeaderType.year);
    expect(segments.first.bucket, TimeBucket(date: DateTime(2026, 8, 14), assetCount: 2));
    expect(segments[1].header, HeaderType.none);
    expect(segments[1].firstAssetIndex, 2);
    expect(segments.last.firstAssetIndex, 5);
    expect(segments.last.bucket, TimeBucket(date: DateTime(2025, 12, 1), assetCount: 1));
  });

  test('asset transition moves and resizes a tile into its new grid rectangle', () {
    const previous = Rect.fromLTWH(0, 100, 100, 100);
    const current = Rect.fromLTWH(120, 220, 80, 80);

    expect(calculateTimelineAssetTransitionRect(previousRect: previous, currentRect: current, progress: 0), previous);
    expect(calculateTimelineAssetTransitionRect(previousRect: previous, currentRect: current, progress: 1), current);
  });

  test('dense cells use the same deterministic grid geometry as regular photo tiles', () {
    expect(
      calculateTimelineDenseAssetRect(
        index: 4,
        columnCount: 3,
        tileExtent: 40,
        containerWidth: 120,
        textDirection: TextDirection.ltr,
      ),
      const Rect.fromLTWH(40, 40, 40, 40),
    );
    expect(
      calculateTimelineDenseAssetRect(
        index: 4,
        columnCount: 3,
        tileExtent: 40,
        containerWidth: 120,
        textDirection: TextDirection.rtl,
      ),
      const Rect.fromLTWH(40, 40, 40, 40),
    );
    expect(
      calculateTimelineDenseAssetRect(
        index: 3,
        columnCount: 3,
        tileExtent: 40,
        containerWidth: 120,
        textDirection: TextDirection.rtl,
      ),
      const Rect.fromLTWH(80, 40, 40, 40),
    );
  });

  testWidgets('dense atlas marker exposes visible per-photo rectangles without per-photo widgets', (tester) async {
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

  testWidgets('timeline args follow constraints after a zero-sized first frame while buckets are still loading', (
    tester,
  ) async {
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

    expect(probed, isNotNull);
    expect(probed!.maxWidth, 0.0);

    tester.view.physicalSize = const Size(1206, 2622);
    await tester.pump();
    await tester.pump();

    expect(
      probed!.maxWidth,
      402.0,
      reason: 'args locked to the zero-sized first frame leave the timeline blank for the whole session',
    );
  });

  testWidgets('timeline args follow constraints after a zero-sized first frame once buckets resolve', (tester) async {
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

    expect(probed, isNotNull);
    expect(probed!.maxWidth, 402.0);
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
    final initialHeight = probed!.maxHeight;
    expect(initialSubscriptions, greaterThan(0));

    // toggling multiselect changes the app bar, so only the available height moves
    tester.view.physicalSize = const Size(1206, 2000);
    await tester.pump();
    await tester.pump();

    expect(probed!.maxHeight, isNot(initialHeight), reason: 'the height should have actually changed');
    expect(probed!.maxWidth, initialWidth);
    expect(
      service.watchCount,
      initialSubscriptions,
      reason: 'a height-only change must not re-run the bucket query for an input the segments do not use',
    );

    // A real width change must recompute tile geometry without restarting the photo query.
    tester.view.physicalSize = const Size(1000, 2000);
    await tester.pump();
    await tester.pump();

    expect(probed!.maxWidth, lessThan(initialWidth));
    expect(service.watchCount, initialSubscriptions);
  });

  testWidgets('changing the grid column count keeps photos visible without showing the loading screen', (tester) async {
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
    container.read(columnsProvider.notifier).state = 3;
    await tester.pump();

    expect(find.byKey(const Key('timeline-loading')), findsNothing);
    expect(service.watchCount, subscriptionsBeforeZoom);
    expect(find.byType(TimelineLayoutTransitionScope), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('timeline-loading')), findsNothing);
  });
}
