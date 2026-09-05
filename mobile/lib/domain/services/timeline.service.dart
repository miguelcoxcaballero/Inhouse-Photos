import 'dart:async';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:immich_mobile/utils/async_mutex.dart';

typedef TimelineAssetSource = Future<List<BaseAsset>> Function(int index, int count);

typedef TimelineBucketSource = Stream<List<Bucket>> Function();

/// Reads the rows that follow a position in the timeline's ordering.
///
/// Optional. Where a source provides it, scrolling forward continues from the
/// last row already held instead of counting rows to an offset - `OFFSET` makes
/// SQLite produce and discard everything before it, which measured 114ms fifty
/// five thousand rows into a library against 31ms for the same read continuing
/// from a key.
typedef TimelineAssetSourceAfter = Future<List<BaseAsset>> Function(BaseAsset after, int count);

typedef TimelineQuery = ({
  TimelineAssetSource assetSource,
  TimelineAssetSourceAfter? assetSourceAfter,
  TimelineBucketSource bucketSource,
  TimelineOrigin origin,
});

/// Folds day buckets into the single bucket a continuous grid needs.
///
/// The asset list keeps its order, so the grid stays chronological; it simply
/// has no day boundary to break a row at. Local-only assets are already part of
/// the same list and are counted here like any other.
@visibleForTesting
List<Bucket> collapseTimelineBuckets(List<Bucket> buckets) {
  var total = 0;
  for (final bucket in buckets) {
    total += bucket.assetCount;
  }
  return total == 0 ? const [] : [Bucket(assetCount: total)];
}

enum TimelineOrigin {
  main,
  localAlbum,
  remoteAlbum,
  remoteAssets,
  favorite,
  trash,
  archive,
  lockedFolder,
  video,
  place,
  person,
  map,
  search,
  deepLink,
  albumActivities,
  folder,
  recentlyAdded,
}

class TimelineFactory {
  final DriftTimelineRepository _timelineRepository;
  final SettingsRepository _settingsRepository;

  const TimelineFactory({required this._timelineRepository, required this._settingsRepository});

  GroupAssetsBy get groupBy {
    final group = _settingsRepository.appConfig.timeline.groupAssetsBy;
    // Auto grouping is not supported in the new timeline yet, and "no grouping"
    // is applied on top of day buckets rather than in SQL, so both fall back to
    // day here.
    return group == GroupAssetsBy.month ? GroupAssetsBy.month : GroupAssetsBy.day;
  }

  bool get _isUngrouped => _settingsRepository.appConfig.timeline.groupAssetsBy == GroupAssetsBy.none;

  /// Wraps a query so the timeline renders as one continuous grid.
  ///
  /// The queries always group by day; collapsing the buckets here keeps the
  /// asset ordering, the local/remote merge and every timeline origin exactly
  /// as they are, and simply removes the day boundaries the grid draws headers
  /// and row breaks at. Doing it in SQL instead would mean a separate bucket
  /// path per origin and a date column that has nothing to hold.
  TimelineService _timeline(TimelineQuery query) {
    if (!_isUngrouped) {
      return TimelineService(query);
    }
    return TimelineService((
      assetSource: query.assetSource,
      assetSourceAfter: query.assetSourceAfter,
      bucketSource: () => query.bucketSource().map(collapseTimelineBuckets),
      origin: query.origin,
    ));
  }

  TimelineService main(List<String> timelineUsers) => _timeline(_timelineRepository.main(timelineUsers, groupBy));

  TimelineService localAlbum({required String albumId}) => _timeline(_timelineRepository.localAlbum(albumId, groupBy));

  TimelineService remoteAlbum({required String albumId}) =>
      _timeline(_timelineRepository.remoteAlbum(albumId, groupBy));

  TimelineService remoteAssets(String userId) => _timeline(_timelineRepository.remote(userId, groupBy));

  TimelineService recentlyAdded(String userId) => _timeline(_timelineRepository.recentlyAdded(userId, groupBy));

  TimelineService favorite(String userId) => _timeline(_timelineRepository.favorite(userId, groupBy));

  TimelineService trash(String userId) => _timeline(_timelineRepository.trash(userId, groupBy));

  TimelineService archive(String userId) => _timeline(_timelineRepository.archived(userId, groupBy));

  TimelineService lockedFolder(String userId) => _timeline(_timelineRepository.locked(userId, groupBy));

