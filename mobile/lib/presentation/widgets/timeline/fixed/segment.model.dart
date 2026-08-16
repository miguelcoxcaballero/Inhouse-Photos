import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:auto_route/auto_route.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/thumb_hash_provider.dart';
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
import 'package:thumbhash/thumbhash.dart' as thumbhash;

int denseTimelineAssetChunkSize({
  required int columnCount,
  required double viewportHeight,
  required double tileExtent,
}) {
  if (tileExtent <= 0 || viewportHeight <= 0) {
    return kTimelineAssetLoadBatchSize;
  }
  final visibleRows = (viewportHeight / tileExtent).ceil();
  final requestedAssets = (visibleRows + 16) * columnCount;
  var chunkSize = kTimelineAssetLoadBatchSize;
  while (chunkSize < requestedAssets && chunkSize < 8192) {
    chunkSize *= 2;
  }
  return chunkSize;
}

int denseTimelineTargetPixels({required double tileExtent, required double devicePixelRatio}) =>
    math.max(32, (tileExtent * devicePixelRatio).ceil());

bool usesInstantDenseTimelineAtlas(int columnCount) => columnCount >= 36;

Uint8List buildDenseThumbhashAtlasPixels(List<String?> hashes, int targetPixels) {
  final atlasWidth = hashes.length * targetPixels;
  final atlas = Uint8List(atlasWidth * targetPixels * 4);

  for (var index = 0; index < hashes.length; index++) {
    final hash = hashes[index];
    if (hash == null || hash.isEmpty) {
      continue;
    }

    try {
      final source = thumbhash.thumbHashToRGBA(base64Decode(hash));
      final scale = math.max(targetPixels / source.width, targetPixels / source.height);
      final visibleSourceWidth = targetPixels / scale;
      final visibleSourceHeight = targetPixels / scale;
      final sourceLeft = (source.width - visibleSourceWidth) / 2;
      final sourceTop = (source.height - visibleSourceHeight) / 2;

      for (var y = 0; y < targetPixels; y++) {
        final sourceY = (sourceTop + (y + 0.5) / scale).floor().clamp(0, source.height - 1);
        for (var x = 0; x < targetPixels; x++) {
          final sourceX = (sourceLeft + (x + 0.5) / scale).floor().clamp(0, source.width - 1);
          final sourceOffset = (sourceY * source.width + sourceX) * 4;
          final destinationOffset = (y * atlasWidth + index * targetPixels + x) * 4;
          atlas[destinationOffset] = source.rgba[sourceOffset];
          atlas[destinationOffset + 1] = source.rgba[sourceOffset + 1];
          atlas[destinationOffset + 2] = source.rgba[sourceOffset + 2];
          atlas[destinationOffset + 3] = source.rgba[sourceOffset + 3];
        }
      }
    } catch (_) {
      // A missing or malformed hash is filled later by the normal thumbnail path.
    }
  }

  return atlas;
}

final Expando<_DenseAssetChunkStore> _denseAssetStores = Expando<_DenseAssetChunkStore>();

class _DenseAssetChunkStore {
  final LinkedHashMap<(int, int), Future<List<BaseAsset>>> _chunks = LinkedHashMap();
  int _revision = -1;

  Future<List<BaseAsset>> loadRow(
    TimelineService service, {
    required int index,
    required int count,
    required int chunkSize,
  }) {
    if (_revision != service.revision) {
      _revision = service.revision;
      _chunks.clear();
    }

    final chunkStart = (index ~/ chunkSize) * chunkSize;
    final chunkCount = math.min(chunkSize, service.totalAssets - chunkStart);
    final key = (chunkStart, chunkCount);
    var chunk = _chunks.remove(key);
    chunk ??= service.loadAssets(chunkStart, chunkCount);
    _chunks[key] = chunk;
    while (_chunks.length > 2) {
      _chunks.remove(_chunks.keys.first);
    }

    return chunk.then((assets) {
      final localIndex = index - chunkStart;
      return assets.sublist(localIndex, localIndex + count);
    });
  }
}

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
      denseOverview: header == HeaderType.year,
    );
  }
}

