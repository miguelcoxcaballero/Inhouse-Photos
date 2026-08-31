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
  final visibleRows = (viewportHeight / tileExtent).ceil();
  final requestedAssets = (visibleRows + 8) * columnCount;
  var chunkSize = kTimelineAssetLoadBatchSize;
  while (chunkSize < requestedAssets && chunkSize < 2048) {
    chunkSize *= 2;
  }
  return chunkSize;
}

/// Physical pixels a batched grid cell must own so that every display pixel it
/// covers is backed by real image data instead of an upscaled preview.
int denseTimelineTargetPixels({required double tileExtent, required double devicePixelRatio}) =>
    math.max(batchedGridMetadataCellPixels, (tileExtent * devicePixelRatio).ceil());

/// Cell size of the instant ThumbHash fallback texture.
///
/// A ThumbHash only carries a handful of DCT coefficients, so expanding it to
/// the full physical cell size costs up to sixteen times the memory and isolate
/// transfer for no additional detail. The fallback is therefore built small and
/// upscaled by the painter, while the real thumbnails are composited at
/// [denseTimelineTargetPixels].
int denseTimelineMetadataPixels(int targetPixels) => math.min(targetPixels, batchedGridMetadataCellPixels);

/// Whether every cell of a panel has to be replaced by a real thumbnail.
///
/// A cell is upgraded once its physical size is meaningfully larger than the
/// detail a ThumbHash carries. At the two densest levels a tile is roughly 25
/// physical pixels on a phone, which the fallback texture already covers at
/// full resolution, and upgrading them would mean several thousand thumbnail
/// requests for a single screen. Cells with no ThumbHash at all are always
/// upgraded, at every zoom level.
bool denseTimelineNeedsThumbnailUpgrade(int targetPixels) => targetPixels >= (batchedGridMetadataCellPixels * 3) ~/ 2;

int denseTimelineRowsPerChild(int columnCount) => switch (columnCount) {
  >= 48 => 4,
  >= 36 => 6,
  >= 24 => 6,
  >= 12 => 8,
  _ => 1,
};

class _DenseAtlasPixelsResult {
  final Uint8List pixels;
  final List<bool> covered;

  const _DenseAtlasPixelsResult(this.pixels, this.covered);
}

@visibleForTesting
bool denseTimelineMetadataCoverageIsComplete(List<bool> covered) => covered.every((cell) => cell);

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
  static const _maxBytes = batchedGridDiskCacheLimitBytes;
  static const _trimToBytes = 224 * 1024 * 1024;

  Future<Directory?>? _directory;
  final Map<String, Future<_DenseDiskAtlasEntry?>> _reads = {};
  final Map<String, Future<void>> _writes = {};

  String _fileName(String slot) => '${sha256.convert(utf8.encode(slot))}.png';

  /// Resolves the panel cache directory, or null when the platform cannot give
  /// one. Resolving to null rather than throwing keeps a device without usable
  /// support storage on the in-memory path instead of turning every panel read
  /// and write into an error the callers have to unwind.
  Future<Directory?> _getDirectory() => _directory ??= () async {
    try {
      final support = await getApplicationSupportDirectory();
      final directory = Directory(path.join(support.path, 'inhouse_grid_panels_v5'));
      await directory.create(recursive: true);
      // v3 stored uncompressed RGBA. Keep it during the first v4 generation so
      // an interrupted upgrade never destroys the previous offline cache; once
      // at least one v4 panel exists, remove the legacy cache on a later launch.
      unawaited(_removeLegacyDenseCacheWhenReady(support, directory));
      unawaited(_trim(directory));
      return directory;
    } catch (_) {
      return null;
    }
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
            if (directory == null) {
              return null;
            }
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
        if (directory == null) {
          return;
        }
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
      if (directory == null) {
        return;
      }
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
  int placeholderColor = 0,
}) {
  final columns = columnCount;
  final rows = (hashes.length / columns).ceil();
  final atlasWidth = columns * targetPixels;
  final atlas = Uint8List(atlasWidth * rows * targetPixels * 4);
  final covered = List<bool>.filled(hashes.length, false);
  // A cell nobody can fill must still read as an empty tile rather than as a
  // hole punched through the gallery, so occupied cells fall back to an opaque
  // placeholder while the real thumbnail is resolved.
  final placeholder = placeholderColor == 0 ? null : _solidThumbnailTile(placeholderColor, targetPixels);

  for (var index = 0; index < hashes.length; index++) {
    final hash = hashes[index];
    Uint8List? tile;
    if (hash != null && hash.isNotEmpty) {
      try {
        tile = _decodeThumbhashSquare(base64Decode(hash), targetPixels);
        covered[index] = true;
      } catch (_) {
        // A malformed hash is filled later by the normal thumbnail path.
      }
    }

    tile ??= placeholder;
    if (tile == null) {
      continue;
    }
    for (var y = 0; y < targetPixels; y++) {
      final destinationX = (index % columns) * targetPixels;
      final destinationY = (index ~/ columns) * targetPixels + y;
      final destinationOffset = (destinationY * atlasWidth + destinationX) * 4;
      final tileOffset = y * targetPixels * 4;
      atlas.setRange(destinationOffset, destinationOffset + targetPixels * 4, tile, tileOffset);
    }
  }

  return _DenseAtlasPixelsResult(atlas, covered);
}

Uint8List _solidThumbnailTile(int rgba, int size) {
  final tile = Uint8List(size * size * 4);
  for (var offset = 0; offset < tile.length; offset += 4) {
    tile[offset] = (rgba >> 24) & 0xFF;
    tile[offset + 1] = (rgba >> 16) & 0xFF;
    tile[offset + 2] = (rgba >> 8) & 0xFF;
    tile[offset + 3] = rgba & 0xFF;
  }
  return tile;
}

/// Starts the CPU-heavy placeholder work from a top-level lexical scope.
///
/// Keeping this wrapper outside the widget State is important: an Isolate.run
/// callback nested in a State method can retain the outer closure context,
/// including the unsendable Element/render tree, even when its body appears to
/// reference only local variables.
Future<_DenseAtlasPixelsResult> _buildDenseThumbhashAtlasInBackground({
  required List<String?> hashes,
  required int targetPixels,
  required int columnCount,
  required int placeholderColor,
}) => Isolate.run(
  // Only the hash strings cross the isolate boundary. Sending pre-decoded RGBA
  // tiles here copied several megabytes per panel on the platform thread and
  // was the dominant cost of generating a batched grid screen.
  () => _buildDenseThumbhashAtlas(hashes, targetPixels, columnCount: columnCount, placeholderColor: placeholderColor),
);

