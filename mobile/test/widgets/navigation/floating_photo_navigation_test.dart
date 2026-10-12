import 'dart:ui' show SemanticsAction;

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/pages/common/tab_shell.page.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/tab.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/navigation/floating_photo_navigation.dart';

class _ReadOnly extends ReadOnlyModeNotifier {
  _ReadOnly(this.value);
  final bool value;
  @override
  bool build() => value;
}

class _NoHaptics extends HapticNotifier {
  _NoHaptics(super.ref);
  @override
  void selectionClick() {}
}

PageInfo _page(String name, String label) => PageInfo(
  name,
  builder: (_) => Scaffold(body: Center(child: Text(label))),
);

void main() {
  Future<({RootStackRouter router, ProviderContainer container})> openShell(
    WidgetTester tester, {
    bool readOnly = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          initial: true,
          page: PageInfo(TabShellRoute.name, builder: (_) => const TabShellPage()),
          children: [
            AutoRoute(page: _page(MainTimelineRoute.name, 'Photos body')),
            AutoRoute(page: _page(DriftSearchRoute.name, 'Legacy search body')),
            AutoRoute(page: _page(DriftAlbumsRoute.name, 'Albums body')),
            AutoRoute(page: _page(DriftLibraryRoute.name, 'Collections body')),
            AutoRoute(page: _page(DriftCreateRoute.name, 'Create body')),
          ],
        ),
        AutoRoute(page: _page(DriftSearchRoute.name, 'Search body')),
      ],
    );
    final container = ProviderContainer(
      overrides: [
        readonlyModeProvider.overrideWith(() => _ReadOnly(readOnly)),
        hapticFeedbackProvider.overrideWith((ref) => _NoHaptics(ref)),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router.config()),
      ),
    );
    await tester.pumpAndSettle();
    return (router: router, container: container);
  }

  testWidgets('collections/create tabs and standalone search preserve the active tab when returning', (tester) async {
    final semantics = tester.ensureSemantics();
    final (:router, :container) = await openShell(tester);
    expect(
      tester.getSemantics(find.bySemanticsLabel('collections')).getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
    );
    final photoTarget = tester.getSize(find.bySemanticsLabel('photos'));
    semantics.dispose();
    expect(tester.getSize(find.byTooltip('search')).height, 56);
    expect(photoTarget.height, greaterThanOrEqualTo(48));
    final photoLabel = tester.widget<Text>(find.text('photos'));
    final labelStyle = DefaultTextStyle.of(tester.element(find.text('photos'))).style.merge(photoLabel.style);
    final labelPainter = TextPainter(
      text: TextSpan(text: photoLabel.data, style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    // Icon + gap + horizontal padding add 50dp to the measured label. Measuring
    // avoids depending on the test font's wider glyphs versus the app font.
    expect(photoTarget.width, closeTo(labelPainter.width + 50, 0.1));
    labelPainter.dispose();
    await tester.tap(find.text('collections'));
    await tester.pumpAndSettle();
    expect(find.text('Collections body'), findsOneWidget);
    expect(container.read(tabProvider), TabEnum.library);

    await tester.tap(find.text('create'));
    await tester.pumpAndSettle();
    expect(find.text('Create body'), findsOneWidget);
    expect(container.read(tabProvider), TabEnum.create);

    await tester.tap(find.byTooltip('search'));
    await tester.pumpAndSettle();
    expect(find.text('Search body'), findsOneWidget);
    expect(find.byType(FloatingPhotoNavigation), findsNothing);
    await router.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('Create body'), findsOneWidget);
    expect(tester.widget<FloatingPhotoNavigation>(find.byType(FloatingPhotoNavigation)).selectedIndex, 2);
    expect(container.read(tabProvider), TabEnum.create);
    expect(tester.takeException(), isNull);
  });

  testWidgets('read-only mode disables collections, create and search', (tester) async {
    await openShell(tester, readOnly: true);
    await tester.tap(find.text('collections'));
    await tester.tap(find.text('create'));
    await tester.tap(find.byTooltip('search'));
    await tester.pumpAndSettle();
    expect(find.text('Photos body'), findsOneWidget);
    final navigation = tester.widget<FloatingPhotoNavigation>(find.byType(FloatingPhotoNavigation));
    expect(navigation.destinations.skip(1).every((destination) => !destination.enabled), isTrue);
    expect(navigation.onSearch, isNull);
  });

  testWidgets('selection hides the floating controls and restores them afterwards', (tester) async {
    await openShell(tester);
    EventStream.shared.emit(const MultiSelectToggleEvent(true));
    await tester.pumpAndSettle();
    expect(find.byType(FloatingPhotoNavigation), findsNothing);
    EventStream.shared.emit(const MultiSelectToggleEvent(false));
    await tester.pumpAndSettle();
    expect(find.byType(FloatingPhotoNavigation), findsOneWidget);
  });

  testWidgets('portrait island and landscape rail adapt without dropping Search', (tester) async {
    await openShell(tester);
    expect(find.byType(FloatingPhotoNavigation), findsOneWidget);
    tester.view.physicalSize = const Size(915, 412);
    await tester.pumpAndSettle();
    expect(find.byType(FloatingPhotoNavigation), findsNothing);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byTooltip('search'), findsOneWidget);
    EventStream.shared.emit(const MultiSelectToggleEvent(true));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsNothing);
    EventStream.shared.emit(const MultiSelectToggleEvent(false));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('small screen, long labels, large text and gesture insets do not overflow', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 700),
            padding: EdgeInsets.only(bottom: 34),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            extendBody: true,
            bottomNavigationBar: FloatingPhotoNavigation(
              destinations: const [
                NavigationDestination(icon: Icon(Icons.photo), label: 'Fotos'),
                NavigationDestination(icon: Icon(Icons.collections), label: 'Colecciones'),
                NavigationDestination(icon: Icon(Icons.add), label: 'Crear'),
              ],
              selectedIndex: 1,
              onDestinationSelected: (_) {},
              searchLabel: 'Buscar',
              onSearch: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final search = find.byTooltip('Buscar');
    expect(tester.getRect(search).bottom, lessThanOrEqualTo(666));
    expect(tester.getSize(search).height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });
}
