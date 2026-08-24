import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/segment_builder.dart';

class FixedSegmentBuilder extends SegmentBuilder {
  final double tileHeight;
  final int columnCount;

  const FixedSegmentBuilder({
    required super.buckets,
    required this.tileHeight,
    required this.columnCount,
    super.spacing,
    super.groupBy,
  });

  List<Segment> generate() {
    final segments = <Segment>[];
    int firstIndex = 0;
    double startOffset = 0;
    int assetIndex = 0;
    DateTime? previousDate;

    for (int i = 0; i < buckets.length; i++) {
      final bucket = buckets[i];
      final batchedGrid = columnCount > 6;

      final assetCount = bucket.assetCount;
      final numberOfRows = (assetCount / columnCount).ceil();
      final rowsPerChild = batchedGrid ? denseTimelineRowsPerChild(columnCount) : 1;
      final numberOfChildren = (numberOfRows / rowsPerChild).ceil();
      final segmentCount = numberOfChildren + 1;

      final segmentFirstIndex = firstIndex;
      firstIndex += segmentCount;
      final segmentLastIndex = firstIndex - 1;

      // Dense levels remain part of the same timeline, but daily headers would
      // be taller than the photos and make scrolling needlessly expensive.
      // Keep the existing day buckets so adding a photo only invalidates its
      // day, while presenting a compact year label in the continuous grid.
      final timelineHeader = batchedGrid
          ? bucket is TimeBucket && bucket.date.year != previousDate?.year
                ? HeaderType.year
                : HeaderType.none
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
          rowsPerChild: rowsPerChild,
          batchedGrid: batchedGrid,
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
