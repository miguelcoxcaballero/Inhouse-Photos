// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:immich_mobile/presentation/widgets/images/contact_sheet_prototype.dart';

/// Explicitly supplied MediaStore IDs avoid scanning a user's library during
/// a benchmark. Run on an already permission-granted installation in profile.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const idsArgument = String.fromEnvironment('CONTACT_SHEET_IDS');
  testWidgets('native contact sheet cold/warm timing', (tester) async {
    final ids = idsArgument.split(',').where((id) => id.isNotEmpty).take(96).toList();
    await tester.runAsync(() async {
      for (final pixels in [32, 64, 128]) {
        for (var pass = 0; pass < 4; pass++) {
          final watch = Stopwatch()..start();
          final result = await ContactSheetPrototype.render(ids, pixels: pixels, columns: 12);
          watch.stop();
          print(
            'CONTACT_SHEET pixels=$pixels pass=$pass completed=${result.completed.length}/${ids.length} '
            'native_us=${result.nativeMicros} total_us=${watch.elapsedMicroseconds} '
            'texture_bytes=${result.image.width * result.image.height * 4}',
          );
          result.image.dispose();
          expect(result.completed, isNotEmpty);
        }
      }
    });
  }, skip: idsArgument.isEmpty);
}
