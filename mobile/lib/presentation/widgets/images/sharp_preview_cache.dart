import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';

/// A zoom-independent cache of real thumbnail pixels, never ThumbHashes.
/// Sheets are retained once, not copied into thousands of per-photo bitmaps.
/// Leases keep visible pixels valid even when the LRU is evicted.
final sharpPreviewCache = SharpPreviewCache();

Object sharpPreviewKey(BaseAsset asset) => (
  asset.localId ?? asset.remoteId,
  asset.updatedAt,
  asset.isEdited,
  asset.width,
  asset.height,
  asset is LocalAsset ? asset.adjustmentTime : null,
);

class SharpPreviewCell {
  final ui.Image image;
  final Rect source;
  const SharpPreviewCell(this.image, this.source);
  int get pixels => source.shortestSide.floor();
}

class SharpPreviewLease {
  final Map<int, SharpPreviewCell> cells;
  final List<ui.Image> _images;
  SharpPreviewLease(this.cells, this._images);
  void dispose() {
    for (final image in _images) {
      image.dispose();
    }
    _images.clear();
    cells.clear();
  }
}

class _Sheet {
  final ui.Image image;
  final Map<Object, Rect> cells;
  _Sheet(this.image, this.cells);
  int get bytes => image.width * image.height * 4;
}

class SharpPreviewCache {
  final int maximumBytes;
  SharpPreviewCache({this.maximumBytes = 24 * 1024 * 1024});
  final LinkedHashMap<int, _Sheet> _sheets = LinkedHashMap();
  final Map<Object, int> _index = {};
  int _serial = 0;
  int _bytes = 0;
  int get bytes => _bytes;

  void put(ui.Image image, Map<Object, Rect> cells) {
    final bytes = image.width * image.height * 4;
    if (cells.isEmpty || bytes > maximumBytes) {
      return;
    }
    final accepted = <Object, Rect>{};
    for (final entry in cells.entries) {
      final old = _sheets[_index[entry.key]]?.cells[entry.key];
      // Never replace sharp pixels with a lower resolution zoom.
      if (old == null || old.shortestSide < entry.value.shortestSide) {
        accepted[entry.key] = entry.value;
      }
    }
    if (accepted.isEmpty) {
      return;
    }
    final id = ++_serial;
    _sheets[id] = _Sheet(image.clone(), accepted);
    _bytes += bytes;
    for (final key in accepted.keys) {
      _index[key] = id;
    }
    while (_bytes > maximumBytes || _index.length > 12000) {
      final oldest = _sheets.keys.first;
      final sheet = _sheets.remove(oldest)!;
      for (final key in sheet.cells.keys) {
        if (_index[key] == oldest) {
          _index.remove(key);
        }
      }
      _bytes -= sheet.bytes;
      sheet.image.dispose();
    }
  }

  SharpPreviewLease take(List<Object> keys) {
    final clones = <int, ui.Image>{};
    final cells = <int, SharpPreviewCell>{};
    for (var i = 0; i < keys.length; i++) {
      final id = _index[keys[i]];
      final sheet = _sheets.remove(id);
      if (sheet == null || id == null) {
        continue;
      }
      _sheets[id] = sheet;
      final image = clones.putIfAbsent(id, sheet.image.clone);
      cells[i] = SharpPreviewCell(image, sheet.cells[keys[i]]!);
    }
    return SharpPreviewLease(cells, clones.values.toList());
  }

  void clear() {
    for (final sheet in _sheets.values) {
      sheet.image.dispose();
    }
    _sheets.clear();
    _index.clear();
    _bytes = 0;
  }
}
