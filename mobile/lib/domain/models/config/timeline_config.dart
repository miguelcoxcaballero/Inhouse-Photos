import 'package:immich_mobile/domain/models/timeline.model.dart';

const int minTimelineTilesPerRow = 2;
const int maxTimelineTilesPerRow = 48;
const List<int> timelineTilesPerRowSteps = [2, 3, 4, 5, 6, 12, 18, 24, 36, 48];

int timelineTilesPerRowStepIndex(int value) => timelineTilesPerRowSteps.indexOf(normalizeTimelineTilesPerRow(value));

int normalizeTimelineTilesPerRow(int value) {
  var nearest = timelineTilesPerRowSteps.first;
  var distance = (value - nearest).abs();
  for (final candidate in timelineTilesPerRowSteps.skip(1)) {
    final candidateDistance = (value - candidate).abs();
    if (candidateDistance < distance) {
      nearest = candidate;
      distance = candidateDistance;
    }
  }
  return nearest;
}

class TimelineConfig {
  final int tilesPerRow;
  final GroupAssetsBy groupAssetsBy;
  final bool storageIndicator;

  const TimelineConfig({this.tilesPerRow = 4, this.groupAssetsBy = GroupAssetsBy.day, this.storageIndicator = true});

  TimelineConfig copyWith({int? tilesPerRow, GroupAssetsBy? groupAssetsBy, bool? storageIndicator}) => TimelineConfig(
    tilesPerRow: tilesPerRow ?? this.tilesPerRow,
    groupAssetsBy: groupAssetsBy ?? this.groupAssetsBy,
    storageIndicator: storageIndicator ?? this.storageIndicator,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TimelineConfig &&
          other.tilesPerRow == tilesPerRow &&
          other.groupAssetsBy == groupAssetsBy &&
          other.storageIndicator == storageIndicator);

  @override
  int get hashCode => Object.hash(tilesPerRow, groupAssetsBy, storageIndicator);

  @override
  String toString() =>
      'TimelineConfig(tilesPerRow: $tilesPerRow, groupAssetsBy: $groupAssetsBy, storageIndicator: $storageIndicator)';
}
