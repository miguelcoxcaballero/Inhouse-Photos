import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/extensions/translate_extensions.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/sheet_tile.widget.dart';
import 'package:immich_mobile/providers/infrastructure/action.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/asset_viewer/detail_panel/exif_map.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

class LocationDetails extends ConsumerWidget {
  final BaseAsset asset;
  final ExifInfo? exifInfo;

  const LocationDetails({super.key, required this.asset, this.exifInfo});

  String? _getLocationName(ExifInfo? exifInfo) {
    if (exifInfo == null) {
      return null;
    }

    final parts = [
      exifInfo.city,
      exifInfo.state,
      exifInfo.country,
    ].whereType<String>().where((name) => name.trim().isNotEmpty).toSet();
    return parts.isEmpty ? null : parts.join(', ');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasCoordinates = exifInfo?.hasCoordinates ?? false;
    final canEdit = asset is RemoteAsset;

    if (!hasCoordinates && !canEdit) {
      return const SizedBox.shrink();
    }

    void editLocation() => ref.read(actionProvider.notifier).editLocation(ActionSource.viewer, context);

    void openMap() {
      if (hasCoordinates) {
        context.pushRoute(DriftMapRoute(initialLocation: LatLng(exifInfo!.latitude!, exifInfo!.longitude!)));
      }
    }

    final locationName = _getLocationName(exifInfo);
    final coordinates = "${exifInfo?.latitude?.toStringAsFixed(4)}, ${exifInfo?.longitude?.toStringAsFixed(4)}";

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SheetTile(
            title: 'location'.t(context: context),
            titleStyle: context.textTheme.labelLarge?.copyWith(color: context.colorScheme.onSurfaceSecondary),
            leading: const Icon(Icons.location_on_outlined, size: 20),
            trailing: canEdit ? const Icon(Icons.edit_outlined, size: 20) : null,
            onTap: canEdit ? editLocation : openMap,
          ),
          if (hasCoordinates)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.isMobile ? 16.0 : 56.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExifMap(
                    exifInfo: exifInfo!,
                    markerId: asset.remoteId,
                    markerAssetThumbhash: asset is RemoteAsset ? (asset as RemoteAsset).thumbHash : null,
                    onTap: openMap,
                  ),
                  const SizedBox(height: 4),
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: openMap,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (locationName != null) Text(locationName, style: context.textTheme.labelLarge),
                                Text(
                                  coordinates,
                                  style: context.textTheme.bodySmall?.copyWith(
                                    color: context.colorScheme.onSurfaceSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.open_in_full_rounded, size: 18, color: context.primaryColor),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (!hasCoordinates && canEdit)
            SheetTile(
              title: "add_a_location".t(context: context),
              titleStyle: context.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: context.primaryColor,
              ),
              leading: const Icon(Icons.location_off),
              onTap: editLocation,
            ),
        ],
      ),
    );
  }
}
