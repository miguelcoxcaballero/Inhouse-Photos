import 'dart:io';

import 'package:async/async.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/infrastructure/entities/local_album.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/local_album_asset.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/local_asset.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/remote_asset.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/remote_asset_cloud_id.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/user.entity.drift.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';

void main() {
  late Drift db;

  setUp(() {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
  });

  tearDown(() async {
    await db.close();
  });

  test('mergedBucket falls back to createdAt when localDateTime is null', () async {
    const userId = 'user-1';
    final createdAt = DateTime(2024, 1, 1, 12);

    await db
        .into(db.userEntity)
        .insert(UserEntityCompanion.insert(id: userId, email: 'user-1@test.dev', name: 'User 1'));

    await db
        .into(db.remoteAssetEntity)
        .insert(
          RemoteAssetEntityCompanion.insert(
            id: 'asset-1',
            name: 'asset-1.jpg',
            type: AssetType.image,
            checksum: 'checksum-1',
            ownerId: userId,
            visibility: AssetVisibility.timeline,
            createdAt: Value(createdAt),
            updatedAt: Value(createdAt),
            uploadedAt: Value(createdAt),
            localDateTime: const Value(null),
          ),
        );

    final buckets = await db.mergedAssetDrift.mergedBucket(groupBy: GroupAssetsBy.day.index, userIds: [userId]).get();

    expect(buckets, hasLength(1));
    expect(buckets.single.assetCount, 1);
    expect(buckets.single.bucketDate, isNotEmpty);
  });

  test('local asset keeps its wall-clock bucket and identity after upload', () async {
    const userId = 'timezone-user';
    const localId = 'timezone-local';
    const checksum = 'timezone-checksum';
    final capturedAt = DateTime.utc(2024, 1, 1, 22, 30);
    // A floating UTC value intentionally represents the device wall clock,
    // matching the server's localDateTime convention.
    final timelineAt = DateTime.utc(2024, 1, 2, 1, 30);

    await db
        .into(db.userEntity)
        .insert(UserEntityCompanion.insert(id: userId, email: 'timezone@test.dev', name: 'Timezone'));
    await db
        .into(db.localAlbumEntity)
        .insert(
          LocalAlbumEntityCompanion.insert(
            id: 'timezone-camera',
            name: 'Camera',
            backupSelection: BackupSelection.selected,
          ),
        );
    await db
        .into(db.localAssetEntity)
        .insert(
          LocalAssetEntityCompanion.insert(
            id: localId,
            name: 'timezone.jpg',
            type: AssetType.image,
            checksum: const Value(checksum),
            createdAt: Value(capturedAt),
            localDateTime: Value(timelineAt),
          ),
        );
    await db
        .into(db.localAlbumAssetEntity)
        .insert(LocalAlbumAssetEntityCompanion.insert(albumId: 'timezone-camera', assetId: localId));

    final localAssets = await db.mergedAssetDrift.mergedAsset(userIds: [userId], limit: (_) => Limit(20, 0)).get();
    final localBuckets = await db.mergedAssetDrift
        .mergedBucket(groupBy: GroupAssetsBy.day.index, userIds: [userId])
        .get();

    expect(localAssets.single.localId, localId);
    expect(localAssets.single.timelineAt, timelineAt);
    expect(localBuckets.single.bucketDate, '2024-01-02');

    await db
        .into(db.remoteAssetEntity)
        .insert(
          RemoteAssetEntityCompanion.insert(
            id: 'timezone-remote',
            name: 'timezone.jpg',
            type: AssetType.image,
            checksum: checksum,
            ownerId: userId,
            visibility: AssetVisibility.timeline,
            createdAt: Value(capturedAt),
            updatedAt: Value(capturedAt),
            uploadedAt: Value(capturedAt),
            localDateTime: Value(timelineAt),
          ),
        );

    final remoteAssets = await db.mergedAssetDrift.mergedAsset(userIds: [userId], limit: (_) => Limit(20, 0)).get();
    final remoteBuckets = await db.mergedAssetDrift
        .mergedBucket(groupBy: GroupAssetsBy.day.index, userIds: [userId])
        .get();

    expect(remoteAssets, hasLength(1));
    expect(remoteAssets.single.remoteId, 'timezone-remote');
    expect(remoteAssets.single.localId, localId);
    expect(remoteAssets.single.timelineAt, timelineAt);
    expect(remoteBuckets.single.bucketDate, '2024-01-02');
  });

  test('mergedAsset orders by the wall clock a photo was taken at, not the instant', () async {
    const userId = 'cross-timezone-user';
    final olderInstant = DateTime.parse('2024-01-01T10:00:00+02:00');
    final newerInstant = DateTime.parse('2024-01-01T09:30:00Z');

    // These are floating wall-clock values, as supplied by the server. The
    // photo captured first reads 10:00 on the clock it was taken by, because
    // that clock was two hours ahead; the one captured 90 minutes later reads
    // 09:30. A timeline sorted on the instant puts them in the order the
    // shutter fired, which is not the order they appear to have been taken in.
    final olderWallClock = DateTime.utc(2024, 1, 1, 10);
    final newerWallClock = DateTime.utc(2024, 1, 1, 9, 30);

    await db.into(db.userEntity).insert(UserEntityCompanion.insert(id: userId, email: 'zones@test.dev', name: 'Zones'));
    await db.batch((batch) {
      batch.insert(
        db.remoteAssetEntity,
        RemoteAssetEntityCompanion.insert(
          id: 'older-at-10',
          name: 'older-at-10.jpg',
          type: AssetType.image,
          checksum: 'older-at-10-checksum',
          ownerId: userId,
          visibility: AssetVisibility.timeline,
          createdAt: Value(olderInstant),
          updatedAt: Value(olderInstant),
          uploadedAt: Value(olderInstant),
          localDateTime: Value(olderWallClock),
        ),
      );
      batch.insert(
        db.remoteAssetEntity,
        RemoteAssetEntityCompanion.insert(
          id: 'newer-at-09-30',
          name: 'newer-at-09-30.jpg',
          type: AssetType.image,
          checksum: 'newer-at-09-30-checksum',
          ownerId: userId,
          visibility: AssetVisibility.timeline,
          createdAt: Value(newerInstant),
          updatedAt: Value(newerInstant),
          uploadedAt: Value(newerInstant),
          localDateTime: Value(newerWallClock),
        ),
      );
    });

    final assets = await db.mergedAssetDrift.mergedAsset(userIds: [userId], limit: (_) => Limit(20, 0)).get();

    // Wall clock decides, so the 10:00 photo leads even though it was shot
    // first. This is the point of the column: the grid reads the way the
    // photos were taken, and the day headers agree with the timestamps drawn
    // on the tiles under them.
    expect(assets.map((asset) => asset.remoteId), ['older-at-10', 'newer-at-09-30']);
    expect(assets.first.createdAt.isBefore(assets.last.createdAt), isTrue);
    expect(assets.map((asset) => asset.timelineAt), [olderWallClock, newerWallClock]);
  });

  test('the timeline read is served by its indexes, not a full sort', () async {
    // 3.1.65 ordered on a computed date expression. EXPLAIN QUERY PLAN shows
    // what that costs: the whole result set is sorted and the local arm is
    // scanned end to end, on every chunk read, behind the one mutex the grid
    // waits on. Adding indexes does not rescue it either - the expression has
    // to go. This asserts the plan itself rather than the shape of the SQL.
    final sql = File('lib/infrastructure/entities/merged_asset.drift.dart')
        .readAsStringSync()
        .split("'")
        .firstWhere((piece) => piece.startsWith('SELECT rae.id AS remote_id'), orElse: () => '');
    expect(sql, isNotEmpty, reason: 'could not find the merged asset query in the generated source');

    final plan = await db
        .customSelect('EXPLAIN QUERY PLAN ${sql.replaceAll(r'IN ($expandeduserIds)', "IN ('u')").replaceAll(r'${generatedlimit.sql}', '')} LIMIT 10')
        .get();
    final details = plan.map((row) => row.data['detail'].toString()).toList();
    final sorts = details.where((d) => d.contains('USE TEMP B-TREE FOR')).toList();

    expect(sorts, isNotEmpty, reason: 'expected the compound select to report how it orders');
    for (final sort in sorts) {
      expect(
        sort,
        contains('LAST TERM'),
        reason: 'the leading sort term must come from an index, not a full sort: ${details.join(' | ')}',
      );
    }
    expect(
      details.any((d) => d.contains('SCAN lae USING INDEX')),
      isTrue,
      reason: 'the local arm must be index-ordered: ${details.join(' | ')}',
    );
    expect(
      details.any((d) => d.contains('SEARCH rae USING INDEX idx_remote_asset_owner_visibility_deleted')),
      isTrue,
      reason: 'the remote arm must use its covering index: ${details.join(' | ')}',
    );
  });

  test('assets are grouped into the same day their bucket counts them in', () async {
    const userId = 'bucket-slice-user';

    // A photo taken abroad late in the day and one taken at home earlier that
    // evening. By capture instant the home photo is newer, but by wall clock
    // the travelling photo already belongs to the next day. The timeline hands
    // each bucket a contiguous slice of the asset list, so if the list is not
    // partitioned the way the buckets are, they are drawn under each other's
    // date headers.
    final abroadInstant = DateTime.parse('2024-05-10T16:00:00Z');
    final homeInstant = DateTime.parse('2024-05-10T18:00:00Z');
    final abroadWallClock = DateTime.utc(2024, 5, 11, 1);
    final homeWallClock = DateTime.utc(2024, 5, 10, 20);

    await db
        .into(db.userEntity)
        .insert(UserEntityCompanion.insert(id: userId, email: 'slice@test.dev', name: 'Slice'));
    await db.batch((batch) {
      batch.insert(
        db.remoteAssetEntity,
        RemoteAssetEntityCompanion.insert(
          id: 'abroad',
          name: 'abroad.jpg',
          type: AssetType.image,
          checksum: 'abroad-checksum',
          ownerId: userId,
          visibility: AssetVisibility.timeline,
          createdAt: Value(abroadInstant),
          updatedAt: Value(abroadInstant),
          localDateTime: Value(abroadWallClock),
        ),
      );
      batch.insert(
        db.remoteAssetEntity,
        RemoteAssetEntityCompanion.insert(
          id: 'home',
          name: 'home.jpg',
          type: AssetType.image,
          checksum: 'home-checksum',
          ownerId: userId,
          visibility: AssetVisibility.timeline,
          createdAt: Value(homeInstant),
          updatedAt: Value(homeInstant),
          localDateTime: Value(homeWallClock),
        ),
      );
    });

    final buckets = await db.mergedAssetDrift.mergedBucket(userIds: [userId], groupBy: 0).get();
    final assets = await db.mergedAssetDrift.mergedAsset(userIds: [userId], limit: (_) => Limit(20, 0)).get();

    expect(buckets.map((b) => b.bucketDate.substring(0, 10)), ['2024-05-11', '2024-05-10']);
    expect(buckets.map((b) => b.assetCount), [1, 1]);

    var cursor = 0;
    for (final bucket in buckets) {
      for (final asset in assets.skip(cursor).take(bucket.assetCount)) {
        expect(
          asset.timelineAt!.toIso8601String().substring(0, 10),
          bucket.bucketDate.substring(0, 10),
          reason: '${asset.remoteId} is drawn under ${bucket.bucketDate} but is not from that day',
        );
      }
      cursor += bucket.assetCount;
    }
    expect(cursor, assets.length);
    expect(assets.map((asset) => asset.remoteId), ['abroad', 'home']);
  });

  test('mergedBucket emits when a local asset is replaced by its remote copy', () async {
    const userId = 'timeline-refresh-user';
    const localId = 'timeline-refresh-local';
    const checksum = 'timeline-refresh-checksum';
    final capturedAt = DateTime.utc(2024, 2, 1, 12);

    await db
        .into(db.userEntity)
        .insert(UserEntityCompanion.insert(id: userId, email: 'refresh@test.dev', name: 'Refresh'));
    await db
        .into(db.localAlbumEntity)
        .insert(
          LocalAlbumEntityCompanion.insert(
            id: 'timeline-refresh-camera',
            name: 'Camera',
            backupSelection: BackupSelection.selected,
          ),
        );
    await db
        .into(db.localAssetEntity)
        .insert(
          LocalAssetEntityCompanion.insert(
            id: localId,
            name: 'refresh.jpg',
            type: AssetType.image,
            checksum: const Value(checksum),
            createdAt: Value(capturedAt),
            localDateTime: Value(capturedAt),
          ),
        );
    await db
        .into(db.localAlbumAssetEntity)
        .insert(LocalAlbumAssetEntityCompanion.insert(albumId: 'timeline-refresh-camera', assetId: localId));

    final queue = StreamQueue(
      db.mergedAssetDrift.mergedBucket(groupBy: GroupAssetsBy.day.index, userIds: [userId]).watch(),
    );
    final localBuckets = await queue.next;
    expect(localBuckets.single.assetCount, 1);
    expect(localBuckets.single.remoteAssetCount, 0);

    await db
        .into(db.remoteAssetEntity)
        .insert(
          RemoteAssetEntityCompanion.insert(
            id: 'timeline-refresh-remote',
            name: 'refresh.jpg',
            type: AssetType.image,
            checksum: checksum,
            ownerId: userId,
            visibility: AssetVisibility.timeline,
            createdAt: Value(capturedAt),
            updatedAt: Value(capturedAt),
            uploadedAt: Value(capturedAt),
            localDateTime: Value(capturedAt),
          ),
        );

    final remoteBuckets = await queue.next.timeout(const Duration(seconds: 2));
    expect(remoteBuckets.single.assetCount, 1);
    expect(remoteBuckets.single.remoteAssetCount, 1);
    await queue.cancel();
  });

  test('completed upload immediately replaces its local tile without a refresh', () async {
    const userId = 'completed-upload-user';
    const localId = 'completed-upload-local';
    const remoteId = 'completed-upload-remote';
    const checksum = 'completed-upload-checksum';
    final capturedAt = DateTime.utc(2024, 2, 3, 14);

    await db
        .into(db.userEntity)
        .insert(UserEntityCompanion.insert(id: userId, email: 'upload@test.dev', name: 'Upload'));
    await db
        .into(db.localAlbumEntity)
        .insert(
          LocalAlbumEntityCompanion.insert(
            id: 'completed-camera',
            name: 'Camera',
            backupSelection: BackupSelection.selected,
          ),
        );
    await db
        .into(db.localAssetEntity)
        .insert(
          LocalAssetEntityCompanion.insert(
            id: localId,
            name: 'completed.jpg',
            type: AssetType.image,
            checksum: const Value(checksum),
            createdAt: Value(capturedAt),
            localDateTime: Value(capturedAt),
          ),
        );
    await db
        .into(db.localAlbumAssetEntity)
        .insert(LocalAlbumAssetEntityCompanion.insert(albumId: 'completed-camera', assetId: localId));

    final bucketQueue = StreamQueue(
      db.mergedAssetDrift.mergedBucket(groupBy: GroupAssetsBy.day.index, userIds: [userId]).watch(),
    );
    expect((await bucketQueue.next).single.remoteAssetCount, 0);

    final source = await DriftLocalAssetRepository(db).getById(localId);
    await RemoteAssetRepository(db).registerCompletedUpload(remoteId: remoteId, ownerId: userId, source: source!);

    final updatedBuckets = await bucketQueue.next.timeout(const Duration(seconds: 2));
    final assets = await db.mergedAssetDrift.mergedAsset(userIds: [userId], limit: (_) => Limit(20, 0)).get();
    final mapping = await (db.remoteAssetCloudIdEntity.select()..where((row) => row.assetId.equals(remoteId)))
        .getSingle();

    expect(updatedBuckets.single.remoteAssetCount, 1);
    expect(assets, hasLength(1));
    expect(assets.single.localId, localId);
    expect(assets.single.remoteId, remoteId);
    expect(mapping.cloudId, checksum);
    await bucketQueue.cancel();
  });

  test('Storage saver metadata merges the local original with its compressed remote copy', () async {
    const userId = 'storage-saver-user';
    const sourceChecksum = 'source-checksum';
    const localId = 'local-original';
    const remoteId = 'remote-compressed';
    final createdAt = DateTime(2024, 2, 1, 12);

    await db
        .into(db.userEntity)
        .insert(UserEntityCompanion.insert(id: userId, email: 'storage-saver@test.dev', name: 'Storage Saver'));
    await db
        .into(db.localAssetEntity)
        .insert(
          LocalAssetEntityCompanion.insert(
            id: localId,
            name: 'original.jpg',
            type: AssetType.image,
            checksum: const Value(sourceChecksum),
            createdAt: Value(createdAt),
          ),
        );
    await db
        .into(db.localAlbumEntity)
        .insert(
          LocalAlbumEntityCompanion.insert(id: 'camera', name: 'Camera', backupSelection: BackupSelection.selected),
        );
    await db
        .into(db.localAlbumAssetEntity)
        .insert(LocalAlbumAssetEntityCompanion.insert(albumId: 'camera', assetId: localId));
    await db
        .into(db.remoteAssetEntity)
        .insert(
          RemoteAssetEntityCompanion.insert(
            id: remoteId,
            name: 'compressed.jpg',
            type: AssetType.image,
            checksum: 'compressed-checksum',
            ownerId: userId,
            visibility: AssetVisibility.timeline,
            createdAt: Value(createdAt),
            updatedAt: Value(createdAt),
            uploadedAt: Value(createdAt),
          ),
        );
    await db
        .into(db.remoteAssetCloudIdEntity)
        .insert(RemoteAssetCloudIdEntityCompanion.insert(assetId: remoteId, cloudId: const Value(sourceChecksum)));

    final assets = await db.mergedAssetDrift.mergedAsset(userIds: [userId], limit: (_) => Limit(20, 0)).get();
    final buckets = await db.mergedAssetDrift.mergedBucket(groupBy: GroupAssetsBy.day.index, userIds: [userId]).get();

    expect(assets, hasLength(1));
    expect(assets.single.remoteId, remoteId);
    expect(assets.single.localId, localId);
    expect(buckets, hasLength(1));
    expect(buckets.single.assetCount, 1);
  });

  test('Storage saver merge remains responsive for a large library', () async {
    const userId = 'large-library-user';
    const albumId = 'large-library-camera';
    const assetCount = 10000;
    final createdAt = DateTime(2024, 3, 1, 12);

    await db
        .into(db.userEntity)
        .insert(UserEntityCompanion.insert(id: userId, email: 'large-library@test.dev', name: 'Large Library'));
    await db
        .into(db.localAlbumEntity)
        .insert(
          LocalAlbumEntityCompanion.insert(id: albumId, name: 'Camera', backupSelection: BackupSelection.selected),
        );

    await db.batch((batch) {
      for (var index = 0; index < assetCount; index++) {
        final localId = 'local-$index';
        final remoteId = 'remote-$index';
        final sourceChecksum = 'source-checksum-$index';

        batch.insert(
          db.localAssetEntity,
          LocalAssetEntityCompanion.insert(
            id: localId,
            name: 'original-$index.jpg',
            type: AssetType.image,
            checksum: Value(sourceChecksum),
            createdAt: Value(createdAt.add(Duration(seconds: index))),
          ),
        );
        batch.insert(
          db.localAlbumAssetEntity,
          LocalAlbumAssetEntityCompanion.insert(albumId: albumId, assetId: localId),
        );
        batch.insert(
          db.remoteAssetEntity,
          RemoteAssetEntityCompanion.insert(
            id: remoteId,
            name: 'compressed-$index.jpg',
            type: AssetType.image,
            checksum: 'compressed-checksum-$index',
            ownerId: userId,
            visibility: AssetVisibility.timeline,
            createdAt: Value(createdAt.add(Duration(seconds: index))),
            updatedAt: Value(createdAt),
            uploadedAt: Value(createdAt),
          ),
        );
        batch.insert(
          db.remoteAssetCloudIdEntity,
          RemoteAssetCloudIdEntityCompanion.insert(assetId: remoteId, cloudId: Value(sourceChecksum)),
        );
      }
    });

    final stopwatch = Stopwatch()..start();
    final assets = await db.mergedAssetDrift
        .mergedAsset(userIds: [userId], limit: (_) => Limit(100, 0))
        .get()
        .timeout(const Duration(seconds: 5));
    final buckets = await db.mergedAssetDrift
        .mergedBucket(groupBy: GroupAssetsBy.day.index, userIds: [userId])
        .get()
        .timeout(const Duration(seconds: 5));
    stopwatch.stop();

    expect(assets, hasLength(100));
    expect(assets.every((asset) => asset.localId != null && asset.remoteId != null), isTrue);
    expect(buckets.fold<int>(0, (total, bucket) => total + bucket.assetCount), assetCount);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
  }, timeout: const Timeout(Duration(seconds: 30)));
}