class _FixedSegmentRow extends ConsumerWidget {
  final int assetIndex;
  final int assetCount;
  final double tileHeight;
  final double spacing;
  final int columnCount;
  final bool denseOverview;

  const _FixedSegmentRow({
    required this.assetIndex,
    required this.assetCount,
    required this.tileHeight,
    required this.spacing,
    required this.columnCount,
    required this.denseOverview,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isScrubbing = ref.watch(timelineStateProvider.select((s) => s.isScrubbing));
    final timelineService = ref.read(timelineServiceProvider);
    final isDynamicLayout = columnCount <= (context.isMobile ? 2 : 3);

    if (timelineService.hasRange(assetIndex, assetCount)) {
      return _buildAssetRow(
        context,
        ref,
        timelineService.getAssets(assetIndex, assetCount),
        timelineService,
        isDynamicLayout,
      );
    }

    if (isScrubbing) {
      return _buildPlaceholder(context);
    }

    if (denseOverview) {
      final viewportHeight = ref.read(timelineArgsProvider).maxHeight;
      final chunkSize = denseTimelineAssetChunkSize(
        columnCount: columnCount,
        viewportHeight: viewportHeight,
        tileExtent: tileHeight,
      );
      final store = _denseAssetStores[timelineService] ??= _DenseAssetChunkStore();
      return FutureBuilder<List<BaseAsset>>(
        future: store.loadRow(timelineService, index: assetIndex, count: assetCount, chunkSize: chunkSize),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return _buildPlaceholder(context);
          }
          return _buildAssetRow(context, ref, snapshot.requireData, timelineService, false);
        },
      );
    }

