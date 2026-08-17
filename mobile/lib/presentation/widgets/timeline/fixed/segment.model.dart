import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:auto_route/auto_route.dart';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
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
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

int denseTimelineAssetChunkSize({
  required int columnCount,
  required double viewportHeight,
  required double tileExtent,
}) {
  if (tileExtent <= 0 || viewportHeight <= 0) {
    return kTimelineAssetLoadBatchSize;
  }
  if (columnCount >= 12) {
    return 8192;
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

bool usesInstantDenseTimelineAtlas(int columnCount) => columnCount >= 12;

int denseTimelineRowsPerChild(int columnCount) => switch (columnCount) {
  >= 48 => 16,
  >= 36 => 24,
  >= 24 => 16,
  >= 12 => 12,
  _ => 1,
};

class _DenseAtlasPixelsResult {
  final Uint8List pixels;
  final List<Uint8List?> tiles;

  const _DenseAtlasPixelsResult(this.pixels, this.tiles);
}

class _DenseDiskAtlasEntry {
  final int width;
  final int height;
  final String signature;
  final Uint8List pixels;

  const _DenseDiskAtlasEntry({
    required this.width,
    required this.height,
    required this.signature,
    required this.pixels,
  });
}

/// Persistent raw-RGBA contact sheets. Raw pixels use more disk than PNG but
/// avoid a full image decompression pass while the user is scrolling.
class _DenseDiskAtlasCache {
  static const _magic = 'IHDPANL3';
  static const _headerBytes = 80;
  static const _maxBytes = 512 * 1024 * 1024;
  static const _trimToBytes = 448 * 1024 * 1024;

  Future<Directory>? _directory;
  final Map<String, Future<_DenseDiskAtlasEntry?>> _reads = {};
  final Map<String, Future<void>> _writes = {};

  String _fileName(String slot) => '${sha256.convert(utf8.encode(slot))}.rgba';

  Future<Directory> _getDirectory() => _directory ??= () async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(path.join(support.path, 'inhouse_year_panels_v3'));
    await directory.create(recursive: true);
    unawaited(_trim(directory));
    return directory;
  }();

  Future<_DenseDiskAtlasEntry?> get(String slot) {
    return _reads.putIfAbsent(slot, () async {
      try {
        final directory = await _getDirectory();
        final file = File(path.join(directory.path, _fileName(slot)));
        final bytes = await file.readAsBytes();
        if (bytes.length < _headerBytes || ascii.decode(bytes.sublist(0, 8)) != _magic) {
          return null;
        }
        final header = ByteData.sublistView(bytes, 8, 16);
        final width = header.getUint32(0, Endian.little);
        final height = header.getUint32(4, Endian.little);
        final expectedLength = _headerBytes + width * height * 4;
        if (width <= 0 || height <= 0 || bytes.length != expectedLength) {
          return null;
        }
        final signature = ascii.decode(bytes.sublist(16, 80));
        unawaited(file.setLastModified(DateTime.now()).catchError((_) => file));
        return _DenseDiskAtlasEntry(
          width: width,
          height: height,
          signature: signature,
          pixels: Uint8List.sublistView(bytes, _headerBytes),
        );
      } catch (_) {
        return null;
      }
    });
  }

  void put(String slot, String signature, int width, int height, Uint8List pixels) {
    if (signature.length != 64 || pixels.lengthInBytes != width * height * 4) {
      return;
    }
    final previous = _writes[slot] ?? Future.value();
    final write = previous.then((_) async {
      try {
        final directory = await _getDirectory();
        final file = File(path.join(directory.path, _fileName(slot)));
        final bytes = Uint8List(_headerBytes + pixels.lengthInBytes);
        bytes.setRange(0, 8, ascii.encode(_magic));
        final header = ByteData.sublistView(bytes, 8, 16);
        header.setUint32(0, width, Endian.little);
        header.setUint32(4, height, Endian.little);
        bytes.setRange(16, 80, ascii.encode(signature));
        bytes.setRange(_headerBytes, bytes.length, pixels);
        final temporary = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
        await temporary.writeAsBytes(bytes, flush: false);
        if (await file.exists()) {
          await file.delete();
        }
        await temporary.rename(file.path);
        _reads[slot] = Future.value(
          _DenseDiskAtlasEntry(width: width, height: height, signature: signature, pixels: pixels),
        );
      } catch (_) {
        // The in-memory atlas remains valid if Android denies or runs out of
        // cache storage; the next successful render can retry the write.
      }
    });
    late final Future<void> trackedWrite;
    trackedWrite = write.whenComplete(() {
      if (identical(_writes[slot], trackedWrite)) {
        _writes.remove(slot);
      }
    });
    _writes[slot] = trackedWrite;
  }

  Future<void> _trim(Directory directory) async {
    try {
      final files = await directory
          .list()
          .where((entity) => entity is File && entity.path.endsWith('.rgba'))
          .cast<File>()
          .toList();
      final entries = <(File, FileStat)>[];
      var total = 0;
      for (final file in files) {
        final stat = await file.stat();
        total += stat.size;
        entries.add((file, stat));
      }
      if (total <= _maxBytes) {
        return;
      }
      entries.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      for (final entry in entries) {
        if (total <= _trimToBytes) {
          break;
        }
        total -= entry.$2.size;
        await entry.$1.delete().catchError((_) => entry.$1);
      }
    } catch (_) {}
  }
}

Uint8List _decodeThumbhashSquare(Uint8List hash, int size) {
  if (hash.length < 5 || size <= 0) {
    throw const FormatException('Invalid ThumbHash');
  }
  final decoded = thumbhash.thumbHashToRGBA(hash);
  final sourceWidth = decoded.width;
  final sourceHeight = decoded.height;
  final sourceSize = math.min(sourceWidth, sourceHeight);
  final sourceLeft = (sourceWidth - sourceSize) / 2;
  final sourceTop = (sourceHeight - sourceSize) / 2;
  final output = Uint8List(size * size * 4);

  // A 16px nearest-neighbour crop is intentional: ThumbHash is already a
  // smooth DCT placeholder and this avoids another expensive filter pass.
  for (var y = 0; y < size; y++) {
    final sourceY = (sourceTop + ((y + 0.5) * sourceSize / size)).floor().clamp(0, sourceHeight - 1);
    for (var x = 0; x < size; x++) {
      final sourceX = (sourceLeft + ((x + 0.5) * sourceSize / size)).floor().clamp(0, sourceWidth - 1);
      final sourceOffset = (sourceY * sourceWidth + sourceX) * 4;
      final targetOffset = (y * size + x) * 4;
      output.setRange(targetOffset, targetOffset + 4, decoded.rgba, sourceOffset);
    }
  }
  return output;
}

_DenseAtlasPixelsResult _buildDenseThumbhashAtlas(
  List<String?> hashes,
  int targetPixels, {
  required int columnCount,
  List<Uint8List?>? cachedTiles,
}) {
  final columns = columnCount;
  final rows = (hashes.length / columns).ceil();
  final atlasWidth = columns * targetPixels;
  final atlas = Uint8List(atlasWidth * rows * targetPixels * 4);
  final tiles = List<Uint8List?>.filled(hashes.length, null);

  for (var index = 0; index < hashes.length; index++) {
    final hash = hashes[index];
    var tile = cachedTiles?[index];
    if (tile == null && (hash == null || hash.isEmpty)) {
      continue;
    }

    if (tile == null) {
      try {
        tile = _decodeThumbhashSquare(base64Decode(hash!), targetPixels);
      } catch (_) {
        // A missing or malformed hash is filled later by the normal thumbnail path.
      }
    }

    if (tile == null) {
      continue;
    }
    tiles[index] = tile;
    for (var y = 0; y < targetPixels; y++) {
      final destinationX = (index % columns) * targetPixels;
      final destinationY = (index ~/ columns) * targetPixels + y;
      final destinationOffset = (destinationY * atlasWidth + destinationX) * 4;
      final tileOffset = y * targetPixels * 4;
      atlas.setRange(destinationOffset, destinationOffset + targetPixels * 4, tile, tileOffset);
    }
  }

  return _DenseAtlasPixelsResult(atlas, tiles);
}

Uint8List buildDenseThumbhashAtlasPixels(List<String?> hashes, int targetPixels, {int? columnCount}) {
  return _buildDenseThumbhashAtlas(hashes, targetPixels, columnCount: columnCount ?? hashes.length).pixels;
}

final Expando<_DenseAssetChunkStore> _denseAssetStores = Expando<_DenseAssetChunkStore>();

class _DenseAssetChunkStore {
  final LinkedHashMap<(int, int), Future<List<BaseAsset>>> _rows = LinkedHashMap();
  final Map<(int, int), List<BaseAsset>> _resolvedRows = {};
  int _revision = -1;

  void _resetIfNeeded(TimelineService service) {
    if (_revision == service.revision) {
      return;
    }
    _revision = service.revision;
    _rows.clear();
    _resolvedRows.clear();
  }

  List<BaseAsset>? getRow(TimelineService service, {required int index, required int count}) {
    _resetIfNeeded(service);
    return _resolvedRows[(index, count)];
  }

  Future<List<BaseAsset>> loadRow(TimelineService service, {required int index, required int count}) {
    _resetIfNeeded(service);
    final exactKey = (index, count);
    final resolved = _resolvedRows[exactKey];
    if (resolved != null) {
      return Future.value(resolved);
    }
    var row = _rows.remove(exactKey);
    if (row == null) {
      final expectedRevision = _revision;
      row = service
          .loadAssets(index, count)
          .then(
            (assets) {
              if (_revision == expectedRevision) {
                _resolvedRows[exactKey] = assets;
              }
              return assets;
            },
            onError: (Object error, StackTrace stackTrace) {
              _rows.remove(exactKey);
              Error.throwWithStackTrace(error, stackTrace);
            },
          );
    }
    _rows[exactKey] = row;
    while (_rows.length > 512) {
      final oldest = _rows.keys.first;
      _rows.remove(oldest);
      _resolvedRows.remove(oldest);
    }

    return row;
  }
}

class FixedSegment extends Segment {
  final double tileHeight;
  final int columnCount;
  final int rowsPerChild;
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
    this.rowsPerChild = 1,
    required super.headerExtent,
    required super.spacing,
    required super.header,
  }) : assert(tileHeight != 0),
       mainAxisExtend = (tileHeight + spacing) * rowsPerChild;

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
    final rowIndexInSegment = (index - (firstIndex + 1)) * rowsPerChild;
    final assetIndex = rowIndexInSegment * columnCount;
    final assetCount = bucket.assetCount;
    final numberOfAssets = math.min(columnCount * rowsPerChild, assetCount - assetIndex);

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
      denseCacheSlot: bucket is TimeBucket
          ? '${(bucket as TimeBucket).date.toUtc().microsecondsSinceEpoch}:$rowIndexInSegment:$columnCount:$numberOfAssets'
          : '$firstAssetIndex:$rowIndexInSegment:$columnCount:$numberOfAssets',
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
  final String denseCacheSlot;

  const _FixedSegmentRow({
    required this.assetIndex,
    required this.assetCount,
    required this.tileHeight,
    required this.spacing,
    required this.columnCount,
    required this.denseOverview,
    required this.denseCacheSlot,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isScrubbing = ref.watch(timelineStateProvider.select((s) => s.isScrubbing));
    final timelineService = ref.read(timelineServiceProvider);
    final cacheSlot = '${timelineService.origin.name}:$denseCacheSlot';
    final isDynamicLayout = columnCount <= (context.isMobile ? 2 : 3);

    _DenseAssetChunkStore? denseStore;
    if (denseOverview) {
      denseStore = _denseAssetStores[timelineService] ??= _DenseAssetChunkStore();
      final cachedAssets = denseStore.getRow(timelineService, index: assetIndex, count: assetCount);
      if (cachedAssets != null) {
        return _buildAssetRow(context, ref, cachedAssets, timelineService, false, cacheSlot);
      }
      unawaited(
        denseStore
            .loadRow(timelineService, index: assetIndex, count: assetCount)
            .then<void>((_) {}, onError: (_, __) {}),
      );
    }

    if (timelineService.hasRange(assetIndex, assetCount)) {
      return _buildAssetRow(
        context,
        ref,
        timelineService.getAssets(assetIndex, assetCount),
        timelineService,
        isDynamicLayout,
        cacheSlot,
      );
    }

    if (isScrubbing) {
      return _buildPlaceholder(context, cacheSlot);
    }

    if (denseOverview) {
      return FutureBuilder<List<BaseAsset>>(
        future: denseStore!.loadRow(timelineService, index: assetIndex, count: assetCount),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return _buildPlaceholder(context, cacheSlot);
          }
          return _buildAssetRow(context, ref, snapshot.requireData, timelineService, false, cacheSlot);
        },
      );
    }

    return FutureBuilder<List<BaseAsset>>(
      future: timelineService.loadAssets(assetIndex, assetCount),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _buildPlaceholder(context, cacheSlot);
        }
        return _buildAssetRow(context, ref, snapshot.requireData, timelineService, isDynamicLayout, cacheSlot);
      },
    );
  }

  Widget _buildPlaceholder(BuildContext context, String cacheSlot) {
    if (denseOverview && denseTimelineRowsPerChild(columnCount) > 1) {
      return _DenseCachedPanel(
        cacheSlot: cacheSlot,
        itemCount: assetCount,
        columnCount: columnCount,
        tileExtent: tileHeight,
      );
    }
    return SegmentBuilder.buildPlaceholder(context, assetCount, size: Size.square(tileHeight), spacing: spacing);
  }

  Widget _buildAssetRow(
    BuildContext context,
    WidgetRef ref,
    List<BaseAsset> assets,
    TimelineService timelineService,
    bool isDynamicLayout,
    String cacheSlot,
  ) {
    if (denseOverview) {
      return _DenseAssetRow(
        key: ValueKey(Object.hash(assetIndex, timelineService.hashCode)),
        assets: assets,
        firstAssetIndex: assetIndex,
        tileExtent: tileHeight,
        columnCount: columnCount,
        cacheSlot: cacheSlot,
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
const int _denseMetadataCellPixels = 16;
const int _denseAtlasCacheBytes = 160 * 1024 * 1024;
const int _denseThumbTileCacheBytes = 32 * 1024 * 1024;
final _DenseThumbnailQueue _denseThumbnailQueue = _DenseThumbnailQueue();
final _DenseAsyncQueue _denseMetadataAtlasQueue = _DenseAsyncQueue(_denseMetadataAtlasConcurrency);
final _DenseRowAtlasCache _denseRowAtlasCache = _DenseRowAtlasCache();
final _DenseThumbTileCache _denseThumbTileCache = _DenseThumbTileCache();
final _DenseDiskAtlasCache _denseDiskAtlasCache = _DenseDiskAtlasCache();

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
  final LinkedHashMap<Object, ui.Image> _images = LinkedHashMap();
  int _bytes = 0;

  ui.Image? get(Object key) {
    final image = _images.remove(key);
    if (image == null) {
      return null;
    }
    _images[key] = image;
    return image.clone();
  }

  void put(Object key, ui.Image image) {
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

Future<ui.Image> _decodeDenseDiskAtlas(_DenseDiskAtlasEntry entry) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(entry.pixels);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: entry.width,
    height: entry.height,
    rowBytes: entry.width * 4,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  buffer.dispose();
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  descriptor.dispose();
  codec.dispose();
  return frame.image;
}

class _DenseCachedPanel extends StatefulWidget {
  final String cacheSlot;
  final int itemCount;
  final int columnCount;
  final double tileExtent;

  const _DenseCachedPanel({
    required this.cacheSlot,
    required this.itemCount,
    required this.columnCount,
    required this.tileExtent,
  });

  @override
  State<_DenseCachedPanel> createState() => _DenseCachedPanelState();
}

class _DenseCachedPanelState extends State<_DenseCachedPanel> {
  ui.Image? _atlas;

  Object get _memoryKey => Object.hash('persistent-slot', widget.cacheSlot);

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void didUpdateWidget(covariant _DenseCachedPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cacheSlot != widget.cacheSlot) {
      _atlas?.dispose();
      _atlas = null;
      _restore();
    }
  }

  Future<void> _restore() async {
    final memory = _denseRowAtlasCache.get(_memoryKey);
    if (memory != null) {
      if (mounted) {
        setState(() => _atlas = memory);
      } else {
        memory.dispose();
      }
      return;
    }
    final entry = await _denseDiskAtlasCache.get(widget.cacheSlot);
    if (entry == null ||
        entry.width != widget.columnCount * _denseMetadataCellPixels ||
        entry.height != (widget.itemCount / widget.columnCount).ceil() * _denseMetadataCellPixels) {
      return;
    }
    final image = await _decodeDenseDiskAtlas(entry);
    if (!mounted) {
      image.dispose();
      return;
    }
    _denseRowAtlasCache.put(_memoryKey, image);
    setState(() => _atlas = image);
  }

  @override
  Widget build(BuildContext context) {
    final rowCount = (widget.itemCount / widget.columnCount).ceil();
    return CustomPaint(
      size: Size(double.infinity, rowCount * widget.tileExtent),
      isComplex: true,
      willChange: false,
      painter: _DenseAssetRowPainter(
        images: const [],
        atlas: _atlas,
        itemCount: widget.itemCount,
        columnCount: widget.columnCount,
        tileExtent: widget.tileExtent,
        textDirection: Directionality.of(context),
        repaint: const _NeverNotifyListenable(),
      ),
    );
  }

  @override
  void dispose() {
    _atlas?.dispose();
    super.dispose();
  }
}

class _NeverNotifyListenable implements Listenable {
  const _NeverNotifyListenable();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

class _DenseThumbTileCache {
  final LinkedHashMap<String, Uint8List> _tiles = LinkedHashMap();
  int _bytes = 0;

  Uint8List? get(String key) {
    final tile = _tiles.remove(key);
    if (tile == null) {
      return null;
    }
    _tiles[key] = tile;
    return tile;
  }

  void put(String key, Uint8List tile) {
    final previous = _tiles.remove(key);
    if (previous != null) {
      _bytes -= previous.lengthInBytes;
    }
    _tiles[key] = tile;
    _bytes += tile.lengthInBytes;
    while (_bytes > _denseThumbTileCacheBytes && _tiles.isNotEmpty) {
      final oldest = _tiles.remove(_tiles.keys.first)!;
      _bytes -= oldest.lengthInBytes;
    }
  }
}

/// Paints a virtualized overview panel in one layer. At 48 columns, 16 rows are
/// collapsed into one state object, one gesture recognizer, and one render
/// object instead of 768 individual tiles or 16 independent row loaders.
class _DenseAssetRow extends StatefulWidget {
  final List<BaseAsset> assets;
  final int firstAssetIndex;
  final double tileExtent;
  final int columnCount;
  final String cacheSlot;
  final _DenseAssetTap onAssetTap;

  const _DenseAssetRow({
    super.key,
    required this.assets,
    required this.firstAssetIndex,
    required this.tileExtent,
    required this.columnCount,
    required this.cacheSlot,
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
  int _atlasTargetPixels = _denseMetadataCellPixels;
  int _completeAtlasKey = 0;
  late Object _slotAtlasKey;
  String _contentSignature = '';
  bool _persistentExact = false;
  bool _baseAtlasReady = false;
  int _requiredActualCount = 0;
  int _loadedCount = 0;
  int _generation = 0;
  final Set<int> _actualThumbnailRequests = {};

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
    _unsubscribeFromImages(preserveAtlas: true);
    final generation = ++_generation;
    final thumbnailTargetPixels = denseTimelineTargetPixels(
      tileExtent: widget.tileExtent,
      devicePixelRatio: _devicePixelRatio ?? 1,
    );
    final atlasTargetPixels = usesInstantDenseTimelineAtlas(widget.columnCount)
        ? _denseMetadataCellPixels
        : thumbnailTargetPixels;
    _images = List<ImageInfo?>.filled(widget.assets.length, null);
    _streams = List<ImageStream?>.filled(widget.assets.length, null);
    _listeners = List<ImageStreamListener?>.filled(widget.assets.length, null);
    _completers = List<Completer<ImageInfo>?>.filled(widget.assets.length, null);
    _loadedCount = 0;
    _atlasBuilding = false;
    _instantOverview = usesInstantDenseTimelineAtlas(widget.columnCount);
    _persistentExact = false;
    _baseAtlasReady = false;
    _atlasTargetPixels = atlasTargetPixels;
    _requiredActualCount = 0;
    _actualThumbnailRequests.clear();

    final atlasKey = Object.hash(
      _instantOverview ? 'thumbhash' : 'thumbnail',
      atlasTargetPixels,
      widget.columnCount,
      Object.hashAll(widget.assets.map((asset) => asset.heroTag)),
    );
    _completeAtlasKey = _instantOverview
        ? Object.hash(
            'complete',
            atlasTargetPixels,
            widget.columnCount,
            Object.hashAll(widget.assets.map((asset) => asset.heroTag)),
          )
        : atlasKey;
    _slotAtlasKey = Object.hash('persistent-slot', widget.cacheSlot);
    _contentSignature = sha256.convert(utf8.encode(_denseContentIdentity())).toString();
    final completeAtlas = _denseRowAtlasCache.get(_completeAtlasKey);
    if (completeAtlas != null) {
      _replaceAtlas(completeAtlas);
      _persistentExact = true;
      _baseAtlasReady = true;
      _scheduleRepaint();
      return;
    }
    final cachedAtlas = _denseRowAtlasCache.get(atlasKey);
    if (cachedAtlas != null) {
      _replaceAtlas(cachedAtlas);
      _baseAtlasReady = true;
      _scheduleRepaint();
    }
    final positionalAtlas = _denseRowAtlasCache.get(_slotAtlasKey);
    if (_atlas == null && positionalAtlas != null) {
      _replaceAtlas(positionalAtlas);
      _scheduleRepaint();
    } else {
      positionalAtlas?.dispose();
    }
    unawaited(_restorePersistentThenBuild(thumbnailTargetPixels, atlasTargetPixels, atlasKey, generation));
  }

  String _denseContentIdentity() {
    final buffer = StringBuffer('v3:${widget.columnCount}:${widget.assets.length};');
    for (final asset in widget.assets) {
      buffer
        ..write(asset.remoteId ?? asset.localId ?? asset.checksum ?? asset.heroTag)
        ..write(':')
        ..write(asset.updatedAt.toUtc().microsecondsSinceEpoch)
        ..write(':')
        ..write(_thumbHashFor(asset) ?? '')
        ..write(';');
    }
    return buffer.toString();
  }

  Future<void> _restorePersistentThenBuild(
    int thumbnailTargetPixels,
    int atlasTargetPixels,
    int atlasKey,
    int generation,
  ) async {
    final entry = await _denseDiskAtlasCache.get(widget.cacheSlot);
    if (!mounted || generation != _generation) {
      return;
    }
    final rows = (widget.assets.length / widget.columnCount).ceil();
    if (entry != null &&
        entry.width == widget.columnCount * atlasTargetPixels &&
        entry.height == rows * atlasTargetPixels) {
      final image = await _decodeDenseDiskAtlas(entry);
      if (!mounted || generation != _generation) {
        image.dispose();
        return;
      }
      setState(() => _replaceAtlas(image));
      _denseRowAtlasCache.put(_slotAtlasKey, image);
      if (entry.signature == _contentSignature) {
        _persistentExact = true;
        _baseAtlasReady = true;
        _denseRowAtlasCache.put(_completeAtlasKey, image);
        return;
      }
    }

    if (_instantOverview) {
      unawaited(_buildThumbhashAtlas(atlasTargetPixels, atlasKey, generation));
    }
    for (var index = 0; index < widget.assets.length; index++) {
      if (_instantOverview && _thumbHashFor(widget.assets[index]) != null) {
        continue;
      }
      _requestActualThumbnail(index, thumbnailTargetPixels, atlasKey, generation);
    }
  }

  void _requestActualThumbnail(int index, int targetPixels, int atlasKey, int generation) {
    if (!_actualThumbnailRequests.add(index)) {
      return;
    }
    _requiredActualCount++;
    _denseThumbnailQueue.schedule(() => _loadAssetImage(index, targetPixels, atlasKey, generation));
  }

  void _replaceAtlas(ui.Image image) {
    if (identical(_atlas, image)) {
      return;
    }
    _atlas?.dispose();
    _atlas = image;
  }

  String? _thumbHashFor(BaseAsset asset) => switch (asset) {
    RemoteAsset(thumbHash: final hash?) when hash.isNotEmpty => hash,
    _ => null,
  };

  Future<void> _buildThumbhashAtlas(int targetPixels, int atlasKey, int generation) async {
    if (_persistentExact) {
      return;
    }
    final hashes = widget.assets.map(_thumbHashFor).toList(growable: false);
    final tileKeys = [
      for (var index = 0; index < widget.assets.length; index++)
        '${widget.assets[index].heroTag}:${hashes[index] ?? ''}',
    ];
    final cachedTiles = tileKeys.map(_denseThumbTileCache.get).toList(growable: false);
    try {
      final result = await _denseMetadataAtlasQueue.schedule(() {
        if (!mounted || generation != _generation) {
          throw const _DenseLoadCancelled();
        }
        return Isolate.run(
          () => _buildDenseThumbhashAtlas(
            hashes,
            targetPixels,
            columnCount: widget.columnCount,
            cachedTiles: cachedTiles,
          ),
        );
      });
      if (!mounted || generation != _generation) {
        return;
      }
      for (var index = 0; index < result.tiles.length; index++) {
        final tile = result.tiles[index];
        if (tile != null && cachedTiles[index] == null) {
          _denseThumbTileCache.put(tileKeys[index], tile);
        } else if (tile == null && hashes[index] != null) {
          _requestActualThumbnail(index, targetPixels, atlasKey, generation);
        }
      }

      final buffer = await ui.ImmutableBuffer.fromUint8List(result.pixels);
      final descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: targetPixels * widget.columnCount,
        height: targetPixels * (hashes.length / widget.columnCount).ceil(),
        rowBytes: targetPixels * widget.columnCount * 4,
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
        _replaceAtlas(atlas);
        _baseAtlasReady = true;
      });
      if (_requiredActualCount == 0) {
        _persistentExact = true;
        _denseRowAtlasCache.put(_completeAtlasKey, atlas);
        _denseRowAtlasCache.put(_slotAtlasKey, atlas);
        _denseDiskAtlasCache.put(
          widget.cacheSlot,
          _contentSignature,
          targetPixels * widget.columnCount,
          targetPixels * (hashes.length / widget.columnCount).ceil(),
          result.pixels,
        );
      }
      _maybeBuildCompositeAtlas(atlasKey, generation);
    } on _DenseLoadCancelled {
      return;
    } catch (_) {
      if (!mounted || generation != _generation) {
        return;
      }
      for (var index = 0; index < hashes.length; index++) {
        _requestActualThumbnail(index, targetPixels, atlasKey, generation);
      }
    }
  }

  Future<void> _loadAssetImage(int index, int targetPixels, int atlasKey, int generation) async {
    if (!mounted || generation != _generation || _persistentExact || (!_instantOverview && _atlas != null)) {
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
    if (_instantOverview) {
      if (_loadedCount == _requiredActualCount && !_baseAtlasReady && _requiredActualCount == widget.assets.length) {
        unawaited(_buildAtlas(targetPixels, atlasKey, generation));
      } else {
        _maybeBuildCompositeAtlas(atlasKey, generation);
      }
    } else if (_loadedCount == widget.assets.length) {
      unawaited(_buildAtlas(targetPixels, atlasKey, generation));
    }
  }

  void _maybeBuildCompositeAtlas(int atlasKey, int generation) {
    if (_instantOverview &&
        _atlas != null &&
        _baseAtlasReady &&
        _requiredActualCount > 0 &&
        _loadedCount == _requiredActualCount &&
        !_atlasBuilding) {
      unawaited(_buildCompositeAtlas(_atlasTargetPixels, atlasKey, generation));
    }
  }

  Future<void> _buildCompositeAtlas(int targetPixels, int atlasKey, int generation) async {
    final sourceAtlas = _atlas;
    if (_atlasBuilding || sourceAtlas == null || !mounted || generation != _generation) {
      return;
    }
    _atlasBuilding = true;
    final rows = (widget.assets.length / widget.columnCount).ceil();
    final width = targetPixels * widget.columnCount;
    final height = targetPixels * rows;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      sourceAtlas,
      Rect.fromLTWH(0, 0, sourceAtlas.width.toDouble(), sourceAtlas.height.toDouble()),
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..filterQuality = FilterQuality.none,
    );
    for (var index = 0; index < _images.length; index++) {
      final image = _images[index]?.image;
      if (image == null) {
        continue;
      }
      paintImage(
        canvas: canvas,
        rect: Rect.fromLTWH(
          (index % widget.columnCount) * targetPixels.toDouble(),
          (index ~/ widget.columnCount) * targetPixels.toDouble(),
          targetPixels.toDouble(),
          targetPixels.toDouble(),
        ),
        image: image,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.none,
      );
    }
    final picture = recorder.endRecording();
    final atlas = await picture.toImage(width, height);
    picture.dispose();
    if (!mounted || generation != _generation) {
      atlas.dispose();
      return;
    }
    _denseRowAtlasCache.put(_completeAtlasKey, atlas);
    _denseRowAtlasCache.put(_slotAtlasKey, atlas);
    setState(() {
      _replaceAtlas(atlas);
      _persistentExact = true;
      _baseAtlasReady = true;
      for (var index = 0; index < _images.length; index++) {
        _images[index]?.dispose();
        _images[index] = null;
      }
    });
    unawaited(_persistAtlas(atlas));
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
    if (_atlasBuilding ||
        _persistentExact ||
        !mounted ||
        generation != _generation ||
        _images.any((image) => image == null)) {
      return;
    }
    _atlasBuilding = true;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    for (var index = 0; index < _images.length; index++) {
      final column = index % widget.columnCount;
      final row = index ~/ widget.columnCount;
      paintImage(
        canvas: canvas,
        rect: Rect.fromLTWH(
          column * targetPixels.toDouble(),
          row * targetPixels.toDouble(),
          targetPixels.toDouble(),
          targetPixels.toDouble(),
        ),
        image: _images[index]!.image,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.none,
      );
    }
    final picture = recorder.endRecording();
    final atlas = await picture.toImage(
      targetPixels * widget.columnCount,
      targetPixels * (_images.length / widget.columnCount).ceil(),
    );
    picture.dispose();
    if (!mounted || generation != _generation) {
      atlas.dispose();
      return;
    }
    _denseRowAtlasCache.put(atlasKey, atlas);
    _denseRowAtlasCache.put(_slotAtlasKey, atlas);
    setState(() {
      _replaceAtlas(atlas);
      _persistentExact = true;
      _baseAtlasReady = true;
      for (var index = 0; index < _images.length; index++) {
        _images[index]?.dispose();
        _images[index] = null;
      }
    });
    unawaited(_persistAtlas(atlas));
  }

  Future<void> _persistAtlas(ui.Image atlas) async {
    final snapshot = atlas.clone();
    try {
      final data = await snapshot.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) {
        return;
      }
      _denseDiskAtlasCache.put(
        widget.cacheSlot,
        _contentSignature,
        atlas.width,
        atlas.height,
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } catch (_) {
    } finally {
      snapshot.dispose();
    }
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

  void _unsubscribeFromImages({bool preserveAtlas = false}) {
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
    if (!preserveAtlas) {
      _atlas?.dispose();
      _atlas = null;
    }
    _loadedCount = 0;
    _requiredActualCount = 0;
    _actualThumbnailRequests.clear();
    _atlasBuilding = false;
    _baseAtlasReady = false;
  }

  void _handleTap(TapUpDetails details, TextDirection textDirection) {
    var offset = details.localPosition.dx;
    if (textDirection == TextDirection.rtl) {
      offset = (context.size?.width ?? 0) - offset;
    }
    final column = (offset / widget.tileExtent).floor();
    final row = (details.localPosition.dy / widget.tileExtent).floor();
    final localIndex = row * widget.columnCount + column;
    if (localIndex >= 0 && localIndex < widget.assets.length) {
      widget.onAssetTap(widget.firstAssetIndex + localIndex, widget.assets[localIndex]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textDirection = Directionality.of(context);
    final rowCount = (widget.assets.length / widget.columnCount).ceil();
    return RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) => _handleTap(details, textDirection),
        child: CustomPaint(
          size: Size(double.infinity, rowCount * widget.tileExtent),
          isComplex: true,
          willChange: false,
          painter: _DenseAssetRowPainter(
            images: _images,
            atlas: _atlas,
            itemCount: widget.assets.length,
            columnCount: widget.columnCount,
            tileExtent: widget.tileExtent,
            textDirection: textDirection,
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
  final int columnCount;
  final double tileExtent;
  final TextDirection textDirection;

  _DenseAssetRowPainter({
    required this.images,
    required this.atlas,
    required this.itemCount,
    required this.columnCount,
    required this.tileExtent,
    required this.textDirection,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final atlas = this.atlas;
    if (atlas != null) {
      final rowCount = (itemCount / columnCount).ceil();
      final left = textDirection == TextDirection.rtl ? size.width - (columnCount * tileExtent) : 0.0;
      canvas.drawImageRect(
        atlas,
        Rect.fromLTWH(0, 0, atlas.width.toDouble(), atlas.height.toDouble()),
        Rect.fromLTWH(left, 0, columnCount * tileExtent, rowCount * tileExtent),
        Paint()..filterQuality = FilterQuality.low,
      );
    }
    for (var index = 0; index < images.length; index++) {
      final image = images[index]?.image;
      if (image == null) {
        continue;
      }
      final column = index % columnCount;
      final row = index ~/ columnCount;
      final left = textDirection == TextDirection.rtl ? size.width - ((column + 1) * tileExtent) : column * tileExtent;
      paintImage(
        canvas: canvas,
        rect: Rect.fromLTWH(left, row * tileExtent, tileExtent, tileExtent),
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
      oldDelegate.columnCount != columnCount ||
      oldDelegate.tileExtent != tileExtent ||
      oldDelegate.textDirection != textDirection;
}
