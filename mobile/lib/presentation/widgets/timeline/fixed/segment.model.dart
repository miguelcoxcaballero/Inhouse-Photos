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
import 'package:immich_mobile/presentation/widgets/timeline/fixed/thumbhash_cell.dart';
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
///
/// Exactly the cell's size on screen, so the atlas blits one to one. It used to
/// be floored at [batchedGridMetadataCellPixels], which at forty-eight columns
/// meant 32px cells for a tile that occupies 23 physical pixels: 1.9x the
/// pixels to decode, to hand between isolates, to hold, and to rescale on every
/// single frame, for detail no display can show. The floor bought nothing
/// because a cell is never drawn larger than this.
///
/// The lower bound is only a guard against a degenerate viewport measurement.
int denseTimelineTargetPixels({required double tileExtent, required double devicePixelRatio}) =>
    math.max(8, (tileExtent * devicePixelRatio).ceil());

/// Cell size of the instant ThumbHash fallback texture.
///
/// A ThumbHash only carries a handful of DCT coefficients, so expanding it to
/// the full physical cell size costs up to sixteen times the memory and isolate
/// transfer for no additional detail. The fallback is therefore built small and
/// scaled by the painter, while the real thumbnails are composited at
/// [denseTimelineTargetPixels].
///
/// Deliberately the same at every zoom level, and independent of [targetPixels].
/// Decoded cells are cached per photo at this size, so one size means one cache
/// shared by every zoom. It used to be `min(targetPixels, 32)`, which is the
/// same 32 everywhere except the densest level, where a 30-pixel cell made
/// forty-eight columns the one zoom that shared nothing - entering or leaving it
/// re-decoded every preview on screen. Thirty-two drawn into a thirty-pixel cell
/// is a scale factor of 1.07 and no visible difference.
int denseTimelineMetadataPixels(int targetPixels) => batchedGridMetadataCellPixels;

/// Every batched cell is backed by a real thumbnail, at every zoom level.
///
/// An earlier build only upgraded cells whose physical size exceeded the
/// fallback texture, on the theory that a 30px tile is too small to show more
/// detail than a ThumbHash carries. That is wrong in practice: a ThumbHash is
/// a handful of DCT coefficients, so a 30px tile renders as a colour smear
/// while a real 32px thumbnail is recognisable. The densest levels are exactly
/// where someone is scanning for a photo by its shape, so they need real
/// pixels the most.
bool denseTimelineNeedsThumbnailUpgrade(int targetPixels) => targetPixels > 0;

/// The rectangles a panel's cells occupy: the full rows, plus the partial last
/// row when the bucket does not divide evenly into columns.
///
/// A dense panel always reserves its full layout extent, so a panel with no
/// texture yet used to paint literally nothing and read as a hole in the
/// timeline several screens tall. Filling these keeps a loading panel visible
/// while leaving the unused trailing cells transparent, as before.
@visibleForTesting
List<Rect> denseTimelineOccupiedRects({
  required int itemCount,
  required int columnCount,
  required double tileExtent,
  required double containerWidth,
  required TextDirection textDirection,
}) {
  if (itemCount <= 0 || columnCount <= 0 || tileExtent <= 0) {
    return const [];
  }
  final isRtl = textDirection == TextDirection.rtl;
  final gridWidth = columnCount * tileExtent;
  final gridLeft = isRtl ? containerWidth - gridWidth : 0.0;
  final fullRows = itemCount ~/ columnCount;
  final remainder = itemCount % columnCount;
  return [
    if (fullRows > 0) Rect.fromLTWH(gridLeft, 0, gridWidth, fullRows * tileExtent),
    if (remainder > 0)
      Rect.fromLTWH(
        isRtl ? containerWidth - (remainder * tileExtent) : gridLeft,
        fullRows * tileExtent,
        remainder * tileExtent,
        tileExtent,
      ),
  ];
}

/// Hex characters a panel fingerprint must have.
///
/// The on-disk atlas header reserves a fixed-width field for it, and a
/// fingerprint of any other width is refused by the cache rather than stored.
/// That coupling used to be an unnamed `64` in three places; a change to the
/// digest then disabled the entire disk cache without a single failure.
/// The blurry preview to draw for [asset] before its real thumbnail arrives.
///
/// A remote photo carries one from the server. A photo still waiting to be
/// backed up carries one generated on device, which is what stops it being the
/// only kind of tile that shows nothing at all while it loads.
///
/// Both the fallback texture and the panel fingerprint read this, and they must
/// agree: a panel whose fingerprint ignored a preview that the texture used
/// would keep a stale, blank-celled atlas after generation filled it in.
@visibleForTesting
String? denseThumbHashOf(BaseAsset asset) => switch (asset) {
  RemoteAsset(thumbHash: final hash?) when hash.isNotEmpty => hash,
  LocalAsset(thumbHash: final hash?) when hash.isNotEmpty => hash,
  _ => null,
};

const int denseAtlasSignatureLength = 64;

int denseTimelineRowsPerChild(int columnCount) => switch (columnCount) {
  >= 48 => 4,
  >= 36 => 6,
  >= 24 => 6,
  >= 12 => 8,
  _ => 1,
};

