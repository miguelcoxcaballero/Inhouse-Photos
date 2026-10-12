import 'dart:async';
import 'dart:io';

import 'package:crop_image/crop_image.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/presentation/pages/edit/media_edit_options.dart';
import 'package:immich_mobile/presentation/pages/edit/media_editor.service.dart';
import 'package:native_video_player/native_video_player.dart';

/// A local save-copy editor. Server and device originals are never overwritten.
class MediaEditPage extends StatefulWidget {
  final BaseAsset asset;
  final ExifInfo? metadata;
  final MediaEditorService? service;
  const MediaEditPage({super.key, required this.asset, this.metadata, this.service});

  @override
  State<MediaEditPage> createState() => _MediaEditPageState();
}

class _MediaEditPageState extends State<MediaEditPage> with WidgetsBindingObserver {
  late final MediaEditorService _service;
  final _crop = CropController();
  File? _source;
  File? _preview;
  NativeVideoPlayerController? _player;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  bool _cancelled = false;
  bool _saved = false;
  bool _playing = false;
  bool _playbackBusy = false;
  bool _cropRefreshScheduled = false;
  double? _progress;
  int _turns = 0;
  bool _flip = false;
  bool _mute = false;
  double _brightness = 0;
  double _contrast = 1;
  double _saturation = 1;
  int _durationMs = 0;
  RangeValues _trim = const RangeValues(0, 1);
  int _tab = 0;
  double? _aspectRatio;
  double _videoRatio = 16 / 9;

