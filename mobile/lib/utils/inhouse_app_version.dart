import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:package_info_plus/package_info_plus.dart';

typedef _NativePatchNumber = ffi.UintPtr Function();
typedef _DartPatchNumber = int Function();

class InhouseAppVersion {
  const InhouseAppVersion({required this.version, required this.buildNumber, required this.patchNumber});

  final String version;
  final String buildNumber;
  final int patchNumber;

  String get displayVersion => patchNumber > 0 ? '$version · update $patchNumber' : version;

  String get detailedVersion => '$displayVersion build.$buildNumber';

  static Future<InhouseAppVersion> read() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final patchNumber = await Isolate.run(() {
      try {
        return ffi.DynamicLibrary.process().lookupFunction<_NativePatchNumber, _DartPatchNumber>(
          'shorebird_current_boot_patch_number',
        )();
      } catch (_) {
        return 0;
      }
    });
    return InhouseAppVersion(
      version: packageInfo.version,
      buildNumber: packageInfo.buildNumber,
      patchNumber: patchNumber,
    );
  }
}
