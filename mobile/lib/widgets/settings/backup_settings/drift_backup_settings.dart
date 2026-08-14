import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/backup_config.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/services/sync_linked_album.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/extensions/translate_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/backup/backup_album.provider.dart';
import 'package:immich_mobile/providers/backup/drift_backup.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:immich_mobile/widgets/settings/setting_group_title.dart';
import 'package:immich_mobile/widgets/settings/setting_list_tile.dart';
import 'package:immich_mobile/widgets/settings/settings_sub_page_scaffold.dart';

class DriftBackupSettings extends ConsumerWidget {
  const DriftBackupSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsSubPageScaffold(
      settings: [
        SettingGroupTitle(
          title: "backup_quality".t(context: context),
          icon: Icons.high_quality_rounded,
        ),
        const _BackupQualityButton(),
        const Divider(),
        SettingGroupTitle(
          title: "network_requirements".t(context: context),
          icon: Icons.cell_tower,
        ),
        const _UseCellularForVideosButton(),
        const _UseCellularForPhotosButton(),
        if (CurrentPlatform.isAndroid) ...[
          const Divider(),
          SettingGroupTitle(
            title: "background_options".t(context: context),
            icon: Icons.charging_station_rounded,
          ),
          const _BackupOnlyWhenChargingButton(),
          const _BackupDelaySlider(),
        ],
        const Divider(),
        SettingGroupTitle(
          title: "backup_albums_sync".t(context: context),
          icon: Icons.sync,
        ),
        const _AlbumSyncActionButton(),
      ],
    );
  }
}

class _BackupQualityButton extends ConsumerWidget {
  const _BackupQualityButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quality = ref.watch(appConfigProvider.select((config) => config.backup.quality));
    final isStorageSaver = quality == BackupQuality.storageSaver;

    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: SettingListTile(
        title: isStorageSaver
            ? "backup_quality_storage_saver".t(context: context)
            : "backup_quality_original".t(context: context),
        subtitle: isStorageSaver
            ? "backup_quality_storage_saver_description".t(context: context)
            : "backup_quality_original_description".t(context: context),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => _showQualityPicker(context, quality),
      ),
    );
  }

  Future<void> _showQualityPicker(BuildContext context, BackupQuality selected) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _BackupQualitySheet(selected: selected),
    );
  }
}

class _BackupQualitySheet extends ConsumerWidget {
  final BackupQuality selected;

