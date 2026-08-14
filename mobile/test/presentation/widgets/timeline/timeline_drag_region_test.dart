import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_drag_region.dart';

Widget _buildDragRegion({
  required ValueChanged<TimelineAssetIndex> onStart,
  required ValueChanged<TimelineAssetIndex> onAssetEnter,
  required VoidCallback onEnd,
  bool scrollable = true,
}) {
  const assets = [
    TimelineAssetIndexWrapper(
      assetIndex: 0,
      segmentIndex: 0,
      child: ColoredBox(
        key: Key('asset-0'),
        color: Colors.transparent,
        child: SizedBox(height: 180, width: double.infinity),
      ),
    ),
    TimelineAssetIndexWrapper(
      assetIndex: 1,
      segmentIndex: 0,
      child: ColoredBox(
        key: Key('asset-1'),
        color: Colors.transparent,
        child: SizedBox(height: 180, width: double.infinity),
      ),
    ),
  ];
  return MaterialApp(
    home: Scaffold(
      body: TimelineDragRegion(
        onStart: onStart,
        onAssetEnter: onAssetEnter,
        onEnd: onEnd,
        child: scrollable
            ? ListView(children: const [...assets, SizedBox(height: 800)])
            : const Column(children: assets),
      ),
    ),
  );
}

void main() {
  testWidgets('a one-finger scroll never starts drag selection even if the finger pauses', (tester) async {
    final starts = <TimelineAssetIndex>[];
    final entered = <TimelineAssetIndex>[];
    var ends = 0;
    await tester.pumpWidget(_buildDragRegion(onStart: starts.add, onAssetEnter: entered.add, onEnd: () => ends++));

    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const Key('asset-0'))));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveBy(const Offset(0, -90));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pump();

    expect(starts, isEmpty);
    expect(entered, isEmpty);
    expect(ends, 0);
  });

  testWidgets('drag selection starts only after a completed long press', (tester) async {
    final starts = <TimelineAssetIndex>[];
    final entered = <TimelineAssetIndex>[];
    var ends = 0;
    await tester.pumpWidget(
      _buildDragRegion(onStart: starts.add, onAssetEnter: entered.add, onEnd: () => ends++, scrollable: false),
    );

    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const Key('asset-0'))));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));

    expect(starts, const [TimelineAssetIndex(assetIndex: 0, segmentIndex: 0)]);

    await gesture.moveTo(tester.getCenter(find.byKey(const Key('asset-1'))));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(entered, contains(const TimelineAssetIndex(assetIndex: 1, segmentIndex: 0)));
    expect(ends, 1);

    final swipe = await tester.startGesture(tester.getCenter(find.byKey(const Key('asset-0'))));
    await tester.pump(const Duration(milliseconds: 50));
    await swipe.moveBy(const Offset(0, -90));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await swipe.up();
    await tester.pump();

    expect(starts, hasLength(1), reason: 'a later swipe must not reuse the previous long-press anchor');
    expect(ends, 1);
  });
}
