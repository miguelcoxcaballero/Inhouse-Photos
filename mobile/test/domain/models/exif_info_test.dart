import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';

import '../../unit/factories/local_asset_factory.dart';

void main() {
  group('photo coordinates', () {
    for (final point in [(0.0, 0.0), (0.0, 24.0), (51.0, 0.0), (-90.0, -180.0), (90.0, 180.0)]) {
      test('retains the real coordinate $point in local and remote metadata', () {
        final exif = ExifInfo(latitude: point.$1, longitude: point.$2);
        final local = LocalAssetFactory.create().copyWith(latitude: point.$1, longitude: point.$2);
        expect(exif.hasCoordinates, isTrue);
        expect(local.hasCoordinates, isTrue);
      });
    }

    for (final exif in [
      const ExifInfo(),
      const ExifInfo(latitude: 0),
      const ExifInfo(longitude: 0),
      const ExifInfo(latitude: double.nan, longitude: 0),
      const ExifInfo(latitude: 0, longitude: double.infinity),
      const ExifInfo(latitude: -91, longitude: 0),
      const ExifInfo(latitude: 0, longitude: 181),
    ]) {
      test('does not show missing or invalid coordinates ${exif.latitude}, ${exif.longitude}', () {
        expect(exif.hasCoordinates, isFalse);
      });
    }
  });
}
