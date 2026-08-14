import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

Rect calculateTimelineAssetTransitionRect({
  required Rect previousRect,
  required Rect currentRect,
  required double progress,
}) {
  final easedProgress = Curves.easeOutCubic.transform(progress.clamp(0.0, 1.0));
  return Rect.lerp(previousRect, currentRect, easedProgress)!;
}

class TimelineLayoutTransitionScope extends InheritedWidget {
  const TimelineLayoutTransitionScope({
    super.key,
    required this.animation,
    required this.previousRects,
    required super.child,
  });

  final Animation<double> animation;
  final Map<Object, Rect> previousRects;

  static TimelineLayoutTransitionScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TimelineLayoutTransitionScope>();

  @override
  bool updateShouldNotify(TimelineLayoutTransitionScope oldWidget) =>
      animation != oldWidget.animation || previousRects != oldWidget.previousRects;
}

class TimelineAssetLayoutTransition extends SingleChildRenderObjectWidget {
  const TimelineAssetLayoutTransition({super.key, required this.assetKey, required super.child});

  final Object assetKey;

  @override
  RenderTimelineAssetLayoutTransition createRenderObject(BuildContext context) {
    final scope = TimelineLayoutTransitionScope.maybeOf(context);
    return RenderTimelineAssetLayoutTransition(assetKey, scope?.animation, scope?.previousRects ?? const {});
  }

  @override
  void updateRenderObject(BuildContext context, RenderTimelineAssetLayoutTransition renderObject) {
    final scope = TimelineLayoutTransitionScope.maybeOf(context);
    renderObject
      ..assetKey = assetKey
      ..animation = scope?.animation
      ..previousRects = scope?.previousRects ?? const {};
  }
}

class RenderTimelineAssetLayoutTransition extends RenderProxyBox {
  RenderTimelineAssetLayoutTransition(this._assetKey, this._animation, this._previousRects);

  Object get assetKey => _assetKey;
  Object _assetKey;

  set assetKey(Object value) {
    if (_assetKey == value) {
      return;
    }
    _assetKey = value;
    markNeedsPaint();
  }

  Animation<double>? get animation => _animation;
  Animation<double>? _animation;

  set animation(Animation<double>? value) {
    if (_animation == value) {
      return;
    }
    if (attached) {
      _animation?.removeListener(markNeedsPaint);
    }
    _animation = value;
    if (attached) {
      _animation?.addListener(markNeedsPaint);
    }
    markNeedsPaint();
  }

  Map<Object, Rect> get previousRects => _previousRects;
  Map<Object, Rect> _previousRects;

  set previousRects(Map<Object, Rect> value) {
    if (identical(_previousRects, value)) {
      return;
    }
    _previousRects = value;
    markNeedsPaint();
  }

  Rect get currentVisualGlobalRect {
    final currentTopLeft = localToGlobal(Offset.zero);
    final currentRect = currentTopLeft & size;
    final previousRect = previousRects[assetKey];
    final progress = animation?.value ?? 1;
    if (previousRect == null || progress >= 1) {
      return currentRect;
    }
    return calculateTimelineAssetTransitionRect(
      previousRect: previousRect,
      currentRect: currentRect,
      progress: progress,
    );
  }

  @override
  void detach() {
    _animation?.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _animation?.addListener(markNeedsPaint);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final previousRect = previousRects[assetKey];
    final progress = animation?.value ?? 1;
    if (child == null || previousRect == null || progress >= 1 || size.isEmpty) {
      super.paint(context, offset);
      return;
    }

    final currentTopLeft = localToGlobal(Offset.zero);
    final currentRect = currentTopLeft & size;
    final visualRect = calculateTimelineAssetTransitionRect(
      previousRect: previousRect,
      currentRect: currentRect,
      progress: progress,
    );
    final translateX = visualRect.left - currentRect.left;
    final translateY = visualRect.top - currentRect.top;
    final scaleX = visualRect.width / currentRect.width;
    final scaleY = visualRect.height / currentRect.height;
    final transform = Matrix4.identity()
      ..translateByDouble(translateX, translateY, 0, 1)
      ..scaleByDouble(scaleX, scaleY, 1, 1);

    context.pushTransform(needsCompositing, offset, transform, super.paint);
  }
}
