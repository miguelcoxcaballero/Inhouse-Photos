import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

const Duration kTimelineZoomSettleDuration = Duration(milliseconds: 220);
const Duration kTimelineLayoutRevealDuration = Duration(milliseconds: 180);

/// Keeps pinch feedback subtle enough that cached thumbnails remain crisp while
/// still tracking the user's fingers. The actual grid geometry changes once,
/// when the gesture settles.
double calculateTimelineZoomPreviewScale(double gestureScale) {
  if (!gestureScale.isFinite || gestureScale <= 0) {
    return 1;
  }
  return math.pow(gestureScale, 0.32).toDouble().clamp(0.82, 1.22);
}

Alignment calculateTimelineZoomAlignment({required Offset focalPoint, required Size viewportSize}) {
  if (viewportSize.isEmpty || !viewportSize.width.isFinite || !viewportSize.height.isFinite) {
    return Alignment.center;
  }
  return Alignment(
    ((focalPoint.dx / viewportSize.width) * 2 - 1).clamp(-1.0, 1.0),
    ((focalPoint.dy / viewportSize.height) * 2 - 1).clamp(-1.0, 1.0),
  );
}

typedef TimelineZoomPreview = ({double scale, Alignment alignment});

class TimelineZoomTransform extends StatelessWidget {
  const TimelineZoomTransform({super.key, required this.preview, required this.child});

  final ValueListenable<TimelineZoomPreview> preview;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TimelineZoomPreview>(
      valueListenable: preview,
      child: child,
      builder: (context, value, child) {
        return Transform.scale(scale: value.scale, alignment: value.alignment, child: child);
      },
    );
  }
}

/// A layout reports readiness only after it has real pixels to paint. This lets
/// the gallery retain the previous layout instead of exposing an empty frame
/// while a dense atlas is restored or assembled.
class TimelineVisualReadySignal extends ChangeNotifier {
  int? _columnCount;
  int _revision = 0;

  int? get columnCount => _columnCount;
  int get revision => _revision;

  void markReady(int columnCount) {
    _columnCount = columnCount;
    _revision++;
    notifyListeners();
  }
}

class TimelineVisualReadyMarker extends SingleChildRenderObjectWidget {
  const TimelineVisualReadyMarker({super.key, required this.columnCount, required this.ready, required super.child});

  final int columnCount;
  final bool ready;

  @override
  RenderTimelineVisualReadyMarker createRenderObject(BuildContext context) =>
      RenderTimelineVisualReadyMarker(columnCount: columnCount, ready: ready);

  @override
  void updateRenderObject(BuildContext context, RenderTimelineVisualReadyMarker renderObject) {
    renderObject
      ..columnCount = columnCount
      ..ready = ready;
  }
}

class RenderTimelineVisualReadyMarker extends RenderProxyBox {
  RenderTimelineVisualReadyMarker({required this._columnCount, required this._ready});

  int get columnCount => _columnCount;
  int _columnCount;

  set columnCount(int value) {
    if (_columnCount == value) {
      return;
    }
    _columnCount = value;
  }

  bool get ready => _ready;
  bool _ready;

  set ready(bool value) {
    if (_ready == value) {
      return;
    }
    _ready = value;
  }

  Rect get globalRect => localToGlobal(Offset.zero) & size;
}

class _RetainedTimelineEntry {
  _RetainedTimelineEntry(this.layoutKey, this.child);

  final Object layoutKey;
  Widget child;
}

/// Keeps the old, already-painted timeline above the incoming layout. The old
/// subtree is retained as Flutter render objects (not rasterized with toImage),
/// so scrolling textures remain GPU-resident and the new layout can prepare
/// underneath without ever revealing the page background.
class TimelineRetainedSwitcher extends StatefulWidget {
  const TimelineRetainedSwitcher({
    super.key,
    required this.layoutKey,
    required this.ready,
    required this.child,
    this.onTransitionComplete,
    this.duration = kTimelineLayoutRevealDuration,
  });

  final Object layoutKey;
  final bool ready;
  final Widget child;
  final VoidCallback? onTransitionComplete;
  final Duration duration;

  @override
  State<TimelineRetainedSwitcher> createState() => TimelineRetainedSwitcherState();
}

class TimelineRetainedSwitcherState extends State<TimelineRetainedSwitcher> with SingleTickerProviderStateMixin {
  static const Animation<double> _visible = AlwaysStoppedAnimation(1);
  late final AnimationController _controller;
  late final Animation<double> _outgoingOpacity;
  late _RetainedTimelineEntry _current;
  _RetainedTimelineEntry? _outgoing;
  int _transitionGeneration = 0;

  @override
  void initState() {
    super.initState();
    _current = _RetainedTimelineEntry(widget.layoutKey, widget.child);
    _controller = AnimationController(vsync: this, duration: widget.duration, value: 1);
    _outgoingOpacity = Tween<double>(
      begin: 1,
      end: 0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
  }

  @override
  void didUpdateWidget(covariant TimelineRetainedSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
    }

    if (_current.layoutKey != widget.layoutKey) {
      _transitionGeneration++;
      _outgoing = _current;
      _current = _RetainedTimelineEntry(widget.layoutKey, widget.child);
      _controller.value = 0;
      _revealWhenReady();
      return;
    }

    _current.child = widget.child;
    if (!oldWidget.ready && widget.ready) {
      _revealWhenReady();
    }
  }

  void _revealWhenReady() {
    if (!widget.ready || _outgoing == null || _controller.isAnimating) {
      return;
    }
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      finishImmediately();
      return;
    }

    final generation = _transitionGeneration;
    _controller.forward(from: 0).whenComplete(() {
      if (mounted && generation == _transitionGeneration) {
        _completeTransition();
      }
    });
  }

  void _completeTransition({bool notify = true}) {
    if (_outgoing == null) {
      return;
    }
    setState(() => _outgoing = null);
    if (notify) {
      widget.onTransitionComplete?.call();
    }
  }

  void finishImmediately() {
    _transitionGeneration++;
    _controller
      ..stop()
      ..value = 1;
    _completeTransition();
  }

  Widget _buildEntry(_RetainedTimelineEntry entry, {required bool outgoing}) {
    return KeyedSubtree(
      key: ValueKey(entry.layoutKey),
      child: ExcludeSemantics(
        excluding: outgoing,
        child: IgnorePointer(
          ignoring: outgoing,
          child: FadeTransition(
            opacity: outgoing ? _outgoingOpacity : _visible,
            child: RepaintBoundary(child: entry.child),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final outgoing = _outgoing;
    return Stack(
      fit: StackFit.expand,
      children: [_buildEntry(_current, outgoing: false), if (outgoing != null) _buildEntry(outgoing, outgoing: true)],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
