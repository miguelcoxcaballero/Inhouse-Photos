import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart' show AlbumAssetOrder;
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart' as domain;
import 'package:immich_mobile/infrastructure/entities/exif.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/local_album.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/local_album_asset.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/local_asset.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/remote_album.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/remote_album_asset.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/remote_asset_cloud_id.entity.drift.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/sync_stream.repository.dart';
import 'package:openapi/api.dart';

const owner = 'backup-user';
const checksum = 'shared-original-checksum';
const syncedId = 'server-photo-id';

SyncAssetV1 asset(String id, String hash, {String ownerId = owner, String? libraryId}) => SyncAssetV1(
  id: id,
  checksum: hash,
  originalFileName: 'photo.jpg',
  ownerId: ownerId,
  type: AssetTypeEnum.IMAGE,
  isFavorite: false,
  isEdited: false,
  createdAt: DateTime.utc(2026, 10, 3, 18, 18),
  fileCreatedAt: DateTime.utc(2024, 3, 23, 12, 17, 19),
  fileModifiedAt: DateTime.utc(2024, 3, 23, 12, 17, 20),
  localDateTime: DateTime.utc(2024, 3, 23, 12, 17, 19),
  deletedAt: null,
  duration: null,
  libraryId: libraryId,
  livePhotoVideoId: null,
  stackId: null,
  thumbhash: null,
  visibility: AssetVisibility.timeline,
  width: 1323,
  height: 1890,
);

SyncAssetV2 v2(SyncAssetV1 a) => SyncAssetV2(
  id: a.id,
  checksum: a.checksum,
  originalFileName: a.originalFileName,
  ownerId: a.ownerId,
  type: a.type,
  isFavorite: a.isFavorite,
  isEdited: a.isEdited,
  createdAt: a.createdAt,
  fileCreatedAt: a.fileCreatedAt,
  fileModifiedAt: a.fileModifiedAt,
  localDateTime: a.localDateTime,
  deletedAt: a.deletedAt,
  duration: 0,
  libraryId: a.libraryId,
  livePhotoVideoId: a.livePhotoVideoId,
  stackId: a.stackId,
  thumbhash: a.thumbhash,
  visibility: a.visibility,
  width: a.width,
  height: a.height,
);

