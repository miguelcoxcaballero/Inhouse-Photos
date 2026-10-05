import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/extensions/translate_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/backup/backup_album.provider.dart';
import 'package:immich_mobile/providers/backup/drift_backup.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/permission.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/upload_speed_calculator.dart';
import 'package:immich_mobile/widgets/backup/backup_cloud_hero.dart';
import 'package:immich_mobile/widgets/backup/backup_stage_bar.dart';
import 'package:immich_mobile/widgets/settings/setting_group_title.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

@RoutePage()
class DriftBackupPage extends ConsumerStatefulWidget {
  const DriftBackupPage({super.key});

  @override
  ConsumerState<DriftBackupPage> createState() => _DriftBackupPageState();
}

class _DriftBackupPageState extends ConsumerState<DriftBackupPage> {
  Future<void>? _startingBackup;
  int _backupGeneration = 0;
  int _startingGeneration = 0;

  @override
  void initState() {
    super.initState();

    WakelockPlus.enable();

    final currentUser = ref.read(currentUserProvider);
    if (currentUser == null) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        return;
      }
      await ref.read(driftBackupProvider.notifier).getBackupStatus(currentUser.id);
      if (!mounted) {
        return;
      }
      if (ref.read(appConfigProvider).backup.enabled) {
        unawaited(_startBackup());
      } else {
        await _synchronize();
        if (mounted) {
          await ref.read(driftBackupProvider.notifier).getBackupStatus(currentUser.id);
        }
      }
    });
  }

  Future<bool> _synchronize() async {
    final notifier = ref.read(driftBackupProvider.notifier);
    notifier.updateSyncing(true);
    try {
      return await ref.read(backgroundSyncProvider).syncRemote();
    } finally {
      if (notifier.mounted) {
        notifier.updateSyncing(false);
      }
    }
  }

  Future<void> _startBackup() {
    final active = _startingBackup;
    if (active != null) {
      if (_startingGeneration == _backupGeneration) {
        return active;
      }
      // If backup was disabled and enabled again while sync was still running,
      // wait for the obsolete attempt before starting the new one.
      return active.then((_) {
        if (mounted && ref.read(appConfigProvider).backup.enabled) {
          return _startBackup();
        }
      });
    }
    _startingGeneration = _backupGeneration;
    return _startingBackup = _startBackupAfterSync().whenComplete(() => _startingBackup = null);
  }

  Future<void> _startBackupAfterSync() async {
    final currentUser = ref.read(currentUserProvider);
    if (currentUser == null) {
      return;
    }
    final generation = _backupGeneration;
    final success = await _synchronize();
    if (!mounted || generation != _backupGeneration || ref.read(currentUserProvider)?.id != currentUser.id) {
      return;
    }
    final notifier = ref.read(driftBackupProvider.notifier);
    await notifier.getBackupStatus(currentUser.id);
    if (!mounted ||
        generation != _backupGeneration ||
        ref.read(currentUserProvider)?.id != currentUser.id ||
        !ref.read(appConfigProvider).backup.enabled) {
      return;
    }
    if (!success) {
      Logger("DriftBackupPage").warning("Remote sync failed; backup can be retried without leaving this screen");
      return;
    }
    await notifier.startForegroundBackup(currentUser.id);
  }

  @override
  dispose() {
    super.dispose();
    WakelockPlus.disable();
  }

  @override
  Widget build(BuildContext context) {
    final hasSelectedAlbums = ref
        .watch(backupAlbumProvider)
        .any((album) => album.backupSelection == BackupSelection.selected);

    final backupNotifier = ref.read(driftBackupProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        title: Text("backup_controller_page_backup".t()),
        leading: IconButton(
          onPressed: () {
            context.maybePop(true);
          },
          splashRadius: 24,
          icon: const Icon(Icons.arrow_back_ios_rounded),
        ),
        actions: [
          IconButton(
            onPressed: () {
              context.pushRoute(const DriftBackupOptionsRoute());
            },
            icon: const Icon(Icons.settings_outlined),
            tooltip: "backup_options".t(context: context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 32),
        children: [
          if (hasSelectedAlbums) ...[
            _BackupSwitchCard(
              onStart: () => unawaited(_startBackup()),
              onStop: () {
                _backupGeneration++;
                backupNotifier.stopForegroundBackup();
              },
            ),
            _BackupStatus(onRetry: () => unawaited(_startBackup())),
            const Divider(height: 24),
          ],
          const _AlbumsTile(),
          if (hasSelectedAlbums) ...[const _PendingTile(), const _UploadsTile(), const _BackgroundReliability()],
        ],
      ),
    );
  }
}

