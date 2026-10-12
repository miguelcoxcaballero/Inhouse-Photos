import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/presentation/pages/search/paginated_search.provider.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/memory.provider.dart';
import 'package:immich_mobile/providers/infrastructure/people.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/search/search_input_focus.provider.dart';
import 'package:immich_mobile/providers/tab.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/navigation/floating_photo_navigation.dart';

@RoutePage()
class TabShellPage extends ConsumerStatefulWidget {
  const TabShellPage({super.key});

  @override
  ConsumerState<TabShellPage> createState() => _TabShellPageState();
}

class _TabShellPageState extends ConsumerState<TabShellPage> {
  bool _selectionEnabled = false;
  StreamSubscription<MultiSelectToggleEvent>? _selectionSubscription;

  @override
  void initState() {
    super.initState();
    _selectionSubscription = EventStream.shared.listen<MultiSelectToggleEvent>((event) {
      if (mounted) {
        setState(() => _selectionEnabled = event.isEnabled);
      }
    });
  }

  @override
  void dispose() {
    _selectionSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isScreenLandscape = context.orientation == Orientation.landscape;
    final isReadonlyModeEnabled = ref.watch(readonlyModeProvider);

    final navigationDestinations = [
      NavigationDestination(
        label: 'photos'.tr(),
        icon: const Icon(Icons.photo_outlined),
        selectedIcon: const Icon(Icons.photo),
      ),
      NavigationDestination(
        label: 'collections'.tr(),
        icon: const Icon(Icons.collections_bookmark_outlined),
        selectedIcon: const Icon(Icons.collections_bookmark),
        enabled: !isReadonlyModeEnabled,
      ),
      NavigationDestination(
        label: 'create'.tr(),
        icon: const Icon(Icons.add_circle_outline_rounded),
        selectedIcon: const Icon(Icons.add_circle_rounded),
        enabled: !isReadonlyModeEnabled,
      ),
    ];

    Widget navigationRail(TabsRouter tabsRouter) {
      return NavigationRail(
        destinations: navigationDestinations
            .map(
              (e) => NavigationRailDestination(
                icon: e.icon,
                label: Text(e.label),
                selectedIcon: e.selectedIcon,
                disabled: !e.enabled,
              ),
            )
            .toList(),
        onDestinationSelected: (index) => _onNavigationSelected(tabsRouter, _visibleTabIndexes[index], ref),
        selectedIndex: _visibleIndex(tabsRouter.activeIndex),
        trailing: IconButton(
          tooltip: 'search'.tr(),
          onPressed: isReadonlyModeEnabled ? null : () => _openSearch(context, ref),
          icon: const Icon(Icons.search_rounded),
        ),
        labelType: NavigationRailLabelType.all,
        groupAlignment: 0.0,
      );
    }

    return AutoTabsRouter(
      // Keep the legacy indexes for existing links and append the new Create tab.
      routes: const [
        MainTimelineRoute(),
        DriftSearchRoute(),
        DriftAlbumsRoute(),
        DriftLibraryRoute(),
        DriftCreateRoute(),
      ],
      duration: const Duration(milliseconds: 600),
      transitionBuilder: (context, child, animation) => FadeTransition(opacity: animation, child: child),
      builder: (context, child) {
        final tabsRouter = AutoTabsRouter.of(context);
        return PopScope(
          canPop: tabsRouter.activeIndex == 0,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              _onNavigationSelected(tabsRouter, kPhotoTabIndex, ref);
            }
          },
          child: Scaffold(
            extendBody: !isScreenLandscape,
            resizeToAvoidBottomInset: false,
            body: isScreenLandscape && !_selectionEnabled
                ? Row(
                    children: [
                      navigationRail(tabsRouter),
                      const VerticalDivider(),
                      Expanded(child: child),
                    ],
                  )
                : child,
            bottomNavigationBar: _BottomNavigationBar(tabsRouter: tabsRouter, destinations: navigationDestinations),
          ),
        );
      },
    );
  }
}

const _visibleTabIndexes = [kPhotoTabIndex, kLibraryTabIndex, 4];

int _visibleIndex(int tabIndex) => switch (tabIndex) {
  kLibraryTabIndex || kAlbumTabIndex => 1,
  4 => 2,
  _ => 0,
};

void _openSearch(BuildContext context, WidgetRef ref) {
  ref.read(searchPreFilterProvider.notifier).clear();
  ref.read(hapticFeedbackProvider.notifier).selectionClick();
  unawaited(context.router.root.push(const DriftSearchRoute()));
}

void _onNavigationSelected(TabsRouter router, int index, WidgetRef ref) {
  // On Photos page menu tapped
  if (router.activeIndex == kPhotoTabIndex && index == kPhotoTabIndex) {
    EventStream.shared.emit(const ScrollToTopEvent());
  }

  if (index == kPhotoTabIndex) {
    ref.invalidate(driftMemoryFutureProvider);
  }

  if (router.activeIndex != kSearchTabIndex && index == kSearchTabIndex) {
    ref.read(searchPreFilterProvider.notifier).clear();
  }

  // On Search page tapped
  if (router.activeIndex == kSearchTabIndex && index == kSearchTabIndex) {
    ref.read(searchInputFocusProvider).requestFocus();
  }

  // Album page
  if (index == kAlbumTabIndex) {
    ref.read(remoteAlbumProvider.notifier).refresh();
  }

  // Library page
  if (index == kLibraryTabIndex) {
    ref.invalidate(localAlbumProvider);
    ref.invalidate(driftGetAllPeopleProvider);
  }

  ref.read(hapticFeedbackProvider.notifier).selectionClick();
  router.setActiveIndex(index);
  ref.read(tabProvider.notifier).state = TabEnum.values[index];
}

class _BottomNavigationBar extends ConsumerStatefulWidget {
  const _BottomNavigationBar({required this.tabsRouter, required this.destinations});

  final List<NavigationDestination> destinations;
  final TabsRouter tabsRouter;

  @override
  ConsumerState createState() => _BottomNavigationBarState();
}

class _BottomNavigationBarState extends ConsumerState<_BottomNavigationBar> {
  bool hideNavigationBar = false;
  StreamSubscription? _eventSubscription;

  @override
  void initState() {
    super.initState();
    _eventSubscription = EventStream.shared.listen<MultiSelectToggleEvent>(_onEvent);
  }

  void _onEvent(MultiSelectToggleEvent event) {
    setState(() {
      hideNavigationBar = event.isEnabled;
    });
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isScreenLandscape = context.orientation == Orientation.landscape;

    if (isScreenLandscape || hideNavigationBar) {
      return const SizedBox.shrink();
    }

    // Legacy deep links can still enter the nested Search route. Search is a
    // focused destination and does not share the floating tab controls.
    if (widget.tabsRouter.activeIndex == kSearchTabIndex) {
      return const SizedBox.shrink();
    }

    return FloatingPhotoNavigation(
      selectedIndex: _visibleIndex(widget.tabsRouter.activeIndex),
      onDestinationSelected: (index) => _onNavigationSelected(widget.tabsRouter, _visibleTabIndexes[index], ref),
      destinations: widget.destinations,
      searchLabel: 'search'.tr(),
      onSearch: ref.watch(readonlyModeProvider) ? null : () => _openSearch(context, ref),
    );
  }
}