  const _BackupQualitySheet({required this.selected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pendingAssets = ref.watch(driftBackupCandidateProvider);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              title: Text(
                context.t.backup_quality,
                style: context.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(context.t.backup_quality_new_items_only),
            ),
            _StorageSavingsVisual(pendingAssets: pendingAssets),
            const SizedBox(height: 8),
            RadioGroup<BackupQuality>(
              groupValue: selected,
              onChanged: (value) => _selectQuality(context, ref, value),
              child: Column(
                children: [
                  RadioListTile<BackupQuality>(
                    value: BackupQuality.original,
                    title: Text(context.t.backup_quality_original),
                    subtitle: Text(context.t.backup_quality_original_description),
                  ),
                  RadioListTile<BackupQuality>(
                    value: BackupQuality.storageSaver,
                    title: Text(context.t.backup_quality_storage_saver),
                    subtitle: Text(context.t.backup_quality_storage_saver_description),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectQuality(BuildContext context, WidgetRef ref, BackupQuality? value) async {
    if (value == null) {
      return;
    }
    await ref.read(settingsProvider).write(SettingsKey.backupQuality, value);
    if (context.mounted) {
      Navigator.pop(context);
    }
  }
}

class _StorageSavingsVisual extends StatelessWidget {
  final AsyncValue<List<LocalAsset>> pendingAssets;

  const _StorageSavingsVisual({required this.pendingAssets});

  @override
  Widget build(BuildContext context) {
    return pendingAssets.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: LinearProgressIndicator(borderRadius: BorderRadius.all(Radius.circular(99))),
      ),
      error: (_, _) => _SavingsCard.empty(context),
      data: (assets) {
        if (assets.isEmpty) {
          return _SavingsCard.empty(context);
        }
        return _SavingsCard(estimate: _BackupStorageEstimate.fromAssets(assets));
      },
    );
  }
}

class _SavingsCard extends StatelessWidget {
  final _BackupStorageEstimate? estimate;

  const _SavingsCard({this.estimate});

  factory _SavingsCard.empty(BuildContext context) => const _SavingsCard();

  @override
  Widget build(BuildContext context) {
    final estimate = this.estimate;
    final hasEstimate = estimate != null && estimate.originalBytes > 0;
    final savedFraction = hasEstimate ? estimate.savedFraction : 0.48;
    final headline = hasEstimate
        ? '≈ ${formatBytes(estimate.savedBytes)} ${context.t.backup_quality_saved}'
        : context.t.backup_quality_future_savings;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            context.colorScheme.primary.withValues(alpha: 0.24),
            context.colorScheme.primaryContainer.withValues(alpha: 0.42),
            context.colorScheme.surfaceContainerHighest.withValues(alpha: 0.72),
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: context.colorScheme.primary.withValues(alpha: 0.34)),
        boxShadow: [
          BoxShadow(
            color: context.colorScheme.primary.withValues(alpha: 0.12),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: context.colorScheme.primary, borderRadius: BorderRadius.circular(14)),
                child: Icon(Icons.auto_awesome_rounded, color: context.colorScheme.onPrimary, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.t.backup_quality_estimated_savings,
                      style: context.textTheme.labelLarge?.copyWith(color: context.colorScheme.onSurfaceVariant),
                    ),
                    Text(
                      headline,
                      style: context.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, height: 1.15),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: context.colorScheme.primary.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  '≈ ${(savedFraction * 100).round()}%',
                  style: context.textTheme.labelLarge?.copyWith(
                    color: context.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (hasEstimate) ...[
            _EstimateBar(
              label: context.t.backup_quality_original,
              value: formatBytes(estimate.originalBytes),
              fraction: 1,
              color: context.colorScheme.onSurface.withValues(alpha: 0.38),
            ),
            const SizedBox(height: 12),
            _EstimateBar(
              label: context.t.backup_quality_storage_saver,
              value: formatBytes(estimate.saverBytes),
              fraction: 1 - savedFraction,
              color: context.colorScheme.primary,
            ),
            const SizedBox(height: 14),
            Text(
              context.t.backup_quality_pending_items(count: estimate.itemCount),
              style: context.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 3),
            Text(
              context.t.backup_quality_estimate_note,
              style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
            ),
          ] else
            Text(
              context.t.backup_quality_no_pending,
              style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

class _EstimateBar extends StatelessWidget {
  final String label;
  final String value;
  final double fraction;
  final Color color;

  const _EstimateBar({required this.label, required this.value, required this.fraction, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: context.textTheme.bodyMedium)),
            Text(value, style: context.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
          ],
        ),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (context, constraints) => Container(
            height: 8,
            decoration: BoxDecoration(
              color: context.colorScheme.onSurface.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(99),
            ),
            alignment: Alignment.centerLeft,
            child: TweenAnimationBuilder<double>(
              duration: const Duration(milliseconds: 650),
              curve: Curves.easeOutCubic,
              tween: Tween(begin: 0, end: fraction.clamp(0.06, 1)),
              builder: (_, animatedFraction, _) => Container(
                width: constraints.maxWidth * animatedFraction,
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(99)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _BackupStorageEstimate {
  final int originalBytes;
  final int saverBytes;
  final int itemCount;

  const _BackupStorageEstimate({required this.originalBytes, required this.saverBytes, required this.itemCount});

  int get savedBytes => (originalBytes - saverBytes).clamp(0, originalBytes);
  double get savedFraction => originalBytes == 0 ? 0 : (savedBytes / originalBytes).clamp(0, 1);

  factory _BackupStorageEstimate.fromAssets(Iterable<BaseAsset> assets) {
    var original = 0.0;
    var saver = 0.0;
    var count = 0;

    for (final asset in assets) {
      count++;
      final pixels = ((asset.width ?? 0) * (asset.height ?? 0)).toDouble();
      if (asset.isVideo) {
        final durationSeconds = ((asset.durationMs ?? 1000) / 1000).clamp(1, double.infinity);
        final effectivePixels = pixels > 0 ? pixels : 1920 * 1080;
        final originalBitrate = switch (effectivePixels) {
          >= 8000000 => 35000000.0,
          >= 3300000 => 18000000.0,
          >= 1900000 => 10000000.0,
          >= 800000 => 6000000.0,
          _ => 3000000.0,
        };
        final saverBitrate = originalBitrate.clamp(0, 5128000.0);
        original += originalBitrate * durationSeconds / 8;
        saver += saverBitrate * durationSeconds / 8;
      } else {
        final effectivePixels = pixels > 0 ? pixels : 12000000.0;
        final originalSize = effectivePixels * 0.34;
        final compressedSize = effectivePixels.clamp(0, 16000000.0) * 0.22;
        original += originalSize;
        saver += compressedSize.clamp(0, originalSize);
      }
    }

    return _BackupStorageEstimate(originalBytes: original.round(), saverBytes: saver.round(), itemCount: count);
  }
}

class _AlbumSyncActionButton extends ConsumerStatefulWidget {
  const _AlbumSyncActionButton();

  @override
  ConsumerState<_AlbumSyncActionButton> createState() => _AlbumSyncActionButtonState();
}

class _AlbumSyncActionButtonState extends ConsumerState<_AlbumSyncActionButton> {
  bool isAlbumSyncInProgress = false;

  Future<void> _manualSyncAlbums() async {
    setState(() {
      isAlbumSyncInProgress = true;
    });

    try {
      await ref.read(backgroundSyncProvider).syncLinkedAlbum();
      await ref.read(backgroundSyncProvider).syncRemote();
    } catch (_) {
    } finally {
      Future.delayed(const Duration(seconds: 1), () {
        if (!mounted) {
          return;
        }
        setState(() {
          isAlbumSyncInProgress = false;
        });
      });
    }
  }

  Future<void> _manageLinkedAlbums() async {
    final currentUser = ref.read(currentUserProvider);
    if (currentUser == null) {
      return;
    }
    final localAlbums = ref.read(backupAlbumProvider);
    final selectedBackupAlbums = localAlbums
        .where((album) => album.backupSelection == BackupSelection.selected)
        .toList();

    await ref.read(syncLinkedAlbumServiceProvider).manageLinkedAlbums(selectedBackupAlbums, currentUser.id);
  }

  @override
  Widget build(BuildContext context) {
    final albumSyncEnable = ref.watch(appConfigProvider.select((c) => c.backup.syncAlbums));
    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: ListView(
        shrinkWrap: true,
        children: [
          Column(
            children: [
              SettingListTile(
                title: "sync_albums".t(context: context),
                subtitle: "sync_upload_album_setting_subtitle".t(context: context),
                trailing: Switch(
                  value: albumSyncEnable,
                  onChanged: (bool newValue) async {
                    await ref.read(settingsProvider).write(.backupSyncAlbums, newValue);

                    if (newValue == true) {
                      await _manageLinkedAlbums();
                    }
                  },
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: albumSyncEnable ? 1.0 : 0.0,
                  child: albumSyncEnable
                      ? SettingListTile(
                          onTap: _manualSyncAlbums,
                          contentPadding: const EdgeInsets.only(left: 32, right: 16),
                          title: "organize_into_albums".t(context: context),
                          subtitle: "organize_into_albums_description".t(context: context),
                          trailing: isAlbumSyncInProgress
                              ? const SizedBox(
                                  width: 32,
                                  height: 32,
                                  child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                                )
                              : IconButton(
                                  onPressed: _manualSyncAlbums,
                                  icon: const Icon(Icons.sync_rounded),
                                  color: context.colorScheme.onSurface.withValues(alpha: 0.7),
                                  iconSize: 20,
                                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BackupSwitchTile extends ConsumerWidget {
  final SettingsKey<bool> metadataKey;
  final bool Function(AppConfig) selector;
  final String titleKey;
  final String subtitleKey;
  final void Function(bool)? onChanged;

  const _BackupSwitchTile({
    required this.metadataKey,
    required this.selector,
    required this.titleKey,
    required this.subtitleKey,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(appConfigProvider.select(selector));
    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: SettingListTile(
        title: titleKey.t(context: context),
        subtitle: subtitleKey.t(context: context),
        trailing: Switch(
          value: value,
          onChanged: (bool newValue) async {
            await ref.read(settingsProvider).write(metadataKey, newValue);
            onChanged?.call(newValue);
          },
        ),
      ),
    );
  }
}

class _UseCellularForVideosButton extends StatelessWidget {
  const _UseCellularForVideosButton();

  @override
  Widget build(BuildContext context) {
    return _BackupSwitchTile(
      metadataKey: SettingsKey.backupUseCellularForVideos,
      selector: (c) => c.backup.useCellularForVideos,
      titleKey: "videos",
      subtitleKey: "network_requirement_videos_upload",
    );
  }
}

class _UseCellularForPhotosButton extends StatelessWidget {
  const _UseCellularForPhotosButton();

  @override
  Widget build(BuildContext context) {
    return _BackupSwitchTile(
      metadataKey: SettingsKey.backupUseCellularForPhotos,
      selector: (c) => c.backup.useCellularForPhotos,
      titleKey: "photos",
      subtitleKey: "network_requirement_photos_upload",
    );
  }
}

class _BackupOnlyWhenChargingButton extends ConsumerWidget {
  const _BackupOnlyWhenChargingButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fgService = ref.read(backgroundWorkerFgServiceProvider);
    return _BackupSwitchTile(
      metadataKey: SettingsKey.backupRequireCharging,
      selector: (c) => c.backup.requireCharging,
      titleKey: "charging",
      subtitleKey: "charging_requirement_mobile_backup",
      onChanged: (value) {
        fgService.configure(requireCharging: value);
      },
    );
  }
}

class _BackupDelaySlider extends ConsumerWidget {
  const _BackupDelaySlider();

  static int backupDelayToSliderValue(int ms) => switch (ms) {
    5 => 0,
    30 => 1,
    120 => 2,
    _ => 3,
  };

  static int backupDelayToSeconds(int v) => switch (v) {
    0 => 5,
    1 => 30,
    2 => 120,
    _ => 600,
  };

  static String formatBackupDelaySliderValue(BuildContext context, int v) => switch (v) {
    0 => context.t.setting_notifications_notify_seconds(count: 5),
    1 => context.t.setting_notifications_notify_seconds(count: 30),
    2 => context.t.setting_notifications_notify_minutes(count: 2),
    _ => context.t.setting_notifications_notify_minutes(count: 10),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final triggerDelay = ref.watch(appConfigProvider.select((c) => c.backup.triggerDelay));
    final currentValue = backupDelayToSliderValue(triggerDelay);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 24.0, top: 8.0),
          child: Text(
            context.t.backup_controller_page_background_delay(
              duration: formatBackupDelaySliderValue(context, currentValue),
            ),
            style: context.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
          ),
        ),
        Slider(
          value: currentValue.toDouble(),
          onChanged: (double v) async {
            final seconds = backupDelayToSeconds(v.toInt());
            await ref.read(settingsProvider).write(SettingsKey.backupTriggerDelay, seconds);
          },
          onChangeEnd: (double v) async {
            final seconds = backupDelayToSeconds(v.toInt());
            await ref.read(settingsProvider).write(SettingsKey.backupTriggerDelay, seconds);
          },
          max: 3.0,
          min: 0.0,
          divisions: 3,
          label: formatBackupDelaySliderValue(context, currentValue),
        ),
      ],
    );
  }
}
