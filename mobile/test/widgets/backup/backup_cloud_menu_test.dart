import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/widgets/backup/backup_cloud_hero.dart';
import 'package:immich_mobile/widgets/backup/backup_stage_bar.dart';

Widget _host(Widget child, {double width = 412}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(width: width, child: child),
    ),
  ),
);

BackupStageBar _bar({
  required int total,
  required int backedUp,
  required int ready,
  required int preparing,
  bool isUploading = false,
}) => BackupStageBar(
  total: total,
  backedUp: backedUp,
  ready: ready,
  preparing: preparing,
  isUploading: isUploading,
  backedUpLabel: 'backed up',
  backedUpLegend: 'Backed up',
  readyLegend: 'Ready',
  preparingLegend: 'Preparing',
  totalLabel: 'Total',
);

void main() {
  testWidgets('the stage bar shows every stage count', (tester) async {
    await tester.pumpWidget(_host(_bar(total: 12840, backedUp: 11205, ready: 1539, preparing: 96)));
    await tester.pumpAndSettle();

    expect(find.text('11,205'), findsOneWidget);
    expect(find.text('1,539'), findsOneWidget);
    expect(find.text('96'), findsOneWidget);
    expect(find.textContaining('87.3%'), findsOneWidget);
  });

  testWidgets('the stage bar never overflows at its edges', (tester) async {
    // Nearly complete with a preparing sliver wider than what is left, on a narrow screen.
    await tester.pumpWidget(_host(_bar(total: 100000, backedUp: 99999, ready: 0, preparing: 1), width: 220));
    await tester.pumpAndSettle();
    // Empty library.
    await tester.pumpWidget(_host(_bar(total: 0, backedUp: 0, ready: 0, preparing: 0), width: 220));
    await tester.pumpAndSettle();
    // Counts that do not add up to the total.
    await tester.pumpWidget(_host(_bar(total: 10, backedUp: 8, ready: 9, preparing: 3), width: 220));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('the cloud only animates while uploading', (tester) async {
    await tester.pumpWidget(
      _host(const BackupCloudHero(state: BackupCloudState.uploading, title: 'Uploading 3 files')),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(CustomPaint), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isTrue);

    await tester.pumpWidget(_host(const BackupCloudHero(state: BackupCloudState.idle, title: 'Waiting to upload')));
    // Settling proves the ticker stopped once nothing is uploading.
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Waiting to upload'), findsOneWidget);
  });

  testWidgets('the cloud stays still when animations are disabled', (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: _host(const BackupCloudHero(state: BackupCloudState.done, title: 'Everything is backed up')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.cloud_done_outlined), findsOneWidget);
  });
}
