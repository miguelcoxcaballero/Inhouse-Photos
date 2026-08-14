import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/widgets/update/required_update_gate.dart';

void main() {
  group('compareInhouseVersions', () {
    test('detects newer, equal, and older semantic versions', () {
      expect(compareInhouseVersions('3.1.2', '3.1.1'), isPositive);
      expect(compareInhouseVersions('3.1.1', '3.1.1'), 0);
      expect(compareInhouseVersions('3.1.0', '3.1.1'), isNegative);
      expect(compareInhouseVersions('3.2', '3.2.0'), 0);
    });
  });

  group('InhouseUpdateManifest', () {
    test('accepts a required update from an approved GitHub host', () {
      final manifest = InhouseUpdateManifest.fromJson({
        'version': '3.1.2',
        'versionCode': 5061,
        'required': true,
        'apkUrl': 'https://raw.githubusercontent.com/miguelcoxcaballero/Inhouse-Photos/main/Inhouse-Photos.apk',
      });

      expect(manifest.version, '3.1.2');
      expect(manifest.versionCode, 5061);
      expect(manifest.required, isTrue);
    });

    test('rejects a download hosted outside the approved GitHub hosts', () {
      expect(
        () => InhouseUpdateManifest.fromJson({
          'version': '3.1.2',
          'versionCode': 5061,
          'required': true,
          'apkUrl': 'https://example.com/Inhouse-Photos.apk',
        }),
        throwsFormatException,
      );
    });

    test('rejects malformed versions and build numbers', () {
      expect(
        () => InhouseUpdateManifest.fromJson({
          'version': 'latest',
          'versionCode': 0,
          'apkUrl': 'https://github.com/miguelcoxcaballero/Inhouse-Photos',
        }),
        throwsFormatException,
      );
    });
  });

  test('repository update manifest matches the ARM64 app build', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final versionMatch = RegExp(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$', multiLine: true).firstMatch(pubspec);
    expect(versionMatch, isNotNull);

    final manifestJson = jsonDecode(File('../android-update.json').readAsStringSync()) as Map<String, dynamic>;
    final manifest = InhouseUpdateManifest.fromJson(manifestJson);
    final baseBuildNumber = int.parse(versionMatch!.group(2)!);

    expect(manifest.version, versionMatch.group(1));
    expect(manifest.versionCode, baseBuildNumber + 2000);
    expect(manifest.required, isTrue);
  });
}
