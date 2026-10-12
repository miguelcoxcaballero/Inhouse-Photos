import 'dart:math';

import 'package:async/async.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/colors.dart';
import 'package:immich_mobile/models/cast/cast_manager_state.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/cast.provider.dart';
import 'package:immich_mobile/extensions/duration_extensions.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/widgets/asset_viewer/animated_play_pause.dart';

class VideoControls extends ConsumerStatefulWidget {
  final String videoPlayerName;
  final bool useThemeColors;

  static const List<Shadow> _controlShadows = [Shadow(color: Colors.black87, blurRadius: 6, offset: Offset(0, 1))];

  const VideoControls({super.key, required this.videoPlayerName, this.useThemeColors = false});

  @override
  ConsumerState<VideoControls> createState() => _VideoControlsState();
}

class _VideoControlsState extends ConsumerState<VideoControls> {
  late final RestartableTimer _hideTimer;

  AutoDisposeStateNotifierProvider<VideoPlayerNotifier, VideoPlayerState> get _provider =>
      videoPlayerProvider(widget.videoPlayerName);

  @override
  void initState() {
    super.initState();
    _hideTimer = RestartableTimer(const Duration(seconds: 5), _onHideTimer);
  }

  @override
  void didUpdateWidget(covariant VideoControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPlayerName != widget.videoPlayerName) {
      _hideTimer.reset();
    }
  }

  @override
  void dispose() {
    _hideTimer.cancel();
    super.dispose();
  }

  void _onHideTimer() {
    if (!mounted) {
      return;
    }
    if (ref.read(_provider).status == VideoPlaybackStatus.playing) {
      ref.read(assetViewerProvider.notifier).setControls(false);
    }
  }

  void _toggle(bool isCasting) {
    if (isCasting) {
      ref.read(castProvider.notifier).toggle();
      return;
    }

    ref.read(_provider.notifier).toggle();
  }

  void _onSeek(bool isCasting, double value) {
    final seekTo = Duration(microseconds: value.toInt());

    if (isCasting) {
      ref.read(castProvider.notifier).seekTo(seekTo);
      return;
    }

    ref.read(_provider.notifier).seekTo(seekTo);
  }

  @override
  Widget build(BuildContext context) {
    final cast = ref.watch(castProvider);
    final isCasting = cast.isCasting;

    final (position, duration) = isCasting
        ? ref.watch(castProvider.select((c) => (c.currentTime, c.duration)))
        : ref.watch(_provider.select((v) => (v.position, v.duration)));

    final videoStatus = ref.watch(_provider.select((v) => v.status));
    final isPlaying = isCasting
        ? cast.castState == CastState.playing
        : videoStatus == VideoPlaybackStatus.playing || videoStatus == VideoPlaybackStatus.buffering;
    final isFinished = !isCasting && videoStatus == VideoPlaybackStatus.completed;

    ref.listen(assetViewerProvider.select((v) => v.showingControls), (prev, showing) {
      if (showing && prev != showing) {
        _hideTimer.reset();
      }
    });
    ref.listen(_provider.select((v) => v.status), (_, __) => _hideTimer.reset());

    final notifier = ref.read(_provider.notifier);
    final isLoaded = duration != Duration.zero;
    final foreground = widget.useThemeColors ? context.colorScheme.onSurface : Colors.white;
    final shadows = widget.useThemeColors ? null : VideoControls._controlShadows;

    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 12),
      child: Column(
        spacing: 4,
        children: [
          Row(
            children: [
              IconButton(
                iconSize: 32,
                padding: const EdgeInsets.all(12),
                constraints: const BoxConstraints(),
                icon: isFinished
                    ? Icon(Icons.replay, color: foreground, shadows: shadows)
                    : AnimatedPlayPause(color: foreground, playing: isPlaying, shadows: shadows),
                onPressed: () => _toggle(isCasting),
              ),
              const Spacer(),
              IgnorePointer(
                child: Text(
                  "${position.format()} / ${duration.format()}",
                  style: TextStyle(
                    color: foreground,
                    fontWeight: FontWeight.w500,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    shadows: shadows,
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
          ),
          Slider(
            value: min(position.inMicroseconds.toDouble(), duration.inMicroseconds.toDouble()),
            min: 0,
            max: max(duration.inMicroseconds.toDouble(), 1),
            thumbColor: widget.useThemeColors ? context.primaryColor : Colors.white,
            activeColor: widget.useThemeColors ? context.primaryColor : Colors.white,
            inactiveColor: widget.useThemeColors ? foreground.withValues(alpha: 0.3) : whiteOpacity75,
            padding: EdgeInsets.zero,
            onChangeStart: (_) => notifier.hold(),
            onChangeEnd: (_) => notifier.release(),
            onChanged: isLoaded ? (value) => _onSeek(isCasting, value) : null,
          ),
        ],
      ),
    );
  }
}