NumberFormat _countFormat(BuildContext context) {
  try {
    return NumberFormat.decimalPattern(Localizations.localeOf(context).toString());
  } catch (_) {
    return NumberFormat.decimalPattern('en');
  }
}

TextStyle? _tileTitleStyle(BuildContext context) =>
    context.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500, height: 1.5);

TextStyle? _tileSubtitleStyle(BuildContext context) =>
    context.textTheme.bodyMedium?.copyWith(color: context.textTheme.bodyMedium?.color?.withAlpha(215));

const _tilePadding = EdgeInsets.only(left: 20, right: 24);

/// The settings-card style switch that enables or disables backup.
class _BackupSwitchCard extends ConsumerStatefulWidget {
  const _BackupSwitchCard({required this.onStart, required this.onStop});

  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  ConsumerState<_BackupSwitchCard> createState() => _BackupSwitchCardState();
}

class _BackupSwitchCardState extends ConsumerState<_BackupSwitchCard> {
  late bool _isEnabled = ref.read(appConfigProvider).backup.enabled;

  Future<void> _onToggle(bool value) async {
    unawaited(HapticFeedback.selectionClick());
    // Flip the switch straight away so the animation follows the finger, then persist.
    setState(() {
      _isEnabled = value;
    });
    try {
      await ref.read(settingsProvider).write(.backupEnabled, value);
    } catch (_) {
      if (mounted) {
        setState(() {
          _isEnabled = !value;
        });
      }
      rethrow;
    }
    if (!mounted) {
      return;
    }

    if (value) {
      widget.onStart.call();
    } else {
      widget.onStop.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = ref.watch(driftBackupProvider.select((state) => state.error));
    final errorCount = ref.watch(driftBackupProvider.select((state) => state.errorCount));
    final isComplete = ref.watch(
      driftBackupProvider.select((state) => state.totalCount > 0 && state.remainderCount == 0),
    );

    final (subtitle, isWarning) = switch ((_isEnabled, error, errorCount, isComplete)) {
      (false, _, _, _) => ("backup_switch_off".t(context: context), false),
      (true, BackupError.syncFailed, _, _) => ("backup_switch_sync_failed".t(context: context), true),
      (true, _, > 0, _) => ("upload_error_with_count".t(context: context, args: {'count': errorCount}), true),
      (true, _, _, true) => ("backup_switch_all_done".t(context: context), false),
      _ => ("backup_switch_on".t(context: context), false),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Card(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        color: context.colorScheme.surfaceContainer,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
        margin: const EdgeInsets.symmetric(vertical: 4.0),
        child: ListTile(
          contentPadding: const EdgeInsets.only(left: 16, right: 12),
          onTap: () => _onToggle(!_isEnabled),
          leading: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(Radius.circular(16)),
              color: _isEnabled
                  ? context.primaryColor.withValues(alpha: 0.14)
                  : context.isDarkTheme
                  ? Colors.black26
                  : Colors.white.withAlpha(100),
            ),
            padding: const EdgeInsets.all(16.0),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              switchInCurve: Curves.easeOutBack,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: RotationTransition(
                  turns: Tween(begin: -0.08, end: 0.0).animate(animation),
                  child: ScaleTransition(scale: Tween(begin: 0.6, end: 1.0).animate(animation), child: child),
                ),
              ),
              child: Icon(
                _isEnabled ? Icons.cloud_upload_outlined : Icons.cloud_off_outlined,
                key: ValueKey(_isEnabled),
                color: context.primaryColor,
              ),
            ),
          ),
          title: Text(
            "backup_controller_page_backup".t(context: context),
            style: context.textTheme.titleMedium!.copyWith(color: context.primaryColor),
          ),
          subtitle: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            // The old text leaves before the new one arrives, so they never overlap.
            switchInCurve: const Interval(0.4, 1, curve: Curves.easeOutCubic),
            switchOutCurve: const Interval(0.6, 1, curve: Curves.easeIn),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, 0.3), end: Offset.zero).animate(animation),
                child: child,
              ),
            ),
            layoutBuilder: (current, previous) =>
                Stack(alignment: AlignmentDirectional.centerStart, children: [...previous, ?current]),
            child: Text(
              subtitle,
              key: ValueKey(subtitle),
              style: context.textTheme.bodyMedium?.copyWith(color: isWarning ? context.colorScheme.error : null),
            ),
          ),
          trailing: Switch.adaptive(value: _isEnabled, onChanged: _onToggle),
        ),
      ),
    );
  }
}

