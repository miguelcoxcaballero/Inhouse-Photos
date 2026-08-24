import 'package:immich_mobile/providers/album/album_sort_by_options.provider.dart';

class AlbumConfig {
  final AlbumSortMode sortMode;
  final bool isReverse;
  final bool isGrid;
  final List<String> offlineAlbumIds;

  const AlbumConfig({
    this.sortMode = AlbumSortMode.mostRecent,
    this.isReverse = true,
    this.isGrid = false,
    this.offlineAlbumIds = const [],
  });

  AlbumConfig copyWith({AlbumSortMode? sortMode, bool? isReverse, bool? isGrid, List<String>? offlineAlbumIds}) =>
      AlbumConfig(
        sortMode: sortMode ?? this.sortMode,
        isReverse: isReverse ?? this.isReverse,
        isGrid: isGrid ?? this.isGrid,
        offlineAlbumIds: offlineAlbumIds ?? this.offlineAlbumIds,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AlbumConfig &&
          other.sortMode == sortMode &&
          other.isReverse == isReverse &&
          other.isGrid == isGrid &&
          _listEquals(other.offlineAlbumIds, offlineAlbumIds));

  @override
  int get hashCode => Object.hash(sortMode, isReverse, isGrid, Object.hashAll(offlineAlbumIds));

  @override
  String toString() =>
      'AlbumConfig(sortMode: $sortMode, isReverse: $isReverse, isGrid: $isGrid, offlineAlbumIds: $offlineAlbumIds)';
}

bool _listEquals(List<String> left, List<String> right) {
  if (identical(left, right)) {
    return true;
  }
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}