void main() {
  late Drift db;
  late SyncStreamRepository sync;
  setUp(() async {
    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    sync = SyncStreamRepository(db);
    await db.customStatement('PRAGMA foreign_keys = ON');
    await sync.updateUsersV1([
      SyncUserV1(
        id: owner,
        email: 'test@example.com',
        name: 'User',
        deletedAt: null,
        avatarColor: const Optional.absent(),
        hasProfileImage: false,
        profileChangedAt: DateTime(2026),
      ),
    ]);
  });
  tearDown(() async => db.close());

  for (final version in [1, 2]) {
    test(
      'V$version resolves the reported UNIQUE 2067 collision without deleting cached rows or album/EXIF links',
      () async {
        await sync.updateAssetsV1([asset('legacy-upload', checksum)]);
        await db
            .into(db.remoteAlbumEntity)
            .insert(RemoteAlbumEntityCompanion.insert(id: 'album', name: 'Album', order: AlbumAssetOrder.asc));
        await db
            .into(db.remoteAlbumAssetEntity)
            .insert(RemoteAlbumAssetEntityCompanion.insert(assetId: 'legacy-upload', albumId: 'album'));
        await db
            .into(db.remoteExifEntity)
            .insert(
              RemoteExifEntityCompanion.insert(assetId: 'legacy-upload', description: const drift.Value('preserve me')),
            );
        if (version == 1) {
          await sync.updateAssetsV1([asset(syncedId, checksum)]);
        } else {
          await sync.updateAssetsV2([v2(asset(syncedId, checksum))]);
        }
        final rows = await db.remoteAssetEntity.select().get();
        expect(rows.length, 2);
        expect(rows.singleWhere((r) => r.id == syncedId).checksum, checksum);
        expect(
          rows.singleWhere((r) => r.id == 'legacy-upload').checksum,
          '${kPendingRemoteChecksumPrefix}legacy-upload',
        );
        expect((await db.remoteAlbumAssetEntity.select().get()).single.assetId, 'legacy-upload');
        expect((await db.remoteExifEntity.select().get()).single.description, 'preserve me');
        expect((await db.remoteAssetCloudIdEntity.select().get()).single.cloudId, checksum);
        expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
        // Its own server event later supplies the actual compressed checksum.
        await sync.updateAssetsV2([v2(asset('legacy-upload', 'compressed-checksum'))]);
        expect(
          (await db.remoteAssetEntity.select().get()).singleWhere((r) => r.id == 'legacy-upload').checksum,
          'compressed-checksum',
        );
        await sync.updateAssetsV2([v2(asset(syncedId, checksum))]);
        expect((await db.remoteAssetEntity.select().get()).length, 2);
      },
    );
  }

  test('a checksum change on an existing ID also reconciles the secondary unique index', () async {
    await sync.updateAssetsV1([asset(syncedId, 'previous-checksum'), asset('legacy-upload', checksum)]);
    await db
        .into(db.remoteAssetCloudIdEntity)
        .insert(
          RemoteAssetCloudIdEntityCompanion.insert(
            assetId: 'legacy-upload',
            cloudId: const drift.Value('original-source-checksum'),
            latitude: const drift.Value(40),
            createdAt: drift.Value(DateTime.utc(2024)),
          ),
        );
    await sync.updateAssetsV2([v2(asset(syncedId, checksum))]);
    final mapping = (await db.remoteAssetCloudIdEntity.select().get()).single;
    expect(mapping.cloudId, 'original-source-checksum');
    expect(mapping.latitude, 40);
    expect(mapping.createdAt, DateTime.utc(2024));
  });

  test('checksum swaps in one batch retain both server IDs', () async {
    await sync.updateAssetsV1([asset('a', 'a-hash'), asset('b', 'b-hash')]);
    await sync.updateAssetsV2([v2(asset('a', 'b-hash')), v2(asset('b', 'a-hash'))]);
    final rows = await db.remoteAssetEntity.select().get();
    expect(rows.singleWhere((r) => r.id == 'a').checksum, 'b-hash');
    expect(rows.singleWhere((r) => r.id == 'b').checksum, 'a-hash');
  });

  test('library and owner checksum scopes remain independent', () async {
    await sync.updateUsersV1([
      SyncUserV1(
        id: 'partner',
        email: 'partner@example.com',
        name: 'Partner',
        deletedAt: null,
        avatarColor: const Optional.absent(),
        hasProfileImage: false,
        profileChangedAt: DateTime(2026),
      ),
    ]);
    await sync.updateAssetsV1([
      asset('phone', checksum),
      asset('lib-a-old', checksum, libraryId: 'library-a'),
      asset('lib-b', checksum, libraryId: 'library-b'),
      asset('partner-asset', checksum, ownerId: 'partner'),
    ]);
    await sync.updateAssetsV2([v2(asset('lib-a-new', checksum, libraryId: 'library-a'))]);
    final rows = await db.remoteAssetEntity.select().get();
    expect(rows.length, 5);
    expect(rows.where((r) => r.checksum == checksum).length, 4);
    expect(rows.singleWhere((r) => r.id == 'lib-a-old').checksum, '${kPendingRemoteChecksumPrefix}lib-a-old');
  });

  test('an unrelated FK failure rolls back the repair, alias, and incoming batch', () async {
    await sync.updateAssetsV1([asset('legacy-upload', checksum)]);
    await expectLater(
      sync.updateAssetsV2([v2(asset(syncedId, checksum)), v2(asset('invalid', 'other', ownerId: 'missing-user'))]),
      throwsA(isA<SqliteException>().having((e) => e.extendedResultCode, 'extended code', 787)),
    );
    final rows = await db.remoteAssetEntity.select().get();
    expect(rows.single.id, 'legacy-upload');
    expect(rows.single.checksum, checksum);
    expect(await db.remoteAssetCloudIdEntity.select().get(), isEmpty);
  });

  test('new upload placeholders cannot claim another server asset checksum and backup counts stay correct', () async {
    await sync.updateAssetsV1([asset(syncedId, checksum)]);
    await db
        .into(db.localAlbumEntity)
        .insert(
          LocalAlbumEntityCompanion.insert(id: 'camera', name: 'Camera', backupSelection: BackupSelection.selected),
        );
    await db
        .into(db.localAssetEntity)
        .insert(
          LocalAssetEntityCompanion.insert(
            id: 'source',
            name: 'photo.jpg',
            type: domain.AssetType.image,
            checksum: const drift.Value(checksum),
            createdAt: drift.Value(DateTime.utc(2024)),
          ),
        );
    await db
        .into(db.localAlbumAssetEntity)
        .insert(LocalAlbumAssetEntityCompanion.insert(albumId: 'camera', assetId: 'source'));
    final source = (await DriftLocalAssetRepository(db).getById('source'))!;
    final remote = RemoteAssetRepository(db);
    await remote.registerCompletedUpload(remoteId: 'receipt-id', ownerId: owner, source: source);
    await remote.registerCompletedUpload(remoteId: 'receipt-id', ownerId: owner, source: source);
    final rows = await db.remoteAssetEntity.select().get();
    expect(rows.length, 2);
    expect(rows.singleWhere((r) => r.id == 'receipt-id').checksum, '${kPendingRemoteChecksumPrefix}receipt-id');
    expect((await db.remoteAssetCloudIdEntity.select().get()).single.cloudId, checksum);
    expect((await remote.get('receipt-id'))?.localId, 'source');
    final backup = DriftBackupRepository(db);
    expect((await backup.getAllCounts(owner)).remainder, 0);
    expect(await backup.getCandidates(owner), isEmpty);
    await sync.updateAssetsV2([v2(asset('receipt-id', 'compressed-checksum'))]);
    expect((await backup.getAllCounts(owner)).remainder, 0);
    expect(await backup.getCandidates(owner), isEmpty);
    expect((await remote.get('receipt-id'))?.localId, 'source');
    expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
  });

  test('a full 5000-event batch recovers and can be replayed idempotently', () async {
    await sync.updateAssetsV1([asset('legacy-upload', checksum)]);
    final events = [v2(asset(syncedId, checksum)), for (int i = 1; i < 5000; i++) v2(asset('asset-$i', 'hash-$i'))];
    await sync.updateAssetsV2(events);
    await sync.updateAssetsV2(events);
    expect((await db.remoteAssetEntity.select().get()).length, 5001);
    expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
  });
}
