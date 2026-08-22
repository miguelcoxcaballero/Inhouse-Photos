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
import 'package:immich_mobile/presentation/widgets/timeline/timeline_zoom_transition.dart';
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
  >= 48 => 4,
  >= 36 => 6,
  >= 24 => 6,
  >= 12 => 8,
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
  final Uint8List encodedBytes;

  const _DenseDiskAtlasEntry({
    required this.width,
    required this.height,
    required this.signature,
    required this.encodedBytes,
  });
}

/// Persistent compressed contact sheets. The atlas is decoded once and kept in
/// the memory LRU, while PNG keeps the offline cache small enough to retain
/// many years of photos on ordinary phones.
class _DenseDiskAtlasCache {
  static const _magic = 'IHDPANL4';
  static const _headerBytes = 80;
  static const _maxBytes = denseOverviewDiskCacheLimitBytes;
  static const _trimToBytes = 224 * 1024 * 1024;

  Future<Directory>? _directory;
  final Map<String, Future<_DenseDiskAtlasEntry?>> _reads = {};
  final Map<String, Future<void>> _writes = {};

  String _fileName(String slot) => '${sha256.convert(utf8.encode(slot))}.png';

  Future<Directory> _getDirectory() => _directory ??= () async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(path.join(support.path, 'inhouse_year_panels_v4'));
    await directory.create(recursive: true);
    // v3 stored uncompressed RGBA. Keep it during the first v4 generation so
    // an interrupted upgrade never destroys the previous offline cache; once
    // at least one v4 panel exists, remove the legacy cache on a later launch.
    unawaited(_removeLegacyDenseCacheWhenReady(support, directory));
    unawaited(_trim(directory));
    return directory;
  }();

  Future<_DenseDiskAtlasEntry?> get(String slot) {
    final inFlight = _reads[slot];
    if (inFlight != null) {
      return inFlight;
    }

    late final Future<_DenseDiskAtlasEntry?> read;
    read =
        () async {
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
            final encodedBytes = Uint8List.sublistView(bytes, _headerBytes);
            if (width <= 0 || height <= 0 || encodedBytes.isEmpty) {
              return null;
            }
            final signature = ascii.decode(bytes.sublist(16, 80));
            return _DenseDiskAtlasEntry(width: width, height: height, signature: signature, encodedBytes: encodedBytes);
          } catch (_) {
            return null;
          }
        }().whenComplete(() {
          // Cache decoded textures, not the compressed file bytes. Retaining every
          // PNG read here duplicated the complete disk cache in Dart heap and was
          // the main source of OOM crashes in long year-view scrolls.
          if (identical(_reads[slot], read)) {
            _reads.remove(slot);
          }
        });
    _reads[slot] = read;
    return read;
  }

  Future<void> put(String slot, String signature, int width, int height, Uint8List encodedBytes) {
    if (signature.length != 64 || width <= 0 || height <= 0 || encodedBytes.isEmpty) {
      return Future.value();
    }
    final previous = _writes[slot] ?? Future.value();
    final write = previous.then((_) async {
      try {
        final directory = await _getDirectory();
        final file = File(path.join(directory.path, _fileName(slot)));
        final bytes = Uint8List(_headerBytes + encodedBytes.lengthInBytes);
        bytes.setRange(0, 8, ascii.encode(_magic));
        final header = ByteData.sublistView(bytes, 8, 16);
        header.setUint32(0, width, Endian.little);
        header.setUint32(4, height, Endian.little);
        bytes.setRange(16, 80, ascii.encode(signature));
        bytes.setRange(_headerBytes, bytes.length, encodedBytes);
        final temporary = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
        await temporary.writeAsBytes(bytes, flush: false);
        if (await file.exists()) {
          await file.delete();
        }
        await temporary.rename(file.path);
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
    return trackedWrite;
  }

  Future<void> remove(String slot) async {
    final _ = _reads.remove(slot);
    try {
      final directory = await _getDirectory();
      await File(path.join(directory.path, _fileName(slot))).delete();
    } catch (_) {
      // A stale entry is harmless; the next successful write replaces it.
    }
  }

  Future<void> _trim(Directory directory) async {
    try {
      final files = await directory
          .list()
          .where((entity) => entity is File && entity.path.endsWith('.png'))
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

Future<void> _removeLegacyDenseCacheWhenReady(Directory support, Directory current) async {
  try {
    final hasNoCurrentCache = await current
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.png'))
        .isEmpty;
    if (hasNoCurrentCache) {
      return;
    }
    await Directory(path.join(support.path, 'inhouse_year_panels_v3')).delete(recursive: true);
  } catch (_) {
    // The legacy cache may already have been removed or be in use by an older
    // process; either case is safe and the new cache remains independent.
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

  // ThumbHash is already a smooth DCT placeholder; nearest-neighbour expansion
  // avoids another expensive filter pass before the real thumbnail arrives.
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
  static const int _chunkSize = 8192;
  static const int _maxResidentChunks = 3;
  static const int _maxResidentRows = 48;

  final LinkedHashMap<int, Future<List<BaseAsset>>> _chunks = LinkedHashMap();
  final Map<int, List<BaseAsset>> _resolvedChunks = {};
  final LinkedHashMap<(int, int), Future<List<BaseAsset>>> _rows = LinkedHashMap();
  final LinkedHashMap<(int, int), List<BaseAsset>> _resolvedRows = LinkedHashMap();
  int _revision = -1;

  void _resetIfNeeded(TimelineService service) {
    if (_revision == service.revision) {
      return;
    }
    _revision = service.revision;
    _chunks.clear();
    _resolvedChunks.clear();
    _rows.clear();
    _resolvedRows.clear();
  }

  List<BaseAsset>? getRow(TimelineService service, {required int index, required int count}) {
    _resetIfNeeded(service);
    if (count <= 0) {
      return const [];
    }
    final rowKey = (index, count);
    final resolvedRow = _resolvedRows.remove(rowKey);
    if (resolvedRow != null) {
      _resolvedRows[rowKey] = resolvedRow;
      return resolvedRow;
    }
    final result = <BaseAsset>[];
    var cursor = index;
    final end = index + count;
    while (cursor < end) {
      final chunkStart = (cursor ~/ _chunkSize) * _chunkSize;
      final chunk = _resolvedChunks[chunkStart];
      if (chunk == null) {
        return null;
      }
      final offset = cursor - chunkStart;
      final take = math.min(end - cursor, chunk.length - offset);
      if (take <= 0) {
        return null;
      }
      result.addAll(chunk.getRange(offset, offset + take));
      cursor += take;
    }
    return result;
  }

  Future<List<BaseAsset>> loadRow(TimelineService service, {required int index, required int count}) {
    _resetIfNeeded(service);
    if (count <= 0) {
      return Future.value(const []);
    }

    final rowKey = (index, count);
    final resolvedRow = _resolvedRows.remove(rowKey);
    if (resolvedRow != null) {
      _resolvedRows[rowKey] = resolvedRow;
      return Future.value(resolvedRow);
    }
    final existing = _rows.remove(rowKey);
    if (existing != null) {
      _rows[rowKey] = existing;
      return existing;
    }

    final expectedRevision = _revision;
    late final Future<List<BaseAsset>> future;
    future = _loadRow(service, index: index, count: count).then(
      (assets) {
        if (_revision == expectedRevision && identical(_rows[rowKey], future)) {
          _resolvedRows[rowKey] = assets;
        }
        return assets;
      },
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_rows[rowKey], future)) {
          _rows.remove(rowKey);
          _resolvedRows.remove(rowKey);
        }
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    _rows[rowKey] = future;
    while (_rows.length > _maxResidentRows) {
      final oldest = _rows.keys.first;
      _rows.remove(oldest);
      _resolvedRows.remove(oldest);
    }
    return future;
  }

  Future<List<BaseAsset>> _loadRow(TimelineService service, {required int index, required int count}) async {
    final end = index + count;
    final loadedChunks = <int, List<BaseAsset>>{};
    var cursor = index;
    while (cursor < end) {
      final chunkStart = (cursor ~/ _chunkSize) * _chunkSize;
      loadedChunks[chunkStart] = await _loadChunk(service, chunkStart);
      cursor = math.min(end, chunkStart + _chunkSize);
    }

    final result = <BaseAsset>[];
    cursor = index;
    while (cursor < end) {
      final chunkStart = (cursor ~/ _chunkSize) * _chunkSize;
      final chunk = loadedChunks[chunkStart];
      if (chunk == null) {
        throw StateError('Dense timeline chunk was evicted before the row was assembled');
      }
      final offset = cursor - chunkStart;
      final take = math.min(end - cursor, chunk.length - offset);
      if (take <= 0) {
        throw StateError('Dense timeline row is outside the current revision');
      }
      result.addAll(chunk.getRange(offset, offset + take));
      cursor += take;
    }
    return result;
  }

  Future<List<BaseAsset>> _loadChunk(TimelineService service, int chunkStart) {
    final resolved = _resolvedChunks[chunkStart];
    if (resolved != null) {
      final existing = _chunks.remove(chunkStart);
      if (existing != null) {
        _chunks[chunkStart] = existing;
      }
      return Future.value(resolved);
    }

    var future = _chunks.remove(chunkStart);
    if (future == null) {
      final expectedRevision = _revision;
      final available = service.totalAssets - chunkStart;
      if (available <= 0) {
        return Future.error(RangeError('Dense timeline chunk is outside the current revision'));
      }
      final count = math.min(_chunkSize, available);
      future = service
          .loadAssets(chunkStart, count)
          .then(
            (assets) {
              if (_revision == expectedRevision && _chunks.containsKey(chunkStart)) {
                _resolvedChunks[chunkStart] = assets;
              }
              return assets;
            },
            onError: (Object error, StackTrace stackTrace) {
              _chunks.remove(chunkStart);
              _resolvedChunks.remove(chunkStart);
              Error.throwWithStackTrace(error, stackTrace);
            },
          );
    }
    _chunks[chunkStart] = future;
    while (_chunks.length > _maxResidentChunks) {
      final oldest = _chunks.keys.first;
      _chunks.remove(oldest);
      _resolvedChunks.remove(oldest);
    }
    return future;
  }
}

class _DenseAtlasPersistenceQueue {
  static const int _maxPending = 8;
  final LinkedHashMap<String, _DenseAtlasPersistenceTask> _pending = LinkedHashMap();
  bool _active = false;

  void schedule({required String slot, required String signature, required ui.Image image}) {
    final snapshot = image.clone();
    _pending.remove(slot)?.image.dispose();
    _pending[slot] = _DenseAtlasPersistenceTask(slot: slot, signature: signature, image: snapshot);
    while (_pending.length > _maxPending) {
      _pending.remove(_pending.keys.first)?.image.dispose();
    }
    _drain();
  }

  void trimPending() {
    while (_pending.length > 2) {
      _pending.remove(_pending.keys.first)?.image.dispose();
    }
  }

  void _drain() {
    if (_active || _pending.isEmpty) {
      return;
    }
    _active = true;
    final task = _pending.remove(_pending.keys.first)!;
    unawaited(
      _encode(task).whenComplete(() {
        _active = false;
        _drain();
      }),
    );
  }

  Future<void> _encode(_DenseAtlasPersistenceTask task) async {
    try {
      final data = await task.image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        return;
      }
      await _denseDiskAtlasCache.put(
        task.slot,
        task.signature,
        task.image.width,
        task.image.height,
        Uint8List.fromList(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)),
      );
    } catch (_) {
    } finally {
      task.image.dispose();
    }
  }
}

class _DenseAtlasPersistenceTask {
  final String slot;
  final String signature;
  final ui.Image image;

  const _DenseAtlasPersistenceTask({required this.slot, required this.signature, required this.image});
}

class FixedSegment extends Segment {
  final double tileHeight;
  final int columnCount;
  final int rowsPerChild;
  final double mainAxisExtend;
  final bool denseOverview;

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
    this.denseOverview = false,
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
      denseOverview: denseOverview,
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
    final timelineState = ref.watch(
      timelineStateProvider.select((state) => (isScrubbing: state.isScrubbing, isInteracting: state.isInteracting)),
    );
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

    if (timelineState.isScrubbing) {
      return _buildPlaceholder(context, ref, cacheSlot);
    }

    if (denseOverview) {
      return FutureBuilder<List<BaseAsset>>(
        future: denseStore!.loadRow(timelineService, index: assetIndex, count: assetCount),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return _buildPlaceholder(context, ref, cacheSlot);
          }
          return _buildAssetRow(context, ref, snapshot.requireData, timelineService, false, cacheSlot);
        },
      );
    }

    return FutureBuilder<List<BaseAsset>>(
      future: timelineService.loadAssets(assetIndex, assetCount),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _buildPlaceholder(context, ref, cacheSlot);
        }
        return _buildAssetRow(context, ref, snapshot.requireData, timelineService, isDynamicLayout, cacheSlot);
      },
    );
  }

  Widget _buildPlaceholder(BuildContext context, WidgetRef ref, String cacheSlot) {
    if (denseOverview && denseTimelineRowsPerChild(columnCount) > 1) {
      return _DenseCachedPanel(
        cacheSlot: cacheSlot,
        firstAssetIndex: assetIndex,
        itemCount: assetCount,
        columnCount: columnCount,
        tileExtent: tileHeight,
        onVisualReady: () => ref.read(timelineVisualReadyProvider).markReady(columnCount),
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
        key: ValueKey(Object.hash(cacheSlot, timelineService.hashCode)),
        assets: assets,
        firstAssetIndex: assetIndex,
        tileExtent: tileHeight,
        columnCount: columnCount,
        cacheSlot: cacheSlot,
        deferHighResolution: ref.read(timelineStateProvider).isInteracting,
        onVisualReady: () => ref.read(timelineVisualReadyProvider).markReady(columnCount),
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
      assetKey: timelineAssetLayoutKey(assetIndex),
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

/// Minimum number of physical pixels used by a dense overview cell. The old
/// 16px atlas was visibly blocky on high-density phone displays.
const int denseOverviewMetadataCellPixels = 32;

/// Hard upper bound for persisted overview atlases. Individual files are
/// compressed PNGs and the oldest generated panels are evicted when full.
const int denseOverviewDiskCacheLimitBytes = 256 * 1024 * 1024;

const int _denseThumbnailConcurrency = 3;
const int _denseMetadataAtlasConcurrency = 1;
const int _denseMetadataCellPixels = denseOverviewMetadataCellPixels;
// ui.Image.clone shares the underlying GPU texture, so keeping a wider rolling
// window here does not duplicate pixels. It prevents a fast fling from evicting
// every nearby panel and falling back to an asynchronous disk decode (visible
// as a brief blank row). Android memory-pressure callbacks still clear it.
const int _denseAtlasCacheBytes = 64 * 1024 * 1024;
const int _denseThumbTileCacheBytes = 8 * 1024 * 1024;
final _DenseThumbnailQueue _denseThumbnailQueue = _DenseThumbnailQueue();
final _DenseAsyncQueue _denseMetadataAtlasQueue = _DenseAsyncQueue(_denseMetadataAtlasConcurrency, maxPending: 48);
final _DenseRowAtlasCache _denseRowAtlasCache = _DenseRowAtlasCache();
final _DenseThumbTileCache _denseThumbTileCache = _DenseThumbTileCache();
final _DenseDiskAtlasCache _denseDiskAtlasCache = _DenseDiskAtlasCache();
final _DenseAtlasPersistenceQueue _denseAtlasPersistenceQueue = _DenseAtlasPersistenceQueue();
final _DenseAsyncQueue _denseWarmupQueue = _DenseAsyncQueue(1, maxPending: 4);
final Map<String, int> _denseWarmupRevisions = {};

/// Drops speculative overview work and LRU textures when the OS signals memory
/// pressure. Visible panels retain their own small atlas, so this does not turn
/// the current viewport blank while immediately releasing off-screen memory.
void releaseDenseTimelineMemory() {
  _denseThumbnailQueue.cancelPending();
  _denseMetadataAtlasQueue.cancelPending();
  _denseWarmupQueue.cancelPending();
  _denseAtlasPersistenceQueue.trimPending();
  _denseRowAtlasCache.clear();
  _denseThumbTileCache.clear();
}

/// Restores a small rolling window of persisted overview panels before the
/// sliver asks for them. This work is serialized and cancellable at the image
/// layer, so opening the gallery never competes with the first visible frame.
void warmDenseOverviewCache({required TimelineService service, required List<Segment> segments, int maxPanels = 2}) {
  var scheduled = 0;
  for (final segment in segments) {
    if (scheduled >= maxPanels) {
      break;
    }
    if (segment is! FixedSegment || !segment.denseOverview) {
      continue;
    }
    final rows = (segment.bucket.assetCount / segment.columnCount).ceil();
    final panelCount = (rows / segment.rowsPerChild).ceil();
    // Spread the warm window across the newest years instead of spending the
    // whole budget on a single very large year.
    final panelsForSegment = math.min(panelCount, 6);
    for (var panel = 0; panel < panelsForSegment && scheduled < maxPanels; panel++) {
      final rowIndex = panel * segment.rowsPerChild;
      final assetIndex = rowIndex * segment.columnCount;
      final assetCount = math.min(segment.columnCount * segment.rowsPerChild, segment.bucket.assetCount - assetIndex);
      if (assetCount <= 0) {
        continue;
      }
      final bucketPrefix = segment.bucket is TimeBucket
          ? (segment.bucket as TimeBucket).date.toUtc().microsecondsSinceEpoch.toString()
          : segment.firstAssetIndex.toString();
      final slot = '${service.origin.name}:$bucketPrefix:$rowIndex:${segment.columnCount}:$assetCount';
      final warmupKey = '${service.hashCode}:$slot';
      if (_denseWarmupRevisions[warmupKey] == service.revision) {
        continue;
      }
      _denseWarmupRevisions[warmupKey] = service.revision;
      scheduled++;
      final width = segment.columnCount * _denseMetadataCellPixels;
      final height = ((assetCount + segment.columnCount - 1) ~/ segment.columnCount) * _denseMetadataCellPixels;
      unawaited(
        _denseWarmupQueue
            .schedule(() async {
              final memoryKey = Object.hash('persistent-slot', slot);
              final existing = _denseRowAtlasCache.get(memoryKey);
              if (existing != null) {
                existing.dispose();
                return;
              }
              final entry = await _denseDiskAtlasCache.get(slot);
              if (entry == null || entry.width != width || entry.height != height) {
                return;
              }
              ui.Image? image;
              try {
                image = await _decodeDenseDiskAtlas(entry);
              } catch (_) {
                await _denseDiskAtlasCache.remove(slot);
              }
              if (image == null) {
                return;
              }
              _denseRowAtlasCache.put(memoryKey, image, signature: entry.signature);
              image.dispose();
            })
            .then<void>((_) {}, onError: (_, __) {}),
      );
    }
  }
}

class _DenseLoadCancelled implements Exception {
  const _DenseLoadCancelled();
}

class _DenseThumbnailQueue {
  static const int _maxPending = 384;
  final List<_DenseThumbnailTask> _pending = [];
  int _active = 0;

  _DenseThumbnailHandle schedule(Future<void> Function() task, {int priority = 1, void Function()? onDiscard}) {
    _pending.removeWhere((item) => item.cancelled);
    if (_pending.length >= _maxPending) {
      final lowestPriority = _pending.fold<int>(0, (value, item) => math.max(value, item.priority));
      final removeIndex = _pending.indexWhere((item) => item.priority == lowestPriority);
      if (removeIndex >= 0) {
        _pending.removeAt(removeIndex).discard();
      }
    }
    final item = _DenseThumbnailTask(task: task, priority: priority, sequence: _sequence++, onDiscard: onDiscard);
    final handle = _DenseThumbnailHandle(item);
    _pending.add(item);
    _drain();
    return handle;
  }

  int _sequence = 0;

  void cancelPending() {
    for (final item in _pending) {
      item.discard(notify: false);
    }
    _pending.clear();
  }

  void _drain() {
    while (_active < _denseThumbnailConcurrency && _pending.isNotEmpty) {
      _pending.sort((a, b) {
        final priority = a.priority.compareTo(b.priority);
        return priority == 0 ? a.sequence.compareTo(b.sequence) : priority;
      });
      final item = _pending.removeAt(0);
      final task = item.task;
      if (item.cancelled || task == null) {
        continue;
      }
      _active++;
      unawaited(
        Future<void>.sync(task).then<void>((_) {}, onError: (_, __) {}).whenComplete(() {
          item.release();
          _active--;
          _drain();
        }),
      );
    }
  }
}

class _DenseThumbnailTask {
  Future<void> Function()? task;
  final int priority;
  final int sequence;
  void Function()? onDiscard;
  bool cancelled = false;

  _DenseThumbnailTask({required this.task, required this.priority, required this.sequence, this.onDiscard});

  void discard({bool notify = true}) {
    if (cancelled) {
      return;
    }
    cancelled = true;
    task = null;
    if (notify) {
      final callback = onDiscard;
      onDiscard = null;
      callback?.call();
    } else {
      onDiscard = null;
    }
  }

  void release() {
    task = null;
    onDiscard = null;
  }
}

class _DenseThumbnailHandle {
  final _DenseThumbnailTask _task;

  const _DenseThumbnailHandle(this._task);

  void cancel() => _task.discard(notify: false);
}

class _DenseAsyncQueue {
  final int concurrency;
  final int maxPending;
  final Queue<_DenseAsyncTask> _pending = Queue();
  int _active = 0;

  _DenseAsyncQueue(this.concurrency, {this.maxPending = 64});

  Future<T> schedule<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    if (_pending.length >= maxPending) {
      _pending.removeFirst().cancel();
    }
    _pending.add(
      _DenseAsyncTask(
        run: () async {
          try {
            final result = await task();
            if (!completer.isCompleted) {
              completer.complete(result);
            }
          } catch (error, stackTrace) {
            if (!completer.isCompleted) {
              completer.completeError(error, stackTrace);
            }
          }
        },
        cancel: () {
          if (!completer.isCompleted) {
            completer.completeError(const _DenseLoadCancelled());
          }
        },
      ),
    );
    _drain();
    return completer.future;
  }

  void cancelPending() {
    while (_pending.isNotEmpty) {
      _pending.removeFirst().cancel();
    }
  }

  void _drain() {
    while (_active < concurrency && _pending.isNotEmpty) {
      final task = _pending.removeFirst();
      _active++;
      unawaited(
        Future<void>.sync(task.run).whenComplete(() {
          _active--;
          _drain();
        }),
      );
    }
  }
}

class _DenseAsyncTask {
  final Future<void> Function() run;
  final void Function() cancel;

  const _DenseAsyncTask({required this.run, required this.cancel});
}

class _DenseRowAtlasCache {
  final LinkedHashMap<Object, ui.Image> _images = LinkedHashMap();
  final Map<Object, String> _signatures = {};
  int _bytes = 0;

  ui.Image? get(Object key) {
    final image = _images.remove(key);
    if (image == null) {
      return null;
    }
    _images[key] = image;
    return image.clone();
  }

  String? signature(Object key) => _signatures[key];

  void put(Object key, ui.Image image, {String? signature}) {
    final previous = _images.remove(key);
    if (previous != null) {
      _bytes -= _imageBytes(previous);
      previous.dispose();
    }
    if (signature == null) {
      _signatures.remove(key);
    } else {
      _signatures[key] = signature;
    }
    final cached = image.clone();
    _images[key] = cached;
    _bytes += _imageBytes(cached);
    while (_bytes > _denseAtlasCacheBytes && _images.isNotEmpty) {
      final oldestKey = _images.keys.first;
      final oldest = _images.remove(oldestKey)!;
      _signatures.remove(oldestKey);
      _bytes -= _imageBytes(oldest);
      oldest.dispose();
    }
  }

  int _imageBytes(ui.Image image) => image.width * image.height * 4;

  void clear() {
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _signatures.clear();
    _bytes = 0;
  }
}

Future<ui.Image> _decodeDenseDiskAtlas(_DenseDiskAtlasEntry entry) async {
  final codec = await ui.instantiateImageCodec(entry.encodedBytes);
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

class _DenseCachedPanel extends StatefulWidget {
  final String cacheSlot;
  final int firstAssetIndex;
  final int itemCount;
  final int columnCount;
  final double tileExtent;
  final VoidCallback onVisualReady;

  const _DenseCachedPanel({
    required this.cacheSlot,
    required this.firstAssetIndex,
    required this.itemCount,
    required this.columnCount,
    required this.tileExtent,
    required this.onVisualReady,
  });

  @override
  State<_DenseCachedPanel> createState() => _DenseCachedPanelState();
}

class _DenseCachedPanelState extends State<_DenseCachedPanel> {
  ui.Image? _atlas;
  int _generation = 0;
  bool _didReportVisualReady = false;

  Object get _memoryKey => Object.hash('persistent-slot', widget.cacheSlot);

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void didUpdateWidget(covariant _DenseCachedPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cacheSlot != widget.cacheSlot ||
        oldWidget.firstAssetIndex != widget.firstAssetIndex ||
        oldWidget.columnCount != widget.columnCount ||
        oldWidget.itemCount != widget.itemCount) {
      _atlas?.dispose();
      _atlas = null;
      _didReportVisualReady = false;
      _restore();
    }
  }

  void _reportVisualReady() {
    if (_didReportVisualReady || _atlas == null) {
      return;
    }
    _didReportVisualReady = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _atlas != null) {
        widget.onVisualReady();
      }
    });
  }

  Future<void> _restore() async {
    final generation = ++_generation;
    final cacheSlot = widget.cacheSlot;
    final memoryKey = _memoryKey;
    final expectedWidth = widget.columnCount * _denseMetadataCellPixels;
    final expectedHeight = (widget.itemCount / widget.columnCount).ceil() * _denseMetadataCellPixels;
    final memory = _denseRowAtlasCache.get(memoryKey);
    if (memory != null) {
      if (mounted && generation == _generation) {
        setState(() => _atlas = memory);
        _reportVisualReady();
      } else {
        memory.dispose();
      }
      return;
    }
    final entry = await _denseDiskAtlasCache.get(cacheSlot);
    if (entry == null || entry.width != expectedWidth || entry.height != expectedHeight) {
      return;
    }
    ui.Image? image;
    try {
      image = await _decodeDenseDiskAtlas(entry);
    } catch (_) {
      await _denseDiskAtlasCache.remove(cacheSlot);
    }
    if (image == null) {
      return;
    }
    if (!mounted || generation != _generation) {
      image.dispose();
      return;
    }
    _denseRowAtlasCache.put(memoryKey, image, signature: entry.signature);
    setState(() => _atlas = image);
    _reportVisualReady();
  }

  Matrix4? _globalToLocalTransform() {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) {
      return null;
    }
    return Matrix4.tryInvert(renderObject.getTransformTo(null));
  }

  @override
  Widget build(BuildContext context) {
    final rowCount = (widget.itemCount / widget.columnCount).ceil();
    final textDirection = Directionality.of(context);
    final layoutTransition = TimelineLayoutTransitionScope.maybeOf(context);
    final assetKeys = [
      for (var index = 0; index < widget.itemCount; index++) timelineAssetLayoutKey(widget.firstAssetIndex + index),
    ];
    final paintSurface = CustomPaint(
      size: Size(double.infinity, rowCount * widget.tileExtent),
      isComplex: true,
      willChange: layoutTransition?.animation.value != 1,
      painter: _DenseAssetRowPainter(
        images: const [],
        atlas: _atlas,
        assetKeys: assetKeys,
        columnCount: widget.columnCount,
        tileExtent: widget.tileExtent,
        textDirection: textDirection,
        layoutAnimation: layoutTransition?.animation,
        previousRects: layoutTransition?.previousRects ?? const {},
        globalToLocalTransform: _globalToLocalTransform,
        repaint: const _NeverNotifyListenable(),
      ),
    );
    return TimelineVisualReadyMarker(
      columnCount: widget.columnCount,
      ready: _atlas != null,
      child: TimelineDenseAssetLayoutMarker(
        assetKeys: assetKeys,
        columnCount: widget.columnCount,
        tileExtent: widget.tileExtent,
        textDirection: textDirection,
        child: layoutTransition?.previousRects.isNotEmpty ?? false
            ? paintSurface
            : RepaintBoundary(child: paintSurface),
      ),
    );
  }

  @override
  void dispose() {
    _generation++;
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

  void clear() {
    _tiles.clear();
    _bytes = 0;
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
  final bool deferHighResolution;
  final VoidCallback onVisualReady;
  final _DenseAssetTap onAssetTap;

  const _DenseAssetRow({
    super.key,
    required this.assets,
    required this.firstAssetIndex,
    required this.tileExtent,
    required this.columnCount,
    required this.cacheSlot,
    required this.deferHighResolution,
    required this.onVisualReady,
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
  int _finishedActualCount = 0;
  int _actualWorkGeneration = 0;
  int _generation = 0;
  bool _didReportVisualReady = false;
  final Set<int> _actualThumbnailRequests = {};
  final Set<_DenseThumbnailHandle> _thumbnailHandles = {};

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
    } else if (oldWidget.deferHighResolution != widget.deferHighResolution) {
      if (widget.deferHighResolution) {
        _cancelActualThumbnailWork();
      } else {
        _queueMissingActualThumbnails();
      }
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
    _finishedActualCount = 0;
    _actualWorkGeneration++;
    _atlasBuilding = false;
    _instantOverview = usesInstantDenseTimelineAtlas(widget.columnCount);
    _persistentExact = false;
    _baseAtlasReady = false;
    _atlasTargetPixels = atlasTargetPixels;
    _requiredActualCount = 0;
    _actualThumbnailRequests.clear();
    _didReportVisualReady = false;

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
    final completeSignature = _denseRowAtlasCache.signature(_completeAtlasKey);
    final completeAtlas = _denseRowAtlasCache.get(_completeAtlasKey);
    if (completeAtlas != null && completeSignature == _contentSignature) {
      _replaceAtlas(completeAtlas);
      _persistentExact = true;
      _baseAtlasReady = true;
      _scheduleRepaint();
      return;
    }
    completeAtlas?.dispose();
    final cachedSignature = _denseRowAtlasCache.signature(atlasKey);
    final cachedAtlas = _denseRowAtlasCache.get(atlasKey);
    if (cachedAtlas != null && cachedSignature == _contentSignature) {
      _replaceAtlas(cachedAtlas);
      _baseAtlasReady = true;
      _scheduleRepaint();
    } else {
      cachedAtlas?.dispose();
    }
    final positionalSignature = _denseRowAtlasCache.signature(_slotAtlasKey);
    final positionalAtlas = _denseRowAtlasCache.get(_slotAtlasKey);
    var restoredFromSlot = false;
    if (positionalAtlas != null && (_atlas == null || positionalSignature == _contentSignature)) {
      _replaceAtlas(positionalAtlas);
      restoredFromSlot = true;
      _scheduleRepaint();
    } else {
      positionalAtlas?.dispose();
    }
    if (restoredFromSlot && positionalSignature == _contentSignature) {
      _persistentExact = true;
      _baseAtlasReady = true;
      _denseRowAtlasCache.put(_completeAtlasKey, _atlas!, signature: _contentSignature);
      return;
    }
    unawaited(
      _restorePersistentThenBuild(
        thumbnailTargetPixels,
        atlasTargetPixels,
        atlasKey,
        generation,
        skipDiskRestore: restoredFromSlot && positionalSignature != null,
      ),
    );
  }

  String _denseContentIdentity() {
    final buffer = StringBuffer('v3:${widget.columnCount}:${widget.assets.length};');
    for (final asset in widget.assets) {
      buffer
        ..write(asset.remoteId ?? asset.localId ?? asset.checksum ?? asset.heroTag)
        ..write(':')
        ..write(asset.updatedAt.toUtc().microsecondsSinceEpoch)
        ..write(':')
        ..write(asset.width ?? 0)
        ..write('x')
        ..write(asset.height ?? 0)
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
    int generation, {
    required bool skipDiskRestore,
  }) async {
    if (!skipDiskRestore) {
      final entry = await _denseDiskAtlasCache.get(widget.cacheSlot);
      if (!mounted || generation != _generation) {
        return;
      }
      final rows = (widget.assets.length / widget.columnCount).ceil();
      if (entry != null &&
          entry.width == widget.columnCount * atlasTargetPixels &&
          entry.height == rows * atlasTargetPixels) {
        ui.Image? image;
        try {
          image = await _decodeDenseDiskAtlas(entry);
        } catch (_) {
          await _denseDiskAtlasCache.remove(widget.cacheSlot);
        }
        if (image != null) {
          if (!mounted || generation != _generation) {
            image.dispose();
            return;
          }
          final restoredImage = image;
          setState(() => _replaceAtlas(restoredImage));
          _denseRowAtlasCache.put(_slotAtlasKey, restoredImage, signature: entry.signature);
          if (entry.signature == _contentSignature) {
            _persistentExact = true;
            _baseAtlasReady = true;
            _denseRowAtlasCache.put(_completeAtlasKey, restoredImage, signature: _contentSignature);
            return;
          }
        }
      }
    }

    if (_instantOverview) {
      unawaited(_buildThumbhashAtlas(atlasTargetPixels, atlasKey, generation));
    }
    if (!widget.deferHighResolution) {
      _queueMissingActualThumbnails(
        thumbnailTargetPixels: thumbnailTargetPixels,
        atlasKey: atlasKey,
        generation: generation,
      );
    }
  }

  void _queueMissingActualThumbnails({int? thumbnailTargetPixels, int? atlasKey, int? generation}) {
    if (_persistentExact || widget.deferHighResolution || !mounted) {
      return;
    }
    final targetPixels =
        thumbnailTargetPixels ??
        denseTimelineTargetPixels(tileExtent: widget.tileExtent, devicePixelRatio: _devicePixelRatio ?? 1);
    final targetAtlasKey =
        atlasKey ??
        Object.hash(
          _instantOverview ? 'thumbhash' : 'thumbnail',
          _atlasTargetPixels,
          widget.columnCount,
          Object.hashAll(widget.assets.map((asset) => asset.heroTag)),
        );
    final targetGeneration = generation ?? _generation;
    for (var index = 0; index < widget.assets.length; index++) {
      // Remote ThumbHashes are already complete visual previews at this tiny
      // scale. Only assets without one (normally new local-only photos) need
      // an individual decode, and those decodes run only while scrolling is idle.
      if (_thumbHashFor(widget.assets[index]) != null) {
        continue;
      }
      _requestActualThumbnail(
        index,
        targetPixels,
        targetAtlasKey,
        targetGeneration,
        priority: index < widget.columnCount * 2 ? 0 : 1,
      );
    }
  }

  void _requestActualThumbnail(int index, int targetPixels, int atlasKey, int generation, {int priority = 1}) {
    if (!_actualThumbnailRequests.add(index)) {
      return;
    }
    _requiredActualCount++;
    final actualWorkGeneration = _actualWorkGeneration;
    _thumbnailHandles.add(
      _denseThumbnailQueue.schedule(
        () async {
          try {
            await _loadAssetImage(index, targetPixels, atlasKey, generation, actualWorkGeneration);
          } finally {
            _finishActualThumbnail(atlasKey, generation, actualWorkGeneration);
          }
        },
        priority: priority,
        onDiscard: () => _finishActualThumbnail(atlasKey, generation, actualWorkGeneration),
      ),
    );
  }

  void _finishActualThumbnail(int atlasKey, int generation, int actualWorkGeneration) {
    if (mounted && generation == _generation && actualWorkGeneration == _actualWorkGeneration) {
      _finishedActualCount++;
      _maybeBuildCompositeAtlas(atlasKey, generation);
    }
  }

  void _replaceAtlas(ui.Image image) {
    if (identical(_atlas, image)) {
      return;
    }
    _atlas?.dispose();
    _atlas = image;
    _reportVisualReady();
  }

  void _reportVisualReady() {
    if (_didReportVisualReady || (_atlas == null && !_images.any((image) => image != null))) {
      return;
    }
    _didReportVisualReady = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && (_atlas != null || _images.any((image) => image != null))) {
        widget.onVisualReady();
      }
    });
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
        } else if (tile == null && hashes[index] != null && !widget.deferHighResolution) {
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

      // A panel can already have a good atlas from the disk/LRU cache while
      // this metadata rebuild is finishing. Replacing it with a newer atlas
      // that has transparent cells for local assets causes a one-frame flash
      // (the actual thumbnail arrives a moment later). Keep the visible base
      // atlas and let the idle thumbnail upgrade merge into it instead.
      final keepExistingAtlas =
          _baseAtlasReady &&
          _atlas != null &&
          _atlas!.width == targetPixels * widget.columnCount &&
          _atlas!.height == targetPixels * (hashes.length / widget.columnCount).ceil();
      if (keepExistingAtlas) {
        atlas.dispose();
        if (_requiredActualCount == 0) {
          _persistentExact = true;
          _denseRowAtlasCache.put(_completeAtlasKey, _atlas!, signature: _contentSignature);
          _denseRowAtlasCache.put(_slotAtlasKey, _atlas!, signature: _contentSignature);
          unawaited(_persistAtlas(_atlas!));
        }
        _maybeBuildCompositeAtlas(atlasKey, generation);
        return;
      }

      _denseRowAtlasCache.put(atlasKey, atlas, signature: _contentSignature);
      setState(() {
        _replaceAtlas(atlas);
        _baseAtlasReady = true;
      });
      if (_requiredActualCount == 0) {
        _persistentExact = true;
        _denseRowAtlasCache.put(_completeAtlasKey, atlas, signature: _contentSignature);
        _denseRowAtlasCache.put(_slotAtlasKey, atlas, signature: _contentSignature);
        unawaited(_persistAtlas(atlas));
      } else {
        // Persist the metadata texture as an immediate next-launch fallback,
        // but mark it as provisional so missing local tiles are still upgraded
        // after the view becomes idle.
        unawaited(_persistAtlas(atlas, exact: false));
      }
      _maybeBuildCompositeAtlas(atlasKey, generation);
    } on _DenseLoadCancelled {
      return;
    } catch (_) {
      if (!mounted || generation != _generation) {
        return;
      }
      if (!widget.deferHighResolution) {
        for (var index = 0; index < hashes.length; index++) {
          _requestActualThumbnail(index, targetPixels, atlasKey, generation, priority: 0);
        }
      }
    }
  }

  Future<void> _loadAssetImage(
    int index,
    int targetPixels,
    int atlasKey,
    int generation,
    int actualWorkGeneration,
  ) async {
    if (!mounted ||
        generation != _generation ||
        actualWorkGeneration != _actualWorkGeneration ||
        _persistentExact ||
        (!_instantOverview && _atlas != null)) {
      return;
    }
    final asset = widget.assets[index];
    // Dense overview upgrades are opportunistic. A failed cloud request must
    // not occupy the queue with retries while the user is scrolling offline;
    // ThumbHash or the persisted atlas remains the instant fallback.
    final maxAttempts = _instantOverview ? 1 : 3;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final provider = await _providerForAttempt(
          asset,
          targetPixels,
          useFullThumbnail: !_instantOverview && attempt == 2,
        );
        if (provider == null ||
            !mounted ||
            generation != _generation ||
            actualWorkGeneration != _actualWorkGeneration) {
          return;
        }
        final image = await _resolveImage(index, provider);
        if (!mounted || generation != _generation || actualWorkGeneration != _actualWorkGeneration) {
          image.dispose();
          return;
        }
        _acceptImage(index, image, targetPixels, atlasKey, generation);
        return;
      } on _DenseLoadCancelled {
        return;
      } catch (_) {
        if (attempt + 1 < maxAttempts &&
            mounted &&
            generation == _generation &&
            actualWorkGeneration == _actualWorkGeneration) {
          await Future<void>.delayed(Duration(milliseconds: attempt == 0 ? 180 : 650));
        }
      }
    }

    if (actualWorkGeneration != _actualWorkGeneration) {
      return;
    }
    if (asset case RemoteAsset(thumbHash: final hash?) when hash.isNotEmpty) {
      try {
        final image = await _resolveImage(index, ThumbHashProvider(thumbHash: hash));
        if (!mounted || generation != _generation || actualWorkGeneration != _actualWorkGeneration) {
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
    _reportVisualReady();
    _scheduleRepaint();
    if (_instantOverview) {
      if (_finishedActualCount == _requiredActualCount &&
          _loadedCount == _requiredActualCount &&
          !_baseAtlasReady &&
          _requiredActualCount == widget.assets.length) {
        unawaited(_buildAtlas(targetPixels, atlasKey, generation));
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
        _finishedActualCount == _requiredActualCount &&
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
    final isComplete = _loadedCount == _requiredActualCount;
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
      _atlasBuilding = false;
      return;
    }
    if (isComplete) {
      _denseRowAtlasCache.put(_completeAtlasKey, atlas, signature: _contentSignature);
    }
    _denseRowAtlasCache.put(_slotAtlasKey, atlas, signature: isComplete ? _contentSignature : ''.padLeft(64, '0'));
    setState(() {
      _replaceAtlas(atlas);
      _persistentExact = isComplete;
      _baseAtlasReady = true;
      for (var index = 0; index < _images.length; index++) {
        _images[index]?.dispose();
        _images[index] = null;
      }
      _atlasBuilding = false;
    });
    unawaited(_persistAtlas(atlas, exact: isComplete));
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
    if (useFullThumbnail && !_instantOverview) {
      return normalProvider;
    }
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
      _atlasBuilding = false;
      return;
    }
    _denseRowAtlasCache.put(atlasKey, atlas, signature: _contentSignature);
    _denseRowAtlasCache.put(_slotAtlasKey, atlas, signature: _contentSignature);
    setState(() {
      _replaceAtlas(atlas);
      _persistentExact = true;
      _baseAtlasReady = true;
      for (var index = 0; index < _images.length; index++) {
        _images[index]?.dispose();
        _images[index] = null;
      }
      _atlasBuilding = false;
    });
    unawaited(_persistAtlas(atlas));
  }

  Future<void> _persistAtlas(ui.Image atlas, {bool exact = true}) {
    _denseAtlasPersistenceQueue.schedule(
      slot: widget.cacheSlot,
      signature: exact ? _contentSignature : ''.padLeft(64, '0'),
      image: atlas,
    );
    return Future.value();
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

  void _cancelActualThumbnailWork() {
    _actualWorkGeneration++;
    for (final handle in _thumbnailHandles) {
      handle.cancel();
    }
    _thumbnailHandles.clear();
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
      _images[index]?.dispose();
    }
    _images = List<ImageInfo?>.filled(widget.assets.length, null);
    _streams = List<ImageStream?>.filled(widget.assets.length, null);
    _listeners = List<ImageStreamListener?>.filled(widget.assets.length, null);
    _completers = List<Completer<ImageInfo>?>.filled(widget.assets.length, null);
    _loadedCount = 0;
    _finishedActualCount = 0;
    _requiredActualCount = 0;
    _actualThumbnailRequests.clear();
  }

  void _unsubscribeFromImages({bool preserveAtlas = false}) {
    _generation++;
    _cancelActualThumbnailWork();
    _images = const [];
    _streams = const [];
    _listeners = const [];
    _completers = const [];
    if (!preserveAtlas) {
      _atlas?.dispose();
      _atlas = null;
    }
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

  Matrix4? _globalToLocalTransform() {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) {
      return null;
    }
    return Matrix4.tryInvert(renderObject.getTransformTo(null));
  }

  @override
  Widget build(BuildContext context) {
    final textDirection = Directionality.of(context);
    final rowCount = (widget.assets.length / widget.columnCount).ceil();
    final layoutTransition = TimelineLayoutTransitionScope.maybeOf(context);
    final assetKeys = [
      for (var index = 0; index < widget.assets.length; index++) timelineAssetLayoutKey(widget.firstAssetIndex + index),
    ];
    final paintSurface = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) => _handleTap(details, textDirection),
      child: CustomPaint(
        size: Size(double.infinity, rowCount * widget.tileExtent),
        isComplex: true,
        willChange: layoutTransition?.animation.value != 1,
        painter: _DenseAssetRowPainter(
          images: _images,
          atlas: _atlas,
          assetKeys: assetKeys,
          columnCount: widget.columnCount,
          tileExtent: widget.tileExtent,
          textDirection: textDirection,
          layoutAnimation: layoutTransition?.animation,
          previousRects: layoutTransition?.previousRects ?? const {},
          globalToLocalTransform: _globalToLocalTransform,
          repaint: _repaint,
        ),
      ),
    );
    return TimelineVisualReadyMarker(
      columnCount: widget.columnCount,
      ready: _atlas != null || _images.any((image) => image != null),
      child: TimelineDenseAssetLayoutMarker(
        assetKeys: assetKeys,
        columnCount: widget.columnCount,
        tileExtent: widget.tileExtent,
        textDirection: textDirection,
        child: layoutTransition?.previousRects.isNotEmpty ?? false
            ? paintSurface
            : RepaintBoundary(child: paintSurface),
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
  final List<Object> assetKeys;
  final int columnCount;
  final double tileExtent;
  final TextDirection textDirection;
  final Animation<double>? layoutAnimation;
  final Map<Object, Rect> previousRects;
  final Matrix4? Function() globalToLocalTransform;

  Float32List? _atlasSourceRects;
  Float32List? _atlasTransforms;
  Float64List? _startLeft;
  Float64List? _startTop;
  Float64List? _startExtent;
  Float64List? _endLeft;
  Float64List? _endTop;

  _DenseAssetRowPainter({
    required this.images,
    required this.atlas,
    required this.assetKeys,
    required this.columnCount,
    required this.tileExtent,
    required this.textDirection,
    required this.layoutAnimation,
    required this.previousRects,
    required this.globalToLocalTransform,
    required Listenable repaint,
  }) : super(repaint: Listenable.merge([repaint, if (layoutAnimation != null) layoutAnimation]));

  int get itemCount => assetKeys.length;

  Rect _currentRect(int index, Size size) => calculateTimelineDenseAssetRect(
    index: index,
    columnCount: columnCount,
    tileExtent: tileExtent,
    containerWidth: size.width,
    textDirection: textDirection,
  );

  void _prepareAtlasReflow(Size size, ui.Image atlas) {
    if (_atlasTransforms != null) {
      return;
    }

    final inverseTransform = globalToLocalTransform();
    final sourceRows = (itemCount / columnCount).ceil();
    final sourceWidth = atlas.width / columnCount;
    final sourceHeight = atlas.height / sourceRows;
    _atlasSourceRects = Float32List(itemCount * 4);
    _atlasTransforms = Float32List(itemCount * 4);
    _startLeft = Float64List(itemCount);
    _startTop = Float64List(itemCount);
    _startExtent = Float64List(itemCount);
    _endLeft = Float64List(itemCount);
    _endTop = Float64List(itemCount);

    for (var index = 0; index < itemCount; index++) {
      final current = _currentRect(index, size);
      final previousGlobal = previousRects[assetKeys[index]];
      final previous = previousGlobal != null && inverseTransform != null
          ? MatrixUtils.transformRect(inverseTransform, previousGlobal)
          : current;
      _startLeft![index] = previous.left;
      _startTop![index] = previous.top;
      _startExtent![index] = previous.width;
      _endLeft![index] = current.left;
      _endTop![index] = current.top;

      final sourceColumn = index % columnCount;
      final sourceRow = index ~/ columnCount;
      final offset = index * 4;
      _atlasSourceRects![offset] = sourceColumn * sourceWidth;
      _atlasSourceRects![offset + 1] = sourceRow * sourceHeight;
      _atlasSourceRects![offset + 2] = (sourceColumn + 1) * sourceWidth;
      _atlasSourceRects![offset + 3] = (sourceRow + 1) * sourceHeight;
    }
  }

  Rect _reflowRect(int index, double progress, Size size) {
    final startLeft = _startLeft;
    if (startLeft == null) {
      return _currentRect(index, size);
    }
    final extent = _startExtent![index] + ((tileExtent - _startExtent![index]) * progress);
    return Rect.fromLTWH(
      startLeft[index] + ((_endLeft![index] - startLeft[index]) * progress),
      _startTop![index] + ((_endTop![index] - _startTop![index]) * progress),
      extent,
      extent,
    );
  }

  void _paintReflowAtlas(Canvas canvas, Size size, ui.Image atlas, double progress) {
    _prepareAtlasReflow(size, atlas);
    final transforms = _atlasTransforms!;
    final sourceRects = _atlasSourceRects!;
    final sourceWidth = atlas.width / columnCount;
    final sourceHeight = atlas.height / (itemCount / columnCount).ceil();
    final sourceExtent = math.min(sourceWidth, sourceHeight);

    for (var index = 0; index < itemCount; index++) {
      final visualRect = _reflowRect(index, progress, size);
      final scale = visualRect.width / sourceExtent;
      final sourceOffset = index * 4;
      final sourceCenterX = (sourceRects[sourceOffset] + sourceRects[sourceOffset + 2]) * 0.5;
      final sourceCenterY = (sourceRects[sourceOffset + 1] + sourceRects[sourceOffset + 3]) * 0.5;
      transforms[sourceOffset] = scale;
      transforms[sourceOffset + 1] = 0;
      transforms[sourceOffset + 2] = visualRect.center.dx - (scale * sourceCenterX);
      transforms[sourceOffset + 3] = visualRect.center.dy - (scale * sourceCenterY);
    }

    canvas.drawRawAtlas(
      atlas,
      transforms,
      sourceRects,
      null,
      null,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final atlas = this.atlas;
    final animationProgress = layoutAnimation?.value ?? 1;
    final isReflowing = previousRects.isNotEmpty && animationProgress < 1;
    final reflowProgress = isReflowing ? timelineLayoutTransitionProgress(animationProgress) : 1.0;
    if (atlas != null) {
      if (isReflowing) {
        _paintReflowAtlas(canvas, size, atlas, reflowProgress);
      } else {
        final rowCount = (itemCount / columnCount).ceil();
        final left = textDirection == TextDirection.rtl ? size.width - (columnCount * tileExtent) : 0.0;
        canvas.drawImageRect(
          atlas,
          Rect.fromLTWH(0, 0, atlas.width.toDouble(), atlas.height.toDouble()),
          Rect.fromLTWH(left, 0, columnCount * tileExtent, rowCount * tileExtent),
          Paint()..filterQuality = FilterQuality.low,
        );
      }
    }
    for (var index = 0; index < images.length; index++) {
      final image = images[index]?.image;
      if (image == null) {
        continue;
      }
      paintImage(
        canvas: canvas,
        rect: isReflowing ? _reflowRect(index, reflowProgress, size) : _currentRect(index, size),
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
      oldDelegate.assetKeys != assetKeys ||
      oldDelegate.columnCount != columnCount ||
      oldDelegate.tileExtent != tileExtent ||
      oldDelegate.textDirection != textDirection ||
      oldDelegate.layoutAnimation != layoutAnimation ||
      oldDelegate.previousRects != previousRects;
}
