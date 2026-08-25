import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/timeline_config.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:thumbhash/thumbhash.dart' as thumbhash;

import '../../../widget_tester_extensions.dart';

String _testThumbHash() {
  final rgba = Uint8List.fromList([
    for (var index = 0; index < 16; index++) ...[220, 70 + index, 35, 255],
  ]);
  return base64Encode(thumbhash.rgbaToThumbHash(4, 4, rgba));
}

TimelineService _denseService(int assetCount) {
  final hash = _testThumbHash();
  final now = DateTime(2026, 8, 25);
  final assets = List<BaseAsset>.generate(
    assetCount,
    (index) => RemoteAsset(
      id: 'remote-$index',
      name: 'photo-$index.jpg',
      ownerId: 'owner',
      checksum: 'checksum-$index',
      type: AssetType.image,
      createdAt: now.subtract(Duration(days: index)),
      updatedAt: now,
      width: 4032,
      height: 3024,
      thumbHash: hash,
      isEdited: false,
    ),
    growable: false,
  );
  final buckets = List<Bucket>.generate(
    assetCount,
    (index) => TimeBucket(date: now.subtract(Duration(days: index)), assetCount: 1),
    growable: false,
  );
  return TimelineService((
    assetSource: (offset, count) async => assets.skip(offset).take(count).toList(growable: false),
    bucketSource: () => Stream.value(buckets),
    origin: TimelineOrigin.main,
  ));
}

void main() {
  testWidgets('48-column gallery produces visible atlases instead of a grey viewport', (tester) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1206, 2619);
    addTearDown(tester.view.reset);

    final service = _denseService(160);
    addTearDown(service.dispose);
    await tester.runAsync(() async {
      await tester.pumpConsumerWidget(
        const Timeline(
          withScrubber: false,
          readOnly: true,
          appBar: SliverToBoxAdapter(child: SizedBox.shrink()),
          bottomSheet: null,
        ),
        overrides: [
          timelineServiceProvider.overrideWithValue(service),
          appConfigProvider.overrideWithValue(const AppConfig(timeline: TimelineConfig(tilesPerRow: 48))),
        ],
      );
      await tester.pump();
      await Future<void>.delayed(const Duration(seconds: 3));
    });
    await tester.pump();

    final densePainters = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((paint) => paint.painter)
        .where((painter) => painter.runtimeType.toString() == '_DenseAssetRowPainter')
        .toList(growable: false);
    expect(densePainters, isNotEmpty);
    expect(densePainters.where((painter) => (painter as dynamic).atlas != null), hasLength(densePainters.length));
    expect(tester.takeException(), isNull);
  });
}