  TimelineService video(String userId) => _timeline(_timelineRepository.video(userId, groupBy));

  TimelineService place(String place) => _timeline(_timelineRepository.place(place, groupBy));

  TimelineService person(String userId, String personId) =>
      _timeline(_timelineRepository.person(userId, personId, groupBy));

  TimelineService fromAssets(List<BaseAsset> assets, TimelineOrigin type) =>
      _timeline(_timelineRepository.fromAssets(assets, type));

  TimelineService fromAssetStream(List<BaseAsset> Function() getAssets, Stream<int> assetCount, TimelineOrigin type) =>
      _timeline(_timelineRepository.fromAssetStream(getAssets, assetCount, type));

  TimelineService fromAssetsWithBuckets(List<BaseAsset> assets, TimelineOrigin type) =>
      _timeline(_timelineRepository.fromAssetsWithBuckets(assets, type));

  TimelineService map(List<String> userIds, TimelineMapOptions options) =>
      _timeline(_timelineRepository.map(userIds, options, groupBy));
}

class TimelineService {
  static const Duration _defaultBucketRefreshInterval = Duration(milliseconds: 750);

  final TimelineAssetSource _assetSource;
  final TimelineAssetSourceAfter? _assetSourceAfter;
  final TimelineBucketSource _bucketSource;
  final TimelineOrigin origin;
  final Duration _bucketRefreshInterval;
  final AsyncMutex _mutex = AsyncMutex();
  final StreamController<_TimelineBucketSnapshot> _publishedBuckets =
      StreamController<_TimelineBucketSnapshot>.broadcast(sync: true);
  final StreamController<int> _publishedAssets = StreamController<int>.broadcast(sync: true);
  int _bufferOffset = 0;
  List<BaseAsset> _buffer = [];
  StreamSubscription? _bucketSubscription;
  Timer? _bucketRefreshTimer;
  List<Bucket>? _pendingBuckets;
  _TimelineBucketSnapshot? _latestBucketSnapshot;
  bool _bucketRefreshRunning = false;
  bool _disposed = false;
  int _publishedBucketRevision = 0;

  int _totalAssets = 0;
  int get totalAssets => _totalAssets;
  int _revision = 0;
  int get revision => _revision;
  Stream<int> watchAssetChanges() => Stream<int>.multi((listener) {
    final subscription = _publishedAssets.stream.listen(listener.add, onDone: listener.close);
    listener.add(_revision);
    listener.onCancel = subscription.cancel;
  });

  TimelineService(TimelineQuery query, {Duration bucketRefreshInterval = _defaultBucketRefreshInterval})
    : this._(
        assetSource: query.assetSource,
        assetSourceAfter: query.assetSourceAfter,
        bucketSource: query.bucketSource,
        origin: query.origin,
        bucketRefreshInterval: bucketRefreshInterval,
      );

  TimelineService._({
    required this._assetSource,
    required this._assetSourceAfter,
    required this._bucketSource,
    required this.origin,
    required this._bucketRefreshInterval,
  }) {
    // Keep one database bucket subscription for the lifetime of the service.
    // The old implementation opened a second query for the UI and queued a
    // complete buffer reload for every upload event. A busy backup could then
    // leave hundreds of obsolete 8k-asset reads ahead of taps and painting.
    _bucketSubscription = _bucketSource().listen(
      _onBucketsChanged,
      onError: (Object error, StackTrace stackTrace) {
        if (!_disposed) {
          _publishedBuckets.addError(error, stackTrace);
        }
      },
    );
  }

  Stream<List<Bucket>> Function() get watchBuckets => _watchPublishedBuckets;

  Stream<List<Bucket>> _watchPublishedBuckets() => Stream<List<Bucket>>.multi((listener) {
    var observedRevision = -1;

    void publish(_TimelineBucketSnapshot snapshot) {
      if (snapshot.revision <= observedRevision) {
        return;
      }
      observedRevision = snapshot.revision;
      listener.add(snapshot.buckets);
    }

    // Subscribe before reading the replay value so an update cannot fall into
    // the gap between the two operations. The revision check removes the one
    // possible duplicate when a synchronous publish happens in that window.
    final subscription = _publishedBuckets.stream.listen(publish, onError: listener.addError, onDone: listener.close);
    final latest = _latestBucketSnapshot;
    if (latest != null) {
      publish(latest);
    }
    listener.onCancel = subscription.cancel;
  });

