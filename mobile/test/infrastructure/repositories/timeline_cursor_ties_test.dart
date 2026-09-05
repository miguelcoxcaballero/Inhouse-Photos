import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/entities/local_album.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/local_album_asset.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/local_asset.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/remote_asset.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/user.entity.drift.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';

void main() {
  test('keyset visits every local and remote row when all timestamps and IDs tie', () async {
    final db = Drift(DatabaseConnection(NativeDatabase.memory()));
    addTearDown(db.close);
    final date = DateTime.utc(2026, 9, 1);
    await db.into(db.userEntity).insert(UserEntityCompanion.insert(id: 'owner', email: 'a@b.c', name: 'Owner'));
    await db
        .into(db.localAlbumEntity)
        .insert(
          LocalAlbumEntityCompanion.insert(id: 'camera', name: 'Camera', backupSelection: BackupSelection.selected),
        );
    await db.batch((batch) {
      for (var i = 0; i < 33; i++) {
        final id = i.toString().padLeft(3, '0');
        batch.insert(
          db.localAssetEntity,
          LocalAssetEntityCompanion.insert(
            id: id,
            name: '$id.jpg',
            type: AssetType.image,
            createdAt: Value(date),
            localDateTime: Value(date),
            checksum: Value('local-$id'),
          ),
        );
        batch.insert(db.localAlbumAssetEntity, LocalAlbumAssetEntityCompanion.insert(albumId: 'camera', assetId: id));
        batch.insert(
          db.remoteAssetEntity,
          RemoteAssetEntityCompanion.insert(
            id: id,
            name: '$id.jpg',
            type: AssetType.image,
            ownerId: 'owner',
            visibility: AssetVisibility.timeline,
            createdAt: Value(date),
            localDateTime: Value(date),
            checksum: 'remote-$id',
          ),
        );
      }
    });
    final expected = await db.mergedAssetDrift.mergedAsset(userIds: ['owner'], limit: (_) => Limit(100, 0)).get();
    expect(expected.length, 66);
    final actual = [...expected.take(7)];
    while (actual.length < expected.length) {
      final last = actual.last;
      final page = await db.mergedAssetDrift
          .mergedAssetAfter(
            userIds: ['owner'],
            afterTimelineAt: last.timelineAt!,
            afterCreatedAt: last.createdAt,
            afterSource: last.cursorSource,
            afterId: last.cursorId,
            limit: (_) => Limit(7, null),
          )
          .get();
      expect(page, isNotEmpty);
      actual.addAll(page);
    }
    expect(
      actual.map((r) => (r.cursorSource, r.cursorId)).toList(),
      expected.map((r) => (r.cursorSource, r.cursorId)).toList(),
    );
    // A failed first page must not starve the rest of the local preview backlog.
    final repo = DriftLocalAssetRepository(db);
    final first = await repo.getAssetsMissingThumbHash(limit: 16);
    final second = await repo.getAssetsMissingThumbHash(limit: 16, afterId: first.last.id);
    expect(second.length, 16);
    expect(second.map((r) => r.id).toSet().intersection(first.map((r) => r.id).toSet()), isEmpty);
  });
}
