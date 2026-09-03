import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/config/timeline_config.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_layout_transition.dart';
import 'package:thumbhash/thumbhash.dart' as thumbhash;

String _testThumbHash(int seed) {
  final rgba = Uint8List.fromList([
    for (var index = 0; index < 16; index++) ...[
      (seed * 31 + index * 13) % 256,
      (seed * 17 + index * 29) % 256,
      (seed * 47 + index * 7) % 256,
      255,
    ],
  ]);
  return base64Encode(thumbhash.rgbaToThumbHash(4, 4, rgba));
}

void main() {
  test('cells are rendered at full resolution except where the tile is tiny', () {
    // This used to assert full physical resolution at every zoom, which was the
    // right rule when the complaint was blurriness. At the densest levels a
    // tile is a couple of millimetres and a full-resolution thumbnail for each
    // of the thousands on screen is what puts raster past the frame budget, so
    // those levels now render at three quarters and scale up. Measured, that
    // costs 11.6/255 of mean channel error against 10.2 for the mildest
    // possible reduction, and saves 41% of the pixels instead of 25%.
    const logicalScreenWidths = [320.0, 390.0, 430.0];
    const devicePixelRatios = [1.0, 2.0, 3.0, 4.0];

    for (final screenWidth in logicalScreenWidths) {
      for (final devicePixelRatio in devicePixelRatios) {
        for (final columnCount in timelineTilesPerRowSteps.where((count) => count > 6)) {
          final tileExtent = screenWidth / columnCount;
          final native = (tileExtent * devicePixelRatio).ceil();
          final targetPixels = denseTimelineTargetPixels(tileExtent: tileExtent, devicePixelRatio: devicePixelRatio);

          if (native > denseResolutionCapBelow) {
            expect(
              targetPixels,
              greaterThanOrEqualTo(native),
              reason:
                  '$columnCount columns on a ${screenWidth}px/$devicePixelRatio x display is large enough '
                  'that it must not be softened',
            );
          } else if (native * 3 / 4 >= 8) {
            // Above the degenerate floor, so the reduction is what decides.
            expect(
              targetPixels,
              lessThan(native),
              reason: 'a $native pixel tile should be taking the reduction',
            );
            expect(
              targetPixels * 4,
              greaterThanOrEqualTo(native * 3),
              reason: 'the reduction must not go below three quarters',
            );
          }
          expect(targetPixels, greaterThanOrEqualTo(8), reason: 'never degenerate');
        }
      }
    }
  });

  test('dense atlas renders every photo including a partially filled final row', () {
    const columnCount = 48;
    const targetPixels = 8;
    const assetCount = (columnCount * 2) + 7;
    final hashes = List<String>.generate(assetCount, _testThumbHash, growable: false);

    final first = buildDenseThumbhashAtlasPixels(hashes, targetPixels, columnCount: columnCount);
    final second = buildDenseThumbhashAtlasPixels(hashes, targetPixels, columnCount: columnCount);
    final atlasWidth = columnCount * targetPixels;
    final atlasRows = (assetCount / columnCount).ceil();

    expect(first, orderedEquals(second), reason: 'rebuilding unchanged previews must not produce a visual flash');
    expect(first, hasLength(atlasWidth * atlasRows * targetPixels * 4));

    for (var index = 0; index < assetCount; index++) {
      final column = index % columnCount;
      final row = index ~/ columnCount;
      final centerX = column * targetPixels + targetPixels ~/ 2;
      final centerY = row * targetPixels + targetPixels ~/ 2;
      final alpha = first[(centerY * atlasWidth + centerX) * 4 + 3];
      expect(alpha, 255, reason: 'photo $index must not disappear from the atlas');
    }

    for (var column = assetCount % columnCount; column < columnCount; column++) {
      final centerX = column * targetPixels + targetPixels ~/ 2;
      final centerY = (atlasRows - 1) * targetPixels + targetPixels ~/ 2;
      expect(first[(centerY * atlasWidth + centerX) * 4 + 3], 0, reason: 'unused cells must stay transparent');
    }
  });

  testWidgets('dense layout retains every stable asset key while column count changes', (tester) async {
    final assetKeys = List<Object>.generate(103, (index) => 'asset-$index', growable: false);

    Future<Map<Object, Rect>> pumpAndCollect(int columnCount) async {
      const width = 384.0;
      final tileExtent = width / columnCount;
      final height = (assetKeys.length / columnCount).ceil() * tileExtent;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: height,
              child: TimelineDenseAssetLayoutMarker(
                assetKeys: assetKeys,
                columnCount: columnCount,
                tileExtent: tileExtent,
                textDirection: TextDirection.ltr,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );

      final marker = tester.renderObject<RenderTimelineDenseAssetLayoutMarker>(
        find.byType(TimelineDenseAssetLayoutMarker),
      );
      final visible = <Object, Rect>{};
      marker.collectVisibleAssetRects(
        Rect.fromLTWH(0, 0, width, math.max(height, tester.view.physicalSize.height)),
        visible,
      );
      return visible;
    }

    final before = await pumpAndCollect(48);
    final after = await pumpAndCollect(12);

    expect(before.keys, orderedEquals(assetKeys));
    expect(after.keys, orderedEquals(assetKeys));
    expect(after.keys.toSet(), before.keys.toSet());
    expect(tester.takeException(), isNull);
  });

  test('the per-asset cell cache does not change what an atlas contains', () {
    // The cache short-circuits decoding, so a cached panel and a freshly
    // decoded one must be indistinguishable. Regrouping the same photos under a
    // different column count exercises the case the cache exists for: the cells
    // are identical across zoom levels even though the panels are not.
    const columnCount = 24;
    const cell = batchedGridMetadataCellPixels;
    final hashes = List<String>.generate(144, (index) => _testThumbHash(index + 500), growable: false);

    final cold = buildDenseThumbhashAtlasPixels(hashes, cell, columnCount: columnCount);
    final warm = buildDenseThumbhashAtlasPixels(hashes, cell, columnCount: columnCount);
    expect(warm, orderedEquals(cold), reason: 'a cached rebuild must be byte-identical to a decoded one');

    final regrouped = buildDenseThumbhashAtlasPixels(hashes, cell, columnCount: 48);
    for (var index = 0; index < hashes.length; index++) {
      final coldOffset =
          (((index ~/ columnCount) * cell + cell ~/ 2) * (columnCount * cell) + (index % columnCount) * cell + cell ~/ 2) * 4;
      final warmOffset = (((index ~/ 48) * cell + cell ~/ 2) * (48 * cell) + (index % 48) * cell + cell ~/ 2) * 4;
      expect(
        regrouped.sublist(warmOffset, warmOffset + 4),
        orderedEquals(cold.sublist(coldOffset, coldOffset + 4)),
        reason: 'photo $index must decode to the same cell whatever the column count',
      );
    }
  });

  test('timeline transition keys are deterministic and collision-free for a large viewport', () {
    final firstBuild = List<Object>.generate(4096, timelineAssetLayoutKey, growable: false);
    final secondBuild = List<Object>.generate(4096, timelineAssetLayoutKey, growable: false);

    expect(firstBuild, orderedEquals(secondBuild));
    expect(firstBuild.toSet(), hasLength(firstBuild.length));
  });
}
