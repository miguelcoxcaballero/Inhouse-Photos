import 'dart:async';
import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/row.dart';
import 'package:immich_mobile/presentation/widgets/timeline/header.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/segment_builder.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.state.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_drag_region.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_layout_transition.dart';
import 'package:immich_mobile/providers/asset_viewer/is_motion_video_playing.provider.dart';
import 'package:immich_mobile/providers/infrastructure/current_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/routing/router.dart';

class FixedSegment extends Segment {
  final double tileHeight;
  final int columnCount;
  final double mainAxisExtend;

  const FixedSegment({
    required super.firstIndex,
    required super.lastIndex,
    required super.startOffset,
    required super.endOffset,
    required super.firstAssetIndex,
    required super.bucket,
    required this.tileHeight,
    required this.columnCount,
    required super.headerExtent,
    required super.spacing,
    required super.header,
  }) : assert(tileHeight != 0),
       mainAxisExtend = tileHeight + spacing;

  @override
  double indexToLayoutOffset(int index) {
    final relativeIndex = index - gridIndex;
    return relativeIndex < 0 ? startOffset : gridOffset + (mainAxisExtend * relativeIndex);
  }

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) {
    final adjustedOffset = scrollOffset - gridOffset;
    if (!adjustedOffset.isFinite || adjustedOffset < 0) {
      return firstIndex;
    }
    return gridIndex + (adjustedOffset / mainAxisExtend).floor();
  }

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) {
    final adjustedOffset = scrollOffset - gridOffset;
    if (!adjustedOffset.isFinite || adjustedOffset < 0) {
      return firstIndex;
    }
    return gridIndex + (adjustedOffset / mainAxisExtend).ceil() - 1;
  }

  @override
  Widget builder(BuildContext context, int index) {
    final rowIndexInSegment = index - (firstIndex + 1);
    final assetIndex = rowIndexInSegment * columnCount;
    final assetCount = bucket.assetCount;
    final numberOfAssets = math.min(columnCount, assetCount - assetIndex);

    if (index == firstIndex) {
      return TimelineHeader(bucket: bucket, header: header, height: headerExtent, assetOffset: firstAssetIndex);
    }

    return _FixedSegmentRow(
      assetIndex: firstAssetIndex + assetIndex,
      assetCount: numberOfAssets,
      tileHeight: tileHeight,
      spacing: spacing,
      columnCount: columnCount,
    );
  }
}

class _FixedSegmentRow extends ConsumerWidget {
  final int assetIndex;
  final int assetCount;
  final double tileHeight;
  final double spacing;
  final int columnCount;

  const _FixedSegmentRow({
    required this.assetIndex,
    required this.assetCount,
    required this.tileHeight,
    required this.spacing,
    required this.columnCount,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isScrubbing = ref.watch(timelineStateProvider.select((state) => state.isScrubbing));
    final timelineService = ref.read(timelineServiceProvider);
    final isDynamicLayout = columnCount <= (context.isMobile ? 2 : 3);

    if (timelineService.hasRange(assetIndex, assetCount)) {
      return _buildAssetRow(
        context,
        timelineService.getAssets(assetIndex, assetCount),
        timelineService,
        isDynamicLayout,
      );
    }

    if (isScrubbing) {
      return _buildPlaceholder(context);
    }

    return FutureBuilder<List<BaseAsset>>(
      future: timelineService.loadAssets(assetIndex, assetCount),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _buildPlaceholder(context);
        }
        return _buildAssetRow(context, snapshot.requireData, timelineService, isDynamicLayout);
      },
    );
  }

  Widget _buildPlaceholder(BuildContext context) =>
      SegmentBuilder.buildPlaceholder(context, assetCount, size: Size.square(tileHeight), spacing: spacing);

  Widget _buildAssetRow(
    BuildContext context,
    List<BaseAsset> assets,
    TimelineService timelineService,
    bool isDynamicLayout,
  ) {
    Widget buildTile(int index) {
      final tile = _AssetTileWidget(
        key: ValueKey(Object.hash(assets[index].heroTag, assetIndex + index, timelineService.hashCode)),
        asset: assets[index],
        assetIndex: assetIndex + index,
      );
      return TimelineAssetIndexWrapper(assetIndex: assetIndex + index, segmentIndex: 0, child: tile);
    }

    final children = [for (var index = 0; index < assets.length; index++) buildTile(index)];
    final widths = List.filled(assets.length, tileHeight);

    if (isDynamicLayout) {
      final aspectRatios = assets.map((asset) => (asset.width ?? 1) / (asset.height ?? 1)).toList();
      final meanAspectRatio = aspectRatios.sum / assets.length;
      final configurations = aspectRatios.map((ratio) {
        if (ratio - meanAspectRatio > 0.3) {
          return 1.5;
        }
        if (ratio - meanAspectRatio < -0.3) {
          return 0.5;
        }
        return 1.0;
      });
      final sum = configurations.sum;

      var index = 0;
      for (final ratio in configurations) {
        widths[index++] = ((ratio * assets.length) / sum) * tileHeight;
      }
    }

    return TimelineRow(
      height: tileHeight,
      widths: widths,
      spacing: spacing,
      textDirection: Directionality.of(context),
      children: children,
    );
  }
}

class _AssetTileWidget extends ConsumerWidget {
  final BaseAsset asset;
  final int assetIndex;

  const _AssetTileWidget({super.key, required this.asset, required this.assetIndex});

  void _handleOnTap(BuildContext context, WidgetRef ref, int heroOffset) {
    final multiSelectState = ref.read(multiSelectProvider);

    if (multiSelectState.forceEnable || multiSelectState.isEnabled) {
      ref.read(multiSelectProvider.notifier).toggleAssetSelection(asset);
      return;
    }

    // This tile already owns the loaded asset, so open it immediately instead
    // of queuing navigation behind an unrelated timeline buffer request.
    ref.read(isPlayingMotionVideoProvider.notifier).playing = false;
    AssetViewer.setAsset(ref, asset);
    unawaited(
      context.pushRoute(
        AssetViewerRoute(
          initialIndex: assetIndex,
          timelineService: ref.read(timelineServiceProvider),
          heroOffset: heroOffset,
          currentAlbum: ref.read(currentRemoteAlbumProvider),
        ),
      ),
    );
  }

  bool _getLockSelectionStatus(WidgetRef ref) {
    final lockSelectionAssets = ref.read(multiSelectProvider.select((state) => state.lockedSelectionAssets));
    if (lockSelectionAssets.isEmpty) {
      return false;
    }

    // RemoteAsset equality intentionally ignores localId, while its historical
    // hash code does not. Compare values directly so equivalent copies lock.
    return lockSelectionAssets.any((lockedAsset) => lockedAsset == asset);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final heroOffset = TabsRouterScope.of(context)?.controller.activeIndex ?? 0;
    final lockSelection = _getLockSelectionStatus(ref);
    final showStorageIndicator = ref.watch(timelineArgsProvider.select((args) => args.showStorageIndicator));
    final showStackIndicator = ref.read(timelineServiceProvider).origin != TimelineOrigin.trash;

    return TimelineAssetLayoutTransition(
      assetKey: timelineAssetLayoutKey(assetIndex),
      child: RepaintBoundary(
        child: GestureDetector(
          onTap: lockSelection ? null : () => _handleOnTap(context, ref, heroOffset),
          child: ThumbnailTile(
            asset,
            lockSelection: lockSelection,
            showStorageIndicator: showStorageIndicator,
            showStackIndicator: showStackIndicator,
            heroOffset: heroOffset,
          ),
        ),
      ),
    );
  }
}
