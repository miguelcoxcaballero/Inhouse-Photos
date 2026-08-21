import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android background backup uses the selectable bounded upload pipeline', () {
    final worker = File('lib/domain/services/background_worker.service.dart').readAsStringSync();
    final uploader = File('lib/services/foreground_upload.service.dart').readAsStringSync();

    expect(worker, isNot(contains('useSequentialUpload: true')));
    expect(worker, contains('backup.speed'));
    expect(uploader, contains('_uploadWithPipeline'));
    expect(uploader, contains('speed.uploadWorkers'));
    expect(uploader, contains('speed.preparationWorkers'));
  });
}
