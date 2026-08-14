import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/timeline_config.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.state.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';

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
  test('grid transition scale follows zoom direction with a restrained professional range', () {
    expect(calculateTimelineLayoutTransitionScale(previousColumns: 4, nextColumns: 3), 0.86);
    expect(calculateTimelineLayoutTransitionScale(previousColumns: 3, nextColumns: 4), 1.14);
    expect(calculateTimelineLayoutTransitionScale(previousColumns: 4, nextColumns: 4), 1.0);
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
    expect(find.byType(TweenAnimationBuilder<double>), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('timeline-loading')), findsNothing);
  });
}
