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

  group('download progress', () {
    test('calculates and clamps determinate progress', () {
      expect(calculateInhouseDownloadProgress(downloadedBytes: 25, totalBytes: 100), 0.25);
      expect(calculateInhouseDownloadProgress(downloadedBytes: 120, totalBytes: 100), 1.0);
    });

    test('uses indeterminate progress without a valid content length', () {
      expect(calculateInhouseDownloadProgress(downloadedBytes: 25, totalBytes: null), isNull);
      expect(calculateInhouseDownloadProgress(downloadedBytes: 25, totalBytes: 0), isNull);
    });

    test('formats downloaded bytes in megabytes', () {
      expect(formatInhouseDownloadBytes(1572864), '1.5 MB');
    });
  });

  test('builds a SideStore install link for the exact IPA release', () {
    final ipa = Uri.parse(
      'https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/v3.1.35-inhouse-ios.1/Inhouse-Photos.ipa',
    );

    final uri = buildSideStoreInstallUri(ipa);

    expect(uri.scheme, 'sidestore');
    expect(uri.host, 'install');
    expect(uri.queryParameters['url'], ipa.toString());
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

    test('accepts an iOS update from an approved GitHub release', () {
      final manifest = InhouseUpdateManifest.fromJson({
        'version': '3.1.24',
        'versionCode': 3083,
        'required': true,
        'ipaUrl':
            'https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/v3.1.24-inhouse-ios.1/Inhouse-Photos.ipa',
      }, assetKey: 'ipaUrl');

      expect(manifest.version, '3.1.24');
      expect(manifest.versionCode, 3083);
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
