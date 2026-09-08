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

class _EmptyTimeline implements TimelineService {
  @override
  Stream<List<Bucket>> Function() get watchBuckets =>
      () => Stream.value(const []);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('pinch coalesces changes while fingers are down and can return to the starting grid', (tester) async {
    var columns = 0;
    var zooming = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          timelineServiceProvider.overrideWithValue(_EmptyTimeline()),
          appConfigProvider.overrideWithValue(const AppConfig(timeline: TimelineConfig(tilesPerRow: 4))),
        ],
        child: MaterialApp(
          home: Timeline(
            withScrubber: false,
            readOnly: true,
            appBar: const SliverToBoxAdapter(child: SizedBox.shrink()),
            topSliverWidget: SliverToBoxAdapter(
              child: Consumer(
                builder: (_, ref, __) {
                  columns = ref.watch(timelineArgsProvider).columnCount;
                  zooming = ref.watch(timelineStateProvider).isZooming;
                  return const SizedBox(height: 300);
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final detector = tester
        .widgetList<RawGestureDetector>(find.byType(RawGestureDetector))
        .firstWhere((widget) => widget.gestures.containsKey(CustomScaleGestureRecognizer));
    final factory = detector.gestures[CustomScaleGestureRecognizer]!;
    final gesture = factory.constructor() as CustomScaleGestureRecognizer;
    factory.initializer(gesture);
    addTearDown(gesture.dispose);

    gesture.onStart!(ScaleStartDetails(pointerCount: 2));
    gesture.onUpdate!(ScaleUpdateDetails(scale: 0.7, pointerCount: 2));
    await tester.pump(const Duration(milliseconds: 119));
    expect(columns, 4);
    await tester.pump(const Duration(milliseconds: 2));
    expect(columns, 5, reason: 'Reflow must start before fingers lift.');
    expect(zooming, isTrue);

    gesture.onUpdate!(ScaleUpdateDetails(scale: 1, pointerCount: 2));
    await tester.pump(const Duration(milliseconds: 121));
    expect(columns, 4);
    gesture.onEnd!(ScaleEndDetails());
    await tester.pumpAndSettle();
    expect(zooming, isFalse);
    // Returning to the same grid should not try to access settings storage.
    expect(tester.takeException(), isNull);
  });
}
