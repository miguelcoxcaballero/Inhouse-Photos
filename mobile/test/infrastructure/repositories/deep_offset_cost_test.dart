// ignore_for_file: avoid_print
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/entities/remote_asset.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/user.entity.drift.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';

void main() {
  // Records what paginating with OFFSET costs the further down the timeline a
  // read happens. SQLite has to produce and discard every row before the
  // offset, so a chunk read deep in a large library is materially slower than
  // the same read at the top - and these reads are serialised behind the one
  // mutex every panel waits on, which is why scrolling far down is slower to
  // fill in than scrolling near the top.
  test('reading a chunk deep into the timeline costs more than reading at the top', () async {
    final db = Drift(DatabaseConnection(NativeDatabase.memory()));
    addTearDown(db.close);

    const userId = 'owner';
    await db.into(db.userEntity).insert(
      UserEntityCompanion.insert(id: userId, email: 'a@b.c', name: 'n'),
    );

    const total = 60000;
    final now = DateTime.utc(2026, 1, 1);
    for (var batch = 0; batch < total ~/ 2000; batch++) {
      await db.batch((b) {
        for (var i = 0; i < 2000; i++) {
          final index = batch * 2000 + i;
          b.insert(
            db.remoteAssetEntity,
            RemoteAssetEntityCompanion.insert(
              id: 'remote-$index',
              name: 'photo-$index.jpg',
              type: AssetType.image,
              checksum: 'checksum-$index',
              ownerId: userId,
              visibility: AssetVisibility.timeline,
              createdAt: Value(now.subtract(Duration(minutes: index))),
              updatedAt: Value(now),
              localDateTime: Value(now.subtract(Duration(minutes: index))),
            ),
          );
        }
      });
    }

    Future<int> timeKeysetAt(int offset) async {
      // The row the caller would have stopped at, fetched once and not timed.
      final boundary = await db.mergedAssetDrift
          .mergedAsset(userIds: [userId], limit: (_) => Limit(1, offset - 1))
          .getSingle();
      final sw = Stopwatch()..start();
      final rows = await db.mergedAssetDrift
          .mergedAssetAfter(
            userIds: [userId],
            afterTimelineAt: boundary.timelineAt!,
            afterCreatedAt: boundary.createdAt,
            afterSource: boundary.cursorSource,
            afterId: boundary.cursorId,
            limit: (_) => Limit(2048, null),
          )
          .get();
      sw.stop();
      expect(rows, hasLength(2048));
      return sw.elapsedMilliseconds;
    }

    Future<int> timeAt(int offset) async {
      final sw = Stopwatch()..start();
      final rows = await db.mergedAssetDrift
          .mergedAsset(userIds: [userId], limit: (_) => Limit(2048, offset))
          .get();
      sw.stop();
      expect(rows, isNotEmpty);
      return sw.elapsedMilliseconds;
    }

    await timeAt(0); // warm
    print('');
    final timings = <int, int>{};
    for (final offset in [0, 10000, 25000, 40000, 55000]) {
      final ms = await timeAt(offset);
      timings[offset] = ms;
      print('OFFSETCOST reading 2048 assets at offset ${offset.toString().padLeft(6)} : $ms ms');
    }
    print('');

    // Not an assertion that it is fast - it is not, and that is the finding.
    // This is a ceiling, so that a change which makes deep reads dramatically
    // worse fails here rather than being discovered from a screenshot.
    for (final offset in [10000, 25000, 40000, 55000]) {
      final ms = await timeKeysetAt(offset);
      print('OFFSETCOST   same read continuing from a key : $ms ms  (offset form ${timings[offset]} ms)');
    }
    print('');

    // The two reads are separate SQL, so the only thing stopping them drifting
    // apart is this: continuing from a key must return exactly what counting to
    // the equivalent offset returns, including across the boundary between the
    // remote and local arms.
    for (final offset in [1, 2048, 20000, 55000]) {
      final boundary = await db.mergedAssetDrift
          .mergedAsset(userIds: [userId], limit: (_) => Limit(1, offset - 1))
          .getSingle();
      final counted = await db.mergedAssetDrift
          .mergedAsset(userIds: [userId], limit: (_) => Limit(500, offset))
          .get();
      final continued = await db.mergedAssetDrift
          .mergedAssetAfter(
            userIds: [userId],
            afterTimelineAt: boundary.timelineAt!,
            afterCreatedAt: boundary.createdAt,
            afterSource: boundary.cursorSource,
            afterId: boundary.cursorId,
            limit: (_) => Limit(500, null),
          )
          .get();
      expect(
        continued.map((row) => row.remoteId ?? row.localId).toList(),
        counted.map((row) => row.remoteId ?? row.localId).toList(),
        reason: 'continuing from offset $offset returned different rows than counting to it',
      );
    }

    // Not an assertion that it is fast - it is not, and that is the finding.
    // This is a ceiling, so that a change which makes deep reads dramatically
    // worse fails here rather than being discovered from a screenshot.
    expect(
      timings[55000]!,
      lessThan(600),
      reason: 'a deep chunk read has become far more expensive than when this was measured',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