    return FutureBuilder<List<BaseAsset>>(
      future: timelineService.loadAssets(assetIndex, assetCount),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _buildPlaceholder(context);
        }
        return _buildAssetRow(context, ref, snapshot.requireData, timelineService, isDynamicLayout);
      },
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    return SegmentBuilder.buildPlaceholder(context, assetCount, size: Size.square(tileHeight), spacing: spacing);
  }

  Widget _buildAssetRow(
    BuildContext context,
    WidgetRef ref,
    List<BaseAsset> assets,
    TimelineService timelineService,
    bool isDynamicLayout,
  ) {
    if (denseOverview) {
      return _DenseAssetRow(
        key: ValueKey(Object.hash(assetIndex, timelineService.hashCode)),
        assets: assets,
        firstAssetIndex: assetIndex,
        tileExtent: tileHeight,
        columnCount: columnCount,
        onAssetTap: (index, asset) => _openAsset(context, ref, index, asset),
      );
    }

    Widget buildTile(int index) {
      final tile = _AssetTileWidget(
        key: ValueKey(Object.hash(assets[index].heroTag, assetIndex + index, timelineService.hashCode)),
        asset: assets[index],
        assetIndex: assetIndex + index,
      );
      return TimelineAssetIndexWrapper(assetIndex: assetIndex + index, segmentIndex: 0, child: tile);
    }

    final children = [for (int i = 0; i < assets.length; i++) buildTile(i)];

    final widths = List.filled(assets.length, tileHeight);

    if (isDynamicLayout) {
      final aspectRatios = assets.map((e) => (e.width ?? 1) / (e.height ?? 1)).toList();
      final meanAspectRatio = aspectRatios.sum / assets.length;

      // 1: mean width
      // 0.5: width < mean - threshold
      // 1.5: width > mean + threshold
      final arConfiguration = aspectRatios.map((e) {
        if (e - meanAspectRatio > 0.3) {
          return 1.5;
        }
        if (e - meanAspectRatio < -0.3) {
          return 0.5;
        }
        return 1.0;
      });

      // Normalize to get width distribution
      final sum = arConfiguration.sum;

      int index = 0;
      for (final ratio in arConfiguration) {
        // Distribute the available width proportionally based on aspect ratio configuration
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

  void _openAsset(BuildContext context, WidgetRef ref, int index, BaseAsset asset) {
    final multiSelectState = ref.read(multiSelectProvider);
    if (multiSelectState.forceEnable || multiSelectState.isEnabled) {
      ref.read(multiSelectProvider.notifier).toggleAssetSelection(asset);
      return;
    }

    ref.read(isPlayingMotionVideoProvider.notifier).playing = false;
    AssetViewer.setAsset(ref, asset);
    unawaited(
      context.pushRoute(
        AssetViewerRoute(
          initialIndex: index,
          timelineService: ref.read(timelineServiceProvider),
          heroOffset: TabsRouterScope.of(context)?.controller.activeIndex ?? 0,
          currentAlbum: ref.read(currentRemoteAlbumProvider),
        ),
      ),
    );
  }
}

class _AssetTileWidget extends ConsumerWidget {
  final BaseAsset asset;
  final int assetIndex;

  const _AssetTileWidget({super.key, required this.asset, required this.assetIndex});

  void _handleOnTap(BuildContext ctx, WidgetRef ref, int assetIndex, BaseAsset asset, int? heroOffset) {
    final multiSelectState = ref.read(multiSelectProvider);

    if (multiSelectState.forceEnable || multiSelectState.isEnabled) {
      ref.read(multiSelectProvider.notifier).toggleAssetSelection(asset);
    } else {
      // The tile could only be built because this asset was already loaded.
      // Waiting on TimelineService here can queue navigation behind an
      // unrelated 1,024-row scroll-buffer fetch, making taps feel unresponsive.
      // The viewer preloads neighbors after its first frame, so open it now.
      ref.read(isPlayingMotionVideoProvider.notifier).playing = false;
      AssetViewer.setAsset(ref, asset);
      unawaited(
        ctx.pushRoute(
          AssetViewerRoute(
            initialIndex: assetIndex,
            timelineService: ref.read(timelineServiceProvider),
            heroOffset: heroOffset,
            currentAlbum: ref.read(currentRemoteAlbumProvider),
          ),
        ),
      );
    }
  }

  bool _getLockSelectionStatus(WidgetRef ref) {
    final lockSelectionAssets = ref.read(multiSelectProvider.select((state) => state.lockedSelectionAssets));

    if (lockSelectionAssets.isEmpty) {
      return false;
    }

    // Iterate with `==` instead of `Set.contains` because `RemoteAsset.hashCode`
    // includes `localId` while `==` does not — so the same server asset can
    // hash to a different bucket when its `localId` differs (e.g., album-fetched
    // copy has localId=null, merged-timeline copy has it populated).
    return lockSelectionAssets.any((a) => a == asset);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final heroOffset = TabsRouterScope.of(context)?.controller.activeIndex ?? 0;

    final lockSelection = _getLockSelectionStatus(ref);
    final showStorageIndicator = ref.watch(timelineArgsProvider.select((args) => args.showStorageIndicator));
    final showStackIndicator = ref.read(timelineServiceProvider).origin != TimelineOrigin.trash;

    return TimelineAssetLayoutTransition(
      assetKey: asset.heroTag,
      child: RepaintBoundary(
        child: GestureDetector(
          onTap: () => lockSelection ? null : _handleOnTap(context, ref, assetIndex, asset, heroOffset),
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

typedef _DenseAssetTap = void Function(int index, BaseAsset asset);

const int _denseThumbnailConcurrency = 32;
const int _denseMetadataAtlasConcurrency = 4;
const int _denseAtlasCacheBytes = 48 * 1024 * 1024;
final _DenseThumbnailQueue _denseThumbnailQueue = _DenseThumbnailQueue();
final _DenseAsyncQueue _denseMetadataAtlasQueue = _DenseAsyncQueue(_denseMetadataAtlasConcurrency);
final _DenseRowAtlasCache _denseRowAtlasCache = _DenseRowAtlasCache();

class _DenseLoadCancelled implements Exception {
  const _DenseLoadCancelled();
}

class _DenseThumbnailQueue {
  final Queue<Future<void> Function()> _pending = Queue();
  int _active = 0;

  void schedule(Future<void> Function() task) {
    _pending.add(task);
    _drain();
  }

  void _drain() {
    while (_active < _denseThumbnailConcurrency && _pending.isNotEmpty) {
      final task = _pending.removeFirst();
      _active++;
      unawaited(
        Future<void>.sync(task).then<void>((_) {}, onError: (_, __) {}).whenComplete(() {
          _active--;
          _drain();
        }),
      );
    }
  }
}

class _DenseAsyncQueue {
  final int concurrency;
  final Queue<Future<void> Function()> _pending = Queue();
  int _active = 0;

  _DenseAsyncQueue(this.concurrency);

  Future<T> schedule<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    _pending.add(() async {
      try {
        completer.complete(await task());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    _drain();
    return completer.future;
  }

  void _drain() {
    while (_active < concurrency && _pending.isNotEmpty) {
      final task = _pending.removeFirst();
      _active++;
      unawaited(
        Future<void>.sync(task).whenComplete(() {
          _active--;
          _drain();
        }),
      );
    }
  }
}

class _DenseRowAtlasCache {
  final LinkedHashMap<int, ui.Image> _images = LinkedHashMap();
  int _bytes = 0;

  ui.Image? get(int key) {
    final image = _images.remove(key);
    if (image == null) {
      return null;
    }
    _images[key] = image;
    return image.clone();
  }

  void put(int key, ui.Image image) {
    final previous = _images.remove(key);
    if (previous != null) {
      _bytes -= _imageBytes(previous);
      previous.dispose();
    }
    final cached = image.clone();
    _images[key] = cached;
    _bytes += _imageBytes(cached);
    while (_bytes > _denseAtlasCacheBytes && _images.isNotEmpty) {
      final oldestKey = _images.keys.first;
      final oldest = _images.remove(oldestKey)!;
      _bytes -= _imageBytes(oldest);
      oldest.dispose();
    }
  }

  int _imageBytes(ui.Image image) => image.width * image.height * 4;
}

/// Paints a complete overview row in one layer. A 48-column phone row therefore
/// uses one state object, one gesture recognizer, and one render object instead
/// of 48 of each. Image arrivals are coalesced into a single repaint per frame.
class _DenseAssetRow extends StatefulWidget {
  final List<BaseAsset> assets;
  final int firstAssetIndex;
  final double tileExtent;
  final int columnCount;
  final _DenseAssetTap onAssetTap;

  const _DenseAssetRow({
    super.key,
    required this.assets,
    required this.firstAssetIndex,
    required this.tileExtent,
    required this.columnCount,
    required this.onAssetTap,
  });

  @override
  State<_DenseAssetRow> createState() => _DenseAssetRowState();
}

class _DenseAssetRowState extends State<_DenseAssetRow> {
  final ValueNotifier<int> _repaint = ValueNotifier(0);
  List<ImageInfo?> _images = const [];
  List<ImageStream?> _streams = const [];
  List<ImageStreamListener?> _listeners = const [];
  List<Completer<ImageInfo>?> _completers = const [];
  ui.Image? _atlas;
  double? _devicePixelRatio;
  bool _repaintScheduled = false;
  bool _atlasBuilding = false;
  bool _instantOverview = false;
  int _loadedCount = 0;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    if (_devicePixelRatio != devicePixelRatio) {
      _devicePixelRatio = devicePixelRatio;
      _subscribeToImages();
    }
  }

  @override
  void didUpdateWidget(covariant _DenseAssetRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tileExtent != widget.tileExtent ||
        oldWidget.columnCount != widget.columnCount ||
        !_sameAssets(oldWidget.assets, widget.assets)) {
      _subscribeToImages();
    }
  }

  bool _sameAssets(List<BaseAsset> previous, List<BaseAsset> next) {
    if (previous.length != next.length) {
      return false;
    }
    for (var index = 0; index < previous.length; index++) {
      if (previous[index].heroTag != next[index].heroTag) {
        return false;
      }
    }
    return true;
  }

  void _subscribeToImages() {
    _unsubscribeFromImages();
    final generation = ++_generation;
    final targetPixels = denseTimelineTargetPixels(
      tileExtent: widget.tileExtent,
      devicePixelRatio: _devicePixelRatio ?? 1,
    );
    _images = List<ImageInfo?>.filled(widget.assets.length, null);
    _streams = List<ImageStream?>.filled(widget.assets.length, null);
    _listeners = List<ImageStreamListener?>.filled(widget.assets.length, null);
    _completers = List<Completer<ImageInfo>?>.filled(widget.assets.length, null);
    _loadedCount = 0;
    _atlasBuilding = false;
    _instantOverview = usesInstantDenseTimelineAtlas(widget.columnCount);

    final atlasKey = Object.hash(
      _instantOverview ? 'thumbhash' : 'thumbnail',
      targetPixels,
      Object.hashAll(widget.assets.map((asset) => asset.heroTag)),
    );
    final cachedAtlas = _denseRowAtlasCache.get(atlasKey);
    if (cachedAtlas != null) {
      _atlas = cachedAtlas;
      _scheduleRepaint();
    } else if (_instantOverview) {
      unawaited(_buildThumbhashAtlas(targetPixels, atlasKey, generation));
    }

    for (var index = 0; index < widget.assets.length; index++) {
      if (_instantOverview && _thumbHashFor(widget.assets[index]) != null) {
        continue;
      }
      _denseThumbnailQueue.schedule(() => _loadAssetImage(index, targetPixels, atlasKey, generation));
    }
  }

  String? _thumbHashFor(BaseAsset asset) => switch (asset) {
    RemoteAsset(thumbHash: final hash?) when hash.isNotEmpty => hash,
    _ => null,
  };

  Future<void> _buildThumbhashAtlas(int targetPixels, int atlasKey, int generation) async {
    final hashes = widget.assets.map(_thumbHashFor).toList(growable: false);
    try {
      final pixels = await _denseMetadataAtlasQueue.schedule(() {
        if (!mounted || generation != _generation) {
          throw const _DenseLoadCancelled();
        }
        return Isolate.run(() => buildDenseThumbhashAtlasPixels(hashes, targetPixels));
      });
      if (!mounted || generation != _generation) {
        return;
      }

      final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
      final descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: targetPixels * hashes.length,
        height: targetPixels,
        rowBytes: targetPixels * hashes.length * 4,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      buffer.dispose();
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      descriptor.dispose();
      codec.dispose();
      final atlas = frame.image;
      if (!mounted || generation != _generation) {
        atlas.dispose();
        return;
      }

      _denseRowAtlasCache.put(atlasKey, atlas);
      setState(() {
        _atlas?.dispose();
        _atlas = atlas;
      });
    } on _DenseLoadCancelled {
      return;
    } catch (_) {
      if (!mounted || generation != _generation) {
        return;
      }
      for (var index = 0; index < hashes.length; index++) {
        if (hashes[index] != null) {
          _denseThumbnailQueue.schedule(() => _loadAssetImage(index, targetPixels, atlasKey, generation));
        }
      }
    }
  }

  Future<void> _loadAssetImage(int index, int targetPixels, int atlasKey, int generation) async {
    if (!mounted || generation != _generation || (!_instantOverview && _atlas != null)) {
      return;
    }
    final asset = widget.assets[index];
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final provider = await _providerForAttempt(asset, targetPixels, useFullThumbnail: attempt == 2);
        if (provider == null || !mounted || generation != _generation) {
          return;
        }
        final image = await _resolveImage(index, provider);
        if (!mounted || generation != _generation) {
          image.dispose();
          return;
        }
        _acceptImage(index, image, targetPixels, atlasKey, generation);
        return;
      } on _DenseLoadCancelled {
        return;
      } catch (_) {
        if (attempt < 2 && mounted && generation == _generation) {
          await Future<void>.delayed(Duration(milliseconds: attempt == 0 ? 180 : 650));
        }
      }
    }

    if (asset case RemoteAsset(thumbHash: final hash?) when hash.isNotEmpty) {
      try {
        final image = await _resolveImage(index, ThumbHashProvider(thumbHash: hash));
        if (!mounted || generation != _generation) {
          image.dispose();
          return;
        }
        _acceptImage(index, image, targetPixels, atlasKey, generation);
      } catch (_) {}
    }
  }

  void _acceptImage(int index, ImageInfo image, int targetPixels, int atlasKey, int generation) {
    _images[index]?.dispose();
    _images[index] = image;
    _loadedCount++;
    _scheduleRepaint();
    if (!_instantOverview && _loadedCount == widget.assets.length) {
      unawaited(_buildAtlas(targetPixels, atlasKey, generation));
    }
  }

  Future<ImageProvider?> _providerForAttempt(
    BaseAsset asset,
    int targetPixels, {
    required bool useFullThumbnail,
  }) async {
    final normalProvider = getThumbnailImageProvider(asset);
    if (normalProvider == null) {
      return null;
    }
    if (useFullThumbnail) {
      return normalProvider;
    }
    try {
      final key = await normalProvider.obtainKey(const ImageConfiguration());
      if (PaintingBinding.instance.imageCache.containsKey(key)) {
        return normalProvider;
      }
    } catch (_) {}
    final denseProvider = getThumbnailImageProvider(asset, size: Size.square(targetPixels.toDouble()));
    return denseProvider == null ? null : ResizeImage.resizeIfNeeded(targetPixels, targetPixels, denseProvider);
  }

  Future<ImageInfo> _resolveImage(int index, ImageProvider provider) {
    final completer = Completer<ImageInfo>();
    final stream = provider.resolve(const ImageConfiguration());
    late final ImageStreamListener listener;

    void detach() {
      stream.removeListener(listener);
      if (_streams[index] == stream) {
        _streams[index] = null;
        _listeners[index] = null;
        _completers[index] = null;
      }
    }

    listener = ImageStreamListener(
      (image, _) {
        detach();
        if (!completer.isCompleted) {
          completer.complete(image);
        } else {
          image.dispose();
        }
      },
      onError: (Object error, StackTrace? stackTrace) {
        detach();
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );
    _streams[index] = stream;
    _listeners[index] = listener;
    _completers[index] = completer;
    stream.addListener(listener);
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        detach();
        throw TimeoutException('Dense thumbnail did not resolve in time');
      },
    );
  }

  Future<void> _buildAtlas(int targetPixels, int atlasKey, int generation) async {
    if (_atlasBuilding || !mounted || generation != _generation || _images.any((image) => image == null)) {
      return;
    }
    _atlasBuilding = true;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    for (var index = 0; index < _images.length; index++) {
      paintImage(
        canvas: canvas,
        rect: Rect.fromLTWH(index * targetPixels.toDouble(), 0, targetPixels.toDouble(), targetPixels.toDouble()),
        image: _images[index]!.image,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.none,
      );
    }
    final picture = recorder.endRecording();
    final atlas = await picture.toImage(targetPixels * _images.length, targetPixels);
    picture.dispose();
    if (!mounted || generation != _generation) {
      atlas.dispose();
      return;
    }
    _denseRowAtlasCache.put(atlasKey, atlas);
    setState(() {
      _atlas?.dispose();
      _atlas = atlas;
      for (var index = 0; index < _images.length; index++) {
        _images[index]?.dispose();
        _images[index] = null;
      }
    });
  }

  void _scheduleRepaint() {
    if (_repaintScheduled) {
      return;
    }
    _repaintScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _repaintScheduled = false;
      if (mounted) {
        _repaint.value++;
      }
    });
  }

  void _unsubscribeFromImages() {
    _generation++;
    for (var index = 0; index < _streams.length; index++) {
      final stream = _streams[index];
      final listener = _listeners[index];
      if (stream != null && listener != null) {
        stream.removeListener(listener);
      }
      final completer = _completers[index];
      if (completer != null && !completer.isCompleted) {
        completer.completeError(const _DenseLoadCancelled());
      }
    }
    for (final image in _images) {
      image?.dispose();
    }
    _images = const [];
    _streams = const [];
    _listeners = const [];
    _completers = const [];
    _atlas?.dispose();
    _atlas = null;
    _loadedCount = 0;
    _atlasBuilding = false;
  }

  void _handleTap(TapUpDetails details, TextDirection textDirection) {
    var offset = details.localPosition.dx;
    if (textDirection == TextDirection.rtl) {
      offset = (context.size?.width ?? 0) - offset;
    }
    final localIndex = (offset / widget.tileExtent).floor();
    if (localIndex >= 0 && localIndex < widget.assets.length) {
      widget.onAssetTap(widget.firstAssetIndex + localIndex, widget.assets[localIndex]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textDirection = Directionality.of(context);
    return RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) => _handleTap(details, textDirection),
        child: CustomPaint(
          size: Size(double.infinity, widget.tileExtent),
          isComplex: true,
          willChange: false,
          painter: _DenseAssetRowPainter(
            images: _images,
            atlas: _atlas,
            itemCount: widget.assets.length,
            tileExtent: widget.tileExtent,
            textDirection: textDirection,
            placeholderColor: Theme.of(context).colorScheme.surfaceContainer,
            repaint: _repaint,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _unsubscribeFromImages();
    _repaint.dispose();
    super.dispose();
  }
}

class _DenseAssetRowPainter extends CustomPainter {
  final List<ImageInfo?> images;
  final ui.Image? atlas;
  final int itemCount;
  final double tileExtent;
  final TextDirection textDirection;
  final Color placeholderColor;

  _DenseAssetRowPainter({
    required this.images,
    required this.atlas,
    required this.itemCount,
    required this.tileExtent,
    required this.textDirection,
    required this.placeholderColor,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = placeholderColor);
    final atlas = this.atlas;
    if (atlas != null) {
      final left = textDirection == TextDirection.rtl ? size.width - (itemCount * tileExtent) : 0.0;
      canvas.drawImageRect(
        atlas,
        Rect.fromLTWH(0, 0, atlas.width.toDouble(), atlas.height.toDouble()),
        Rect.fromLTWH(left, 0, itemCount * tileExtent, tileExtent),
        Paint()..filterQuality = FilterQuality.none,
      );
    }
    for (var index = 0; index < images.length; index++) {
      final image = images[index]?.image;
      if (image == null) {
        continue;
      }
      final left = textDirection == TextDirection.rtl ? size.width - ((index + 1) * tileExtent) : index * tileExtent;
      paintImage(
        canvas: canvas,
        rect: Rect.fromLTWH(left, 0, tileExtent, tileExtent),
        image: image,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.none,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DenseAssetRowPainter oldDelegate) =>
      oldDelegate.images != images ||
      oldDelegate.atlas != atlas ||
      oldDelegate.itemCount != itemCount ||
      oldDelegate.tileExtent != tileExtent ||
      oldDelegate.textDirection != textDirection ||
      oldDelegate.placeholderColor != placeholderColor;
}
