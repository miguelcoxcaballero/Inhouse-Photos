import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/memory.model.dart';
import 'package:immich_mobile/extensions/translate_extensions.dart';
import 'package:immich_mobile/presentation/pages/drift_memory.page.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';
import 'package:immich_mobile/providers/infrastructure/memory.provider.dart';
import 'package:immich_mobile/routing/router.dart';

/// Includes the space between the carousel and the first grid row.
double memoryLaneHeightForWidth(double width) => (width * 0.58).clamp(224.0, 280.0) + 24;

class DriftMemoryLane extends ConsumerWidget {
  const DriftMemoryLane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memoryLaneProvider = ref.watch(driftMemoryFutureProvider);
    // A partially synchronized memory may temporarily have no assets. Hiding
    // it keeps the lane stable instead of letting an empty card crash or flash.
    final memories = (memoryLaneProvider.value ?? const <DriftMemory>[])
        .where((memory) => memory.assets.isNotEmpty)
        .toList(growable: false);
    if (memories.isEmpty) {
      return const SizedBox.shrink();
    }

    final width = MediaQuery.sizeOf(context).width;
    return SizedBox(
      height: memoryLaneHeightForWidth(width),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        itemCount: memories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final memory = memories[index];
          return SizedBox(
            width: (width * 0.44).clamp(168.0, 224.0),
            child: Material(
              color: Colors.black,
              borderRadius: BorderRadius.circular(32),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () {
                  ref.read(hapticFeedbackProvider.notifier).heavyImpact();
                  DriftMemoryPage.setMemory(ref, memory);
                  context.pushRoute(DriftMemoryRoute(memories: memories, memoryIndex: index));
                },
                child: DriftMemoryCard(key: Key(memory.id), memory: memory),
              ),
            ),
          );
        },
      ),
    );
  }
}

class DriftMemoryCard extends ConsumerWidget {
  const DriftMemoryCard({super.key, required this.memory});

  final DriftMemory memory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final yearsAgo = DateTime.now().year - memory.data.year;
    final title = 'years_ago'.t(context: context, args: {'years': yearsAgo.toString()});
    return Semantics(
      button: true,
      label: 'Open memory from ${memory.data.year}',
      child: RepaintBoundary(
        child: Stack(
          children: [
            ColorFiltered(
              colorFilter: ColorFilter.mode(Colors.black.withValues(alpha: 0.2), BlendMode.darken),
              child: SizedBox.expand(
                child: Thumbnail.remote(
                  remoteId: memory.assets[0].id,
                  thumbhash: memory.assets[0].thumbHash ?? "",
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.center,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black54],
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 18,
              left: 16,
              right: 16,
              child: Text(
                title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w500, color: Colors.white, fontSize: 19),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