  void _onBucketsChanged(List<Bucket> buckets) {
    if (_disposed) {
      return;
    }
    // Only the newest database snapshot matters. While a buffer read is in
    // flight, newer snapshots replace the pending one instead of adding more
    // work to the mutex queue.
    _pendingBuckets = buckets;
    if (_revision == 0 && !_bucketRefreshRunning && _bucketRefreshTimer == null) {
      unawaited(_processPendingBuckets());
      return;
    }
    _scheduleBucketRefresh();
  }

  void _scheduleBucketRefresh() {
    if (_disposed || _bucketRefreshRunning || _bucketRefreshTimer != null || _pendingBuckets == null) {
      return;
    }
    _bucketRefreshTimer = Timer(_bucketRefreshInterval, () {
      _bucketRefreshTimer = null;
      unawaited(_processPendingBuckets());
    });
  }

  Future<void> _processPendingBuckets() async {
    if (_disposed || _bucketRefreshRunning) {
      return;
    }
    final buckets = _pendingBuckets;
    if (buckets == null) {
      return;
    }
    _pendingBuckets = null;
    _bucketRefreshRunning = true;
    try {
      await _mutex.run(() => _applyBuckets(buckets));
    } catch (error, stackTrace) {
      if (!_disposed) {
        _publishedBuckets.addError(error, stackTrace);
      }
    } finally {
      _bucketRefreshRunning = false;
      if (_pendingBuckets != null) {
        _scheduleBucketRefresh();
      }
    }
  }

  Future<void> _applyBuckets(List<Bucket> buckets) async {
    // Database content and grid geometry have separate notifications. A
    // same-count upload or edit refreshes metadata without reconstructing all
    // slivers. Unchanged panels keep their decoded textures.
    final published = _latestBucketSnapshot?.buckets;
    final sameLayout =
        published != null &&
        _buffer.isNotEmpty &&
        published.length == buckets.length &&
        const ListEquality<Bucket>().equals(published, buckets);

    final totalAssets = buckets.fold<int>(0, (acc, bucket) => acc + bucket.assetCount);

    if (totalAssets == 0) {
      _bufferOffset = 0;
      _buffer = [];
    } else {
      final int offset;
      final int count;
      // A dense overview can temporarily request several thousand assets. Do
      // not repeat that huge read for every upload notification: refresh one
      // normal navigation window and let demand-loading fetch another range.
      if (_bufferOffset >= totalAssets || _buffer.isEmpty) {
        offset = 0;
        count = math.min(kTimelineAssetLoadBatchSize, totalAssets);
      } else {
        offset = _bufferOffset;
        count = math.min(kTimelineAssetLoadBatchSize, totalAssets - _bufferOffset);
      }
      _buffer = await _assetSource(offset, count);
      _bufferOffset = offset;
    }

    if (_disposed) {
      return;
    }
    // Equal bucket counts do not mean equal photos (upload reconciliation,
    // edits and thumbnail hashes all change without affecting day geometry).
    // Re-read only the bounded navigation window.
    // Publish the buckets only after their matching asset window is coherent.
    // All consumers share this replaying stream, so relayout no longer opens a
    // duplicate Drift query or races ahead of the service buffer.
    _totalAssets = totalAssets;
    _revision++;
    _publishedAssets.add(_revision);
    // Data outside the current window can have changed as well. Invalidate
    // demand-loaded metadata, but do not regenerate the day/row geometry.
    if (sameLayout) {
      return;
    }
    final snapshot = _TimelineBucketSnapshot(++_publishedBucketRevision, List.unmodifiable(buckets));
    _latestBucketSnapshot = snapshot;
    _publishedBuckets.add(snapshot);
    EventStream.shared.emit(const TimelineReloadEvent());
  }

  Future<List<BaseAsset>> loadAssets(int index, int count) => _mutex.run(() => _loadAssets(index, count));

