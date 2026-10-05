import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:intl/intl.dart';

/// Backup progress split into stages: backed up | ready to upload | preparing.
class BackupStageBar extends StatefulWidget {
  const BackupStageBar({
    super.key,
    required this.total,
    required this.backedUp,
    required this.ready,
    required this.preparing,
    required this.backedUpLabel,
    required this.backedUpLegend,
    required this.readyLegend,
    required this.preparingLegend,
    required this.totalLabel,
    this.isPreparing = false,
    this.isUploading = false,
    this.isError = false,
  });

  final int total;
  final int backedUp;
  final int ready;
  final int preparing;

  /// Text after the percentage, e.g. "backed up".
  final String backedUpLabel;
  final String backedUpLegend;
  final String readyLegend;
  final String preparingLegend;
  final String totalLabel;

  final bool isPreparing;
  final bool isUploading;
  final bool isError;

  @override
  State<BackupStageBar> createState() => _BackupStageBarState();
}

class _BackupStageBarState extends State<BackupStageBar> with SingleTickerProviderStateMixin {
  static const _height = 12.0;
  static const _gap = 2.0;
  static const _duration = Duration(milliseconds: 600);
  static const _curve = Cubic(0.2, 0, 0, 1);

  late final AnimationController _stripes = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncStripes();
  }

  @override
  void didUpdateWidget(covariant BackupStageBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncStripes();
  }

  void _syncStripes() {
    final animate = widget.isUploading && !widget.isError && !MediaQuery.disableAnimationsOf(context);
    if (animate && !_stripes.isAnimating) {
      _stripes.repeat();
    } else if (!animate && _stripes.isAnimating) {
      _stripes.stop();
    }
  }

  @override
  void dispose() {
    _stripes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final locale = Localizations.localeOf(context).toString();
    final count = _numberFormat(locale);
    final fraction = widget.total == 0 ? 0.0 : widget.backedUp / widget.total;
    final backedColor = widget.isError ? scheme.error : context.primaryColor;
    final readyColor = context.primaryColor.withValues(alpha: 0.4);
    final preparingColor = context.isDarkTheme ? const Color(0xFFF4B64A) : const Color(0xFFD9A23A);
    final secondary = context.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceSecondary);
    const tabular = [FontFeature.tabularFigures()];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: _percentFormat(locale).format(fraction),
                      style: context.textTheme.titleLarge?.copyWith(
                        fontSize: 22,
                        color: backedColor,
                        fontFeatures: tabular,
                      ),
                    ),
                    TextSpan(text: ' ${widget.backedUpLabel}', style: secondary),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '${widget.totalLabel} ', style: secondary),
                  TextSpan(
                    text: count.format(widget.total),
                    style: context.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontFeatures: tabular),
                  ),
                ],
              ),
              maxLines: 1,
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(_height / 2),
          child: SizedBox(
            height: _height,
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (widget.total == 0) {
                  return ColoredBox(color: scheme.secondaryContainer);
                }
                final available = math.max(0.0, constraints.maxWidth - 2 * _gap);
                double width(int value) => (available * value / widget.total).clamp(0.0, available);
                // Preparing keeps a visible sliver; the ready stripe absorbs the difference so the row never overflows.
                final backedWidth = width(widget.backedUp);
                final preparingWidth = widget.preparing > 0
                    ? math.max(0.0, math.min(math.max(width(widget.preparing), 4.0), available - backedWidth))
                    : 0.0;
                final readyWidth = math.max(
                  0.0,
                  math.min(width(widget.ready), available - backedWidth - preparingWidth),
                );
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AnimatedContainer(duration: _duration, curve: _curve, width: backedWidth, color: backedColor),
                    const SizedBox(width: _gap),
                    AnimatedContainer(
                      duration: _duration,
                      curve: _curve,
                      width: readyWidth,
                      child: CustomPaint(painter: _StripesPainter(_stripes, context.primaryColor)),
                    ),
                    const SizedBox(width: _gap),
                    AnimatedContainer(duration: _duration, curve: _curve, width: preparingWidth, color: preparingColor),
                  ],
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 14,
          runSpacing: 4,
          children: [
            _LegendItem(color: backedColor, label: widget.backedUpLegend, value: count.format(widget.backedUp)),
            _LegendItem(color: readyColor, label: widget.readyLegend, value: count.format(widget.ready)),
            _LegendItem(
              color: preparingColor,
              label: widget.preparingLegend,
              value: count.format(widget.preparing),
              busy: widget.isPreparing,
            ),
          ],
        ),
      ],
    );
  }

  static NumberFormat _numberFormat(String locale) {
    try {
      return NumberFormat.decimalPattern(locale);
    } catch (_) {
      return NumberFormat.decimalPattern('en');
    }
  }

  static NumberFormat _percentFormat(String locale) {
    try {
      return NumberFormat.decimalPercentPattern(locale: locale, decimalDigits: 1);
    } catch (_) {
      return NumberFormat.decimalPercentPattern(locale: 'en', decimalDigits: 1);
    }
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.color, required this.label, required this.value, this.busy = false});

  final Color color;
  final String label;
  final String value;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final style = context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceSecondary);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 6),
        Text(label, style: style),
        const SizedBox(width: 4),
        Text(
          value,
          style: style?.copyWith(
            color: context.colorScheme.onSurface,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (busy) ...[
          const SizedBox(width: 6),
          SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2, color: context.primaryColor)),
        ],
      ],
    );
  }
}

/// Diagonal stripes that slide while files upload.
class _StripesPainter extends CustomPainter {
  _StripesPainter(this.progress, this.color) : super(repaint: progress);

  final Animation<double> progress;
  final Color color;

  static const _period = 17.0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = color.withValues(alpha: 0.22));
    final stripe = Paint()..color = color.withValues(alpha: 0.45);
    final shift = progress.value * _period;
    canvas.clipRect(Offset.zero & size);
    for (var x = -size.height - _period + shift; x < size.width + size.height; x += _period) {
      final path = Path()
        ..moveTo(x, size.height)
        ..lineTo(x + size.height, 0)
        ..lineTo(x + size.height + _period / 2, 0)
        ..lineTo(x + _period / 2, size.height)
        ..close();
      canvas.drawPath(path, stripe);
    }
  }

  @override
  bool shouldRepaint(covariant _StripesPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.progress != progress;
}
