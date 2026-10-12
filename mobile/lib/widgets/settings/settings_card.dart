import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';

class SettingsCard extends StatelessWidget {
  const SettingsCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.settingRoute,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final PageRouteInfo settingRoute;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      minLeadingWidth: 28,
      horizontalTitleGap: 20,
      leading: Icon(icon, color: context.primaryColor, size: 26),
      title: Text(title, style: context.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text(
          subtitle,
          style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant),
        ),
      ),
      onTap: () => context.pushRoute(settingRoute),
    );
  }
}

/// A single rounded surface keeps related settings together while every row
/// retains its own tap target and accessibility label.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Material(
    color: context.colorScheme.surfaceContainer,
    borderRadius: BorderRadius.circular(24),
    clipBehavior: Clip.antiAlias,
    child: Column(mainAxisSize: MainAxisSize.min, children: children),
  );
}
