import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/config/image_config.dart';
import 'package:immich_mobile/domain/models/log.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/log.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/models/server_info/server_info.model.dart';
import 'package:immich_mobile/providers/backup/backup.provider.dart';
import 'package:immich_mobile/providers/backup/drift_backup.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/app_health.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:immich_mobile/utils/cache/custom_image_cache.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class AppHealthSettings extends ConsumerStatefulWidget {
  const AppHealthSettings({super.key});

  @override
  ConsumerState<AppHealthSettings> createState() => _AppHealthSettingsState();
}

class _AppHealthSettingsState extends ConsumerState<AppHealthSettings> {
  late Future<_DiagnosticsData> _diagnostics;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _diagnostics = _loadDiagnostics(refreshRemote: true);
  }

  Future<_DiagnosticsData> _loadDiagnostics({required bool refreshRemote}) async {
    final user = ref.read(currentUserProvider);
    if (refreshRemote) {
      await Future.wait<void>([
        ref.read(serverInfoProvider.notifier).getServerInfo().then<void>((_) {}),
        ref.read(backupProvider.notifier).updateDiskInfo(),
        if (user != null) ref.read(driftBackupProvider.notifier).getBackupStatus(user.id),
      ]);
    }
    final results = await Future.wait<Object>([PackageInfo.fromPlatform(), LogService.I.getMessages()]);
    return _DiagnosticsData(packageInfo: results[0] as PackageInfo, logs: results[1] as List<LogMessage>);
  }

  Future<void> _refresh() async {
    if (_refreshing) {
      return;
    }
    setState(() {
      _refreshing = true;
      _diagnostics = _loadDiagnostics(refreshRemote: true);
    });
    try {
      await _diagnostics;
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
      }
    }
  }

  Future<void> _retryBackup() async {
    final user = ref.read(currentUserProvider);
    if (user == null) {
      return;
    }
    await ref.read(driftBackupProvider.notifier).retryFailedUploads(user.id);
    if (mounted) {
      context.scaffoldMessenger.showSnackBar(
        const SnackBar(content: Text('Backup retry started. Failed items will be checked again.')),
      );
    }
  }

  Future<void> _setCacheMode(ImageCacheMode mode) async {
    await ref.read(settingsProvider).write(.imageCacheMode, mode);
    applyImageCacheMode(PaintingBinding.instance.imageCache, mode);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _clearCache() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    if (mounted) {
      setState(() {});
      context.scaffoldMessenger.showSnackBar(const SnackBar(content: Text('Memory image cache cleared.')));
    }
  }

  Future<void> _exportDiagnostics(_DiagnosticsData data) async {
    final server = ref.read(serverInfoProvider);
    final disk = ref.read(backupProvider);
    final backup = ref.read(driftBackupProvider);
    final config = SettingsRepository.instance.appConfig;
    final logs = summarizeLogHealth(data.logs);
    final cache = PaintingBinding.instance.imageCache;
    final report = buildAppHealthReport(
      appVersion: data.packageInfo.version,
      buildNumber: data.packageInfo.buildNumber,
      platform: Platform.operatingSystemVersion,
      endpoint: redactServerEndpoint(Store.tryGet(StoreKey.serverEndpoint)),
      serverVersion: server.serverVersion.toString(),
      serverStatus: server.versionStatus.name,
      diskSummary: '${disk.diskUse} used of ${disk.diskSize} (${disk.diskUsagePercentage.toStringAsFixed(1)}%)',
      backupTotal: backup.totalCount,
      backupComplete: backup.backupCount,
      backupRemaining: backup.remainderCount,
      backupErrors: backup.errorCount + (backup.error == BackupError.none ? 0 : 1),
      imageCacheItems: cache.currentSize,
      imageCacheBytes: cache.currentSizeBytes,
      logWarnings: logs.warnings,
      logSevere: logs.severe,
      offlineAlbumCount: config.album.offlineAlbumIds.length,
      originalBytes: config.backup.uploadedOriginalBytes,
      storedBytes: config.backup.storedBytes,
    );
    final directory = await getTemporaryDirectory();
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final file = File('${directory.path}/Inhouse-Photos-Diagnostics-$stamp.txt');
    await file.writeAsString(report, flush: true);
    if (!mounted) {
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    await Share.shareXFiles(
      [XFile(file.path)],
      subject: 'Inhouse Photos diagnostics',
      sharePositionOrigin: box == null ? const Rect.fromLTWH(0, 0, 1, 1) : box.localToGlobal(Offset.zero) & box.size,
    );
  }

  @override
  Widget build(BuildContext context) {
    final server = ref.watch(serverInfoProvider);
    final disk = ref.watch(backupProvider);
    final backup = ref.watch(driftBackupProvider);
    final config = ref.watch(appConfigProvider);
    final endpoint = redactServerEndpoint(Store.tryGet(StoreKey.serverEndpoint));
    final cache = PaintingBinding.instance.imageCache;
    final hasProblem =
        server.versionStatus == VersionStatus.error || backup.error != BackupError.none || backup.errorCount > 0;
    final savings = (config.backup.uploadedOriginalBytes - config.backup.storedBytes).clamp(
      0,
      config.backup.uploadedOriginalBytes,
    );

    return FutureBuilder<_DiagnosticsData>(
      future: _diagnostics,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final logSummary = data == null ? null : summarizeLogHealth(data.logs);
        return ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 72),
          children: [
            const _SectionLabel('OVERVIEW'),
            ListTile(
              leading: Icon(
                hasProblem ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
                color: hasProblem ? context.colorScheme.error : Colors.green,
              ),
              title: Text(hasProblem ? 'App Health needs attention' : 'Everything looks healthy'),
              subtitle: Text(endpoint),
              trailing: _refreshing
                  ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                  : IconButton(onPressed: _refresh, tooltip: 'Refresh', icon: const Icon(Icons.refresh_rounded)),
            ),
            if (data != null)
              _ValueTile(
                icon: Icons.phone_android_rounded,
                title: 'App version',
                value: '${data.packageInfo.version} (${data.packageInfo.buildNumber})',
              ),
            _ValueTile(
              icon: Icons.dns_outlined,
              title: 'Server',
              value: server.versionStatus == VersionStatus.error
                  ? 'Not reachable'
                  : 'v${server.serverVersion} · ${server.versionStatus.name}',
            ),
            _ValueTile(
              icon: Icons.storage_outlined,
              title: 'Server storage',
              value: disk.diskSize == '0'
                  ? 'Unavailable'
                  : '${disk.diskUse} / ${disk.diskSize} · ${disk.diskUsagePercentage.toStringAsFixed(0)}%',
            ),
            const Divider(height: 24),
            const _SectionLabel('BACKUP'),
            ListTile(
              leading: const Icon(Icons.cloud_upload_outlined),
              title: Text(backup.remainderCount == 0 ? 'Backup is complete' : '${backup.remainderCount} items waiting'),
              subtitle: Text(
                '${backup.backupCount} of ${backup.totalCount} backed up'
                '${backup.errorCount == 0 ? '' : ' · ${backup.errorCount} failed'}',
              ),
              trailing: backup.errorCount > 0 || backup.error != BackupError.none
                  ? TextButton(onPressed: _retryBackup, child: const Text('Retry'))
                  : backup.isSyncing
                  ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                  : null,
            ),
            _ValueTile(
              icon: Icons.data_saver_on_rounded,
              title: 'Storage saved by compression',
              value: config.backup.uploadedOriginalBytes == 0
                  ? 'Measured from new Storage saver uploads'
                  : '${formatHumanReadableBytes(savings, 1)} saved · '
                        '${formatHumanReadableBytes(config.backup.storedBytes, 1)} stored',
            ),
            _ValueTile(
              icon: Icons.offline_pin_outlined,
              title: 'Offline albums',
              value: '${config.album.offlineAlbumIds.length} kept available on this device',
            ),
            const Divider(height: 24),
            const _SectionLabel('CACHE AND PERFORMANCE'),
            ListTile(
              leading: const Icon(Icons.speed_rounded),
              title: const Text('Image cache profile'),
              subtitle: Text(
                '${cache.currentSize} images · ${formatHumanReadableBytes(cache.currentSizeBytes, 1)} in memory',
              ),
              trailing: DropdownButtonHideUnderline(
                child: DropdownButton<ImageCacheMode>(
                  value: config.image.cacheMode,
                  onChanged: (value) => value == null ? null : _setCacheMode(value),
                  items: const [
                    DropdownMenuItem(value: ImageCacheMode.automatic, child: Text('Auto')),
                    DropdownMenuItem(value: ImageCacheMode.compact, child: Text('Compact')),
                    DropdownMenuItem(value: ImageCacheMode.performance, child: Text('Fast')),
                  ],
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.cleaning_services_outlined),
              title: const Text('Clear temporary image memory'),
              subtitle: const Text('Original photos and offline albums are never removed.'),
              onTap: _clearCache,
            ),
            const Divider(height: 24),
            const _SectionLabel('DIAGNOSTICS'),
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('App logs'),
              subtitle: Text(
                logSummary == null
                    ? 'Loading recent diagnostics…'
                    : '${logSummary.warnings} warnings · ${logSummary.severe} severe entries',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.pushRoute(const AppLogRoute()),
            ),
            ListTile(
              enabled: data != null,
              leading: const Icon(Icons.ios_share_rounded),
              title: const Text('Export safe diagnostics'),
              subtitle: const Text('Creates a report without credentials, filenames, or photo metadata.'),
              onTap: data == null ? null : () => _exportDiagnostics(data),
            ),
          ],
        );
      },
    );
  }
}

class _DiagnosticsData {
  final PackageInfo packageInfo;
  final List<LogMessage> logs;

  const _DiagnosticsData({required this.packageInfo, required this.logs});
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
    child: Text(
      text,
      style: context.textTheme.labelSmall?.copyWith(
        color: context.colorScheme.primary,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
      ),
    ),
  );
}

class _ValueTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;

  const _ValueTile({required this.icon, required this.title, required this.value});

  @override
  Widget build(BuildContext context) => ListTile(leading: Icon(icon), title: Text(title), subtitle: Text(value));
}
