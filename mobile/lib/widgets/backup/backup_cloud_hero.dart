import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';

/// [syncing] spins the ring without the rising photos: nothing is being uploaded yet.
enum BackupCloudState { off, idle, syncing, uploading, done, error }

/// Cloud at the top of the backup page. While files upload, small photo-toned
/// squares rise from both sides into it. Turning backup on or off pops the cloud;
/// every other change cross-fades.
class BackupCloudHero extends StatefulWidget {
  const BackupCloudHero({super.key, required this.state, required this.title, this.subtitle, this.footer});

  final BackupCloudState state;
  final String title;
  final String? subtitle;

  /// Extra content below the title, e.g. the sync error and its retry button.
  final Widget? footer;

  @override
  State<BackupCloudHero> createState() => _BackupCloudHeroState();
}

class _BackupCloudHeroState extends State<BackupCloudHero> with TickerProviderStateMixin {
  static const _cloudTop = 14.0;
  static const _ringSize = 78.0;
  static const _circleSize = 64.0;
  static const _switchDuration = Duration(milliseconds: 350);

  // Text leaves during the first 40 % and the new text arrives after it, so they never overlap.
  static const _textIn = Interval(0.4, 1, curve: Curves.easeOutCubic);
  static const _textOut = Interval(0.6, 1, curve: Curves.easeIn);

  late final Ticker _ticker;
  final _seconds = ValueNotifier<double>(0);

