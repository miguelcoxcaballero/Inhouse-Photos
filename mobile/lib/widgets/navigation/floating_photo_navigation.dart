import 'package:flutter/material.dart';

/// A compact navigation island with Search kept outside the tab capsule.
///
/// The surrounding scaffold extends its body underneath this widget. SafeArea
/// still reserves the system gesture area and the body receives the complete
/// navigation inset, so its last item can scroll clear of the controls.
class FloatingPhotoNavigation extends StatelessWidget {
  const FloatingPhotoNavigation({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.searchLabel,
    this.onSearch,
  });

  final List<NavigationDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final String searchLabel;
  final VoidCallback? onSearch;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final height = MediaQuery.textScalerOf(context).scale(14) > 20 ? 76.0 : 56.0;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Align(
        heightFactor: 1,
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Row(
            children: [
              Expanded(
                child: Material(
                  color: colors.surfaceContainer,
                  elevation: 3,
                  shadowColor: colors.shadow.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(height / 2),
                  clipBehavior: Clip.antiAlias,
                  child: SizedBox(
                    height: height,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final compact = constraints.maxWidth < 270 || height > 56;
                          return Row(
                            children: [
                              for (var index = 0; index < destinations.length; index++)
                                if (index == selectedIndex && !compact)
                                  IntrinsicWidth(
                                    child: _Destination(
                                      destination: destinations[index],
                                      selected: true,
                                      onTap: () => onDestinationSelected(index),
                                    ),
                                  )
                                else
                                  Expanded(
                                    flex: destinations[index].label.runes.length + (index == selectedIndex ? 4 : 0),
                                    child: _Destination(
                                      destination: destinations[index],
                                      selected: index == selectedIndex,
                                      onTap: () => onDestinationSelected(index),
                                    ),
                                  ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox.square(
                dimension: height,
                child: IconButton.filledTonal(
                  onPressed: onSearch,
                  tooltip: searchLabel,
                  style: IconButton.styleFrom(
                    backgroundColor: colors.surfaceContainer,
                    foregroundColor: colors.onSurface,
                    shadowColor: colors.shadow.withValues(alpha: 0.25),
                    elevation: 3,
                  ),
                  icon: const Icon(Icons.search_rounded, size: 26),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Destination extends StatelessWidget {
  const _Destination({required this.destination, required this.selected, required this.onTap});

  final NavigationDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = !destination.enabled
        ? colors.onSurface.withValues(alpha: 0.38)
        : selected
        ? colors.onSecondaryContainer
        : colors.onSurfaceVariant;
    return Semantics(
      selected: selected,
      button: true,
      enabled: destination.enabled,
      label: destination.label,
      onTap: destination.enabled ? onTap : null,
      excludeSemantics: true,
      child: Tooltip(
        message: destination.label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(28),
            onTap: destination.enabled ? onTap : null,
            // Keep the complete 56dp tab as the touch target; only its painted
            // selected pill is inset to match the compact floating navigation.
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: selected ? colors.secondaryContainer : Colors.transparent,
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: selected ? 12 : 8),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (selected) ...[
                          IconTheme(
                            data: IconThemeData(size: 20, color: foreground),
                            child: destination.selectedIcon ?? destination.icon,
                          ),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(
                            destination.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: foreground, fontSize: 14, fontWeight: FontWeight.w500),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
