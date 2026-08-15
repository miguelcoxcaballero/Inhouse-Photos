import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';

void main() {
  test('multipart upload throttles UI progress without delaying streamed bytes', () async {
    final updates = <({int bytes, int total})>[];
    final request = ProgressMultipartRequest(
      'POST',
      Uri.parse('https://example.test/assets'),
      onProgress: (bytes, total) => updates.add((bytes: bytes, total: total)),
    );
    const chunkCount = 500;
    request.files.add(
      MultipartFile(
        'assetData',
        Stream<List<int>>.fromIterable(List.generate(chunkCount, (index) => [index % 256])),
        chunkCount,
        filename: 'photo.jpg',
      ),
    );

    final streamedBytes = await request.finalize().fold<int>(0, (total, chunk) => total + chunk.length);

    expect(streamedBytes, request.contentLength);
    expect(updates, isNotEmpty);
    expect(updates.last.bytes, request.contentLength);
    expect(updates.last.total, request.contentLength);
    expect(updates.length, lessThan(10));
  });
}
