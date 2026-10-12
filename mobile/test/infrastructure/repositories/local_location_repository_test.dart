import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/repositories/local_location.repository.dart';

import '../../unit/factories/local_asset_factory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.inhousesoftware.photos/media_location');
  const repository = LocalLocationRepository();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('reads only the opened photo and preserves exact zero coordinates', () async {
    final asset = LocalAssetFactory.create(id: '1234');
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'read');
      expect(call.arguments, {'id': asset.id, 'isVideo': false});
      return {'latitude': 0.0, 'longitude': 0.0};
    });

    final exif = await repository.read(asset);
    expect(exif?.latitude, 0);
    expect(exif?.longitude, 0);
    expect(exif?.hasCoordinates, isTrue);
  });

  test('does not invent GPS when metadata is absent or media-location permission is denied', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await repository.read(LocalAssetFactory.create()), isNull);
  });

  test('ignores incomplete and invalid native metadata', () async {
    for (final data in [
      {'latitude': 32.0},
      {'latitude': 91.0, 'longitude': 23.0},
      {'latitude': 32.0, 'longitude': double.nan},
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => data);
      expect(await repository.read(LocalAssetFactory.create()), isNull);
    }
  });

  test('unavailable local media does not prevent opening photo details', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => throw PlatformException(code: 'location_unavailable'));
    expect(await repository.read(LocalAssetFactory.create()), isNull);
  });

  test('uses the platform index on iOS without invoking Android methods', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    messenger.setMockMethodCallHandler(channel, (_) async => fail('Android location reader called on iOS'));
    expect(await repository.read(LocalAssetFactory.create()), isNull);
  });
}
