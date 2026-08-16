import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/segment_builder.dart';

class FixedSegmentBuilder extends SegmentBuilder {
  final double tileHeight;
  final int columnCount;
  final bool yearOverview;

  const FixedSegmentBuilder({
    required super.buckets,
    required this.tileHeight,
    required this.columnCount,
    super.spacing,
    super.groupBy,
    this.yearOverview = false,
  });

  List<Bucket> _layoutBuckets() {
    if (!yearOverview) {
      return buckets;
    }

    final result = <Bucket>[];
    DateTime? activeYear;
    var activeCount = 0;

    void flushYear() {
      if (activeYear != null) {
        result.add(TimeBucket(date: activeYear!, assetCount: activeCount));
      }
      activeYear = null;
      activeCount = 0;
    }

    for (final bucket in buckets) {
      if (bucket is! TimeBucket) {
        flushYear();
        result.add(bucket);
        continue;
      }

      if (activeYear?.year != bucket.date.year) {
        flushYear();
        activeYear = DateTime(bucket.date.year);
      }
      activeCount += bucket.assetCount;
    }
    flushYear();
    return result;
  }

  List<Segment> generate() {
    final segments = <Segment>[];
    int firstIndex = 0;
    double startOffset = 0;
    int assetIndex = 0;
    DateTime? previousDate;

    final layoutBuckets = _layoutBuckets();
    for (int i = 0; i < layoutBuckets.length; i++) {
      final bucket = layoutBuckets[i];

      final assetCount = bucket.assetCount;
      final numberOfRows = (assetCount / columnCount).ceil();
      final segmentCount = numberOfRows + 1;

      final segmentFirstIndex = firstIndex;
      firstIndex += segmentCount;
      final segmentLastIndex = firstIndex - 1;

      final timelineHeader = yearOverview
          ? HeaderType.year
          : switch (groupBy) {
              GroupAssetsBy.month => HeaderType.month,
              GroupAssetsBy.day || GroupAssetsBy.auto =>
                bucket is TimeBucket && bucket.date.month != previousDate?.month
                    ? HeaderType.monthAndDay
                    : HeaderType.day,
              GroupAssetsBy.none => HeaderType.none,
            };
      final headerExtent = SegmentBuilder.headerExtent(timelineHeader);

      final segmentStartOffset = startOffset;
      startOffset += headerExtent + (tileHeight * numberOfRows) + spacing * (numberOfRows - 1);
      final segmentEndOffset = startOffset;

      segments.add(
        FixedSegment(
          firstIndex: segmentFirstIndex,
          lastIndex: segmentLastIndex,
          startOffset: segmentStartOffset,
          endOffset: segmentEndOffset,
          firstAssetIndex: assetIndex,
          bucket: bucket,
          tileHeight: tileHeight,
          columnCount: columnCount,
          headerExtent: headerExtent,
          spacing: spacing,
          header: timelineHeader,
        ),
      );

      assetIndex += assetCount;
      if (bucket is TimeBucket) {
        previousDate = bucket.date;
      }
    }
    return segments;
  }
}