Uint8List buildDenseThumbhashAtlasPixels(
  List<String?> hashes,
  int targetPixels, {
  int? columnCount,
  int placeholderColor = 0,
}) {
  return _buildDenseThumbhashAtlas(
    hashes,
    targetPixels,
    columnCount: columnCount ?? hashes.length,
    placeholderColor: placeholderColor,
  ).pixels;
}

final Expando<_DenseAssetChunkStore> _denseAssetStores = Expando<_DenseAssetChunkStore>();

class _DenseAssetChunkStore {
  static const int _chunkSize = 2048;
  static const int _maxResidentChunks = 4;
  static const int _maxResidentRows = 128;

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
  static const int _maxPending = 4;
  final LinkedHashMap<String, _DenseAtlasPersistenceTask> _pending = LinkedHashMap();
  bool _active = false;
  bool _appVisible = true;
  Timer? _foregroundDrainTimer;

  void setAppVisible(bool visible) {
    if (_appVisible == visible) {
      return;
    }
    _appVisible = visible;
    if (!visible) {
      _foregroundDrainTimer?.cancel();
      _foregroundDrainTimer = null;
      _drain();
    }
  }

  void schedule({
    required String slot,
    required String signature,
    required ui.Image image,
    required bool allowWhileVisible,
  }) {
    final snapshot = image.clone();
    _pending.remove(slot)?.image.dispose();
    _pending[slot] = _DenseAtlasPersistenceTask(
      slot: slot,
      signature: signature,
      image: snapshot,
      allowWhileVisible: allowWhileVisible,
    );
    while (_pending.length > _maxPending) {
      _pending.remove(_pending.keys.first)?.image.dispose();
    }
    if (_appVisible && allowWhileVisible) {
      _scheduleForegroundDrain();
    } else {
      _drain();
    }
  }

  void trimPending() {
    while (_pending.length > 1) {
      _pending.remove(_pending.keys.first)?.image.dispose();
    }
  }

  void _drain() {
    if (_active || _pending.isEmpty) {
      return;
    }
    String? slot;
    if (_appVisible) {
      slot = _pending.entries.firstWhereOrNull((entry) => entry.value.allowWhileVisible)?.key;
      if (slot == null) {
        return;
      }
    } else {
      slot = _pending.keys.first;
    }
    _active = true;
    final task = _pending.remove(slot)!;
    unawaited(
      _encode(task).whenComplete(() {
        _active = false;
        if (_appVisible) {
          _scheduleForegroundDrain(delay: const Duration(milliseconds: 450));
        } else {
          _drain();
        }
      }),
    );
  }