/// The content fingerprint of one dense panel, used to decide whether a cached
/// atlas still matches the assets it was built from.
///
/// This runs synchronously on the UI thread every time a panel resets, and at
/// forty-eight columns a panel holds 192 assets. It used to concatenate every
/// asset's fields into one ~19KB string and SHA-256 it, which measured 270us
/// per panel AOT - 7.6ms across the twenty-eight panels a dense screen holds,
/// spent on nothing but cache keys, before any pixel is produced. Folding the
/// same fields into two 64-bit accumulators as they are read costs 11.7us.
///
/// The value only ever has to answer "are these the same assets as the atlas I
/// have", in memory and against the disk cache, so a wide non-cryptographic
/// digest is the right tool. Two independent FNV-1a lanes give 128 bits.
///
/// `v9` also retires every `v8` entry on disk, which is what a change of
/// fingerprint algorithm requires anyway.
@visibleForTesting
String denseContentSignature(List<BaseAsset> assets, {required int columnCount, required int targetPixels}) {
  const primes = [0x100000001b3, 0x88b6a51b1d2c9, 0x1000193, 0xa24baed4963ee4];
  // Four lanes, because [denseAtlasSignatureLength] hex characters is what the
  // on-disk header reserves for this field. Emitting anything else makes the
  // disk cache silently refuse to store the panel, which is not a fallback -
  // it is the difference between scrolling back over photos already seen and
  // fetching every one of them again.
  //
  // The leading lane also folds in a format version, so changing the mix retires
  // stale entries without needing a separate prefix that would break the width.
  final lanes = <int>[0xcbf29ce484222325 ^ 9, 0x9e3779b97f4a7c15, 0x27d4eb2f165667c5, 0xff51afd7ed558ccd];

  void mixInt(int value) {
    for (var i = 0; i < lanes.length; i++) {
      lanes[i] = (lanes[i] ^ (i.isEven ? value : value ^ (value >> 32))) * primes[i];
    }
  }

  void mixString(String? value) {
    if (value == null) {
      mixInt(0);
      return;
    }
    for (var c = 0; c < value.length; c++) {
      final unit = value.codeUnitAt(c);
      for (var i = 0; i < lanes.length; i++) {
        lanes[i] = (lanes[i] ^ unit) * primes[i];
      }
    }
    // Length is mixed separately so that "ab" + "c" and "a" + "bc" in adjacent
    // fields cannot collapse to the same state.
    mixInt(value.length);
  }

  mixInt(columnCount);
  mixInt(assets.length);
  mixInt(targetPixels);
  for (final asset in assets) {
    mixString(asset.remoteId ?? asset.localId ?? asset.checksum ?? asset.heroTag);
    mixInt(asset.updatedAt.toUtc().microsecondsSinceEpoch);
    mixInt(asset.width ?? 0);
    mixInt(asset.height ?? 0);
    mixString(denseThumbHashOf(asset));
  }
  final buffer = StringBuffer();
  for (final lane in lanes) {
    // Halves, because Dart ints are 64-bit signed: `toUnsigned(64)` cannot
    // widen them, so a negative lane would render with a minus sign and blow
    // the fixed-width field the disk header expects.
    buffer
      ..write(((lane >> 32) & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0'))
      ..write((lane & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0'));
  }
  return buffer.toString();
}

class _DenseAtlasPixelsResult {
  final Uint8List pixels;
  final List<bool> covered;

  const _DenseAtlasPixelsResult(this.pixels, this.covered);
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
  static const _magic = 'IHDPANL6';
  static const _headerBytes = 80;
  static const _signatureBytes = denseAtlasSignatureLength;
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
      final directory = Directory(path.join(support.path, 'inhouse_grid_panels_v7'));
      await directory.create(recursive: true);
      // v6 baked the placeholder colour into the texture, so a panel kept
      // whatever palette was active when it was first generated. Keep the old
      // cache until at least one v7 panel exists, then drop it on a later launch.
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
            final signature = ascii.decode(bytes.sublist(16, 16 + _signatureBytes));
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
    if (signature.length != _signatureBytes || width <= 0 || height <= 0 || encodedBytes.isEmpty) {
      DenseGridStats.diskWritesRefused++;
      return Future.value();
    }
    final previous = _writes[slot] ?? Future.value();
    final write = previous.then((_) async {
      try {
        final directory = await _getDirectory();
        if (directory == null) {
          DenseGridStats.diskDirectoryUnavailable++;
          return;
        }
        final file = File(path.join(directory.path, _fileName(slot)));
        final bytes = Uint8List(_headerBytes + encodedBytes.lengthInBytes);
        bytes.setRange(0, 8, ascii.encode(_magic));
        final header = ByteData.sublistView(bytes, 8, 16);
        header.setUint32(0, width, Endian.little);
        header.setUint32(4, height, Endian.little);
        bytes.setRange(16, 16 + _signatureBytes, ascii.encode(signature));
        bytes.setRange(_headerBytes, bytes.length, encodedBytes);
        final temporary = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
        await temporary.writeAsBytes(bytes, flush: false);
        if (await file.exists()) {
          await file.delete();
        }
        await temporary.rename(file.path);
        DenseGridStats.diskAtlasWrites++;
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
    await Directory(path.join(support.path, 'inhouse_grid_panels_v6')).delete(recursive: true);
  } catch (_) {
    // The legacy cache may already have been removed or be in use by an older
    // process; either case is safe and the new cache remains independent.
  }
}

/// Decoded ThumbHash cells, keyed by the hash itself.
///
/// A decoded cell depends only on the hash and the cell size, and
/// [denseTimelineMetadataPixels] clamps that size to
/// [batchedGridMetadataCellPixels] at every zoom level. So the same photo yields
/// the identical 32x32 cell whether the grid is showing twelve columns or
/// forty-eight - yet it used to be re-decoded from scratch every time a panel
/// was rebuilt, because the work was buried inside a per-panel, per-zoom atlas.
///
/// Caching the per-asset part of that turns a rebuild into memcpy. Measured AOT
/// on a 192-photo panel: 9.7ms of decoding becomes 0.34ms of copying. The cache
/// is what makes changing zoom, or scrolling back over ground already covered,
/// resolve without recomputing anything.
class _DenseCellCache {
  // Cells are at most [batchedGridMetadataCellPixels] square, so 4KiB each and
  // usually less. This budget is under 6MiB per isolate; with three atlas
  // workers each holding only the panels routed to them, the scheme costs about
  // 18MiB at worst.
  //
  // Entries are keyed by size as well as hash, because the cell size now
  // follows the tile's size on screen. Zoom levels therefore no longer share
  // cells - what the cache still buys is scrolling back over ground already
  // covered, and returning to a zoom level visited before.
  static const int _maxEntries = 1536;
  final LinkedHashMap<String, Uint8List> _entries = LinkedHashMap();

  Uint8List? take(String hash, int size) {
    final key = '$size:$hash';
    final hit = _entries.remove(key);
    if (hit != null) {
      _entries[key] = hit;
    }
    return hit;
  }

  void put(String hash, int size, Uint8List cell) {
    final key = '$size:$hash';
    _entries.remove(key);
    _entries[key] = cell;
    while (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }
}

/// Per-isolate cell cache. Workers and the main isolate each keep their own.
final _denseCellCache = _DenseCellCache();

/// Builds the instant fallback texture.
///
/// Cells with no usable ThumbHash are left fully transparent on purpose. This
/// texture is cached in memory and persisted to disk, so baking a theme colour
/// into it made a panel keep whatever palette happened to be active when it was
/// first generated - the colour is not part of the cache identity, so a panel
/// baked under one theme was restored and treated as valid under another one
/// forever. The painter fills those cells live instead, underneath the atlas.
_DenseAtlasPixelsResult _buildDenseThumbhashAtlas(List<String?> hashes, int targetPixels, {required int columnCount}) {
  final columns = columnCount;
  final rows = (hashes.length / columns).ceil();
  final atlasWidth = columns * targetPixels;
  final atlas = Uint8List(atlasWidth * rows * targetPixels * 4);
  final covered = List<bool>.filled(hashes.length, false);

  for (var index = 0; index < hashes.length; index++) {
    final hash = hashes[index];
    Uint8List? tile;
    if (hash != null && hash.isNotEmpty) {
      tile = _denseCellCache.take(hash, targetPixels);
      if (tile != null) {
        covered[index] = true;
      } else {
        try {
          tile = decodeThumbHashCell(base64Decode(hash), targetPixels);
          _denseCellCache.put(hash, targetPixels, tile);
          covered[index] = true;
        } catch (_) {
          // A malformed hash is filled later by the normal thumbnail path.
        }
      }
    }

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

/// Starts the CPU-heavy placeholder work from a top-level lexical scope.
///
/// Keeping this wrapper outside the widget State is important: an Isolate.run
/// callback nested in a State method can retain the outer closure context,
/// including the unsendable Element/render tree, even when its body appears to
/// reference only local variables.
/// One job for the fallback-texture workers.
class _DenseAtlasJob {
  final int id;
  final List<String?> hashes;
  final int targetPixels;
  final int columnCount;
  final SendPort reply;

  const _DenseAtlasJob({
    required this.id,
    required this.hashes,
    required this.targetPixels,
    required this.columnCount,
    required this.reply,
  });
}

/// Long-lived isolates that build fallback textures.
///
/// Every panel used to call `Isolate.run`, which spawns and tears down an
/// isolate per panel. Flinging a 48-column screen streams panels in constantly,
/// so that was a steady churn of isolate setup and collection behind the
/// scrolling. These workers are started once and reused.
///
/// `Isolate.run` returned its result through `Isolate.exit`, which hands the
/// buffer over without copying. A plain `SendPort.send` does copy, and at 48
/// columns that is most of a megabyte per panel, so the pixels travel back as
/// [TransferableTypedData] to keep the hand-off free.
class _DenseAtlasWorkerPool {
  _DenseAtlasWorkerPool(this.size);

  final int size;
  final List<SendPort> _workers = [];
  final Map<int, Completer<_DenseAtlasPixelsResult>> _pending = {};
  Future<void>? _starting;
  ReceivePort? _responses;
  int _nextJobId = 0;

  Future<void> _start() => _starting ??= () async {
    final responses = ReceivePort();
    _responses = responses;
    responses.listen((message) {
      if (message is! List || message.length != 3) {
        return;
      }
      final completer = _pending.remove(message[0] as int);
      if (completer == null || completer.isCompleted) {
        return;
      }
      final pixels = message[1];
      completer.complete(
        _DenseAtlasPixelsResult(
          pixels is TransferableTypedData ? pixels.materialize().asUint8List() : pixels as Uint8List,
          (message[2] as List).cast<bool>(),
        ),
      );
    });
    for (var index = 0; index < size; index++) {
      final ready = ReceivePort();
      await Isolate.spawn(
        _denseAtlasWorkerMain,
        ready.sendPort,
        errorsAreFatal: false,
        debugName: 'dense-atlas-$index',
      );
      _workers.add(await ready.first as SendPort);
      ready.close();
    }
  }();

  /// Runs one panel's fallback texture on a worker.
  ///
  /// [affinity] picks the worker. Each worker keeps its own cache of decoded
  /// ThumbHash cells, so sending the same panel to the same worker is what makes
  /// that cache worth having: round-robin dispatch gave a rebuilt panel a
  /// one-in-[size] chance of landing where its cells already were. Panels are
  /// stable units of content, so hashing their identity spreads work evenly
  /// while keeping each panel on one worker. Cost only shifts on the first
  /// decode; afterwards the work is a memcpy either way.
  Future<_DenseAtlasPixelsResult> run({
    required List<String?> hashes,
    required int targetPixels,
    required int columnCount,
    required Object affinity,
  }) async {
    try {
      await _start();
    } catch (_) {
      // A device that cannot spawn isolates still gets its gallery, just with
      // the decode happening inline.
      return _buildDenseThumbhashAtlas(hashes, targetPixels, columnCount: columnCount);
    }
    if (_workers.isEmpty) {
      return _buildDenseThumbhashAtlas(hashes, targetPixels, columnCount: columnCount);
    }
    final id = _nextJobId++;
    final completer = Completer<_DenseAtlasPixelsResult>();
    _pending[id] = completer;
    final worker = _workers[affinity.hashCode.abs() % _workers.length];
    worker.send(
      _DenseAtlasJob(
        id: id,
        hashes: hashes,
        targetPixels: targetPixels,
        columnCount: columnCount,
        reply: _responses!.sendPort,
      ),
    );
    return completer.future;
  }
}

/// Entry point for a fallback-texture worker. Must stay top level.
void _denseAtlasWorkerMain(SendPort ready) {
  final jobs = ReceivePort();
  ready.send(jobs.sendPort);
  jobs.listen((message) {
    if (message is! _DenseAtlasJob) {
      return;
    }
    try {
      final result = _buildDenseThumbhashAtlas(message.hashes, message.targetPixels, columnCount: message.columnCount);
      message.reply.send([
        message.id,
        TransferableTypedData.fromList([result.pixels]),
        result.covered,
      ]);
    } catch (_) {
      message.reply.send([message.id, Uint8List(0), <bool>[]]);
    }
  });
}

final _DenseAtlasWorkerPool _denseAtlasWorkers = _DenseAtlasWorkerPool(_denseMetadataAtlasConcurrency);

Future<_DenseAtlasPixelsResult> _buildDenseThumbhashAtlasInBackground({
  required List<String?> hashes,
  required int targetPixels,
  required int columnCount,
  required Object affinity,
}) => _denseAtlasWorkers.run(hashes: hashes, targetPixels: targetPixels, columnCount: columnCount, affinity: affinity);

@visibleForTesting
Uint8List buildDenseThumbhashAtlasPixels(List<String?> hashes, int targetPixels, {int? columnCount}) =>
    _buildDenseThumbhashAtlas(hashes, targetPixels, columnCount: columnCount ?? hashes.length).pixels;

final Expando<_DenseAssetChunkStore> _denseAssetStores = Expando<_DenseAssetChunkStore>();

class _DenseAssetChunkStore {
  // Both are derived from the live viewport by [configure] rather than being
  // guessed, because the right values differ by an order of magnitude between
  // three columns and forty-eight. Holding too few chunks meant one was evicted
  // while panels still needed it and re-read immediately, and every re-read
  // queues behind the timeline service's single mutex, so panels never received
  // their rows at all. These hold asset references, not pixels.
  int _chunkSize = kTimelineAssetLoadBatchSize;
  int _maxResidentChunks = 4;
  int _maxResidentRows = 128;

  /// Sizes the cache for the range the sliver actually keeps mounted.
  ///
  /// The sliver holds one viewport of cache extent either side of the visible
  /// one, so roughly three viewports of assets are live at any moment.
  void configure({required int columnCount, required double viewportHeight, required double tileExtent}) {
    final chunkSize = denseTimelineAssetChunkSize(
      columnCount: columnCount,
      viewportHeight: viewportHeight,
      tileExtent: tileExtent,
    );
    final mountedAssets = tileExtent > 0 && viewportHeight > 0
        ? ((viewportHeight * 3) / tileExtent).ceil() * columnCount
        : chunkSize;
    _maxResidentChunks = math.max(4, (mountedAssets / chunkSize).ceil() + 2);
    _maxResidentRows = math.max(128, (mountedAssets / math.max(1, columnCount)).ceil() * 2);
    if (chunkSize == _chunkSize) {
      return;
    }
    // Chunk boundaries moved, so every cached slice is addressed differently.
    _chunkSize = chunkSize;
    _chunks.clear();
    _resolvedChunks.clear();
    _rows.clear();
    _resolvedRows.clear();
  }

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

  /// Assembles a row, retrying once when the timeline revision moved underneath.
  ///
  /// A backup finishing mid-scroll bumps the revision and clears the chunk
  /// cache, so a row already in flight fails to assemble. That failure used to
  /// surface as a permanently empty panel, because nothing rebuilt the row
  /// afterwards. Retrying against the refreshed revision resolves it instead.
  Future<List<BaseAsset>> _loadRow(TimelineService service, {required int index, required int count}) async {
    try {
      return await _assembleRow(service, index: index, count: count);
    } on StateError {
      _resetIfNeeded(service);
      return _assembleRow(service, index: index, count: count);
    }
  }

  Future<List<BaseAsset>> _assembleRow(TimelineService service, {required int index, required int count}) async {
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
  /// Floor and ceiling for the gap between foreground writes.
  ///
  /// The floor stops a cheap encode turning into a tight loop; the ceiling is
  /// the old fixed value, so the slowest case is no worse than before.
  static const Duration _minForegroundGap = Duration(milliseconds: 120);
  static const Duration _maxForegroundGap = Duration(milliseconds: 450);
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
    DenseGridStats.diskWritesScheduled++;
    final snapshot = image.clone();
    _pending.remove(slot)?.image.dispose();
    _pending[slot] = _DenseAtlasPersistenceTask(
      slot: slot,
      signature: signature,
      image: snapshot,
      allowWhileVisible: allowWhileVisible,
    );
    while (_pending.length > _maxPending) {
      DenseGridStats.diskWritesEvicted++;
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
    final timer = Stopwatch()..start();
    unawaited(
      _encode(task).whenComplete(() {
        timer.stop();
        _active = false;
        if (_appVisible) {
          // Paced by what the write actually cost rather than a fixed gap. One
          // write is a PNG encode of the whole panel, and that varies by an
          // order of magnitude with zoom: 47.9ms at eighteen columns against
          // 10.2ms at forty-eight. A single 450ms gap is calibrated for the
          // expensive end, so at the dense end - where a screen holds far more
          // panels and cold start has the most to gain - it was idle roughly
          // forty times longer than the work it was spacing out.
          //
          // Four times the last encode keeps the duty cycle at twenty per cent
          // whatever the zoom, so this never occupies more of a frame than it
          // did before.
          final measured = timer.elapsed * 4;
          _scheduleForegroundDrain(
            delay: measured < _minForegroundGap
                ? _minForegroundGap
                : (measured > _maxForegroundGap ? _maxForegroundGap : measured),
          );
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
    denseStore.configure(
      columnCount: columnCount,
      viewportHeight: ref.read(timelineArgsProvider).maxHeight,
      tileExtent: tileHeight,
    );
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

// At the densest zoom levels a single screen legitimately wants thousands of
// 32px thumbnails, and nearly all of them are small reads from the shared
// thumbnail disk cache rather than fresh downloads. Four at a time made that
// crawl; the work itself is tiny, so the limit only needs to stop a fling from
// starving raster/UI work on mid-range phones.
const int _denseThumbnailConcurrency = 8;
const int _denseMetadataAtlasConcurrency = 3;
// ui.Image.clone shares the underlying GPU texture, so keeping a wider rolling
// window here does not duplicate pixels. It prevents a fast fling from evicting
// every nearby panel and falling back to an asynchronous disk decode (visible
// as a brief blank row). Android memory-pressure callbacks still clear it.
//
// A finished panel is held under both its content key and its positional slot
// key, and the budget counts each clone separately even though they share one
// texture. The accounting therefore over-reports by roughly 2x, which at 48
// columns left barely one screen of headroom and made scrolling back flash
// blank rows. The budget below is the accounted figure, not real memory.
const int _denseAtlasCacheBytes = 96 * 1024 * 1024;

/// Where a dense panel's texture came from, counted so that scrolling back over
/// ground already covered can be measured rather than assumed.
///
/// A revisited panel should be served by memory, or failing that by disk. Any
/// thumbnail refetch or ThumbHash rebuild on the way back is work that should
/// not be happening.
@visibleForTesting
class DenseGridStats {
  static int memoryAtlasHits = 0;
  static int memoryAtlasMisses = 0;
  static int diskAtlasHits = 0;
  static int diskAtlasMisses = 0;
  static int thumbhashAtlasBuilds = 0;
  static int compositeAtlasBuilds = 0;
  static int diskAtlasWrites = 0;
  static int diskDirectoryUnavailable = 0;
  static int diskWritesScheduled = 0;
  static int diskWritesEvicted = 0;
  static int diskWritesRefused = 0;

  static void reset() {
    memoryAtlasHits = 0;
    memoryAtlasMisses = 0;
    diskAtlasHits = 0;
    diskAtlasMisses = 0;
    thumbhashAtlasBuilds = 0;
    compositeAtlasBuilds = 0;
    diskAtlasWrites = 0;
    diskDirectoryUnavailable = 0;
    diskWritesScheduled = 0;
    diskWritesEvicted = 0;
    diskWritesRefused = 0;
  }

  static String summary() =>
      'memory ${memoryAtlasHits}h/${memoryAtlasMisses}m  '
      'disk ${diskAtlasHits}h/${diskAtlasMisses}m  '
      'thumbhashBuilds $thumbhashAtlasBuilds  compositeBuilds $compositeAtlasBuilds  '
      'diskWrite sched $diskWritesScheduled/evicted $diskWritesEvicted/'
      'refused $diskWritesRefused/written $diskAtlasWrites  noDir $diskDirectoryUnavailable';
}

final DenseThumbnailQueue _denseThumbnailQueue = DenseThumbnailQueue();

/// True while the dense grid is loading thumbnails for something on screen.
///
/// Exposed so background work can stand aside for it without reaching into the
/// widget layer.
bool denseGridIsResolvingThumbnails() => _denseThumbnailQueue.isBusy;
final DenseTimelineTaskQueue _denseMetadataAtlasQueue = DenseTimelineTaskQueue(
  _denseMetadataAtlasConcurrency,
  // A 48-column screen plus its cache extent is well over a hundred panels.
  // Rejecting them at schedule time turned into a retry storm that competed
  // with the panels actually on screen.
  maxPending: 512,
);
final DenseRowAtlasCache _denseRowAtlasCache = DenseRowAtlasCache();
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

@visibleForTesting
class DenseThumbnailQueue {
  DenseThumbnailQueue({this.maxPending = 4096});

  // A whole batched-grid screen can legitimately want a few thousand cells, so
  // the queue is ordered by a heap instead of re-sorting a list on every
  // dequeue. Re-sorting made scheduling quadratic and stalled the UI isolate
  // exactly when the gallery was trying to fill in.
  //
  // This is smaller than one screen of the densest grid, which puts 4808 cells
  // on screen, so requests really are dropped and really are re-asked for. That
  // looks like it should starve the panels that ask last, since a full queue
  // drops the newest and retries ask in the same order - but raising it to
  // 12288 was measured and changed nothing: 22 panels of 29 finished against 24
  // and 25 on the unchanged build, which is inside the run to run spread.
  // Capacity is not what stops those panels finishing, so it stays where it was
  // rather than costing memory for a disproved theory.
  //
  // The discard path is ordinary rather than exceptional, so callers must
  // expect `onDiscard` to run before `schedule` returns.
  final int maxPending;
  final HeapPriorityQueue<_DenseThumbnailTask> _pending = HeapPriorityQueue(_compareTasks);
  int _active = 0;
  int _sequence = 0;

  static int _compareTasks(_DenseThumbnailTask a, _DenseThumbnailTask b) {
    final priority = a.priority.compareTo(b.priority);
    return priority == 0 ? a.sequence.compareTo(b.sequence) : priority;
  }

  /// Whether the grid is currently resolving thumbnails somebody can see.
  ///
  /// Background preview generation asks this before every batch, because a
  /// preview for a photo further down the library is worth nothing if producing
  /// it delays the photo on screen.
  bool get isBusy => _active > 0 || _pending.isNotEmpty;

  DenseThumbnailHandle schedule(Future<void> Function() task, {int priority = 1, void Function()? onDiscard}) {
    final item = _DenseThumbnailTask(task: task, priority: priority, sequence: _sequence++, onDiscard: onDiscard);
    final handle = DenseThumbnailHandle._(item);
    if (_pending.length >= maxPending) {
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

/// Opaque reference to one queued thumbnail request, so a panel can cancel the
/// work it asked for. Only [DenseThumbnailQueue] constructs these.
@visibleForTesting
class DenseThumbnailHandle {
  final _DenseThumbnailTask _task;

  const DenseThumbnailHandle._(this._task);

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

/// Rolling window of recently painted panel textures.
///
/// Public for the accounting regression test below it; the app uses the single
/// shared instance.
@visibleForTesting
class DenseRowAtlasCache {
  final LinkedHashMap<Object, ui.Image> _images = LinkedHashMap();
  final Map<Object, String> _signatures = {};
  /// Which cells a stored texture already carries a real thumbnail for.
  ///
  /// Only meaningful for a partially finished panel. Without it a restored
  /// partial texture would have to re-request every cell to find out what it
  /// already had, which is most of the cost it exists to avoid.
  final Map<Object, Set<int>> _merged = {};
  int _bytes = 0;

  ui.Image? get(Object key) {
    final image = _images.remove(key);
    if (image == null) {
      DenseGridStats.memoryAtlasMisses++;
      return null;
    }
    DenseGridStats.memoryAtlasHits++;
    _images[key] = image;
    return image.clone();
  }

  String? signature(Object key) => _signatures[key];

  Set<int>? merged(Object key) => _merged[key];

  void put(Object key, ui.Image image, {String? signature, Set<int>? merged}) {
    final previous = _images.remove(key);
    if (previous != null) {
      _bytes -= _uniqueBytes(previous);
      previous.dispose();
    }
    if (signature == null) {
      _signatures.remove(key);
    } else {
      _signatures[key] = signature;
    }
    if (merged == null) {
      _merged.remove(key);
    } else {
      _merged[key] = merged;
    }
    final cached = image.clone();
    _bytes += _uniqueBytes(cached);
    _images[key] = cached;
    while (_bytes > _denseAtlasCacheBytes && _images.isNotEmpty) {
      final oldestKey = _images.keys.first;
      final oldest = _images.remove(oldestKey)!;
      _signatures.remove(oldestKey);
      _merged.remove(oldestKey);
      _bytes -= _uniqueBytes(oldest);
      oldest.dispose();
    }
  }

  /// The bytes [image] actually costs, which is nothing if another entry
  /// already holds the same texture.
  ///
  /// A finished panel is deliberately held under two keys - its position and
  /// its content - so it survives both scrolling back to the same place and the
  /// same photos appearing elsewhere. `clone` shares one texture between them,
  /// but the budget used to charge for both, so the cache evicted at half the
  /// memory it was configured for. At eighteen columns a panel atlas is 3.7MB,
  /// which is the difference between holding about thirteen panels and about
  /// twenty-six - between a scroll back over three screens hitting cache and
  /// refetching every thumbnail on it.
  int _uniqueBytes(ui.Image image) {
    for (final other in _images.values) {
      if (!identical(other, image) && other.isCloneOf(image)) {
        return 0;
      }
    }
    return image.width * image.height * 4;
  }

  @visibleForTesting
  int get accountedBytes => _bytes;

  void clear() {
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _signatures.clear();
    _merged.clear();
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

  /// How far beyond the visible viewport a panel may resolve thumbnails.
  ///
  /// 3.1.65 widened this to 0.75 of a viewport either side so panels would
  /// arrive already sharp. On a 48-column screen that took the number of cells
  /// eligible to resolve, decode and composite from roughly one viewport to two
  /// and a half, all of it running while the finger is still moving, and the
  /// next thing reported was heavy lag. It is speculative work that was never
  /// measured on a device, so it goes back to the viewport-only behaviour that
  /// shipped in 3.1.60 through 3.1.64. Sharpening is slightly more visible;
  /// scrolling is what has to come first.
  static const double _viewportPrefetchFactor = 0.0;

  /// Longest gap between attempts to finish a panel that is still missing
  /// cells, and how many attempts it gets.
  ///
  /// Three attempts at a fixed cadence was too few: the thumbnail queue sheds
  /// its newest work when full and reports it as finished, so a busy moment
  /// burned every attempt in a couple of seconds and left the panel a
  /// placeholder for good. Retrying forever is the opposite mistake, because a
  /// panel that genuinely cannot resolve would then re-queue its cells for as
  /// long as it stayed mounted. Backing off to eight seconds over eight
  /// attempts recovers from a shortage lasting around a minute and then stops.
  static const Duration _maxUpgradeRetryDelay = Duration(seconds: 8);

  /// Consecutive retries that achieve nothing, not retries in total: any cell
  /// merging resets this. A panel still making progress is never cut off.
  static const int _maxUpgradeAttempts = 8;
  // Tier 1 collapses the first cells of a panel almost immediately, so the
  // per-cell draws above are short lived. Later tiers batch more aggressively
  // because by then the panel already looks sharp.
  static const Duration _compositeFirstDebounce = Duration(milliseconds: 150);
  static const Duration _compositeDebounce = Duration(milliseconds: 300);
  static const Duration _compositeIdleDebounce = Duration(milliseconds: 2000);
  static const Duration _upgradeRetryDelay = Duration(milliseconds: 900);

  final ValueNotifier<int> _repaint = ValueNotifier(0);
  late List<Object> _assetKeys;

  /// Last rows seen for [_DenseAssetRow.cacheSlot].
  ///
  /// The parent hands over a null list whenever the service buffer slides off
  /// this panel, which happens constantly while scrolling a dense grid. Keeping
  /// the rows here means a transient null no longer cancels every in-flight
  /// thumbnail and discards the panel's progress, which is what stopped the
  /// densest levels from ever converging on a sharp image.
  List<BaseAsset>? _assets;
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
  Color _placeholderTone = const Color(0x00000000);
  Color _surfaceTone = const Color(0x00000000);
  bool _repaintScheduled = false;
  bool _metadataAtlasRequested = false;
  int _metadataRetries = 0;
  Timer? _metadataRetryTimer;
  Timer? _compositeTimer;
  Timer? _upgradeRetryTimer;
  bool _atlasBuilding = false;
  bool _compositeDirty = false;
  int _compositeTier = 0;
  int _targetPixels = batchedGridMetadataCellPixels;
  int _metadataPixels = batchedGridMetadataCellPixels;
  int _completeAtlasKey = 0;
  /// Where a partly finished panel is kept, addressed by its content.
  ///
  /// The slot key is positional, so scrolling recycles it away almost at once.
  /// Without a content-addressed home, a panel that had resolved most of its
  /// photos but not all of them was thrown away entirely on the way past, and
  /// coming back re-fetched every one of them.
  int _partialAtlasKey = 0;
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
  final Set<DenseThumbnailHandle> _thumbnailHandles = {};

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
    _placeholderTone = context.colorScheme.surfaceContainerHighest;
    _surfaceTone = context.colorScheme.surface;
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
      _assets = null;
    }
    if (oldWidget.cacheSlot != widget.cacheSlot ||
        oldWidget.tileExtent != widget.tileExtent ||
        oldWidget.columnCount != widget.columnCount ||
        oldWidget.itemCount != widget.itemCount ||
        (widget.assets != null && !_sameAssets(_assets, widget.assets))) {
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
    _metadataRetries = 0;
    _upgradeAttempts = 0;
    _upgradeIndexes.clear();
    _pendingIndexes.clear();
    _mergedIndexes.clear();
    _didReportVisualReady = false;

    final assets = widget.assets ?? _assets;
    _assets = assets;
    if (assets == null) {
      _contentSignature = '';
      _baseAtlasKey = 0;
      _completeAtlasKey = 0;
      _partialAtlasKey = 0;
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
    _contentSignature = denseContentSignature(assets, columnCount: widget.columnCount, targetPixels: _targetPixels);
    final identity = Object.hashAll(assets.map((asset) => asset.heroTag));
    _baseAtlasKey = Object.hash('dense-base', _metadataPixels, widget.columnCount, identity);
    _completeAtlasKey = Object.hash('dense-complete', _targetPixels, widget.columnCount, identity);
    _partialAtlasKey = Object.hash('dense-partial', _targetPixels, widget.columnCount, identity);
    final upgradeEveryCell = denseTimelineNeedsThumbnailUpgrade(_targetPixels);
    for (var index = 0; index < assets.length; index++) {
      // Every cell must carry a real thumbnail before the panel counts as
      // final. The ThumbHash is only ever the instant first paint, and a cell
      // with no ThumbHash at all has nothing else to show.
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

    // Not finished, but the work already done for exactly these photos is worth
    // resuming: it shows sharp immediately instead of blurring back, and only
    // the cells it never got are requested again.
    final partial = _takeCachedAtlas(_partialAtlasKey);
    if (partial != null) {
      final resumable = partial.signature == 'partial:$_contentSignature' && partial.cellPixels == _targetPixels;
      if (resumable) {
        _replaceAtlas(partial.image, signature: _provisionalSignature, cellPixels: partial.cellPixels);
        _baseAtlasReady = true;
        _mergedIndexes.addAll(_denseRowAtlasCache.merged(_partialAtlasKey) ?? const <int>{});
        _scheduleRepaint();
      } else {
        partial.image.dispose();
      }
    }

    final base = _takeCachedAtlas(_baseAtlasKey);
    if (base != null) {
      // `_baseAtlasReady` already true means a partial composite was adopted
      // just above; overwriting it with the blurry texture would undo exactly
      // the work this is meant to preserve.
      if (base.signature == _contentSignature && _atlasSignature != _contentSignature && !_baseAtlasReady) {
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
    // Restoring is an optimisation; building is the guarantee. This runs
    // unawaited, so anything thrown while reading or decoding a cached texture
    // would otherwise vanish into an unhandled async error and take the call
    // below with it - leaving a panel that is laid out and painting its
    // placeholder colour with nothing queued and no retry pending. The early
    // returns inside still skip the rebuild, because those are the cases where
    // the panel already has what it needs or no longer wants it.
    try {
      if (!skipDiskRestore) {
        final entry = await _denseDiskAtlasCache.get(widget.cacheSlot);
        if (entry == null) {
          DenseGridStats.diskAtlasMisses++;
        } else {
          DenseGridStats.diskAtlasHits++;
        }
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
    } catch (_) {
      // Fall through and build the panel from scratch.
    }

    _queueVisibleOverviewWork(generation: generation);
  }

  void _queueVisibleOverviewWork({int? generation}) {
    if (_persistentExact || !mounted || _assets == null) {
      return;
    }
    // The instant ThumbHash texture is still built for the whole sliver cache
    // window, so a panel is never blank when it scrolls in. Only the expensive
    // per-asset upgrade below is restricted to what is actually on screen.
    final priority = _viewportState().priority;
    final targetGeneration = generation ?? _generation;
    if (!_baseAtlasReady && !_metadataAtlasRequested) {
      _metadataAtlasRequested = true;
      unawaited(_buildThumbhashAtlas(targetGeneration, priority: priority));
    }
    _queueMissingActualThumbnails(generation: targetGeneration);
  }

  /// Where this panel sits relative to the visible viewport.
  ///
  /// `measured` is false when the sliver's paint transform is unavailable. Such
  /// a panel is treated as visible on purpose: a custom layout transform must
  /// never be able to stop a panel from loading at all, which is what used to
  /// leave panels permanently blank during a zoom reflow.
  ({bool measured, bool visible, int priority}) _viewportState() {
    final renderObject = context.findRenderObject();
    final mediaSize = MediaQuery.maybeSizeOf(context);
    if (renderObject is! RenderBox || !renderObject.attached || !renderObject.hasSize || mediaSize == null) {
      return (measured: false, visible: true, priority: _offscreenPriority);
    }
    final panelRect = MatrixUtils.transformRect(renderObject.getTransformTo(null), Offset.zero & renderObject.size);
    // Upgrading only what is already on screen means every panel starts
    // resolving thumbnails at the moment it becomes visible, so the sharpening
    // happens in front of the person scrolling. Reaching most of the way into
    // the sliver's cache extent instead lets a panel arrive already sharp.
    // Priority is still distance-based, so visible rows are always served
    // first and this band only consumes genuinely idle capacity.
    final viewport = (Offset.zero & mediaSize).inflate(mediaSize.height * _viewportPrefetchFactor);
    if (!panelRect.overlaps(viewport)) {
      return (measured: true, visible: false, priority: _offscreenPriority);
    }
    // Centre-most panels are the first ones a person sees after the pinch.
    // Distance-based priority prevents dozens of tiny day rows below the fold
    // from evicting the actual visible work from the bounded atlas queue.
    return (measured: true, visible: true, priority: (panelRect.center.dy - (mediaSize.height * 0.5)).abs().round());
  }

  void _queueMissingActualThumbnails({int? generation}) {
    final assets = _assets;
    if (_persistentExact || widget.deferHighResolution || assets == null || !mounted || _upgradeIndexes.isEmpty) {
      return;
    }
    final viewport = _viewportState();
    if (!viewport.visible) {
      // Queueing the whole cache extent buries the rows the person is looking
      // at under thousands of requests they cannot see. The retry pass picks
      // this panel up as soon as it scrolls into view.
      _scheduleUpgradeRetry();
      return;
    }
    final targetGeneration = generation ?? _generation;
    final panelPriority = viewport.priority;
    // The retry is this panel's only route back from a failed or rejected
    // request, so it must not be reachable only by the happy path. A throw from
    // inside the loop used to skip it and strand the panel: mounted, sized and
    // painting its placeholder, with nothing left that would ever try again.
    // Whatever goes wrong for one cell, the panel still gets another go.
    try {
      for (final index in _upgradeIndexes) {
        if (_mergedIndexes.contains(index)) {
          continue;
        }
        _requestActualThumbnail(index, targetGeneration, priority: panelPriority + (index ~/ widget.columnCount));
      }
    } finally {
      _scheduleUpgradeRetry();
    }
  }

  void _requestActualThumbnail(int index, int generation, {required int priority}) {
    if (!_pendingIndexes.add(index)) {
      return;
    }
    final actualWorkGeneration = _actualWorkGeneration;
    // Not `late final`. A full queue discards the newest request from inside
    // `schedule`, so `onDiscard` can run before `schedule` has returned - and a
    // dense screen wants more cells than the queue holds, so that is the normal
    // case here, not an edge one. Reading a `late` local from that callback
    // threw, and the throw escaped the loop in `_queueMissingActualThumbnails`,
    // so the rest of the panel's cells were never requested and the retry that
    // would have recovered them was never scheduled. The index also stayed in
    // `_pendingIndexes`, which stops a panel ever counting as complete. That is
    // a panel stuck on its ThumbHash for as long as it stays on screen.
    DenseThumbnailHandle? handle;
    var settled = false;

    void finish() {
      settled = true;
      final scheduled = handle;
      if (scheduled != null) {
        _thumbnailHandles.remove(scheduled);
      }
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
    // Already discarded, and never tracked, so there is nothing to hold on to.
    if (!settled) {
      _thumbnailHandles.add(handle);
    }
  }

  /// Re-queues cells the bounded scheduler dropped, or that failed while the
  /// panel was off-screen.
  ///
  /// This used to stop after three attempts to avoid re-decoding a panel
  /// forever. That turned a transient shortage into a permanent one: the
  /// thumbnail queue drops its newest work when full, and each drop counts as
  /// an attempt, so a run of panels competing for device thumbnails could burn
  /// all three attempts in a couple of seconds and then sit as placeholders for
  /// as long as they stayed mounted. Attempts now back off instead of running
  /// out, which costs nothing once a panel is complete because the guard below
  /// stops scheduling entirely.
  void _scheduleUpgradeRetry() {
    if (_persistentExact ||
        !mounted ||
        _upgradeRetryTimer != null ||
        _upgradeAttempts >= _maxUpgradeAttempts ||
        _mergedIndexes.containsAll(_upgradeIndexes)) {
      return;
    }
    final backoff = _upgradeRetryDelay * (1 << _upgradeAttempts.clamp(0, 4));
    _upgradeRetryTimer = Timer(backoff > _maxUpgradeRetryDelay ? _maxUpgradeRetryDelay : backoff, () {
      _upgradeRetryTimer = null;
      if (!mounted || _persistentExact) {
        return;
      }
      if (_pendingIndexes.isNotEmpty || _atlasBuilding) {
        _scheduleUpgradeRetry();
        return;
      }
      if (widget.deferHighResolution || !_viewportState().visible) {
        // Still off-screen or still being flung: try again later instead of
        // competing with the panels the person is actually looking at.
        _scheduleUpgradeRetry();
        return;
      }
      _upgradeAttempts++;
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

  String? _thumbHashFor(BaseAsset asset) => denseThumbHashOf(asset);

  void _scheduleMetadataRetry({Duration? delay}) {
    if (_metadataRetryTimer != null || !mounted || _persistentExact || _baseAtlasReady) {
      return;
    }
    // A full screen of dense panels can all be rejected by the bounded atlas
    // queue at once. Retrying every 80ms turned that into a storm that starved
    // the very panels it was waiting on, so back off instead.
    // Clamped before the shift: `80 << retries` overflows to a negative number
    // past sixty-odd retries, and a negative Duration fires the timer at once,
    // turning the backoff into the retry storm it exists to prevent.
    final backoff = delay ?? Duration(milliseconds: 80 << math.min(_metadataRetries, 4));
    _metadataRetries++;
    _metadataRetryTimer = Timer(backoff, () {
      _metadataRetryTimer = null;
      if (mounted && !_metadataAtlasRequested) {
        _queueVisibleOverviewWork();
      }
    });
  }

  Future<void> _buildThumbhashAtlas(int generation, {required int priority}) async {
    final assets = _assets;
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
    // Read here for the same reason: the worker choice must not reach back into
    // this State from inside the closure.
    final signature = _contentSignature;
    try {
      DenseGridStats.thumbhashAtlasBuilds++;
      final result = await _denseMetadataAtlasQueue.schedule(() {
        if (!mounted || generation != _generation) {
          throw const _DenseLoadCancelled();
        }
        return _buildDenseThumbhashAtlasInBackground(
          hashes: hashes,
          targetPixels: metadataPixels,
          columnCount: columnCount,
          affinity: signature,
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
      // Same reasoning as the upgrade loop: the metadata retry is what repairs
      // the fast path, so resolving thumbnails must not be able to cost the
      // panel its retry. Without this, one throw here left a panel showing
      // nothing but placeholder colour for as long as it stayed on screen.
      try {
        _queueMissingActualThumbnails(generation: generation);
      } finally {
        _scheduleMetadataRetry(delay: const Duration(milliseconds: 180));
      }
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
    final assets = _assets;
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
    // The painter already draws decoded cells over the fallback texture, so a
    // thumbnail can be on screen the frame after it resolves. Waiting for the
    // composite to run was what made sharpening take seconds; the composite is
    // now only an optimisation that collapses these draws into one texture.
    // Repaints coalesce to at most one per frame.
    _scheduleRepaint();
  }

  void _scheduleCompositeAtlas(int generation) {
    if (!mounted || generation != _generation || _persistentExact) {
      return;
    }
    var ready = 0;
    for (final image in _images) {
      if (image != null) {
        ready++;
      }
    }
    if (ready == 0) {
      if (_pendingIndexes.isEmpty) {
        _finalizeAtlas(generation);
      }
      return;
    }
    _compositeDirty = true;
    // Until a cell is composited the painter draws it individually, so collapse
    // them as soon as a meaningful batch exists. Thumbnails normally arrive far
    // slower than this, but a warm disk cache can deliver a whole panel at once.
    if (_pendingIndexes.isEmpty || ready >= widget.columnCount * 2) {
      _compositeTimer?.cancel();
      _compositeTimer = null;
      _compositeTier = 0;
      unawaited(_buildCompositeAtlas(generation));
      return;
    }
    // Every composite re-rasterises the whole panel, so they are batched. The
    // tier must be able to move *down*: an armed idle pass previously stayed
    // armed even when the rest of the panel landed milliseconds later, which
    // is what turned a fast load into a visible multi-second sharpen.
    final int tier;
    final Duration delay;
    if (_mergedIndexes.isEmpty) {
      tier = 1;
      delay = _compositeFirstDebounce;
    } else if (ready >= widget.columnCount) {
      tier = 2;
      delay = _compositeDebounce;
    } else {
      tier = 3;
      delay = _compositeIdleDebounce;
    }
    if (_compositeTimer != null && tier >= _compositeTier) {
      return;
    }
    _compositeTimer?.cancel();
    _compositeTier = tier;
    _compositeTimer = Timer(delay, () {
      _compositeTimer = null;
      _compositeTier = 0;
      if (mounted && generation == _generation) {
        unawaited(_buildCompositeAtlas(generation));
      }
    });
  }

  Future<void> _buildCompositeAtlas(int generation) async {
    final assets = _assets;
    if (_atlasBuilding || _persistentExact || assets == null || !mounted || generation != _generation) {
      return;
    }
    if (!_images.any((image) => image != null)) {
      return;
    }
    _atlasBuilding = true;
    _compositeDirty = false;
    DenseGridStats.compositeAtlasBuilds++;
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
    if (merged.isNotEmpty) {
      // Progress refunds the retry budget. The bound exists to stop a panel
      // that genuinely cannot resolve from re-queueing itself forever, not to
      // cap how long a panel that is still filling in may take. A dense screen
      // asks for more cells than the thumbnail queue holds, so a panel can burn
      // attempts on requests that were discarded rather than tried - which is
      // how a bound of three became a permanent blur before, and how a bound of
      // eight could do the same.
      _upgradeAttempts = 0;
    }
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
    } else {
      // Keep the unfinished work under its content as well, with a record of
      // which cells it already holds, so coming back to it resumes instead of
      // starting over. Tagged rather than signed with the content signature so
      // it can never be mistaken for a finished panel.
      _denseRowAtlasCache.put(
        _partialAtlasKey,
        atlas,
        signature: 'partial:$_contentSignature',
        merged: Set<int>.of(_mergedIndexes),
      );
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

  /// Marks a panel final once every one of its cells carries a real thumbnail.
  ///
  /// A panel is never marked final on a partial result. An earlier build forced
  /// this after a few failed retries to avoid redoing work, which meant one
  /// offline moment could bake a blurry or grey panel into the on-disk cache
  /// permanently. Redoing the work is cheap by comparison, because the
  /// thumbnails that did succeed are still in the shared thumbnail disk cache.
  void _finalizeAtlas(int generation) {
    final atlas = _atlas;
    if (!mounted || generation != _generation || _persistentExact || atlas == null || _atlasBuilding) {
      return;
    }
    if (_atlasCellPixels != _targetPixels || !_baseAtlasReady || !_mergedIndexes.containsAll(_upgradeIndexes)) {
      _scheduleUpgradeRetry();
      return;
    }
    _persistentExact = true;
    _atlasSignature = _contentSignature;
    _denseRowAtlasCache.put(_completeAtlasKey, atlas, signature: _contentSignature);
    _denseRowAtlasCache.put(_slotAtlasKey, atlas, signature: _contentSignature);
    unawaited(_persistAtlas(atlas, exact: true));
  }

  /// The thumbnail is requested at exactly the cell size, not a rounded one.
  ///
  /// Quantising these so neighbouring zoom levels share a cache entry was tried
  /// and measured: changing zoom refetched 1104 photos quantised against 1070
  /// unquantised, which is no improvement. Returning to a zoom level already
  /// visited refetches four, so the cache was never losing what it had - a
  /// denser grid simply shows more photos, and those fetches are for photos that
  /// had never been on screen. Rounding up would have cost twice the bytes per
  /// thumbnail at some zoom levels to buy that.
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
    _compositeTier = 0;
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
    final assets = _assets;
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
        // Deliberately not flagged complex. The painter collapsed to a single
        // atlas draw, so hinting the raster cache only allocated an offscreen
        // surface per panel - two dozen of them at 48 columns - and the region
        // of that surface the painter did not cover is where a foreign light
        // grey was surfacing.
        willChange: reflowActive,
        painter: _DenseAssetRowPainter(
          images: _images,
          atlas: _atlas,
          assetKeys: _assetKeys,
          columnCount: widget.columnCount,
          tileExtent: widget.tileExtent,
          backgroundColor: _surfaceTone,
          placeholderColor: _placeholderTone,
          atlasHidesPlaceholder: _persistentExact && _atlas != null,
          upgradeCells: _upgradeIndexes.length,
          mergedCells: _mergedIndexes.length,
          pendingCells: _pendingIndexes.length,
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
      // Measured, not assumed. Removing this lowers the median frame cost at
      // eighteen columns from about 5.6ms to 4.7ms, but the spread across
      // repeated identical sweeps goes from 1.8ms to 4.8ms, with one sweep at
      // 9.1ms. Without a boundary any panel repainting dirties all of them, so
      // frames become cheap or expensive depending on what happened to change -
      // and stutter is the expensive tail, not the median. Kept deliberately.
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
  final Color backgroundColor;
  final Color placeholderColor;
  /// Whether the atlas is known to be opaque over every cell the panel fills.
  ///
  /// True only for a finished panel, where every occupied cell carries a real
  /// thumbnail. The placeholder fill underneath is then covered pixel for pixel
  /// and painting it is pure overdraw - a third full pass over the panel on
  /// every frame it is on screen, on top of the background and the atlas.
  final bool atlasHidesPlaceholder;
  /// Why a panel has not finished, for the on-device loading tests.
  ///
  /// A panel counts as finished when every cell it wants upgraded has been
  /// merged and nothing is still in flight. Reporting the three numbers
  /// separately is the difference between knowing a panel is stuck and knowing
  /// which of those it is stuck on.
  final int upgradeCells;
  final int mergedCells;
  final int pendingCells;
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
    required this.backgroundColor,
    required this.placeholderColor,
    required this.atlasHidesPlaceholder,
    required this.upgradeCells,
    required this.mergedCells,
    required this.pendingCells,
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
    // A panel owns every pixel it is given. The cells a bucket does not fill
    // are still part of this surface, and leaving them transparent meant they
    // showed whatever the compositor had beneath - which on some devices is a
    // light grey that belongs to no palette in this app.
    canvas.drawRect(Offset.zero & size, Paint()..color = backgroundColor);
    if (!isReflowing && !atlasHidesPlaceholder) {
      // Painted under everything else so a panel is never invisible, whatever
      // stage of loading it is in. During a zoom reflow the cells are moving,
      // so a static fill would not line up and is skipped.
      final fill = Paint()..color = placeholderColor;
      for (final rect in denseTimelineOccupiedRects(
        itemCount: itemCount,
        columnCount: columnCount,
        tileExtent: tileExtent,
        containerWidth: size.width,
        textDirection: textDirection,
      )) {
        canvas.drawRect(rect, fill);
      }
    }
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
        filterQuality: FilterQuality.low,
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
      oldDelegate.backgroundColor != backgroundColor ||
      oldDelegate.placeholderColor != placeholderColor ||
      oldDelegate.atlasHidesPlaceholder != atlasHidesPlaceholder ||
      oldDelegate.textDirection != textDirection ||
      oldDelegate.layoutAnimation != layoutAnimation ||
      oldDelegate.previousRects != previousRects;
}
