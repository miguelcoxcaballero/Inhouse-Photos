import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/presentation/pages/edit/media_edit.page.dart';
import 'package:immich_mobile/presentation/pages/edit/media_edit_options.dart';
import 'package:immich_mobile/presentation/pages/edit/media_editor.service.dart';

import '../../../fixtures/asset.stub.dart';
import '../../../widget_tester_extensions.dart';

class _EditorService extends MediaEditorService {
  final File photo;
  final saves = <MediaEditOptions>[];
  Completer<void>? pendingSave;
  int cancellations = 0;
  bool disposed = false;

  _EditorService(this.photo);

  @override
  Future<File> acquire(BaseAsset asset, void Function(double?) onProgress) async => photo;

  @override
  Future<Map<Object?, Object?>> inspect(File source, {required bool isVideo}) async => {
    'previewPath': photo.path,
    'width': 320,
    'height': 200,
  };

  @override
  Future<void> saveCopy(
    File source,
    BaseAsset asset,
    MediaEditOptions options,
    void Function(double) onProgress, {
    ExifInfo? metadata,
  }) async {
    saves.add(options);
    onProgress(0.25);
    pendingSave = Completer<void>();
    await pendingSave!.future;
  }

  @override
  Future<void> cancel() async {
    cancellations++;
    pendingSave!.completeError(StateError('Export cancelled'));
  }

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File photo;

  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : true,
    );
    EasyLocalization.logger.enableBuildModes = [];
    await EasyLocalization.ensureInitialized();

    directory = await Directory.systemTemp.createTemp('inhouse-editor-test-');
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 320, 200), Paint()..color = Colors.orange);
    canvas.drawRect(const Rect.fromLTWH(160, 0, 160, 200), Paint()..color = Colors.blue);
    final picture = recorder.endRecording();
    final image = await picture.toImage(320, 200);
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    photo = await File('${directory.path}/original.png').writeAsBytes(png.buffer.asUint8List());
    image.dispose();
    picture.dispose();
  });

  tearDownAll(() => directory.delete(recursive: true));

  Future<void> openEditor(
    WidgetTester tester,
    _EditorService service, {
    Size size = const Size(412, 915),
    ValueChanged<bool?>? onResult,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpConsumerWidget(
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final saved = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => MediaEditPage(asset: LocalAssetStub.image1, service: service),
                ),
              );
              onResult?.call(saved);
            },
            child: const Text('Open editor'),
          ),
        ),
      ),
    );
    // Preload outside the fake clock before CropImage starts an image stream.
    await tester.runAsync(() => precacheImage(FileImage(photo), tester.element(find.byType(Scaffold))));
    await tester.tap(find.text('Open editor'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Preparing original…'), findsNothing);
  }

  Future<void> adjustBrightness(WidgetTester tester) async {
    await tester.tap(find.text('Adjust'));
    await tester.pumpAndSettle();
    final slider = find.byType(Slider).first;
    await tester.drag(slider, const Offset(70, 0));
    await tester.pumpAndSettle();
  }

  testWidgets('photo adjustment saves one copy, then returns success to refresh the library', (tester) async {
    final service = _EditorService(photo);
    bool? saved;
    await openEditor(tester, service, onResult: (result) => saved = result);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    await adjustBrightness(tester);

    // A second tap before the next rendered frame must not start another export.
    await tester.tap(find.text('Save copy'));
    await tester.tap(find.text('Save copy'));
    await tester.pump();
    expect(service.saves, hasLength(1));
    expect(service.saves.single.brightness, greaterThan(0));
    expect(saved, isNull);

    service.pendingSave!.complete();
    await tester.pumpAndSettle();
    expect(saved, isTrue);
    expect(service.disposed, isTrue);
    expect(find.byType(MediaEditPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelled export keeps edits open and never reports a saved copy', (tester) async {
    final service = _EditorService(photo);
    bool? saved;
    await openEditor(tester, service, onResult: (result) => saved = result);
    await adjustBrightness(tester);
    await tester.tap(find.text('Save copy'));
    await tester.pump();
    await tester.tap(find.text('cancel'.tr()));
    await tester.pumpAndSettle();

    expect(service.cancellations, 1);
    expect(saved, isNull);
    expect(find.byType(MediaEditPage), findsOneWidget);
    expect(find.textContaining('Copy saved in'), findsNothing);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('discard confirmation can be cancelled before leaving without saving', (tester) async {
    final service = _EditorService(photo);
    await openEditor(tester, service);
    await tester.tap(find.byTooltip('Rotate right'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('cancel'.tr()));
    await tester.pumpAndSettle();
    expect(find.byType(MediaEditPage), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('confirm'.tr()));
    await tester.pumpAndSettle();
    expect(find.byType(MediaEditPage), findsNothing);
    expect(service.saves, isEmpty);
    expect(service.disposed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('photo controls remain usable on a compact landscape screen', (tester) async {
    final service = _EditorService(photo);
    await openEditor(tester, service, size: const Size(568, 320));
    await adjustBrightness(tester);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byType(Slider).last);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('Save copy')).bottom, lessThanOrEqualTo(320));
    expect(tester.getRect(find.byType(Slider).last).bottom, lessThanOrEqualTo(320));
    await tester.drag(find.byType(Slider).last, const Offset(-50, 0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
