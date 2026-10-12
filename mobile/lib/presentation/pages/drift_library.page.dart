import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/translate_extensions.dart';
import 'package:immich_mobile/presentation/widgets/images/local_album_thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/people/collection_people_row.widget.dart';
import 'package:immich_mobile/presentation/widgets/people/partner_user_avatar.widget.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/user.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/common/immich_sliver_app_bar.dart';
import 'package:immich_mobile/widgets/map/map_thumbnail.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

@RoutePage()
class DriftLibraryPage extends ConsumerWidget {
  const DriftLibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const Scaffold(
      body: CustomScrollView(
        slivers: [
          ImmichSliverAppBar(snap: false, floating: false, pinned: true, showUploadButton: false),
          SliverToBoxAdapter(child: _PlacesCollection()),
          SliverToBoxAdapter(child: _PeopleCollection()),
          SliverToBoxAdapter(child: _CollectionShortcuts()),
          SliverToBoxAdapter(child: _DeviceCollection()),
          SliverToBoxAdapter(child: _SharingCollection()),
          SliverToBoxAdapter(child: SizedBox(height: 120)),
        ],
      ),
    );
  }
}

// Use a real photo's coordinates when available. A world overview is preferable
// to showing an unrelated place when the library has no geotagged photos yet.
final _collectionMapCenterProvider = FutureProvider.autoDispose<LatLng?>((ref) async {
  final places = await ref.watch(placesProvider.future);
  if (places.isEmpty) {
    return null;
  }
  final exif = await ref.watch(remoteAssetRepositoryProvider).getExif(places.first.$2);
  if (exif == null || !exif.hasCoordinates) {
    return null;
  }
  return LatLng(exif.latitude!, exif.longitude!);
});

class _CollectionHeading extends StatelessWidget {
  const _CollectionHeading({required this.title, this.onViewAll});

  final String title;
  final VoidCallback? onViewAll;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 24, right: 16, top: 16, bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          ),
          if (onViewAll != null)
            TextButton(
              onPressed: onViewAll,
              child: Text('view_all'.t(context: context)),
            ),
        ],
      ),
    );
  }
}

