import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/presentation/widgets/map/map.widget.dart';
import 'package:immich_mobile/presentation/widgets/map/map.state.dart';
import 'package:immich_mobile/presentation/widgets/map/map_settings_sheet.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

@RoutePage()
class DriftMapPage extends StatelessWidget {
  final LatLng? initialLocation;

  const DriftMapPage({super.key, this.initialLocation});

  void onSettingsPressed(BuildContext context) {
    showModalBottomSheet(
      elevation: 0.0,
      showDragHandle: true,
      isScrollControlled: true,
      context: context,
      builder: (_) => UncontrolledProviderScope(
        container: ProviderScope.containerOf(context),
        child: const DriftMapSettingsSheet(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // A photo can open this route from another map's viewer. Each route owns
    // its viewport so navigating the new map cannot dispose that viewer's
    // original timeline service behind it.
    return ProviderScope(
      overrides: [mapStateProvider.overrideWith(MapStateNotifier.new)],
      child: Builder(
        builder: (context) => Scaffold(
          extendBodyBehindAppBar: true,
          body: Stack(
            children: [
              DriftMap(initialLocation: initialLocation),
              Positioned(
                left: 20,
                top: 70,
                child: IconButton.filled(
                  color: context.colorScheme.onPrimaryContainer,
                  onPressed: () => ContextHelper(context).pop(),
                  icon: const Icon(Icons.arrow_back_ios_new_rounded),
                  style: IconButton.styleFrom(
                    padding: const EdgeInsets.all(8),
                    backgroundColor: context.colorScheme.primaryContainer,
                    shadowColor: Colors.black26,
                    elevation: 4,
                  ),
                ),
              ),
              Positioned(
                right: 20,
                top: 70,
                child: IconButton.filled(
                  color: context.colorScheme.onPrimaryContainer,
                  onPressed: () => onSettingsPressed(context),
                  icon: const Icon(Icons.more_vert_rounded),
                  style: IconButton.styleFrom(
                    padding: const EdgeInsets.all(8),
                    backgroundColor: context.colorScheme.primaryContainer,
                    shadowColor: Colors.black26,
                    elevation: 4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
