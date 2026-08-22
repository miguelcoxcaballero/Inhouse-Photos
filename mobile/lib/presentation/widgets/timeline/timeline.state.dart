import 'dart:math' as math;

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/constants.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment_builder.dart';
import 'package:immich_mobile/presentation/widgets/timeline/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_zoom_transition.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';

class TimelineArgs {
  final double maxWidth;
  final double maxHeight;
  final double spacing;
  final int columnCount;
  final bool showStorageIndicator;
  final bool withStack;
  final GroupAssetsBy? groupBy;
  final bool yearOverview;

  const TimelineArgs({
    required this.maxWidth,
    required this.maxHeight,
    this.spacing = kTimelineSpacing,
    this.columnCount = kTimelineColumnCount,
    this.showStorageIndicator = false,
    this.withStack = false,
    this.groupBy,
    this.yearOverview = false,
  });

  @override
  bool operator ==(covariant TimelineArgs other) {
    return spacing == other.spacing &&
        maxWidth == other.maxWidth &&
        maxHeight == other.maxHeight &&
        columnCount == other.columnCount &&
        showStorageIndicator == other.showStorageIndicator &&
        withStack == other.withStack &&
        groupBy == other.groupBy &&
        yearOverview == other.yearOverview;
  }

  @override
  int get hashCode =>
      maxWidth.hashCode ^
      maxHeight.hashCode ^
      spacing.hashCode ^
      columnCount.hashCode ^
      showStorageIndicator.hashCode ^
      withStack.hashCode ^
      groupBy.hashCode ^
      yearOverview.hashCode;
}

class TimelineState {
  final bool isScrubbing;
  final bool isScrolling;
  final bool isZooming;

  const TimelineState({this.isScrubbing = false, this.isScrolling = false, this.isZooming = false});

  bool get isInteracting => isScrubbing || isScrolling || isZooming;

  @override
  bool operator ==(covariant TimelineState other) {
    return isScrubbing == other.isScrubbing && isScrolling == other.isScrolling && isZooming == other.isZooming;
  }

  @override
  int get hashCode => isScrubbing.hashCode ^ isScrolling.hashCode ^ isZooming.hashCode;

  TimelineState copyWith({bool? isScrubbing, bool? isScrolling, bool? isZooming}) {
    return TimelineState(
      isScrubbing: isScrubbing ?? this.isScrubbing,
      isScrolling: isScrolling ?? this.isScrolling,
      isZooming: isZooming ?? this.isZooming,
    );
  }
}

class TimelineStateNotifier extends Notifier<TimelineState> {
  void setScrubbing(bool isScrubbing) {
    if (state.isScrubbing == isScrubbing) {
      return;
    }
    state = state.copyWith(isScrubbing: isScrubbing);
  }

  void setScrolling(bool isScrolling) {
    if (state.isScrolling == isScrolling) {
      return;
    }
    state = state.copyWith(isScrolling: isScrolling);
  }

  void setZooming(bool isZooming) {
    if (state.isZooming == isZooming) {
      return;
    }
    state = state.copyWith(isZooming: isZooming);
  }

  @override
  TimelineState build() => const TimelineState();
}

// Keep the photo bucket subscription independent from grid geometry. Column-count
// and width changes can then relayout existing data without entering a loading state.
final timelineBucketProvider = StreamProvider.autoDispose<List<Bucket>>(
  (ref) => ref.watch(timelineServiceProvider).watchBuckets(),
  dependencies: [timelineServiceProvider],
);

// This provider synchronously derives layout segments from the latest buckets.
// It should be used only after the timeline service and timeline args provider are overridden.
final timelineSegmentProvider = Provider.autoDispose<AsyncValue<List<Segment>>>((ref) {
  // maxHeight is left out on purpose, a height-only change must not relayout the segments
  final (maxWidth, columnCount, spacing, groupByArg, yearOverview) = ref.watch(
    timelineArgsProvider.select(
      (args) => (args.maxWidth, args.columnCount, args.spacing, args.groupBy, args.yearOverview),
    ),
  );
  final availableTileWidth = maxWidth - (spacing * (columnCount - 1));
  final tileExtent = math.max(0, availableTileWidth) / columnCount;

  final groupBy = groupByArg ?? ref.watch(appConfigProvider.select((config) => config.timeline.groupAssetsBy));
  return ref.watch(timelineBucketProvider).whenData((buckets) {
    return FixedSegmentBuilder(
      buckets: buckets,
      tileHeight: tileExtent,
      columnCount: columnCount,
      spacing: spacing,
      groupBy: groupBy!,
      yearOverview: yearOverview,
    ).generate();
  });
}, dependencies: [timelineBucketProvider, timelineArgsProvider]);

final timelineStateProvider = NotifierProvider<TimelineStateNotifier, TimelineState>(TimelineStateNotifier.new);

final timelineVisualReadyProvider = Provider.autoDispose<TimelineVisualReadySignal>((ref) {
  final signal = TimelineVisualReadySignal();
  ref.onDispose(signal.dispose);
  return signal;
});