class _PlacesCollection extends ConsumerWidget {
  const _PlacesCollection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final places = ref.watch(placesProvider).valueOrNull ?? const <(String, String)>[];
    final centre = ref.watch(_collectionMapCenterProvider).valueOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CollectionHeading(
          title: 'places'.t(context: context),
          onViewAll: () => context.pushRoute(DriftPlaceRoute(currentLocation: centre)),
        ),
        SizedBox(
          height: 158,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            scrollDirection: Axis.horizontal,
            itemCount: places.length.clamp(0, 10) + 1,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, index) {
              if (index == 0) {
                return Semantics(
                  button: true,
                  label: 'open_in_map_view'.t(context: context),
                  child: Material(
                    clipBehavior: Clip.antiAlias,
                    borderRadius: BorderRadius.circular(24),
                    color: context.colorScheme.surfaceContainerLow,
                    child: InkWell(
                      onTap: () => context.pushRoute(DriftMapRoute(initialLocation: centre)),
                      child: SizedBox(
                        width: 216,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            IgnorePointer(
                              child: MapThumbnail(
                                key: ValueKey(centre),
                                width: 216,
                                height: 158,
                                centre: centre ?? const LatLng(20, 0),
                                zoom: centre == null ? 1 : 8,
                                showAttribution: true,
                                themeMode: context.isDarkTheme ? ThemeMode.dark : ThemeMode.light,
                              ),
                            ),
                            Align(
                              alignment: Alignment.bottomCenter,
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 20),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: context.colorScheme.surface.withValues(alpha: 0.92),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text('view_map'.t(context: context), style: context.textTheme.labelLarge),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }
              final place = places[index - 1];
              return Material(
                color: context.colorScheme.surfaceContainerLow,
                clipBehavior: Clip.antiAlias,
                borderRadius: BorderRadius.circular(24),
                child: InkWell(
                  onTap: () => context.pushRoute(DriftPlaceDetailRoute(place: place.$1)),
                  child: SizedBox(
                    width: 110,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(18),
                              child: SizedBox.expand(
                                child: Thumbnail.remote(remoteId: place.$2, thumbhash: ''),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(top: 10, bottom: 6),
                            child: Text(place.$1, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PeopleCollection extends StatelessWidget {
  const _PeopleCollection();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _CollectionHeading(
          title: 'people'.t(context: context),
          onViewAll: () => context.pushRoute(const DriftPeopleCollectionRoute()),
        ),
        const CollectionPeopleRow(showNames: true),
      ],
    );
  }
}

typedef _CollectionAction = ({IconData icon, String label, VoidCallback onTap});

class _CollectionShortcuts extends ConsumerWidget {
  const _CollectionShortcuts();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trashEnabled = ref.watch(serverInfoProvider.select((state) => state.serverFeatures.trash));
    final actions = <_CollectionAction>[
      (icon: Icons.star_border_rounded, label: 'favorites', onTap: () => context.pushRoute(const DriftFavoriteRoute())),
      (icon: Icons.photo_album_outlined, label: 'albums', onTap: () => context.pushRoute(const DriftAlbumsRoute())),
      (
        icon: Icons.schedule_rounded,
        label: 'recently_added',
        onTap: () => context.pushRoute(const DriftRecentlyAddedRoute()),
      ),
      (
        icon: Icons.play_circle_outline_rounded,
        label: 'videos',
        onTap: () => context.pushRoute(const DriftVideoRoute()),
      ),
      (icon: Icons.inventory_2_outlined, label: 'archived', onTap: () => context.pushRoute(const DriftArchiveRoute())),
      (
        icon: Icons.lock_outline_rounded,
        label: 'locked_folder',
        onTap: () => context.pushRoute(const DriftLockedFolderRoute()),
      ),
      (icon: Icons.link_rounded, label: 'shared_links', onTap: () => context.pushRoute(const SharedLinkRoute())),
      if (trashEnabled)
        (icon: Icons.delete_outline_rounded, label: 'trash', onTap: () => context.pushRoute(const DriftTrashRoute())),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 30, bottom: 20),
            child: Text('other_collections'.t(context: context), style: context.textTheme.titleSmall),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Column(
              spacing: 2,
              children: [
                for (var i = 0; i < actions.length; i += 2)
                  IntrinsicHeight(
                    child: Row(
                      spacing: 2,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var j = i; j < i + 2 && j < actions.length; j++)
                          Expanded(child: _CollectionShortcut(action: actions[j])),
                        if (i + 1 == actions.length) const Expanded(child: SizedBox()),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CollectionShortcut extends StatelessWidget {
  const _CollectionShortcut({required this.action});
  final _CollectionAction action;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        onTap: action.onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 58),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(action.icon, size: 23, color: context.colorScheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(action.label.t(context: context), style: context.textTheme.bodyMedium),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DeviceCollection extends ConsumerWidget {
  const _DeviceCollection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(localAlbumProvider).valueOrNull ?? [];
    return Column(
      children: [
        _CollectionHeading(
          title: 'on_this_device'.t(context: context),
          onViewAll: () => context.pushRoute(const DriftLocalAlbumsRoute()),
        ),
        if (albums.isNotEmpty)
          SizedBox(
            height: 108,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: albums.length.clamp(0, 8),
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final album = albums[index];
                return SizedBox(
                  width: 108,
                  child: Material(
                    clipBehavior: Clip.antiAlias,
                    borderRadius: BorderRadius.circular(20),
                    child: InkWell(
                      onTap: () => context.pushRoute(LocalTimelineRoute(album: album)),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          LocalAlbumThumbnail(albumId: album.id),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Colors.transparent, Colors.black.withValues(alpha: 0.65)],
                              ),
                            ),
                          ),
                          Align(
                            alignment: Alignment.bottomLeft,
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Text(
                                album.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 24),
          leading: const Icon(Icons.folder_outlined),
          title: Text('folders'.t(context: context)),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => context.pushRoute(FolderRoute()),
        ),
      ],
    );
  }
}

@visibleForTesting
final sharedWithPartnerProvider = StreamProvider.autoDispose<Iterable<Partner>>((ref) {
  final currentUser = ref.watch(currentUserProvider);
  if (currentUser == null) {
    return const .empty();
  }
  return ref.watch(partnerServiceProvider).search(currentUser.id, .sharedWith);
});

class _SharingCollection extends ConsumerWidget {
  const _SharingCollection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final partners = ref.watch(sharedWithPartnerProvider).valueOrNull ?? [];
    return Column(
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 24),
          leading: const Icon(Icons.group_outlined),
          title: Text('partners'.t(context: context)),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => context.pushRoute(const PartnerRoute()),
        ),
        for (final partner in partners)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            leading: PartnerUserAvatar(userId: partner.id, name: partner.name),
            title: const Text('partner_list_user_photos').t(context: context, args: {'user': partner.name}),
            onTap: () => context.pushRoute(DriftPartnerDetailRoute(partner: partner)),
          ),
      ],
    );
  }
}
