import 'package:drift/drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/entities/local_asset.entity.drift.dart';
import 'package:immich_mobile/infrastructure/utils/asset.mixin.dart';
import 'package:immich_mobile/infrastructure/utils/drift_default.mixin.dart';

@TableIndex.sql('CREATE INDEX IF NOT EXISTS idx_local_asset_checksum ON local_asset_entity (checksum)')
@TableIndex.sql('CREATE INDEX IF NOT EXISTS idx_local_asset_cloud_id ON local_asset_entity (i_cloud_id)')
@TableIndex.sql('CREATE INDEX IF NOT EXISTS idx_local_asset_created_at ON local_asset_entity (created_at)')
// The timeline orders on the wall clock; without this the local arm of the
// merged query is a full table scan.
@TableIndex.sql(
  'CREATE INDEX IF NOT EXISTS idx_local_asset_local_date_time ON local_asset_entity (local_date_time DESC)',
)
// Finds photos that still need a preview generated. Partial on purpose: it only
// indexes the backlog, so it costs nothing once the backlog is empty, which is
// the steady state. A plain index would carry every row in the library forever
// to answer a question that is almost always "none".
@TableIndex.sql('''
CREATE INDEX IF NOT EXISTS idx_local_asset_missing_thumb_hash
ON local_asset_entity (id) WHERE thumb_hash IS NULL
''')
class LocalAssetEntity extends Table with DriftDefaultsMixin, AssetEntityMixin {
  const LocalAssetEntity();

  TextColumn get id => text()();
  TextColumn get checksum => text().nullable()();

  /// The capture time expressed as a timezone-independent wall-clock value.
  ///
  /// [createdAt] remains the real UTC instant. This value mirrors the server's
  /// `localDateTime` so a device asset stays in the same timeline position when
  /// its local row is replaced by the uploaded remote row.
  DateTimeColumn get localDateTime => dateTime().nullable()();

  /// A ThumbHash of this photo, generated on device.
  ///
  /// Remote assets get one from the server, which is what lets the grid paint a
  /// blurry preview the instant a panel appears. Local photos had no equivalent,
  /// so their cells stayed blank until a real thumbnail decoded - which is why
  /// not-yet-backed-up photos were the ones visibly loading. Filled in by a
  /// background pass; null means "not generated yet", never "has none".
  TextColumn get thumbHash => text().nullable()();

  // Only used during backup to mirror the favorite status of the asset in the server
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();

  IntColumn get orientation => integer().withDefault(const Constant(0))();

  TextColumn get iCloudId => text().nullable()();

  DateTimeColumn get adjustmentTime => dateTime().nullable()();

  RealColumn get latitude => real().nullable()();

  RealColumn get longitude => real().nullable()();

  IntColumn get playbackStyle => intEnum<AssetPlaybackStyle>().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

DateTime timelineLocalDateTime(DateTime instant) {
  final local = instant.toLocal();
  return DateTime.utc(
    local.year,
    local.month,
    local.day,
    local.hour,
    local.minute,
    local.second,
    local.millisecond,
    local.microsecond,
  );
}

extension LocalAssetEntityDataDomainExtension on LocalAssetEntityData {
  LocalAsset toDto({String? remoteId}) => LocalAsset(
    id: id,
    name: name,
    checksum: checksum,
    type: type,
    createdAt: createdAt,
    updatedAt: updatedAt,
    durationMs: durationMs,
    isFavorite: isFavorite,
    height: height,
    width: width,
    remoteId: remoteId,
    orientation: orientation,
    playbackStyle: playbackStyle,
    adjustmentTime: adjustmentTime,
    latitude: latitude,
    longitude: longitude,
    cloudId: iCloudId,
    isEdited: false,
  );
}