  bool get _video => widget.asset.isVideo;
  String _text(String english, String spanish) => context.locale.languageCode == 'es' ? spanish : english;
  MediaEditOptions get _options => MediaEditOptions(
    crop: _crop.crop,
    quarterTurns: _turns,
    flipHorizontal: _flip,
    brightness: _brightness,
    contrast: _contrast,
    saturation: _saturation,
    mute: _mute,
    startMs: _trim.start.round(),
    endMs: _video ? _trim.end.round() : null,
  );
  bool get _changed => !_loading && _source != null && _options.hasChanges(durationMs: _durationMs);

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? MediaEditorService();
    WidgetsBinding.instance.addObserver(this);
    _crop.addListener(_onCrop);
    unawaited(_load());
  }

  void _onCrop() {
    if (!mounted) {
      return;
    }
    // CropImage can synchronously publish a cached image from its initState.
    // Defer the parent's refresh until that build has finished.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      if (_cropRefreshScheduled) {
        return;
      }
      _cropRefreshScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _cropRefreshScheduled = false;
        if (mounted) {
          setState(() {});
        }
      });
    } else {
      setState(() {});
    }
  }

  Future<void> _load() async {
    try {
      final source = await _service.acquire(widget.asset, (progress) {
        if (mounted) {
          setState(() => _progress = progress);
        }
      });
      if (!mounted) {
        return;
      }
      final info = await _service.inspect(source, isVideo: _video);
      if (!mounted) {
        return;
      }
      setState(() {
        _source = source;
        _loading = false;
        if (_video) {
          _durationMs = (info['durationMs'] as num).toInt();
          _trim = RangeValues(0, _durationMs.toDouble());
          _videoRatio = (info['width'] as num).toDouble() / (info['height'] as num).toDouble();
        } else {
          _preview = File(info['previewPath'] as String);
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error.toString();
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _player?.onPlaybackPositionChanged.removeListener(_checkTrimEnd);
    _player?.onError.removeListener(_onPlayerError);
    _crop.removeListener(_onCrop);
    _crop.dispose();
    unawaited(_service.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_playerAction((player) => player.pause()));
      if (mounted) {
        setState(() => _playing = false);
      }
    }
  }

  Future<void> _playerAction(Future<void> Function(NativeVideoPlayerController player) action) async {
    final player = _player;
    if (player == null) {
      return;
    }
    try {
      await action(player);
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    }
  }

  Future<void> _save() async {
    if (_source == null || _saving || !_changed) {
      return;
    }
    setState(() {
      _saving = true;
      _progress = 0;
      _error = null;
      _cancelled = false;
      _playing = false;
    });
    try {
      await _playerAction((player) => player.pause());
      if (!mounted) {
        return;
      }
      if (_cancelled) {
        setState(() => _saving = false);
        return;
      }
      await _service.saveCopy(_source!, widget.asset, _options, (progress) {
        if (mounted) {
          setState(() => _progress = progress);
        }
      }, metadata: widget.metadata);
      if (!mounted) {
        return;
      }
      setState(() {
        _saving = false;
        _saved = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _text(
              'Copy saved in Inhouse Edits. Your original is unchanged.',
              'Copia guardada en Inhouse Edits. El original se conserva.',
            ),
          ),
        ),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.of(context).pop(true);
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = _cancelled ? null : error.toString();
        });
      }
    }
  }

  Future<void> _close() async {
    if (_saving) {
      return;
    }
    if (_changed) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('editor_discard_edits_title'.tr()),
          content: Text('editor_discard_edits_prompt'.tr()),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text('cancel'.tr())),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text('confirm'.tr())),
          ],
        ),
      );
      if (discard != true || !mounted) {
        return;
      }
    }
    setState(() => _saved = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Navigator.of(context).pop();
      }
    });
  }

  Future<void> _initPlayer(NativeVideoPlayerController controller) async {
    _player = controller;
    controller.onPlaybackPositionChanged.addListener(_checkTrimEnd);
    controller.onError.addListener(_onPlayerError);
    try {
      final source = await VideoSource.init(path: _source!.uri.toString(), type: VideoSourceType.file);
      if (!mounted) {
        return;
      }
      await controller.setVolume(_mute ? 0 : 1);
      await controller.loadVideoSource(source);
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    }
  }

  void _onPlayerError() {
    if (mounted && _player?.onError.value != null) {
      setState(() => _error = _player!.onError.value);
    }
  }

  void _checkTrimEnd() {
    if (_playing && (_player?.onPlaybackPositionChanged.value ?? 0) >= _trim.end.round()) {
      unawaited(_playerAction((player) => player.pause()));
      if (mounted) {
        setState(() => _playing = false);
      }
    }
  }

  Future<void> _togglePlayback() async {
    final player = _player;
    if (player == null || _playbackBusy) {
      return;
    }
    setState(() => _playbackBusy = true);
    final nextPlaying = !_playing;
    try {
      if (nextPlaying) {
        await player.seekTo(_trim.start.round());
        await player.play();
      } else {
        await player.pause();
      }
      if (mounted) {
        setState(() => _playing = nextPlaying);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _playbackBusy = false);
      }
    }
  }

  void _rotate(int turns) {
    setState(() => _turns += turns);
    if (!_video && _aspectRatio != null) {
      _crop.aspectRatio = _turns.isEven ? _aspectRatio : 1 / _aspectRatio!;
    }
  }

  void _reset() {
    _crop.aspectRatio = null;
    _crop.crop = const Rect.fromLTWH(0, 0, 1, 1);
    setState(() {
      _turns = 0;
      _flip = false;
      _brightness = 0;
      _contrast = 1;
      _saturation = 1;
      _mute = false;
      _aspectRatio = null;
      _trim = RangeValues(0, _durationMs.toDouble());
    });
    unawaited(_playerAction((player) => player.setVolume(1)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: _saved || (!_saving && !_changed),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          unawaited(_close());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(onPressed: _saving ? null : _close, icon: const Icon(Icons.close_rounded)),
          title: Text('edit'.tr()),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                onPressed: _saving || _loading || !_changed || _source == null ? null : _save,
                child: Text(_text('Save copy', 'Guardar copia')),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              if (_saving) ...[
                LinearProgressIndicator(value: !_video && (_progress ?? 0) < 1 ? null : _progress),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          (_progress ?? 0) >= 1
                              ? _text('Adding to your library…', 'Añadiendo a la biblioteca…')
                              : _text('Saving copy…', 'Guardando copia…'),
                        ),
                      ),
                      TextButton(
                        onPressed: _cancelled || (_progress ?? 0) >= 1
                            ? null
                            : () async {
                                if ((_progress ?? 0) >= 1) {
                                  return;
                                }
                                setState(() => _cancelled = true);
                                await _service.cancel();
                              },
                        child: Text('cancel'.tr()),
                      ),
                    ],
                  ),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '${_text('Could not complete the edit. Your original is safe.', 'No se ha podido completar la edición. El original está a salvo.')}\n$_error',
                    style: TextStyle(color: colors.error),
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              Expanded(
                child: _loading
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(value: _progress),
                            const SizedBox(height: 16),
                            Text(_text('Preparing original…', 'Preparando original…')),
                          ],
                        ),
                      )
                    : _source == null
                    ? const SizedBox.shrink()
                    : AbsorbPointer(
                        absorbing: _saving,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: _video
                              ? Center(
                                  child: RotatedBox(
                                    quarterTurns: _turns,
                                    child: AspectRatio(
                                      aspectRatio: _videoRatio,
                                      child: NativeVideoPlayerView(onViewReady: _initPlayer),
                                    ),
                                  ),
                                )
                              : RotatedBox(
                                  quarterTurns: _turns,
                                  child: Transform.flip(
                                    flipX: _flip,
                                    child: CropImage(
                                      controller: _crop,
                                      image: Image.file(_preview!),
                                      gridColor: colors.primary,
                                      minimumImageSize: 24,
                                      overlayWidget: ColoredBox(
                                        color: colors.surface,
                                        child: ColorFiltered(
                                          colorFilter: ColorFilter.matrix(_options.colorMatrix),
                                          child: Image.file(_preview!, fit: BoxFit.fill),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                      ),
              ),
              if (_source != null)
                AbsorbPointer(
                  absorbing: _saving,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.45),
                    child: SingleChildScrollView(
                      child: Container(
                        decoration: BoxDecoration(
                          color: colors.surfaceContainer,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                        ),
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_video)
                              _videoControls()
                            else ...[
                              SegmentedButton<int>(
                                segments: [
                                  ButtonSegment(
                                    value: 0,
                                    icon: const Icon(Icons.crop_rotate_rounded),
                                    label: Text(_text('Crop', 'Recortar')),
                                  ),
                                  ButtonSegment(
                                    value: 1,
                                    icon: const Icon(Icons.tune_rounded),
                                    label: Text(_text('Adjust', 'Ajustar')),
                                  ),
                                ],
                                selected: {_tab},
                                onSelectionChanged: (value) => setState(() => _tab = value.first),
                              ),
                              const SizedBox(height: 8),
                              if (_tab == 0)
                                _photoControls()
                              else ...[
                                _adjustment(
                                  _text('Brightness', 'Brillo'),
                                  _brightness,
                                  -0.5,
                                  0.5,
                                  (v) => setState(() => _brightness = v),
                                ),
                                _adjustment(
                                  _text('Contrast', 'Contraste'),
                                  _contrast,
                                  0.5,
                                  1.5,
                                  (v) => setState(() => _contrast = v),
                                ),
                                _adjustment(
                                  _text('Saturation', 'Saturación'),
                                  _saturation,
                                  0,
                                  2,
                                  (v) => setState(() => _saturation = v),
                                ),
                              ],
                            ],
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _text('Original is kept', 'Se conserva el original'),
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                ),
                                TextButton(onPressed: _changed ? _reset : null, child: Text('reset'.tr())),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _photoControls() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: _text('Rotate left', 'Girar a la izquierda'),
            onPressed: () => _rotate(-1),
            icon: const Icon(Icons.rotate_left_rounded),
          ),
          IconButton(
            tooltip: _text('Rotate right', 'Girar a la derecha'),
            onPressed: () => _rotate(1),
            icon: const Icon(Icons.rotate_right_rounded),
          ),
          IconButton(
            tooltip: _text('Flip', 'Voltear'),
            isSelected: _flip,
            onPressed: () => setState(() => _flip = !_flip),
            icon: const Icon(Icons.flip_rounded),
          ),
        ],
      ),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          spacing: 8,
          children: [
            for (final ratio in <(String, double?)>[
              (_text('Free', 'Libre'), null),
              ('1:1', 1),
              ('4:3', 4 / 3),
              ('3:4', 3 / 4),
              ('16:9', 16 / 9),
              ('9:16', 9 / 16),
            ])
              ChoiceChip(
                label: Text(ratio.$1),
                selected: _aspectRatio == ratio.$2,
                onSelected: (_) {
                  setState(() => _aspectRatio = ratio.$2);
                  _crop.aspectRatio = ratio.$2 == null || _turns.isEven ? ratio.$2 : 1 / ratio.$2!;
                },
              ),
          ],
        ),
      ),
    ],
  );

  Widget _adjustment(String label, double value, double min, double max, ValueChanged<double> changed) => Row(
    children: [
      SizedBox(width: 90, child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
      Expanded(
        child: Slider(value: value, min: min, max: max, onChanged: changed),
      ),
    ],
  );

  Widget _videoControls() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(_text('Trim video', 'Recortar vídeo'), style: Theme.of(context).textTheme.titleMedium),
          Text('${_time(_trim.start)} – ${_time(_trim.end)}'),
        ],
      ),
      RangeSlider(
        values: _trim,
        min: 0,
        max: _durationMs.toDouble(),
        onChanged: (values) {
          if (values.end - values.start < (_durationMs < 1000 ? _durationMs : 1000)) {
            return;
          }
          setState(() {
            _trim = values;
            _playing = false;
          });
          unawaited(_playerAction((player) => player.pause()));
          unawaited(_playerAction((player) => player.seekTo(values.start.round())));
        },
      ),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            tooltip: _text('Preview selection', 'Ver selección'),
            onPressed: _playbackBusy ? null : _togglePlayback,
            icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
          ),
          IconButton(
            tooltip: _text('Rotate', 'Girar'),
            onPressed: () => _rotate(1),
            icon: const Icon(Icons.rotate_right_rounded),
          ),
          FilterChip(
            label: Text(_text('Mute', 'Silenciar')),
            avatar: Icon(_mute ? Icons.volume_off_rounded : Icons.volume_up_rounded),
            selected: _mute,
            onSelected: (value) {
              setState(() => _mute = value);
              unawaited(_playerAction((player) => player.setVolume(value ? 0 : 1)));
            },
          ),
        ],
      ),
    ],
  );

  String _time(double ms) {
    final seconds = ms ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}.${((ms % 1000) / 100).floor()}';
  }
}