  void _scheduleForegroundDrain({Duration delay = const Duration(milliseconds: 900)}) {
    if (_foregroundDrainTimer != null || !_appVisible || !_pending.values.any((task) => task.allowWhileVisible)) {
      return;
    }
    _foregroundDrainTimer = Timer(delay, () {
      _foregroundDrainTimer = null;
      _drain();
    });
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
  final bool allowWhileVisible;

  const _DenseAtlasPersistenceTask({
    required this.slot,
    required this.signature,
    required this.image,
    required this.allowWhileVisible,
  });
}

class FixedSegment extends Segment {
  final double tileHeight;
  final int columnCount;
  final int rowsPerChild;
  final double mainAxisExtend;
  final bool batchedGrid;

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
    this.batchedGrid = false,
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
  Key childKey(int index) {
    final relativeIndex = index - firstIndex;
    final bucketIdentity = switch (bucket) {
      TimeBucket(date: final date) => '${date.year}-${date.month}-${date.day}',
      _ => '${bucket.runtimeType}:$firstAssetIndex',
    };
    return ValueKey<String>('fixed:$bucketIdentity:$columnCount:$relativeIndex');
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
      batchedGrid: batchedGrid,
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
  final bool batchedGrid;
  final String denseCacheSlot;

  const _FixedSegmentRow({
    required this.assetIndex,
    required this.assetCount,
    required this.tileHeight,
    required this.spacing,
    required this.columnCount,
    required this.batchedGrid,
    required this.denseCacheSlot,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timelineState = ref.watch(
      timelineStateProvider.select((state) => (isScrubbing: state.isScrubbing, isInteracting: state.isInteracting)),
    );
    final timelineService = ref.read(timelineServiceProvider);
    final cacheSlot = '${timelineService.origin.name}:$denseCacheSlot';

    if (batchedGrid) {
      return _buildBatchedPanel(
        context,
        ref,
        timelineService,
        cacheSlot,
        isInteracting: timelineState.isInteracting,
        isScrubbing: timelineState.isScrubbing,
      );
    }

    final isDynamicLayout = columnCount <= (context.isMobile ? 2 : 3);

    // Prefer the service's freshly coalesced navigation window. Previously a
    // dense row started an 8,192-asset preload before checking this buffer, so
    // every three-photo backup batch launched a redundant giant database read.
    if (timelineService.hasRange(assetIndex, assetCount)) {
      return _buildAssetRow(
        context,
        ref,
        timelineService.getAssets(assetIndex, assetCount),
        timelineService,
        isDynamicLayout,
      );
    }

    if (timelineState.isScrubbing) {
      return _buildPlaceholder(context);
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

  /// Builds the batched grid panel without ever changing the widget type at
  /// this position in the tree.
  ///
  /// A separate placeholder widget used to take over whenever the assets were
  /// not resident yet, or while the scrubber was active. Every swap discarded
  /// the panel element together with its atlas and its in-flight thumbnail
  /// work, which is what made the batched grid blink and reload the same
  /// panels repeatedly. The panel now simply receives a null asset list and
  /// keeps painting whatever texture it already has.
  Widget _buildBatchedPanel(
    BuildContext context,
    WidgetRef ref,
    TimelineService timelineService,
    String cacheSlot, {
    required bool isInteracting,
    required bool isScrubbing,
  }) {
    final denseStore = _denseAssetStores[timelineService] ??= _DenseAssetChunkStore();
    final resident = timelineService.hasRange(assetIndex, assetCount)
        ? timelineService.getAssets(assetIndex, assetCount)
        : denseStore.getRow(timelineService, index: assetIndex, count: assetCount);

    return FutureBuilder<List<BaseAsset>>(
      initialData: resident,
      // Scrubbing flies past thousands of rows; starting a database read for
      // each one only delays the rows the finger actually lands on.
      future: resident != null || isScrubbing
          ? null
          : denseStore.loadRow(timelineService, index: assetIndex, count: assetCount),
      builder: (context, snapshot) => _DenseAssetRow(
        key: ValueKey(Object.hash(cacheSlot, timelineService.hashCode)),
        assets: snapshot.data,
        itemCount: assetCount,
        firstAssetIndex: assetIndex,
        tileExtent: tileHeight,
        columnCount: columnCount,
        cacheSlot: cacheSlot,
        deferHighResolution: isInteracting,
        onVisualReady: () {},
        onAssetTap: (index, asset) => _openAsset(context, ref, index, asset),
      ),
    );
  }

  Widget _buildPlaceholder(BuildContext context) =>
      SegmentBuilder.buildPlaceholder(context, assetCount, size: Size.square(tileHeight), spacing: spacing);

  Widget _buildAssetRow(
    BuildContext context,
    WidgetRef ref,
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
          onTap: lockSelection ? null : () => _handleOnTap(context, ref, assetIndex, asset, heroOffset),
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

/// Minimum number of physical pixels used by a batched grid cell. The old
/// 16px atlas was visibly blocky on high-density phone displays.
const int batchedGridMetadataCellPixels = 32;

/// Hard upper bound for persisted batched-grid atlases. Individual files are
/// compressed PNGs and the oldest generated panels are evicted when full.
const int batchedGridDiskCacheLimitBytes = 256 * 1024 * 1024;

// Small native thumbnails are inexpensive, but keeping this bounded prevents
// a fast fling from competing with raster/UI work on mid-range phones.
const int _denseThumbnailConcurrency = 4;
const int _denseMetadataAtlasConcurrency = 2;
// ui.Image.clone shares the underlying GPU texture, so keeping a wider rolling
// window here does not duplicate pixels. It prevents a fast fling from evicting
// every nearby panel and falling back to an asynchronous disk decode (visible
// as a brief blank row). Android memory-pressure callbacks still clear it.
const int _denseAtlasCacheBytes = 64 * 1024 * 1024;
final _DenseThumbnailQueue _denseThumbnailQueue = _DenseThumbnailQueue();
final DenseTimelineTaskQueue _denseMetadataAtlasQueue = DenseTimelineTaskQueue(
  _denseMetadataAtlasConcurrency,
  maxPending: 128,
);
final _DenseRowAtlasCache _denseRowAtlasCache = _DenseRowAtlasCache();
final _DenseDiskAtlasCache _denseDiskAtlasCache = _DenseDiskAtlasCache();
final _DenseAtlasPersistenceQueue _denseAtlasPersistenceQueue = _DenseAtlasPersistenceQueue();

/// Prevents speculative PNG serialization from consuming foreground raster
/// time. Pending atlases are flushed only after the app leaves the screen.
void setDenseTimelineAppVisible(bool visible) => _denseAtlasPersistenceQueue.setAppVisible(visible);

/// Drops speculative grid work and LRU textures when the OS signals memory
/// pressure. Visible panels retain their own small atlas, so this does not turn
/// the current viewport blank while immediately releasing off-screen memory.
void releaseDenseTimelineMemory() {
  _denseThumbnailQueue.cancelPending();
  _denseMetadataAtlasQueue.cancelPending();
  _denseAtlasPersistenceQueue.trimPending();
  _denseRowAtlasCache.clear();
}

class _DenseLoadCancelled implements Exception {
  final bool retry;

  const _DenseLoadCancelled({this.retry = false});
}

class _DenseThumbnailQueue {
  // A whole batched-grid screen can legitimately want a few thousand cells, so
  // the queue is ordered by a heap instead of re-sorting a list on every
  // dequeue. Re-sorting made scheduling quadratic and stalled the UI isolate
  // exactly when the gallery was trying to fill in.
  static const int _maxPending = 4096;
  final HeapPriorityQueue<_DenseThumbnailTask> _pending = HeapPriorityQueue(_compareTasks);
  int _active = 0;
  int _sequence = 0;

  static int _compareTasks(_DenseThumbnailTask a, _DenseThumbnailTask b) {
    final priority = a.priority.compareTo(b.priority);
    return priority == 0 ? a.sequence.compareTo(b.sequence) : priority;
  }

  _DenseThumbnailHandle schedule(Future<void> Function() task, {int priority = 1, void Function()? onDiscard}) {
    final item = _DenseThumbnailTask(task: task, priority: priority, sequence: _sequence++, onDiscard: onDiscard);
    final handle = _DenseThumbnailHandle(item);
    if (_pending.length >= _maxPending) {
      // Dropping the newest request keeps the already-prioritised backlog
      // intact; the owning panel re-queues what is still missing once it has
      // drained.
      item.discard();
      return handle;
    }
    _pending.add(item);
    _drain();
    return handle;
  }

  void cancelPending() {
    for (final item in _pending.toUnorderedList()) {
      item.discard(notify: false);
    }
    _pending.clear();
  }

  void _drain() {
    while (_active < _denseThumbnailConcurrency && _pending.isNotEmpty) {
      final item = _pending.removeFirst();
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

/// A small priority queue used by the dense gallery's atlas decoder.
///
/// Kept public for focused scheduler regression tests. Lower priority values
/// represent panels nearer the centre of the visible viewport.
@visibleForTesting
class DenseTimelineTaskQueue {
  final int concurrency;
  final int maxPending;
  final List<_DenseAsyncTask> _pending = [];
  int _active = 0;
  int _sequence = 0;

  DenseTimelineTaskQueue(this.concurrency, {this.maxPending = 64}) : assert(concurrency > 0), assert(maxPending > 0);

  Future<T> schedule<T>(Future<T> Function() task, {int priority = 0}) {
    final completer = Completer<T>();
    final queued = _DenseAsyncTask(
      priority: priority,
      sequence: _sequence++,
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
      cancel: (retry) {
        if (!completer.isCompleted) {
          completer.completeError(_DenseLoadCancelled(retry: retry));
        }
      },
    );
    if (_pending.length >= maxPending) {
      var worstIndex = 0;
      for (var index = 1; index < _pending.length; index++) {
        final candidate = _pending[index];
        final worst = _pending[worstIndex];
        if (candidate.priority > worst.priority ||
            (candidate.priority == worst.priority && candidate.sequence > worst.sequence)) {
          worstIndex = index;
        }
      }
      final worst = _pending[worstIndex];
      if (queued.priority < worst.priority) {
        _pending.removeAt(worstIndex).cancel(true);
      } else {
        queued.cancel(true);
        return completer.future;
      }
    }
    _pending.add(queued);
    _drain();
    return completer.future;
  }

  void cancelPending() {
    while (_pending.isNotEmpty) {
      _pending.removeLast().cancel(false);
    }
  }

  void _drain() {
    while (_active < concurrency && _pending.isNotEmpty) {
      _pending.sort((a, b) {
        final priority = a.priority.compareTo(b.priority);
        return priority != 0 ? priority : a.sequence.compareTo(b.sequence);
      });
      final task = _pending.removeAt(0);
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
  final int priority;
  final int sequence;
  final Future<void> Function() run;
  final void Function(bool retry) cancel;

  const _DenseAsyncTask({required this.priority, required this.sequence, required this.run, required this.cancel});
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

/// Paints a virtualized grid panel in one layer. At 48 columns, four rows are
/// collapsed into one state object, one gesture recognizer, and one render
/// object instead of 192 individual tiles or four independent row loaders.
///
/// [assets] is null while the rows this panel covers are still being read from
/// the database. The panel then keeps painting whatever texture it already
/// restored instead of being replaced by a separate placeholder widget, which
/// is what used to make the batched grid blink on every scroll and scrub.
class _DenseAssetRow extends StatefulWidget {
  final List<BaseAsset>? assets;
  final int itemCount;
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
    required this.itemCount,
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
  static const int _offscreenPriority = 1 << 20;
  static const int _maxUpgradeAttempts = 3;
  static const Duration _compositeDebounce = Duration(milliseconds: 700);
  static const Duration _upgradeRetryDelay = Duration(milliseconds: 900);

  final ValueNotifier<int> _repaint = ValueNotifier(0);
  late List<Object> _assetKeys;
  List<ImageInfo?> _images = const [];
  List<ImageStream?> _streams = const [];
  List<ImageStreamListener?> _listeners = const [];
  List<Completer<ImageInfo>?> _completers = const [];
  ui.Image? _atlas;
  // What the currently painted texture actually contains, so a coarse
  // fallback can never replace a finished full-resolution panel.
  String? _atlasSignature;
  int? _atlasCellPixels;
  double? _devicePixelRatio;
  int _placeholderColor = 0;
  bool _repaintScheduled = false;
  bool _metadataAtlasRequested = false;
  Timer? _metadataRetryTimer;
  Timer? _compositeTimer;
  Timer? _upgradeRetryTimer;
  bool _atlasBuilding = false;
  bool _compositeDirty = false;
  int _targetPixels = batchedGridMetadataCellPixels;
  int _metadataPixels = batchedGridMetadataCellPixels;
  int _completeAtlasKey = 0;
  int _baseAtlasKey = 0;
  late Object _slotAtlasKey;
  String _contentSignature = '';
  bool _persistentExact = false;
  bool _baseAtlasReady = false;
  int _upgradeAttempts = 0;
  int _actualWorkGeneration = 0;
  int _generation = 0;
  bool _didReportVisualReady = false;
  final Set<int> _upgradeIndexes = {};
  final Set<int> _pendingIndexes = {};
  final Set<int> _mergedIndexes = {};
  final Set<_DenseThumbnailHandle> _thumbnailHandles = {};

  int get _rowCount => (widget.itemCount / widget.columnCount).ceil();

  String get _provisionalSignature => ''.padLeft(64, '0');

  @override
  void initState() {
    super.initState();
    _updateAssetKeys();
    _slotAtlasKey = Object.hash('persistent-slot', widget.cacheSlot);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    // The placeholder only fills cells that have neither a ThumbHash nor a
    // resolvable thumbnail, so a theme switch updates it for future panels
    // rather than reloading every atlas in the gallery.
    _placeholderColor = _rgbaOf(context.colorScheme.surfaceContainerHighest);
    if (_devicePixelRatio == devicePixelRatio) {
      return;
    }
    _devicePixelRatio = devicePixelRatio;
    _resetPanel();
  }

  @override
  void didUpdateWidget(covariant _DenseAssetRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.firstAssetIndex != widget.firstAssetIndex || oldWidget.itemCount != widget.itemCount) {
      _updateAssetKeys();
    }
    if (oldWidget.cacheSlot != widget.cacheSlot) {
      _slotAtlasKey = Object.hash('persistent-slot', widget.cacheSlot);
    }
    if (oldWidget.cacheSlot != widget.cacheSlot ||
        oldWidget.tileExtent != widget.tileExtent ||
        oldWidget.columnCount != widget.columnCount ||
        oldWidget.itemCount != widget.itemCount ||
        !_sameAssets(oldWidget.assets, widget.assets)) {
      _resetPanel();
    } else if (oldWidget.deferHighResolution && !widget.deferHighResolution) {
      _queueVisibleOverviewWork();
    }
  }

  void _updateAssetKeys() {
    _assetKeys = List<Object>.generate(
      widget.itemCount,
      (index) => timelineAssetLayoutKey(widget.firstAssetIndex + index),
      growable: false,
    );
  }

  bool _sameAssets(List<BaseAsset>? previous, List<BaseAsset>? next) {
    if (previous == null || next == null) {
      return previous == null && next == null;
    }
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

  int _rgbaOf(Color color) {
    final argb = color.toARGB32();
    return ((argb << 8) | ((argb >> 24) & 0xFF)) & 0xFFFFFFFF;
  }

  /// Cell size of [image] when it belongs to this panel, otherwise null.
  ///
  /// Two sizes are legitimate: the small instant ThumbHash texture and the
  /// full physical resolution composite. Anything else is left over from a
  /// different zoom level or display and must not be painted.
  int? _cellPixelsOf(ui.Image image) => _cellPixelsForSize(image.width, image.height);

  int? _cellPixelsForSize(int width, int height) {
    final rows = _rowCount;
    if (rows <= 0 || widget.columnCount <= 0) {
      return null;
    }
    for (final candidate in <int>{_targetPixels, _metadataPixels}) {
      if (width == widget.columnCount * candidate && height == rows * candidate) {
        return candidate;
      }
    }
    return null;
  }

  ({ui.Image image, int cellPixels, String? signature})? _takeCachedAtlas(Object key) {
    final signature = _denseRowAtlasCache.signature(key);
    final image = _denseRowAtlasCache.get(key);
    if (image == null) {
      return null;
    }
    final cellPixels = _cellPixelsOf(image);
    if (cellPixels == null) {
      image.dispose();
      return null;
    }
    return (image: image, cellPixels: cellPixels, signature: signature);
  }

  /// Rebuilds every derived key and restarts the loading pipeline.
  ///
  /// Only ever called from `didChangeDependencies`/`didUpdateWidget`, where a
  /// build always follows, so the synchronous cache hits deliberately avoid
  /// `setState` and repaint through the painter's listenable instead.
  void _resetPanel() {
    _unsubscribeFromImages(preserveAtlas: true);
    final generation = _generation;
    _targetPixels = denseTimelineTargetPixels(tileExtent: widget.tileExtent, devicePixelRatio: _devicePixelRatio ?? 1);
    _metadataPixels = denseTimelineMetadataPixels(_targetPixels);
    _persistentExact = false;
    _baseAtlasReady = false;
    _metadataAtlasRequested = false;
    _upgradeAttempts = 0;
    _upgradeIndexes.clear();
    _pendingIndexes.clear();
    _mergedIndexes.clear();
    _didReportVisualReady = false;

    final assets = widget.assets;
    if (assets == null) {
      _contentSignature = '';
      _baseAtlasKey = 0;
      _completeAtlasKey = 0;
      _images = const [];
      _streams = const [];
      _listeners = const [];
      _completers = const [];
      if (_atlas == null) {
        final slot = _takeCachedAtlas(_slotAtlasKey);
        if (slot != null) {
          _replaceAtlas(slot.image, signature: slot.signature, cellPixels: slot.cellPixels);
          _scheduleRepaint();
        } else {
          unawaited(_restoreSlotAtlasFromDisk(generation));
        }
      }
      return;
    }

    _images = List<ImageInfo?>.filled(assets.length, null);
    _streams = List<ImageStream?>.filled(assets.length, null);
    _listeners = List<ImageStreamListener?>.filled(assets.length, null);
    _completers = List<Completer<ImageInfo>?>.filled(assets.length, null);
    _contentSignature = sha256.convert(utf8.encode(_denseContentIdentity(assets))).toString();
    final identity = Object.hashAll(assets.map((asset) => asset.heroTag));
    _baseAtlasKey = Object.hash('dense-base', _metadataPixels, widget.columnCount, identity);
    _completeAtlasKey = Object.hash('dense-complete', _targetPixels, widget.columnCount, identity);
    final upgradeEveryCell = denseTimelineNeedsThumbnailUpgrade(_targetPixels);
    for (var index = 0; index < assets.length; index++) {
      // Cells whose ThumbHash already covers the physical cell need no network
      // or disk round trip; everything else must be backed by a real thumbnail
      // before the panel can be considered final.
      if (upgradeEveryCell || _thumbHashFor(assets[index]) == null) {
        _upgradeIndexes.add(index);
      }
    }

    // The texture kept across this reset is already the finished panel for
    // exactly this content, so nothing has to be reloaded or recomposited.
    if (_atlasIsFinalForContent) {
      _persistentExact = true;
      _baseAtlasReady = true;
      _mergedIndexes.addAll(_upgradeIndexes);
      _denseRowAtlasCache.put(_completeAtlasKey, _atlas!, signature: _contentSignature);
      return;
    }

    final complete = _takeCachedAtlas(_completeAtlasKey);
    if (complete != null) {
      if (complete.signature == _contentSignature && complete.cellPixels == _targetPixels) {
        _replaceAtlas(complete.image, signature: _contentSignature, cellPixels: complete.cellPixels);
        _persistentExact = true;
        _baseAtlasReady = true;
        _mergedIndexes.addAll(_upgradeIndexes);
        _scheduleRepaint();
        return;
      }
      complete.image.dispose();
    }

    final base = _takeCachedAtlas(_baseAtlasKey);
    if (base != null) {
      if (base.signature == _contentSignature && _atlasSignature != _contentSignature) {
        _replaceAtlas(base.image, signature: _contentSignature, cellPixels: base.cellPixels);
        _baseAtlasReady = true;
        _scheduleRepaint();
      } else {
        _baseAtlasReady = _baseAtlasReady || base.signature == _contentSignature;
        base.image.dispose();
      }
    }

    var restoredFromSlot = false;
    if (_atlas == null) {
      final slot = _takeCachedAtlas(_slotAtlasKey);
      if (slot != null) {
        _replaceAtlas(slot.image, signature: slot.signature, cellPixels: slot.cellPixels);
        restoredFromSlot = true;
        _scheduleRepaint();
        if (slot.signature == _contentSignature) {
          _baseAtlasReady = true;
          if (slot.cellPixels == _targetPixels) {
            _persistentExact = true;
            _mergedIndexes.addAll(_upgradeIndexes);
            _denseRowAtlasCache.put(_completeAtlasKey, _atlas!, signature: _contentSignature);
            return;
          }
        }
      }
    }

    unawaited(_restoreThenBuild(generation, skipDiskRestore: restoredFromSlot));
  }

  /// Paints the last texture stored for this grid position while the assets
  /// themselves are still loading.
  Future<void> _restoreSlotAtlasFromDisk(int generation) async {
    final entry = await _denseDiskAtlasCache.get(widget.cacheSlot);
    if (!mounted || generation != _generation || _atlas != null || entry == null) {
      return;
    }
    if (_cellPixelsForSize(entry.width, entry.height) == null) {
      return;
    }
    final image = await _decodeDiskAtlas(entry);
    if (image == null) {
      return;
    }
    if (!mounted || generation != _generation || _atlas != null) {
      image.dispose();
      return;
    }
    _denseRowAtlasCache.put(_slotAtlasKey, image, signature: entry.signature);
    setState(
      () => _replaceAtlas(image, signature: entry.signature, cellPixels: _cellPixelsForSize(entry.width, entry.height)),
    );
  }

  Future<ui.Image?> _decodeDiskAtlas(_DenseDiskAtlasEntry entry) async {
    try {
      return await _decodeDenseDiskAtlas(entry);
    } catch (_) {
      await _denseDiskAtlasCache.remove(widget.cacheSlot);
      return null;
    }
  }

  Future<void> _restoreThenBuild(int generation, {required bool skipDiskRestore}) async {
    if (!skipDiskRestore) {
      final entry = await _denseDiskAtlasCache.get(widget.cacheSlot);
      if (!mounted || generation != _generation) {
        return;
      }
      final cellPixels = entry == null ? null : _cellPixelsForSize(entry.width, entry.height);
      if (entry != null && cellPixels != null) {
        final image = await _decodeDiskAtlas(entry);
        if (!mounted || generation != _generation) {
          image?.dispose();
          return;
        }
        if (image != null) {
          setState(() => _replaceAtlas(image, signature: entry.signature, cellPixels: cellPixels));
          _denseRowAtlasCache.put(_slotAtlasKey, image, signature: entry.signature);
          if (entry.signature == _contentSignature) {
            _baseAtlasReady = true;
            if (cellPixels == _targetPixels) {
              _persistentExact = true;
              _mergedIndexes.addAll(_upgradeIndexes);
              _denseRowAtlasCache.put(_completeAtlasKey, image, signature: _contentSignature);
              return;
            }
          }
        }
      }
    }

    _queueVisibleOverviewWork(generation: generation);
  }

  String _denseContentIdentity(List<BaseAsset> assets) {
    // v6 invalidates atlases from builds that expanded the ThumbHash fallback
    // to the full cell size and could mark a partially upgraded panel final.
    final buffer = StringBuffer('v6:${widget.columnCount}:${assets.length}:$_targetPixels;');
    for (final asset in assets) {
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

  void _queueVisibleOverviewWork({int? generation}) {
    if (_persistentExact || !mounted || widget.assets == null) {
      return;
    }
    // A mounted dense row is already inside the sliver's viewport/cache
    // window. Custom sliver paint transforms can make its global rectangle
    // temporarily unavailable (or report no overlap), so visibility must only
    // affect priority — never whether the atlas is generated at all.
    final priority = _viewportPriority() ?? _offscreenPriority;
    final targetGeneration = generation ?? _generation;
    if (!_baseAtlasReady && !_metadataAtlasRequested) {
      _metadataAtlasRequested = true;
      unawaited(_buildThumbhashAtlas(targetGeneration, priority: priority));
    }
    _queueMissingActualThumbnails(generation: targetGeneration);
  }

  int? _viewportPriority() {
    final renderObject = context.findRenderObject();
    final mediaSize = MediaQuery.maybeSizeOf(context);
    if (renderObject is! RenderBox || !renderObject.attached || !renderObject.hasSize || mediaSize == null) {
      return null;
    }
    final panelRect = MatrixUtils.transformRect(renderObject.getTransformTo(null), Offset.zero & renderObject.size);
    final viewport = (Offset.zero & mediaSize).inflate(mediaSize.height * 0.2);
    if (!panelRect.overlaps(viewport)) {
      return null;
    }
    // Centre-most panels are the first ones a person sees after the pinch.
    // Distance-based priority prevents dozens of tiny day rows below the fold
    // from evicting the actual visible work from the bounded atlas queue.
    return (panelRect.center.dy - (mediaSize.height * 0.5)).abs().round();
  }

  void _queueMissingActualThumbnails({int? generation}) {
    final assets = widget.assets;
    if (_persistentExact || widget.deferHighResolution || assets == null || !mounted || _upgradeIndexes.isEmpty) {
      return;
    }
    final targetGeneration = generation ?? _generation;
    final panelPriority = _viewportPriority() ?? _offscreenPriority;
    for (final index in _upgradeIndexes) {
      if (_mergedIndexes.contains(index)) {
        continue;
      }
      _requestActualThumbnail(index, targetGeneration, priority: panelPriority + (index ~/ widget.columnCount));
    }
    _scheduleUpgradeRetry();
  }

  void _requestActualThumbnail(int index, int generation, {required int priority}) {
    if (!_pendingIndexes.add(index)) {
      return;
    }
    final actualWorkGeneration = _actualWorkGeneration;
    late final _DenseThumbnailHandle handle;

    void finish() {
      _thumbnailHandles.remove(handle);
      if (!mounted || generation != _generation || actualWorkGeneration != _actualWorkGeneration) {
        return;
      }
      _pendingIndexes.remove(index);
      _scheduleCompositeAtlas(generation);
    }

    handle = _denseThumbnailQueue.schedule(
      () async {
        try {
          await _loadAssetImage(index, generation, actualWorkGeneration);
        } finally {
          finish();
        }
      },
      priority: priority,
      onDiscard: finish,
    );
    _thumbnailHandles.add(handle);
  }

  /// Re-queues cells the bounded scheduler dropped, or that failed while the
  /// panel was off-screen, so a panel is never left permanently half upgraded.
  void _scheduleUpgradeRetry() {
    if (_persistentExact ||
        !mounted ||
        _upgradeRetryTimer != null ||
        _upgradeAttempts >= _maxUpgradeAttempts ||
        _mergedIndexes.containsAll(_upgradeIndexes)) {
      return;
    }
    _upgradeRetryTimer = Timer(_upgradeRetryDelay, () {
      _upgradeRetryTimer = null;
      if (!mounted || _persistentExact) {
        return;
      }
      if (_pendingIndexes.isNotEmpty || _atlasBuilding) {
        _scheduleUpgradeRetry();
        return;
      }
      if (widget.deferHighResolution || _viewportPriority() == null) {
        // Still off-screen or still being flung: try again later instead of
        // competing with the panels the person is actually looking at.
        _scheduleUpgradeRetry();
        return;
      }
      _upgradeAttempts++;
      if (_upgradeAttempts >= _maxUpgradeAttempts) {
        // Some assets simply cannot be resolved on this device. Bank the work
        // already done instead of re-decoding the whole panel forever.
        _finalizeAtlas(_generation, force: true);
        return;
      }
      _actualThumbnailRequestsReset();
      _queueMissingActualThumbnails();
    });
  }

  void _actualThumbnailRequestsReset() {
    // Bumping the work generation makes any request still in flight drop its
    // result instead of clearing an index the retry pass has just re-queued.
    _actualWorkGeneration++;
    _pendingIndexes.clear();
    for (final handle in _thumbnailHandles) {
      handle.cancel();
    }
    _thumbnailHandles.clear();
  }

  void _replaceAtlas(ui.Image image, {required String? signature, required int? cellPixels}) {
    _atlasSignature = signature;
    _atlasCellPixels = cellPixels;
    if (identical(_atlas, image)) {
      return;
    }
    _atlas?.dispose();
    _atlas = image;
    _reportVisualReady();
  }

  bool get _atlasIsFinalForContent =>
      _atlas != null && _atlasSignature == _contentSignature && _atlasCellPixels == _targetPixels;

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

  void _scheduleMetadataRetry({Duration delay = const Duration(milliseconds: 80)}) {
    if (_metadataRetryTimer != null || !mounted || _persistentExact || _baseAtlasReady) {
      return;
    }
    _metadataRetryTimer = Timer(delay, () {
      _metadataRetryTimer = null;
      if (mounted && !_metadataAtlasRequested) {
        _queueVisibleOverviewWork();
      }
    });
  }

  Future<void> _buildThumbhashAtlas(int generation, {required int priority}) async {
    final assets = widget.assets;
    if (assets == null || _persistentExact) {
      return;
    }
    final hashes = assets.map(_thumbHashFor).toList(growable: false);
    // Keep the isolate callback completely detached from this State object.
    // Reading `widget.columnCount` inside it implicitly captured `this`, which
    // made Isolate.run try to send the whole element/render tree and caused
    // every dense panel atlas to fail before it was generated.
    final columnCount = widget.columnCount;
    final metadataPixels = _metadataPixels;
    final placeholderColor = _placeholderColor;
    try {
      final result = await _denseMetadataAtlasQueue.schedule(() {
        if (!mounted || generation != _generation) {
          throw const _DenseLoadCancelled();
        }
        return _buildDenseThumbhashAtlasInBackground(
          hashes: hashes,
          targetPixels: metadataPixels,
          columnCount: columnCount,
          placeholderColor: placeholderColor,
        );
      }, priority: priority);
      if (!mounted || generation != _generation) {
        return;
      }
      for (var index = 0; index < result.covered.length; index++) {
        if (!result.covered[index]) {
          _upgradeIndexes.add(index);
        }
      }

      final atlas = await _rasterizeAtlasPixels(
        result.pixels,
        width: metadataPixels * columnCount,
        height: metadataPixels * (hashes.length / columnCount).ceil(),
      );
      if (!mounted || generation != _generation) {
        atlas.dispose();
        return;
      }

      // A panel can already have a good atlas from the disk/LRU cache while
      // this metadata rebuild is finishing. Replacing it with a newer, coarser
      // atlas causes a one-frame flash, so keep the visible base atlas and let
      // the thumbnail upgrade merge into it instead.
      if (_baseAtlasReady && _atlas != null) {
        atlas.dispose();
      } else {
        _denseRowAtlasCache.put(_baseAtlasKey, atlas, signature: _contentSignature);
        setState(() {
          _replaceAtlas(atlas, signature: _contentSignature, cellPixels: metadataPixels);
          _baseAtlasReady = true;
        });
        // Persist the fallback texture as an immediate next-launch paint, but
        // never mark it exact: its cells still have to be upgraded.
        unawaited(_persistAtlas(atlas, exact: false));
      }
      _queueMissingActualThumbnails(generation: generation);
      _scheduleCompositeAtlas(generation);
    } on _DenseLoadCancelled catch (error) {
      if (mounted && generation == _generation) {
        _metadataAtlasRequested = false;
        if (error.retry) {
          _scheduleMetadataRetry();
        }
      }
      return;
    } catch (_) {
      if (!mounted || generation != _generation) {
        return;
      }
      _metadataAtlasRequested = false;
      // A malformed hash, codec failure, or platform atlas error must never
      // leave the panel as a permanent empty surface. Resolve real cached
      // thumbnails while a later metadata-atlas retry repairs the fast path.
      _upgradeIndexes.addAll(Iterable<int>.generate(assets.length));
      _queueMissingActualThumbnails(generation: generation);
      _scheduleMetadataRetry(delay: const Duration(milliseconds: 180));
    }
  }

  Future<ui.Image> _rasterizeAtlasPixels(Uint8List pixels, {required int width, required int height}) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      rowBytes: width * 4,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final ui.Codec codec;
    final ui.FrameInfo frame;
    try {
      codec = await descriptor.instantiateCodec();
      try {
        frame = await codec.getNextFrame();
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
      buffer.dispose();
    }
    return frame.image;
  }

  Future<void> _loadAssetImage(int index, int generation, int actualWorkGeneration) async {
    final assets = widget.assets;
    if (!mounted ||
        generation != _generation ||
        actualWorkGeneration != _actualWorkGeneration ||
        _persistentExact ||
        assets == null ||
        index >= assets.length) {
      return;
    }
    final targetPixels = _targetPixels;
    final provider = _providerForAsset(assets[index], targetPixels);
    if (provider == null) {
      return;
    }
    final ImageInfo image;
    try {
      image = await _resolveImage(index, provider);
    } on _DenseLoadCancelled {
      return;
    } catch (_) {
      // The ThumbHash already painted in the base atlas remains the fallback;
      // the retry pass picks this cell up again once the panel settles.
      return;
    }
    if (!mounted || generation != _generation || actualWorkGeneration != _actualWorkGeneration) {
      image.dispose();
      return;
    }
    _acceptImage(index, image);
  }

  void _acceptImage(int index, ImageInfo image) {
    if (index >= _images.length) {
      image.dispose();
      return;
    }
    _images[index]?.dispose();
    _images[index] = image;
    _reportVisualReady();
    if (_atlas == null) {
      // Nothing else is painting this panel yet, so show the decoded cells
      // directly until the first atlas is composited.
      _scheduleRepaint();
    }
  }

  void _scheduleCompositeAtlas(int generation) {
    if (!mounted || generation != _generation || _persistentExact) {
      return;
    }
    if (!_images.any((image) => image != null)) {
      if (_pendingIndexes.isEmpty) {
        _finalizeAtlas(generation);
      }
      return;
    }
    _compositeDirty = true;
    if (_pendingIndexes.isEmpty) {
      _compositeTimer?.cancel();
      _compositeTimer = null;
      unawaited(_buildCompositeAtlas(generation));
      return;
    }
    // Merge partial progress on a timer so a large panel sharpens while the
    // rest of its thumbnails are still arriving, instead of staying blurry
    // until the very last cell resolves.
    _compositeTimer ??= Timer(_compositeDebounce, () {
      _compositeTimer = null;
      if (mounted && generation == _generation) {
        unawaited(_buildCompositeAtlas(generation));
      }
    });
  }

  Future<void> _buildCompositeAtlas(int generation) async {
    final assets = widget.assets;
    if (_atlasBuilding || _persistentExact || assets == null || !mounted || generation != _generation) {
      return;
    }
    if (!_images.any((image) => image != null)) {
      return;
    }
    _atlasBuilding = true;
    _compositeDirty = false;
    final targetPixels = _targetPixels;
    final rows = _rowCount;
    final width = targetPixels * widget.columnCount;
    final height = targetPixels * rows;
    final merged = <int>[];
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final source = _atlas;
    if (source != null) {
      // The fallback texture is deliberately small; scaling it up here is the
      // only place a ThumbHash is ever enlarged, and the cells that matter are
      // overwritten with real pixels immediately below.
      canvas.drawImageRect(
        source,
        Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..filterQuality = FilterQuality.low,
      );
    }
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
        filterQuality: FilterQuality.medium,
      );
      merged.add(index);
    }
    final picture = recorder.endRecording();
    final atlas = await picture.toImage(width, height);
    picture.dispose();
    if (!mounted || generation != _generation) {
      atlas.dispose();
      _atlasBuilding = false;
      return;
    }
    // Only the cells actually drawn into this texture are released. Images
    // that resolved while `toImage` was running stay queued for the next
    // merge; discarding them used to leave those photos permanently blurry.
    for (final index in merged) {
      _images[index]?.dispose();
      _images[index] = null;
    }
    _mergedIndexes.addAll(merged);
    final isComplete = _pendingIndexes.isEmpty && _mergedIndexes.containsAll(_upgradeIndexes);
    setState(() {
      _replaceAtlas(atlas, signature: isComplete ? _contentSignature : _provisionalSignature, cellPixels: targetPixels);
      _baseAtlasReady = true;
      _persistentExact = isComplete;
      _atlasBuilding = false;
    });
    _denseRowAtlasCache.put(_slotAtlasKey, atlas, signature: isComplete ? _contentSignature : _provisionalSignature);
    if (isComplete) {
      _denseRowAtlasCache.put(_completeAtlasKey, atlas, signature: _contentSignature);
    }
    unawaited(_persistAtlas(atlas, exact: isComplete));
    if (isComplete) {
      return;
    }
    if (_compositeDirty) {
      _scheduleCompositeAtlas(generation);
    } else {
      _scheduleUpgradeRetry();
    }
  }

  /// Marks a panel final once every cell it can resolve has been merged.
  void _finalizeAtlas(int generation, {bool force = false}) {
    final atlas = _atlas;
    if (!mounted || generation != _generation || _persistentExact || atlas == null || _atlasBuilding) {
      return;
    }
    if (_atlasCellPixels != _targetPixels) {
      // The panel is still showing the coarse fallback, so it cannot be final.
      if (!force) {
        _scheduleUpgradeRetry();
      }
      return;
    }
    if (!force && !(_baseAtlasReady && _mergedIndexes.containsAll(_upgradeIndexes))) {
      _scheduleUpgradeRetry();
      return;
    }
    _persistentExact = true;
    _atlasSignature = _contentSignature;
    _denseRowAtlasCache.put(_completeAtlasKey, atlas, signature: _contentSignature);
    _denseRowAtlasCache.put(_slotAtlasKey, atlas, signature: _contentSignature);
    unawaited(_persistAtlas(atlas, exact: true));
  }

  ImageProvider? _providerForAsset(BaseAsset asset, int targetPixels) {
    final provider = getThumbnailImageProvider(asset, size: Size.square(targetPixels.toDouble()));
    return provider == null ? null : ResizeImage.resizeIfNeeded(targetPixels, targetPixels, provider);
  }

  Future<ImageInfo> _resolveImage(int index, ImageProvider provider) {
    final completer = Completer<ImageInfo>();
    final stream = provider.resolve(const ImageConfiguration());
    late final ImageStreamListener listener;

    void detach() {
      stream.removeListener(listener);
      if (index < _streams.length && _streams[index] == stream) {
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
    if (index < _streams.length) {
      _streams[index] = stream;
      _listeners[index] = listener;
      _completers[index] = completer;
    }
    stream.addListener(listener);
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        detach();
        throw TimeoutException('Dense thumbnail did not resolve in time');
      },
    );
  }

  Future<void> _persistAtlas(ui.Image atlas, {bool exact = true}) {
    _denseAtlasPersistenceQueue.schedule(
      slot: widget.cacheSlot,
      signature: exact ? _contentSignature : _provisionalSignature,
      image: atlas,
      allowWhileVisible: exact,
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
    _compositeTimer?.cancel();
    _compositeTimer = null;
    _upgradeRetryTimer?.cancel();
    _upgradeRetryTimer = null;
    _actualThumbnailRequestsReset();
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
    final length = _images.length;
    _images = List<ImageInfo?>.filled(length, null);
    _streams = List<ImageStream?>.filled(length, null);
    _listeners = List<ImageStreamListener?>.filled(length, null);
    _completers = List<Completer<ImageInfo>?>.filled(length, null);
  }

  void _unsubscribeFromImages({bool preserveAtlas = false}) {
    _generation++;
    _metadataRetryTimer?.cancel();
    _metadataRetryTimer = null;
    _cancelActualThumbnailWork();
    _images = const [];
    _streams = const [];
    _listeners = const [];
    _completers = const [];
    if (!preserveAtlas) {
      _atlas?.dispose();
      _atlas = null;
      _atlasSignature = null;
      _atlasCellPixels = null;
    }
    _atlasBuilding = false;
    _compositeDirty = false;
  }

  void _handleTap(TapUpDetails details, TextDirection textDirection) {
    final assets = widget.assets;
    if (assets == null) {
      return;
    }
    var offset = details.localPosition.dx;
    if (textDirection == TextDirection.rtl) {
      offset = (context.size?.width ?? 0) - offset;
    }
    final column = (offset / widget.tileExtent).floor();
    final row = (details.localPosition.dy / widget.tileExtent).floor();
    final localIndex = row * widget.columnCount + column;
    if (localIndex >= 0 && localIndex < assets.length) {
      widget.onAssetTap(widget.firstAssetIndex + localIndex, assets[localIndex]);
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
    final layoutTransition = TimelineLayoutTransitionScope.maybeOf(context);
    final reflowActive = layoutTransition?.previousRects.isNotEmpty ?? false;
    final paintSurface = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) => _handleTap(details, textDirection),
      child: CustomPaint(
        size: Size(double.infinity, _rowCount * widget.tileExtent),
        isComplex: true,
        willChange: reflowActive,
        painter: _DenseAssetRowPainter(
          images: _images,
          atlas: _atlas,
          assetKeys: _assetKeys,
          columnCount: widget.columnCount,
          tileExtent: widget.tileExtent,
          textDirection: textDirection,
          layoutAnimation: reflowActive ? layoutTransition?.animation : null,
          previousRects: reflowActive ? layoutTransition!.previousRects : const {},
          globalToLocalTransform: _globalToLocalTransform,
          repaint: _repaint,
        ),
      ),
    );
    return TimelineDenseAssetLayoutMarker(
      assetKeys: _assetKeys,
      columnCount: widget.columnCount,
      tileExtent: widget.tileExtent,
      textDirection: textDirection,
      child: reflowActive ? paintSurface : RepaintBoundary(child: paintSurface),
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
