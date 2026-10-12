import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:immich_mobile/widgets/map/map_thumbnail.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:url_launcher/url_launcher.dart';

class ExifMap extends StatelessWidget {
  final ExifInfo exifInfo;
  // TODO: Pass in a BaseAsset instead of the ID and thumbhash when removing old timeline
  // This is currently structured this way because of the old timeline implementation
  // reusing this component
  final String? markerId;
  final String? markerAssetThumbhash;
  final MapCreatedCallback? onMapCreated;
  final VoidCallback? onTap;
  final double height;

  const ExifMap({
    super.key,
    required this.exifInfo,
    this.markerAssetThumbhash,
    this.markerId = 'marker',
    this.onMapCreated,
    this.onTap,
    this.height = 132,
  });

  @override
  Widget build(BuildContext context) {
    final hasCoordinates = exifInfo.hasCoordinates;
    if (!hasCoordinates) {
      return const SizedBox.shrink();
    }
    Future<Uri?> createCoordinatesUri() async {
      if (!hasCoordinates) {
        return null;
      }

      final double latitude = exifInfo.latitude!;
      final double longitude = exifInfo.longitude!;

      const zoomLevel = 16;

      if (Platform.isAndroid) {
        Uri uri = Uri(
          scheme: 'geo',
          host: '$latitude,$longitude',
          queryParameters: {'z': '$zoomLevel', 'q': '$latitude,$longitude'},
        );
        if (await canLaunchUrl(uri)) {
          return uri;
        }
      } else if (Platform.isIOS) {
        var params = {'ll': '$latitude,$longitude', 'q': '$latitude,$longitude', 'z': '$zoomLevel'};
        Uri uri = Uri.https('maps.apple.com', '/', params);
        if (await canLaunchUrl(uri)) {
          return uri;
        }
      }

      return Uri(
        scheme: 'https',
        host: 'openstreetmap.org',
        queryParameters: {'mlat': '$latitude', 'mlon': '$longitude'},
        fragment: 'map=$zoomLevel/$latitude/$longitude',
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return MapThumbnail(
          key: ValueKey((exifInfo.latitude, exifInfo.longitude)),
          centre: LatLng(exifInfo.latitude!, exifInfo.longitude!),
          height: height,
          width: constraints.maxWidth,
          zoom: 12.0,
          assetMarkerRemoteId: markerId,
          assetThumbhash: markerAssetThumbhash,
          showMarkerPin: markerId == null || markerAssetThumbhash == null,
          onTap: (tapPosition, latLong) async {
            if (onTap != null) {
              onTap!();
              return;
            }
            Uri? uri = await createCoordinatesUri();

            if (uri == null) {
              return;
            }

            dPrint(() => 'Opening Map Uri: $uri');
            unawaited(launchUrl(uri));
          },
          onCreated: onMapCreated,
        );
      },
    );
  }
}
