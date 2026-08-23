import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/timeline_config.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/presentation/widgets/timeline/constants.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment_builder.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.state.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_layout_transition.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';

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

  test('the gallery is one continuous two-to-six-column grid', () {
    expect(normalizeTimelineTilesPerRow(0), 2);
    expect(normalizeTimelineTilesPerRow(1), 2);
    for (var columns = 2; columns <= 6; columns++) {
      expect(normalizeTimelineTilesPerRow(columns), columns);
    }
    expect(normalizeTimelineTilesPerRow(12), 6);
    expect(normalizeTimelineTilesPerRow(48), 6);

    expect(calculateTimelineColumnCount(scaleFactor: 0.15, gestureStartScaleFactor: 1), 6);
    expect(calculateTimelineColumnCount(scaleFactor: 5, gestureStartScaleFactor: 5), 2);
    expect(timelineScaleFactorForColumnCount(48), 1);
  });

  test('zooming is treated as active timeline interaction', () {
    expect(const TimelineState(isZooming: true).isInteracting, isTrue);
    expect(const TimelineState().isInteracting, isFalse);
  });

  test('the largest grid uses ordinary rows and ordinary timeline headers', () {
    final segment =
        FixedSegmentBuilder(
              buckets: [TimeBucket(date: DateTime(2026, 8, 14), assetCount: 14)],
              tileHeight: 64,
              columnCount: 6,
            ).generate().single
            as FixedSegment;

    expect(segment.lastIndex - segment.firstIndex, 3);
    expect(segment.endOffset - segment.gridOffset, 3 * 64 + segment.spacing);
    expect(segment.header, HeaderType.monthAndDay);
  });

  test('asset transition moves and resizes a tile into its new grid rectangle', () {
    const previous = Rect.fromLTWH(0, 100, 100, 100);
    const current = Rect.fromLTWH(120, 220, 80, 80);

    expect(calculateTimelineAssetTransitionRect(previousRect: previous, currentRect: current, progress: 0), previous);
    expect(calculateTimelineAssetTransitionRect(previousRect: previous, currentRect: current, progress: 1), current);
  });

  testWidgets('legacy overview settings become the ordinary six-column grid', (tester) async {
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

    expect(probed?.columnCount, 6);
    expect(probed?.spacing, kTimelineSpacing);
    expect(probed?.showStorageIndicator, isTrue);
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