/// The cloud with its animation and the progress bar below it.
class _BackupStatus extends ConsumerWidget {
  const _BackupStatus({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isEnabled = ref.watch(appConfigProvider.select((config) => config.backup.enabled));
    final backup = ref.watch(driftBackupProvider);
    final syncStatus = ref.watch(syncStatusProvider);
    final count = _countFormat(context);

    final activeUploads = backup.uploadItems.values.where((item) => item.isFailed != true).length;
    final isError = backup.error == BackupError.syncFailed;
    final isComplete = backup.totalCount > 0 && backup.remainderCount == 0;
    final pending = "backup_hero_pending".t(context: context, args: {'count': count.format(backup.remainderCount)});

    final (state, title, subtitle) = switch (null) {
      _ when isError => (BackupCloudState.error, "backup_hero_sync_failed".t(context: context), null),
      _ when !isEnabled => (
        BackupCloudState.off,
        "backup_hero_off".t(context: context),
        backup.remainderCount > 0 ? pending : null,
      ),
      _ when activeUploads > 0 => (
        BackupCloudState.uploading,
        "backup_hero_uploading".t(context: context, args: {'count': activeUploads}),
        // Only read while uploading: the aggregate speed is meaningless otherwise.
        formatAggregateUploadSpeed(ref.read(driftBackupProvider.notifier).currentUploadBytesPerSecond),
      ),
      _ when backup.isSyncing => (BackupCloudState.syncing, "backup_hero_syncing".t(context: context), null),
      _ when isComplete => (BackupCloudState.done, "backup_hero_done".t(context: context), null),
      _ => (BackupCloudState.idle, "backup_hero_waiting".t(context: context), pending),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BackupCloudHero(
          state: state,
          title: title,
          subtitle: subtitle,
          footer: isError
              ? Column(
                  children: [
                    if (syncStatus.errorMessage case final String message)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                        child: SelectableText(
                          message,
                          textAlign: TextAlign.center,
                          style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceSecondary),
                        ),
                      ),
                    TextButton.icon(
                      onPressed: backup.isSyncing ? null : onRetry,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text("backup_retry_sync".tr()),
                    ),
                  ],
                )
              : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: BackupStageBar(
            total: backup.totalCount,
            backedUp: backup.backupCount,
            remaining: backup.remainderCount,
            isUploading: activeUploads > 0,
            isError: isError,
            backedUpLabel: "backup_bar_backed_up".t(context: context),
            backedUpLegend: "backup_bar_legend_backed_up".t(context: context),
            remainingLegend: "backup_pending_title".t(context: context),
            totalLabel: "total".t(context: context),
          ),
        ),
      ],
    );
  }
}

class _AlbumsTile extends ConsumerWidget {
  const _AlbumsTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(backupAlbumProvider);
    final selected = albums
        .where((album) => album.backupSelection == BackupSelection.selected)
        .map(
          (album) => album.name == "Recent" || album.name == "Recents" ? "${album.name} (${'all'.tr()})" : album.name,
        )
        .join(", ");
    final excluded = albums
        .where((album) => album.backupSelection == BackupSelection.excluded)
        .map((album) => album.name)
        .join(", ");

    return ListTile(
      contentPadding: _tilePadding,
      leading: const Icon(Icons.photo_library_outlined),
      title: Text("albums".tr(), style: _tileTitleStyle(context)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            selected.isNotEmpty ? selected : "backup_controller_page_none_selected".tr(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _tileSubtitleStyle(context),
          ),
          if (excluded.isNotEmpty)
            Text(
              "${"backup_controller_page_excluded".tr()}$excluded",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _tileSubtitleStyle(context)?.copyWith(color: Colors.red[300]),
            ),
        ],
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () async {
        await context.pushRoute(const DriftBackupAlbumSelectionRoute());
        final currentUser = ref.read(currentUserProvider);
        if (currentUser == null) {
          return;
        }
        unawaited(ref.read(driftBackupProvider.notifier).getBackupStatus(currentUser.id));
      },
    );
  }
}

class _PendingTile extends ConsumerWidget {
  const _PendingTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remainder = ref.watch(driftBackupProvider.select((state) => state.remainderCount));

    return ListTile(
      contentPadding: _tilePadding,
      leading: const Icon(Icons.pending_outlined),
      title: Text("backup_pending_title".t(context: context), style: _tileTitleStyle(context)),
      subtitle: Text(
        "backup_pending_subtitle".t(context: context, args: {'count': _countFormat(context).format(remainder)}),
        style: _tileSubtitleStyle(context),
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => context.pushRoute(const DriftBackupAssetDetailRoute()),
    );
  }
}

