import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/common/immich_sliver_app_bar.dart';

/// Entry points to the creation and sharing tools that are available in Inhouse.
@RoutePage()
class DriftCreatePage extends StatelessWidget {
  const DriftCreatePage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return CustomScrollView(
      slivers: [
        const ImmichSliverAppBar(snap: false),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          sliver: SliverToBoxAdapter(child: Text('create'.tr(), style: Theme.of(context).textTheme.headlineLarge)),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList.list(
            children: [
              _CreateTile(
                icon: Icons.photo_album_outlined,
                title: 'create_album'.tr(),
                color: colors.primaryContainer,
                onTap: () => context.router.root.push(const DriftCreateAlbumRoute()),
              ),
              const SizedBox(height: 12),
              _CreateTile(
                icon: Icons.link_rounded,
                title: 'shared_links'.tr(),
                color: colors.surfaceContainer,
                onTap: () => context.router.root.push(const SharedLinkRoute()),
              ),
            ],
          ),
        ),
        SliverPadding(padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 24)),
      ],
    );
  }
}

class _CreateTile extends StatelessWidget {
  const _CreateTile({required this.icon, required this.title, required this.color, required this.onTap});

  final IconData icon;
  final String title;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            children: [
              Icon(icon, size: 32, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 20),
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}
