import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/translate_extensions.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/providers/infrastructure/people.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';

/// A compact, scrollable strip of actual recognized people used by collections
/// and search. Hidden people are never suggested.
class CollectionPeopleRow extends ConsumerWidget {
  const CollectionPeopleRow({super.key, this.showNames = false});

  final bool showNames;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final people =
        ref.watch(driftGetAllPeopleProvider).valueOrNull?.where((person) => !person.isHidden).take(12).toList() ?? [];
    final diameter = showNames ? 64.0 : 44.0;
    final labelStyle = context.textTheme.labelMedium;
    final labelHeight =
        MediaQuery.textScalerOf(context).scale(labelStyle?.fontSize ?? 12) * (labelStyle?.height ?? 1.5);
    return SizedBox(
      height: showNames ? math.max(96, diameter + 14 + labelHeight) : 60,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        scrollDirection: Axis.horizontal,
        itemCount: people.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final person = index < people.length ? people[index] : null;
          final label = person == null
              ? (people.isEmpty ? 'people' : 'view_all').t(context: context)
              : person.name.isEmpty
              ? 'no_name'.t(context: context)
              : person.name;
          // Do not reuse the empty-state avatar when the first real face loads.
          return Semantics(
            key: ValueKey(person?.id ?? 'all-people'),
            button: true,
            label: label,
            child: Tooltip(
              message: label,
              child: InkWell(
                borderRadius: BorderRadius.circular(32),
                onTap: () => person == null
                    ? context.pushRoute(const DriftPeopleCollectionRoute())
                    : context.pushRoute(DriftPersonRoute(person: person)),
                child: SizedBox(
                  width: showNames ? 72 : 48,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircleAvatar(
                        radius: diameter / 2,
                        backgroundColor: context.colorScheme.surfaceContainerHigh,
                        backgroundImage: person == null
                            ? null
                            : RemoteImageProvider(url: getFaceThumbnailUrl(person.id)),
                        child: person == null
                            ? Icon(
                                people.isEmpty ? Icons.people_outline_rounded : Icons.more_horiz_rounded,
                                color: context.colorScheme.onSurfaceVariant,
                              )
                            : null,
                      ),
                      if (showNames)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.textTheme.labelMedium,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
