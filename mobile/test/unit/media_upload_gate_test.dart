import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/media_upload_gate.dart';

void main() {
  test('only one video uploads at a time, even with many available photo slots', () async {
    final gate = MediaUploadGate(24);
    expect(await gate.acquire(isVideo: true), isTrue);
    final waiting = [gate.acquire(isVideo: true), gate.acquire(isVideo: true)];
    var started = 0;
    for (final future in waiting) {
      unawaited(
        future.then((allowed) {
          if (allowed) {
            started++;
          }
        }),
      );
    }
    await Future<void>.delayed(Duration.zero);
    expect(started, 0);
    gate.release(isVideo: true);
    expect(await waiting.first, isTrue);
    expect(started, 1);
    gate.release(isVideo: true);
    expect(await waiting.last, isTrue);
    gate.release(isVideo: true);
  });

  test('photos run in parallel when no video is waiting', () async {
    final gate = MediaUploadGate(3);
    for (var i = 0; i < 3; i++) {
      expect(await gate.acquire(isVideo: false), isTrue);
    }
    final waiting = gate.acquire(isVideo: false);
    var started = false;
    unawaited(waiting.then((allowed) => started = allowed));
    await Future<void>.delayed(Duration.zero);
    expect(started, isFalse);
    gate.release(isVideo: false);
    expect(await waiting, isTrue);
    for (var i = 0; i < 3; i++) {
      gate.release(isVideo: false);
    }
  });

  test('a waiting video gets an exclusive turn after the active photo batch', () async {
    final gate = MediaUploadGate(2);
    expect(await gate.acquire(isVideo: false), isTrue);
    expect(await gate.acquire(isVideo: false), isTrue);
    final video = gate.acquire(isVideo: true);
    final photo = gate.acquire(isVideo: false);
    var videoStarted = false;
    var photoStarted = false;
    unawaited(video.then((allowed) => videoStarted = allowed));
    unawaited(photo.then((allowed) => photoStarted = allowed));
    gate.release(isVideo: false);
    await Future<void>.delayed(Duration.zero);
    expect(videoStarted, isFalse);
    expect(photoStarted, isFalse);
    gate.release(isVideo: false);
    expect(await video, isTrue);
    expect(photoStarted, isFalse);
    gate.release(isVideo: true);
    expect(await photo, isTrue);
    gate.release(isVideo: false);
  });

  test('photo batches get a turn between queued videos', () async {
    final gate = MediaUploadGate(2);
    expect(await gate.acquire(isVideo: true), isTrue);
    final nextVideo = gate.acquire(isVideo: true);
    final photo = gate.acquire(isVideo: false);
    gate.release(isVideo: true);
    expect(await photo, isTrue);
    var videoStarted = false;
    unawaited(nextVideo.then((allowed) => videoStarted = allowed));
    await Future<void>.delayed(Duration.zero);
    expect(videoStarted, isFalse);
    gate.release(isVideo: false);
    expect(await nextVideo, isTrue);
    gate.release(isVideo: true);
  });

  test('cancellation wakes both media types and prevents new uploads', () async {
    final gate = MediaUploadGate(1);
    expect(await gate.acquire(isVideo: true), isTrue);
    final video = gate.acquire(isVideo: true);
    final photo = gate.acquire(isVideo: false);
    gate.cancel();
    expect(await video, isFalse);
    expect(await photo, isFalse);
    gate.release(isVideo: true);
    expect(await gate.acquire(isVideo: false), isFalse);
  });
}
