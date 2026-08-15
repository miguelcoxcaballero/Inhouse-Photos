import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android background backup keeps the three-upload worker pool', () {
    final worker = File('lib/domain/services/background_worker.service.dart').readAsStringSync();
    final uploader = File('lib/services/foreground_upload.service.dart').readAsStringSync();

    expect(worker, isNot(contains('useSequentialUpload: true')));
    expect(uploader, contains('int concurrentWorkers = 3'));
  });
}
