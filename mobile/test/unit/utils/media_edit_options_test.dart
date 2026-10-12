import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/presentation/pages/edit/media_edit_options.dart';

void main() {
  List<double> pixel(MediaEditOptions options, double r, double g, double b) {
    final m = options.colorMatrix;
    return [
      for (final i in [0, 5, 10]) m[i] * r + m[i + 1] * g + m[i + 2] * b + m[i + 4],
    ];
  }

  test('default adjustments preserve channel values for preview and export', () {
    expect(pixel(const MediaEditOptions(), 20, 110, 240), [20, 110, 240]);
    expect(const MediaEditOptions().hasChanges(durationMs: 0), false);
  });

  test('zero saturation produces equal luminance channels', () {
    final result = pixel(const MediaEditOptions(saturation: 0), 255, 0, 0);
    expect(result[0], closeTo(54.213, 0.001));
    expect(result[1], result[0]);
    expect(result[2], result[0]);
  });

  test('brightness and contrast operate around middle gray', () {
    expect(pixel(const MediaEditOptions(contrast: 1.5), 128, 128, 128), [128, 128, 128]);
    expect(pixel(const MediaEditOptions(brightness: 0.2), 0, 0, 0), [51, 51, 51]);
  });

  test('counterclockwise UI rotation is exported as a normalized quarter turn', () {
    expect(const MediaEditOptions(quarterTurns: -1).toMap()['rotation'], 270);
    expect(const MediaEditOptions(quarterTurns: 4).hasChanges(durationMs: 0), false);
  });

  test('full video range is not an edit but trimming or muting is', () {
    expect(const MediaEditOptions(endMs: 10000).hasChanges(durationMs: 10000), false);
    expect(const MediaEditOptions(startMs: 1, endMs: 10000).hasChanges(durationMs: 10000), true);
    expect(const MediaEditOptions(mute: true).hasChanges(durationMs: 10000), true);
    expect(const MediaEditOptions(crop: Rect.fromLTWH(0.1, 0, 0.9, 1)).hasChanges(durationMs: 0), true);
  });

  test('pending server extraction does not erase GPS from an edited original', () {
    final parameters = editedLocationParameters(const ExifInfo(fileSize: 4000), hasRemote: true);
    expect(parameters['replaceLocation'], false);
    expect(parameters.containsKey('location'), false);
  });

  test('manual server coordinates take precedence even before extraction', () {
    final parameters = editedLocationParameters(const ExifInfo(latitude: 0, longitude: 0), hasRemote: true);
    expect(parameters['replaceLocation'], true);
    expect(parameters['location'], [0, 0]);
  });

  test('location cleared from extracted metadata stays cleared in a copy', () {
    final parameters = editedLocationParameters(const ExifInfo(width: 4000, height: 3000), hasRemote: true);
    expect(parameters['replaceLocation'], true);
    expect(parameters.containsKey('location'), false);
  });

  test('missing local location does not erase embedded EXIF GPS', () {
    final parameters = editedLocationParameters(const ExifInfo(width: 4000, height: 3000), hasRemote: false);
    expect(parameters['replaceLocation'], false);
  });
}