  /// Fades the rising photos in and out instead of cutting them.
  late final AnimationController _presence = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  );

  /// One-shot pop played when backup is turned on or off.
  late final AnimationController _toggle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
    value: 1,
  );
  bool _turnedOn = true;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) => _seconds.value = elapsed.inMicroseconds / Duration.microsecondsPerSecond);
    _presence.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && _ticker.isActive) {
        _ticker.stop();
        _seconds.value = 0;
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(covariant BackupCloudHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasOff = oldWidget.state == BackupCloudState.off;
    final isOff = widget.state == BackupCloudState.off;
    if (wasOff != isOff && !_reduceMotion) {
      _turnedOn = !isOff;
      _toggle.forward(from: 0);
    }
    _syncMotion();
  }

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  void _syncMotion() {
    if (_reduceMotion) {
      _presence.value = 0;
      return;
    }
    if (widget.state == BackupCloudState.uploading) {
      if (!_ticker.isActive) {
        _ticker.start();
      }
      _presence.forward();
    } else {
      _presence.reverse();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _presence.dispose();
    _toggle.dispose();
    _seconds.dispose();
    super.dispose();
  }

  /// Turning on overshoots outwards, turning off dips inwards; both settle at 1.
  double _popScale(double value) {
    final peak = _turnedOn ? 1.14 : 0.9;
    if (value < 0.35) {
      return 1 + (peak - 1) * Curves.easeOut.transform(value / 0.35);
    }
    return peak + (1 - peak) * Curves.easeOutBack.transform((value - 0.35) / 0.65);
  }

  static Widget _fadeSlide(Widget child, Animation<double> animation) => FadeTransition(
    opacity: animation,
    child: SlideTransition(
      position: Tween(
        begin: const Offset(0, 0.25),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final primary = context.primaryColor;
    final isError = widget.state == BackupCloudState.error;
    final showRing = widget.state == BackupCloudState.uploading || widget.state == BackupCloudState.syncing;
    // Keeps the text readable while a square passes behind it.
    final halo = [Shadow(color: scheme.surface, blurRadius: 6), Shadow(color: scheme.surface, blurRadius: 12)];
    final (icon, iconColor, circleColor) = switch (widget.state) {
      BackupCloudState.off => (Icons.cloud_off_outlined, scheme.onSurfaceSecondary, scheme.surfaceContainer),
      BackupCloudState.idle ||
      BackupCloudState.uploading => (Icons.cloud_upload_outlined, primary, scheme.surfaceContainer),
      BackupCloudState.syncing => (Icons.cloud_sync_outlined, primary, scheme.surfaceContainer),
      BackupCloudState.done => (Icons.cloud_done_outlined, primary, scheme.surfaceContainer),
      BackupCloudState.error => (Icons.warning_rounded, scheme.error, scheme.errorContainer),
    };

    final cloud = SizedBox.square(
      dimension: _ringSize,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          AnimatedSwitcher(
            duration: _switchDuration,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(scale: Tween(begin: 0.85, end: 1.0).animate(animation), child: child),
            ),
            child: showRing
                ? SizedBox.square(
                    key: const ValueKey('ring'),
                    dimension: _ringSize - 2,
                    child: CircularProgressIndicator(strokeWidth: 3, strokeCap: StrokeCap.round, color: primary),
                  )
                : const SizedBox.square(key: ValueKey('no-ring'), dimension: _ringSize - 2),
          ),
          AnimatedContainer(
            duration: _switchDuration,
            curve: Curves.easeOutCubic,
            width: _circleSize,
            height: _circleSize,
            decoration: BoxDecoration(color: circleColor, shape: BoxShape.circle),
            child: AnimatedSwitcher(
              duration: _switchDuration,
              switchInCurve: Curves.easeOutBack,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(scale: Tween(begin: 0.5, end: 1.0).animate(animation), child: child),
              ),
              child: Icon(icon, key: ValueKey(icon), size: 32, color: iconColor),
            ),
          ),
        ],
      ),
    );

    return Stack(
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _RisingPhotosPainter(_seconds, _presence, cloudCentreY: _cloudTop + _ringSize / 2),
            ),
          ),
        ),
        SizedBox(
          width: double.infinity,
          child: Column(
            children: [
              const SizedBox(height: _cloudTop),
              AnimatedBuilder(
                animation: Listenable.merge([_seconds, _presence, _toggle]),
                builder: (context, child) {
                  final bob = -1.5 * (1 - math.cos(2 * math.pi * _seconds.value / 2.2)) * _presence.value;
                  final popping = _toggle.value < 1;
                  return Transform.translate(
                    offset: Offset(0, bob),
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        // Turning on sends a single ring outwards from the cloud.
                        if (popping && _turnedOn)
                          IgnorePointer(
                            child: Opacity(
                              opacity: (1 - _toggle.value) * 0.6,
                              child: Transform.scale(
                                scale: 1 + 0.7 * Curves.easeOutCubic.transform(_toggle.value),
                                child: Container(
                                  width: _circleSize,
                                  height: _circleSize,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(color: primary, width: 2),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        Transform.scale(scale: popping ? _popScale(_toggle.value) : 1, child: child),
                      ],
                    ),
                  );
                },
                child: cloud,
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: AnimatedSwitcher(
                  duration: _switchDuration,
                  switchInCurve: _textIn,
                  switchOutCurve: _textOut,
                  transitionBuilder: _fadeSlide,
                  // Keyed by state so live counts update in place without re-animating.
                  child: Text(
                    widget.title,
                    key: ValueKey(widget.state),
                    textAlign: TextAlign.center,
                    style: context.textTheme.titleMedium?.copyWith(color: isError ? scheme.error : null, shadows: halo),
                  ),
                ),
              ),
              AnimatedSize(
                duration: _switchDuration,
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: Column(
                  children: [
                    AnimatedSwitcher(
                      duration: _switchDuration,
                      switchInCurve: _textIn,
                      switchOutCurve: _textOut,
                      transitionBuilder: _fadeSlide,
                      child: widget.subtitle == null
                          ? SizedBox(key: ValueKey(widget.state), width: double.infinity)
                          : Padding(
                              key: ValueKey(widget.state),
                              padding: const EdgeInsets.fromLTRB(24, 2, 24, 0),
                              child: Text(
                                widget.subtitle!,
                                textAlign: TextAlign.center,
                                style: context.textTheme.bodyMedium?.copyWith(
                                  color: scheme.onSurfaceSecondary,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                  shadows: halo,
                                ),
                              ),
                            ),
                    ),
                    if (widget.footer case final Widget footer) footer,
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ],
    );
  }
}

/// Twelve photo-like squares, half from each side, each rising into the cloud
/// on its own period so the stream never pulses in sync.
class _RisingPhotosPainter extends CustomPainter {
  _RisingPhotosPainter(this.seconds, this.presence, {required this.cloudCentreY})
    : super(repaint: Listenable.merge([seconds, presence]));

  final ValueListenable<double> seconds;
  final Animation<double> presence;
  final double cloudCentreY;

  // Muted photo tones shared with the inhouse photos website.
  static const _tones = [
    (Color(0xFFC9A16E), Color(0xFF487082)),
    (Color(0xFF463128), Color(0xFFD4B693)),
    (Color(0xFFB8C9CA), Color(0xFF3C5834)),
    (Color(0xFFBD8B65), Color(0xFF634931)),
    (Color(0xFF778F9E), Color(0xFFD5B79C)),
    (Color(0xFF473729), Color(0xFFE1C197)),
    (Color(0xFF8895A3), Color(0xFF3C574A)),
    (Color(0xFFC4A683), Color(0xFF755E51)),
  ];
  static const _count = 12;
  static const _side = 24.0;

  @override
  void paint(Canvas canvas, Size size) {
    final fade = presence.value;
    if (fade == 0) {
      return;
    }
    final t = seconds.value;
    final target = Offset(size.width / 2, cloudCentreY);
    const rect = Rect.fromLTWH(-_side / 2, -_side / 2, _side, _side);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(6));

    for (var i = 0; i < _count; i++) {
      final local = t - (i * 0.37) % 3;
      if (local < 0) {
        continue;
      }
      final phase = (local / (2.4 + (i % 4) * 0.45)) % 1;
      // Squares start only near the edges, so they converge on the cloud without crossing the text.
      final fraction = i.isOdd ? 0.73 + ((i * 13) % 76) / 412 : 0.034 + ((i * 17) % 80) / 412;
      final start = Offset(size.width * fraction + _side / 2, size.height - 6 - _side / 2);
      final eased = Curves.easeInOut.transform(phase);
      final centre = Offset.lerp(start, target, eased)!;
      final opacity =
          fade *
          (phase < 0.12
              ? phase / 0.12
              : phase > 0.72
              ? (1 - phase) / 0.28
              : 1.0);
      final (from, to) = _tones[i % _tones.length];

      canvas
        ..save()
        ..translate(centre.dx, centre.dy)
        ..rotate((i.isOdd ? 1 : -1) * (6 + i * 3) * math.pi / 180 * (1 - eased))
        ..scale(1 - 0.75 * eased)
        ..drawRRect(
          rrect.shift(const Offset(0, 2)),
          Paint()
            ..color = Colors.black.withValues(alpha: 0.18 * opacity)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
        )
        ..drawRRect(
          rrect,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                from.withValues(alpha: opacity),
                to.withValues(alpha: opacity),
              ],
            ).createShader(rect),
        )
        ..restore();
    }
  }

  @override
  bool shouldRepaint(covariant _RisingPhotosPainter oldDelegate) =>
      oldDelegate.seconds != seconds || oldDelegate.presence != presence || oldDelegate.cloudCentreY != cloudCentreY;
}
