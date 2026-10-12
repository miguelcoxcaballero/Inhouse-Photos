import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:logging/logging.dart';

/// Android's bulk MediaStore query omits GPS. Read only the opened asset, with
/// the already granted media permission; never request the device's location.
class LocalLocationRepository {
  static const _channel = MethodChannel('com.inhousesoftware.photos/media_location');
  static final _log = Logger('LocalLocationRepository');

  const LocalLocationRepository();

  Future<ExifInfo?> read(LocalAsset asset) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }
    try {
      final coordinates = await _channel.invokeMapMethod<String, num>('read', {
        'id': asset.id,
        'isVideo': asset.isVideo,
      });
      if (coordinates == null) {
        return null;
      }
      final exif = ExifInfo(
        latitude: coordinates['latitude']?.toDouble(),
        longitude: coordinates['longitude']?.toDouble(),
      );
      return exif.hasCoordinates ? exif : null;
    } on PlatformException catch (error) {
      _log.warning('Could not read existing photo location', error.code);
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
