import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';

void main() {
  test('light and dark runtime SVG logos use the orange brand mark only', () {
    for (final path in ['assets/inhouse-photos-logo.svg', 'assets/inhouse-photos-logo-light.svg']) {
      final svg = File(path).readAsStringSync();
      final colors = RegExp(r'#[0-9A-Fa-f]{6}').allMatches(svg).map((match) => match.group(0)!.toUpperCase()).toSet();
      expect(colors, {'#D97736'}, reason: path);
    }
  });

  test('Android 12 uses the dedicated 1152px safe-area splash asset', () {
    final bytes = File('assets/inhouse-photos-splash-android12.png').readAsBytesSync();
    final header = ByteData.sublistView(bytes);
    expect(header.getUint32(16), 1152);
    expect(header.getUint32(20), 1152);

    final pubspec = File('pubspec.yaml').readAsStringSync();
    final generator = File('scripts/generate_inhouse_brand_assets.ps1').readAsStringSync();
    expect(RegExp('inhouse-photos-splash-android12.png').allMatches(pubspec), hasLength(2));
    expect(generator, contains("'assets\\inhouse-photos-splash-android12.png' 1152 0.43"));
  });

  test('startup handoff and first timeline load do not render a second logo loader', () {
    final splash = File('lib/pages/common/splash_screen.page.dart').readAsStringSync();
    final timeline = File('lib/presentation/pages/dev/main_timeline.page.dart').readAsStringSync();
    final login = File('lib/widgets/forms/login/login_form.dart').readAsStringSync();

    expect(splash, contains('Scaffold(body: SizedBox.expand())'));
    expect(timeline, contains('loadingWidget: const SizedBox.expand()'));
    expect(login, isNot(contains('logoAnimationController')));
  });

  test('login title scales the complete Inhouse Photos name into the form', () {
    final login = File('lib/widgets/forms/login/login_form.dart').readAsStringSync();
    final title = File('lib/widgets/common/immich_title_text.dart').readAsStringSync();

    expect(title, contains("'inhouse photos'"));
    expect(login, contains('FittedBox(fit: BoxFit.scaleDown, child: ImmichTitleText())'));
  });

  test('backup quality labels are bundled instead of exposing translation keys', () {
    for (final locale in ['en', 'es']) {
      final translations = CodegenLoader.mapLocales[locale]!;
      expect(translations['backup_quality'], isNot('backup_quality'), reason: locale);
      expect(translations['backup_quality_storage_saver'], isNot('backup_quality_storage_saver'), reason: locale);
      expect(
        translations['backup_quality_estimated_savings'],
        isNot('backup_quality_estimated_savings'),
        reason: locale,
      );
    }
    expect(File('lib/main.dart').readAsStringSync(), contains('useFallbackTranslations: true'));
  });
}