class _UploadsTile extends ConsumerWidget {
  const _UploadsTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(
      driftBackupProvider.select(
        (state) => state.uploadItems.values.where((item) => item.isFailed != true).firstOrNull,
      ),
    );

    return ListTile(
      contentPadding: _tilePadding,
      leading: const Icon(Icons.upload_outlined),
      title: Text("backup_uploads_title".t(context: context), style: _tileTitleStyle(context)),
      subtitle: Text(
        current == null
            ? "backup_uploads_none".t(context: context)
            : "${current.filename} · ${(current.progress * 100).clamp(0, 100).round()} %",
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _tileSubtitleStyle(context)?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => context.pushRoute(const DriftUploadDetailRoute()),
    );
  }
}

/// Android permissions that keep background backups alive, shown only while missing.
class _BackgroundReliability extends ConsumerStatefulWidget {
  const _BackgroundReliability();

  @override
  ConsumerState<_BackgroundReliability> createState() => _BackgroundReliabilityState();
}

class _BackgroundReliabilityState extends ConsumerState<_BackgroundReliability> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (CurrentPlatform.isAndroid && state == AppLifecycleState.resumed && mounted) {
      unawaited(ref.read(notificationPermissionProvider.notifier).getNotificationPermission());
      unawaited(ref.read(batteryOptimizationProvider.notifier).getBatteryOptimizationPermission());
    }
  }

  void showPermissionsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(context.t.notification_permission_dialog_content),
        actions: [
          ImmichTextButton(
            labelText: context.t.cancel,
            variant: .ghost,
            expanded: false,
            onPressed: () => ContextHelper(ctx).pop(),
          ),
          ImmichTextButton(
            labelText: context.t.settings,
            variant: .ghost,
            expanded: false,
            onPressed: () {
              ContextHelper(context).pop();
              openAppSettings();
            },
          ),
        ],
      ),
    );
  }

  void showBatteryOptimizationInfo() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: Text(context.t.backup_controller_page_background_battery_info_title),
          content: SingleChildScrollView(child: Text(context.t.backup_controller_page_background_battery_info_message)),
          actions: [
            ImmichTextButton(
              labelText: context.t.backup_controller_page_background_battery_info_link,
              variant: .ghost,
              expanded: false,
              onPressed: () => launchUrl(Uri.parse('https://dontkillmyapp.com'), mode: LaunchMode.externalApplication),
            ),
            ImmichTextButton(
              labelText: context.t.backup_controller_page_background_battery_info_ok,
              variant: .ghost,
              expanded: false,
              onPressed: () => ContextHelper(ctx).pop(),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isBackupEnabled = ref.watch(appConfigProvider.select((config) => config.backup.enabled));
    final notificationStatus = ref.watch(notificationPermissionProvider);
    final batteryOptimizationStatus = ref.watch(batteryOptimizationProvider).valueOrNull;

    final needsNotifications = notificationStatus != PermissionStatus.granted;
    final needsBattery = batteryOptimizationStatus != PermissionStatus.granted;
    final visible = CurrentPlatform.isAndroid && isBackupEnabled && (needsNotifications || needsBattery);

    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: !visible
          ? const SizedBox(width: double.infinity)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Divider(height: 24),
                SettingGroupTitle(
                  title: "backup_background_group".t(context: context),
                  icon: Icons.info_outline_rounded,
                  contentPadding: const EdgeInsets.only(left: 20, right: 20, bottom: 4),
                ),
                if (needsNotifications)
                  ListTile(
                    contentPadding: _tilePadding,
                    leading: const Icon(Icons.notifications_outlined),
                    title: Text("backup_notifications_title".t(context: context), style: _tileTitleStyle(context)),
                    subtitle: Text(
                      "backup_notifications_subtitle".t(context: context),
                      style: _tileSubtitleStyle(context),
                    ),
                    trailing: const Icon(Icons.open_in_new_outlined),
                    onTap: () {
                      ref.read(notificationPermissionProvider.notifier).requestNotificationPermission().then((p) {
                        if (p == PermissionStatus.permanentlyDenied) {
                          showPermissionsDialog();
                        }
                      });
                    },
                  ),
                if (needsBattery)
                  ListTile(
                    contentPadding: _tilePadding,
                    leading: const Icon(Icons.battery_alert_outlined),
                    title: Text("backup_battery_title".t(context: context), style: _tileTitleStyle(context)),
                    subtitle: Text("backup_battery_subtitle".t(context: context), style: _tileSubtitleStyle(context)),
                    trailing: const Icon(Icons.open_in_new_outlined),
                    onTap: showBatteryOptimizationInfo,
                  ),
              ],
            ),
    );
  }
}
