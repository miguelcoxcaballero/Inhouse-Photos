import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';

void main() {
  testWidgets('local-only photos show the pending-upload icon at 70% opacity', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: ThumbnailStorageIndicator(storage: AssetState.local)),
      ),
    );

    final opacity = tester.widget<Opacity>(find.byKey(pendingUploadIndicatorKey));
    expect(opacity.opacity, 0.7);
    expect(
      find.descendant(of: find.byKey(pendingUploadIndicatorKey), matching: find.byType(CustomPaint)),
      findsOneWidget,
    );
  });

  for (final storage in [AssetState.remote, AssetState.merged]) {
    testWidgets('$storage photos do not show a storage icon', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(child: ThumbnailStorageIndicator(storage: storage)),
        ),
      );

      expect(find.byKey(pendingUploadIndicatorKey), findsNothing);
    });
  }
}
