import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';

/// Values are expressed in the upright original's coordinates, before rotation.
@immutable
class MediaEditOptions {
  final Rect crop;
  final int quarterTurns;
  final bool flipHorizontal;
  final double brightness;
  final double contrast;
  final double saturation;
  final int startMs;
  final int? endMs;
  final bool mute;

  const MediaEditOptions({
    this.crop = const Rect.fromLTWH(0, 0, 1, 1),
    this.quarterTurns = 0,
    this.flipHorizontal = false,
    this.brightness = 0,
    this.contrast = 1,
    this.saturation = 1,
    this.startMs = 0,
    this.endMs,
    this.mute = false,
  });

  /// Flutter and Android consume the same matrix, avoiding preview/export drift.
  List<double> get colorMatrix {
    final s = saturation.clamp(0.0, 2.0);
    final c = contrast.clamp(0.5, 1.5);
    final r = (1 - s) * 0.2126;
    final g = (1 - s) * 0.7152;
    final b = (1 - s) * 0.0722;
    final offset = brightness.clamp(-0.5, 0.5) * 255 + 128 * (1 - c);
    return [
      (r + s) * c,
      g * c,
      b * c,
      0,
      offset,
      r * c,
      (g + s) * c,
      b * c,
      0,
      offset,
      r * c,
      g * c,
      (b + s) * c,
      0,
      offset,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  bool hasChanges({required int durationMs}) =>
      crop != const Rect.fromLTWH(0, 0, 1, 1) ||
      quarterTurns % 4 != 0 ||
      flipHorizontal ||
      brightness != 0 ||
      contrast != 1 ||
      saturation != 1 ||
      mute ||
      startMs != 0 ||
      (endMs != null && endMs! != durationMs);

  Map<String, Object?> toMap() => {
    'crop': [crop.left, crop.top, crop.right, crop.bottom],
    'rotation': (quarterTurns % 4) * 90,
    'flipHorizontal': flipHorizontal,
    'colorMatrix': colorMatrix,
    'startMs': startMs,
    'endMs': endMs,
    'mute': mute,
  };
}

/// The server creates file-size-only EXIF rows before extraction. Such a row
/// must not erase embedded GPS while the processing queue is catching up.
Map<String, Object?> editedLocationParameters(ExifInfo? metadata, {required bool hasRemote}) {
  final hasCoordinates = metadata?.hasCoordinates == true;
  final hasExtractedDimensions = (metadata?.width ?? 0) > 0 && (metadata?.height ?? 0) > 0;
  return {
    'replaceLocation': hasRemote && (hasCoordinates || hasExtractedDimensions),
    if (hasCoordinates) 'location': [metadata!.latitude!, metadata.longitude!],
  };
}
