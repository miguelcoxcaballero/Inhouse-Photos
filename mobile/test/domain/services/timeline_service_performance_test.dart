import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';

void main() {
  test('bucket storms retain only the newest pending database refresh', () async {
    final source = StreamController<List<Bucket>>.broadcast(sync: true);
    final firstReadStarted = Completer<void>();
    final releaseFirstRead = Completer<void>();
    final publishedCounts = <int>[];
    final secondSnapshotPublished = Completer<void>();
    var assetReads = 0;

    final service = TimelineService((
      assetSource: (index, count) async {
        assetReads++;
        if (assetReads == 1) {
          firstReadStarted.complete();
          await releaseFirstRead.future;
        }
        return const <BaseAsset>[];
      },
      bucketSource: () => source.stream,
      assetSourceAfter: null,
      origin: TimelineOrigin.main,
    ), bucketRefreshInterval: const Duration(milliseconds: 10));
    final subscription = service.watchBuckets().listen((buckets) {
      publishedCounts.add(buckets.fold(0, (total, bucket) => total + bucket.assetCount));
      if (publishedCounts.length == 2 && !secondSnapshotPublished.isCompleted) {
        secondSnapshotPublished.complete();
      }
    });

    source.add(const [Bucket(assetCount: 1)]);
    await firstReadStarted.future;
    source
      ..add(const [Bucket(assetCount: 2)])
      ..add(const [Bucket(assetCount: 3)])
      ..add(const [Bucket(assetCount: 4)]);

    expect(assetReads, 1, reason: 'new snapshots must not queue reads behind the in-flight refresh');
    releaseFirstRead.complete();
    await secondSnapshotPublished.future.timeout(const Duration(seconds: 2));

    expect(assetReads, 2);
    expect(publishedCounts, [1, 4]);

    await subscription.cancel();
    await source.close();
    await service.dispose();
  });

  test('all timeline consumers share one replaying bucket query', () async {
    final source = StreamController<List<Bucket>>.broadcast(sync: true);
    var sourceSubscriptions = 0;
    final service = TimelineService((
      assetSource: (index, count) async => const <BaseAsset>[],
      assetSourceAfter: null,
      bucketSource: () {
        sourceSubscriptions++;
        return source.stream;
      },
      origin: TimelineOrigin.main,
    ), bucketRefreshInterval: Duration.zero);
    final first = Completer<int>();
    final second = Completer<int>();
    final firstSubscription = service.watchBuckets().listen((buckets) => first.complete(buckets.single.assetCount));
    final secondSubscription = service.watchBuckets().listen((buckets) => second.complete(buckets.single.assetCount));

    source.add(const [Bucket(assetCount: 7)]);
    expect(await first.future.timeout(const Duration(seconds: 2)), 7);
    expect(await second.future.timeout(const Duration(seconds: 2)), 7);

    final replayed = Completer<int>();
    final lateSubscription = service.watchBuckets().listen((buckets) => replayed.complete(buckets.single.assetCount));
    expect(await replayed.future.timeout(const Duration(seconds: 2)), 7);
    expect(sourceSubscriptions, 1);

    await firstSubscription.cancel();
    await secondSubscription.cancel();
    await lateSubscription.cancel();
    await source.close();
    await service.dispose();
  });
}