  Future<List<BaseAsset>> _loadAssets(int index, int count) async {
    if (hasRange(index, count)) {
      return getAssets(index, count);
    }

    // if the requested offset is greater than the cached offset, the user scrolls forward "down"
    final bool forward = _bufferOffset < index;

    // make sure to load a meaningful amount of data (and not only the requested slice)
    // otherwise, each call to [loadAssets] would result in DB call trashing performance
    // fills small requests to [kTimelineAssetLoadBatchSize], adds some legroom into the opposite scroll direction for large requests
    final len = math.max(kTimelineAssetLoadBatchSize, count + kTimelineAssetLoadOppositeSize);
    // when scrolling forward, start shortly before the requested offset
    // when scrolling backward, end shortly after the requested offset to guard against the user scrolling
    // in the other direction a tiny bit resulting in another required load from the DB
    final start = math.max(
      0,
      forward
          ? index - kTimelineAssetLoadOppositeSize
          : (len > kTimelineAssetLoadBatchSize ? index : index + count - len),
    );

    // Scrolling forward into the rows immediately after what is already held
    // can continue from the last of them rather than counting back to an
    // offset. Reading a chunk 55,000 rows down measured 114ms by offset and
    // 31ms by key, and the offset form grows with depth while the key form does
    // not - which is why far into the library fills in more slowly than near
    // the top.
    //
    // Restricted to the case where continuing actually lands on what was asked
    // for: the read starts at the end of the buffer, so it only helps when the
    // requested range begins there or within the same read.
    final continuation = _assetSourceAfter;
    final bufferEnd = _bufferOffset + _buffer.length;
    final key = _buffer.isEmpty ? null : _buffer.last.timelineAt;
    if (continuation != null && key != null && forward && index >= bufferEnd && index + count <= bufferEnd + len) {
      _buffer = await continuation(_buffer.last, len);
      _bufferOffset = bufferEnd;
      return getAssets(index, count);
    }

    _buffer = await _assetSource(start, len);
    _bufferOffset = start;

    return getAssets(index, count);
  }

  bool hasRange(int index, int count) =>
      index >= 0 &&
      index < _totalAssets &&
      index >= _bufferOffset &&
      index + count <= _bufferOffset + _buffer.length &&
      index + count <= _totalAssets;

  List<BaseAsset> getAssets(int index, int count) {
    if (!hasRange(index, count)) {
      throw RangeError('TimelineService::getAssets Index out of range');
    }
    int start = index - _bufferOffset;
    return _buffer.slice(start, start + count);
  }

  // Preload assets around the given index for asset viewer
  Future<void> preloadAssets(int index) => _mutex.run(() => _loadAssets(index, math.min(5, _totalAssets - index)));

  BaseAsset getRandomAsset() => _buffer.elementAt(math.Random().nextInt(_buffer.length));

  BaseAsset getAsset(int index) {
    if (!hasRange(index, 1)) {
      throw RangeError(
        'TimelineService::getAsset Index $index not in buffer range [$_bufferOffset, ${_bufferOffset + _buffer.length})',
      );
    }
    return _buffer.elementAt(index - _bufferOffset);
  }

  /// Gets an asset at the given index, automatically loading the buffer if needed.
  /// This is an async version that can handle out-of-range indices by loading the appropriate buffer.
  Future<BaseAsset?> getAssetAsync(int index) async {
    if (index < 0 || index >= _totalAssets) {
      return null;
    }

    if (hasRange(index, 1)) {
      return _buffer.elementAt(index - _bufferOffset);
    }

    // Load the buffer containing the requested index
    try {
      final assets = await loadAssets(index, 1);
      return assets.isNotEmpty ? assets.first : null;
    } catch (e) {
      return null;
    }
  }

  /// Safely gets an asset at the given index without throwing a RangeError.
  /// Returns null if the index is out of bounds or not currently in the buffer.
  /// For automatic buffer loading, use getAssetAsync instead.
  BaseAsset? getAssetSafe(int index) {
    if (index < 0 || index >= _totalAssets || !hasRange(index, 1)) {
      return null;
    }
    return _buffer.elementAt(index - _bufferOffset);
  }

  /// Finds the index of an asset by its heroTag within the current buffer.
  /// Returns null if the asset is not found in the buffer.
  int? getIndex(String heroTag) {
    final index = _buffer.indexWhere((a) => a.heroTag == heroTag);
    return index >= 0 ? _bufferOffset + index : null;
  }

  Future<void> dispose() async {
    _disposed = true;
    _bucketRefreshTimer?.cancel();
    _bucketRefreshTimer = null;
    _pendingBuckets = null;
    await _bucketSubscription?.cancel();
    _bucketSubscription = null;
    await _publishedBuckets.close();
    await _publishedAssets.close();
    _buffer = [];
    _bufferOffset = 0;
  }
}

class _TimelineBucketSnapshot {
  final int revision;
  final List<Bucket> buckets;

  const _TimelineBucketSnapshot(this.revision, this.buckets);
}
