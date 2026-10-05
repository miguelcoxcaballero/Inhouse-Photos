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

BackupStageBar _bar({required int total, required int backedUp, required int remaining, bool isUploading = false}) =>
    BackupStageBar(
      total: total,
      backedUp: backedUp,
      remaining: remaining,
      isUploading: isUploading,
      backedUpLabel: 'backed up',
      backedUpLegend: 'Backed up',
      remainingLegend: 'Pending',
      totalLabel: 'Total',
    );

void main() {
  testWidgets('the bar shows backed-up and pending counts, without a preparing stage', (tester) async {
    await tester.pumpWidget(_host(_bar(total: 12840, backedUp: 11205, remaining: 1635)));
    await tester.pumpAndSettle();

    expect(find.text('11,205'), findsOneWidget);
    expect(find.text('1,635'), findsOneWidget);
    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('Preparing'), findsNothing);
    expect(find.textContaining('87.3%'), findsOneWidget);
  });

  testWidgets('the stage bar never overflows at its edges', (tester) async {
    // Nearly complete, on a narrow screen.
    await tester.pumpWidget(_host(_bar(total: 100000, backedUp: 99999, remaining: 1), width: 220));
    await tester.pumpAndSettle();
    // Empty library.
    await tester.pumpWidget(_host(_bar(total: 0, backedUp: 0, remaining: 0), width: 220));
    await tester.pumpAndSettle();
    // Counts that do not add up to the total.
    await tester.pumpWidget(_host(_bar(total: 10, backedUp: 8, remaining: 9), width: 220));
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

  testWidgets('turning backup on and off pops the cloud once and settles', (tester) async {
    await tester.pumpWidget(_host(const BackupCloudHero(state: BackupCloudState.off, title: 'Backup is off')));
    await tester.pumpAndSettle();

    await tester.pumpWidget(_host(const BackupCloudHero(state: BackupCloudState.idle, title: 'Waiting to upload')));
    await tester.pump(const Duration(milliseconds: 120));
    final popping = tester
        .widgetList<Transform>(find.byType(Transform))
        .any((t) => t.transform.getMaxScaleOnAxis() > 1.01);
    expect(popping, isTrue);
    await tester.pumpAndSettle();
    expect(find.text('Waiting to upload'), findsOneWidget);
    expect(find.text('Backup is off'), findsNothing);

    await tester.pumpWidget(_host(const BackupCloudHero(state: BackupCloudState.off, title: 'Backup is off')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
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
