import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';

BaseAsset _asset(int index) => LocalAsset(
  id: 'local-$index',
  name: 'photo-$index.jpg',
  checksum: 'checksum-$index',
  type: AssetType.image,
  createdAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: index)),
  updatedAt: DateTime.utc(2026, 1, 1),
  playbackStyle: AssetPlaybackStyle.image,
  isEdited: false,
);

void main() {
  test('same-count metadata changes refresh the asset window', () async {
    final changes = StreamController<List<Bucket>>.broadcast();
    var current = _asset(0);
    final service = TimelineService((
      assetSource: (offset, count) async => [current],
      bucketSource: () => changes.stream,
      assetSourceAfter: null,
      origin: TimelineOrigin.main,
    ), bucketRefreshInterval: const Duration(milliseconds: 10));
    addTearDown(service.dispose);
    addTearDown(changes.close);
    changes.add([const Bucket(assetCount: 1)]);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final revision = service.revision;
    current = (current as LocalAsset).copyWith(isFavorite: true);
    changes.add([const Bucket(assetCount: 1)]);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(service.revision, greaterThan(revision));
    expect(service.getAssets(0, 1).single.isFavorite, isTrue);
  });
  test('a refresh that changes no bucket does not invalidate the grid', () async {
    // Bumping the revision resets every panel and drops every cached asset
    // chunk. Background preview generation writes to a table the bucket query
    // reads, so an unchanged refresh arrives every time a batch lands - twice a
    // second while it runs. Treating those as real changes rebuilt the whole
    // grid continuously, which on a large library looks like rows that never
    // finish loading.
    final controller = StreamController<List<Bucket>>.broadcast();
    addTearDown(controller.close);
    var assetReads = 0;

    final service = TimelineService((
      assetSource: (offset, count) async {
        assetReads++;
        return List<BaseAsset>.generate(count, (i) => _asset(offset + i), growable: false);
      },
      bucketSource: () => controller.stream,
      assetSourceAfter: null,
      origin: TimelineOrigin.main,
    ), bucketRefreshInterval: const Duration(milliseconds: 50));
    addTearDown(service.dispose);

    var layouts = 0;
    final layoutSubscription = service.watchBuckets().listen((_) => layouts++);
    addTearDown(layoutSubscription.cancel);
    List<Bucket> buckets() => [
      TimeBucket(date: DateTime.utc(2026, 1, 2), assetCount: 40),
      TimeBucket(date: DateTime.utc(2026, 1, 1), assetCount: 60),
    ];

    controller.add(buckets());
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final revisionAfterFirst = service.revision;
    final readsAfterFirst = assetReads;
    expect(revisionAfterFirst, greaterThan(0), reason: 'the first snapshot must load');

    // Five identical snapshots, as a run of preview writes would produce.
    for (var i = 0; i < 5; i++) {
      controller.add(buckets());
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(service.revision, greaterThan(revisionAfterFirst), reason: 'asset caches must see database changes');
    expect(layouts, 1, reason: 'identical buckets must not regenerate grid geometry');
    expect(assetReads, greaterThan(readsAfterFirst), reason: 'same counts must still check for changed assets');

    // A real change still gets through.
    controller.add([
      TimeBucket(date: DateTime.utc(2026, 1, 2), assetCount: 41),
      TimeBucket(date: DateTime.utc(2026, 1, 1), assetCount: 60),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(service.revision, greaterThan(revisionAfterFirst), reason: 'a genuine change must still refresh');
  }, timeout: const Timeout(Duration(seconds: 30)));
}
