import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/map.model.dart';
import 'package:immich_mobile/domain/services/map.service.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:immich_mobile/presentation/widgets/map/map.state.dart';
import 'package:immich_mobile/providers/infrastructure/map.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:mocktail/mocktail.dart';

import '../../service.mocks.dart';
import '../../unit/factories/user_factory.dart';

class _MapFactory extends Mock implements MapFactory {}

void main() {
  test('a map opened from photo details does not replace the original map viewport or marker service', () async {
    final userService = MockUserService();
    final user = UserFactory.createDto();
    when(() => userService.tryGetMyUser()).thenReturn(user);
    when(() => userService.watchMyUser()).thenAnswer((_) => const Stream.empty());
    final origin = LatLngBounds(southwest: const LatLng(40, -5), northeast: const LatLng(41, -4));
    final focused = LatLngBounds(southwest: const LatLng(0, 0), northeast: const LatLng(1, 1));
    final factory = _MapFactory();
    registerFallbackValue(TimelineMapOptions(bounds: origin));
    when(() => factory.remote(any(), any())).thenAnswer((call) {
      final options = call.positionalArguments[1] as TimelineMapOptions;
      return MapService((markerSource: (_) async => [Marker(location: options.bounds.northeast, assetId: 'photo')]));
    });

    final root = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(const AppConfig()),
        currentUserProvider.overrideWith((_) => CurrentUserProvider(userService)),
        mapFactoryProvider.overrideWithValue(factory),
      ],
    );
    addTearDown(root.dispose);
    final originalRoute = ProviderContainer(
      parent: root,
      overrides: [mapStateProvider.overrideWith(MapStateNotifier.new)],
    );
    addTearDown(originalRoute.dispose);
    originalRoute.read(mapStateProvider.notifier).setBounds(origin);
    final originalService = originalRoute.read(mapServiceProvider);

    // The second route is opened while the first route's viewer is alive.
    final detailsRoute = ProviderContainer(
      parent: originalRoute,
      overrides: [mapStateProvider.overrideWith(MapStateNotifier.new)],
    );
    detailsRoute.read(mapStateProvider.notifier).setBounds(focused);
    final focusedService = detailsRoute.read(mapServiceProvider);

    expect(focusedService, isNot(same(originalService)));
    expect((await focusedService.getMarkers(null)).single.location, focused.northeast);
    expect(originalRoute.read(mapStateProvider).bounds, origin);
    expect(originalRoute.read(mapServiceProvider), same(originalService));
    expect((await originalService.getMarkers(null)).single.location, origin.northeast);

    detailsRoute.dispose();
    expect(originalRoute.read(mapServiceProvider), same(originalService));
    expect(originalRoute.read(mapStateProvider).bounds, origin);
  });
}
