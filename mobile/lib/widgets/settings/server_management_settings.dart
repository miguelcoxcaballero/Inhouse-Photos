import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/services/server_management.service.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

class ServerManagementSettings extends ConsumerStatefulWidget {
  const ServerManagementSettings({super.key});

  @override
  ConsumerState<ServerManagementSettings> createState() => _ServerManagementSettingsState();
}

class _ServerManagementSettingsState extends ConsumerState<ServerManagementSettings> {
  late final http.Client _client;
  late final ServerManagementService _service;
  ServerManagementStatus? _status;
  String? _error;
  bool _loading = false;
  bool _acting = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _client = http.Client();
    _service = ServerManagementService(_client);
    unawaited(_refresh());
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_status?.busy == true) {
        unawaited(_refresh());
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _client.close();
    super.dispose();
  }

  Uri? get _url => ServerManagementService.urlForEndpoint(Store.tryGet(StoreKey.serverEndpoint));
  String? get _token => Store.tryGet(StoreKey.accessToken);

  Future<void> _refresh() async {
    if (_loading || !ref.read(authProvider).isAdmin) {
      return;
    }
    final url = _url;
    final token = _token;
    if (url == null || token == null || token.isEmpty) {
      if (mounted) {
        setState(() => _error = 'Connect to your HTTPS server as an administrator.');
      }
      return;
    }
    setState(() => _loading = true);
    try {
      final status = await _service.read(url, token);
      if (mounted) {
        setState(() {
          _status = status;
          _error = null;
        });
      }
    } on ServerManagementException catch (error) {
      if (mounted) {
        setState(() => _error = error.message);
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<bool> _confirm(String title, String detail) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(detail),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Continue')),
          ],
        ),
      ) ??
      false;

  Future<void> _act(ServerManagementAction action, String title, String detail) async {
    final url = _url;
    final token = _token;
    if (_acting || url == null || token == null || !await _confirm(title, detail)) {
      return;
    }
    setState(() => _acting = true);
    try {
      await _service.act(url, token, action);
      await _refresh();
    } on ServerManagementException catch (error) {
      if (mounted) {
        context.scaffoldMessenger.showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) {
        setState(() => _acting = false);
      }
    }
  }

  Future<void> _chooseBackupDrive(ServerManagementStatus status) async {
    final choices = status.disks.where((disk) => disk.canUseForBackup).toList();
    if (choices.isEmpty) {
      return;
    }
    final root = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Backup drive'),
              subtitle: Text('Choose another drive, not the photo library drive.'),
            ),
            for (final disk in choices)
              ListTile(
                leading: Icon(disk.isBackup ? Icons.check_circle_rounded : Icons.sd_storage_outlined),
                title: Text('${disk.root} ${disk.name}'),
                subtitle: Text('${formatHumanReadableBytes(disk.free, 1)} free'),
                onTap: () => Navigator.pop(context, disk.root),
              ),
          ],
        ),
      ),
    );
    if (root == null || root == status.backupDestination || !mounted) {
      return;
    }
    if (!await _confirm(
      'Use $root for backups?',
      'This changes only the destination for future backups. Existing photos and backups will not be moved or deleted.',
    )) {
      return;
    }
    final url = _url;
    final token = _token;
    if (url == null || token == null) {
      return;
    }
    setState(() => _acting = true);
    try {
      await _service.selectBackupDrive(url, token, root);
      await _refresh();
    } on ServerManagementException catch (error) {
      if (mounted) {
        context.scaffoldMessenger.showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) {
        setState(() => _acting = false);
      }
    }
  }

  String _date(String utc) {
    final value = DateTime.tryParse(utc);
    if (value == null) {
      return 'Not yet';
    }
    final local = value.toLocal();
    return '${local.day}/${local.month}/${local.year} · ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(authProvider).isAdmin) {
      return const Center(child: Text('Administrator access is required to manage the PC.'));
    }
    final status = _status;
    final working = _acting || status?.busy == true;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 80),
        children: [
          ListTile(
            leading: Icon(
              status?.serverOnline == true ? Icons.check_circle_rounded : Icons.dns_outlined,
              color: status?.serverOnline == true ? context.colorScheme.primary : context.colorScheme.error,
            ),
            title: Text(
              status == null
                  ? 'Windows server'
                  : status.serverOnline
                  ? 'Server online'
                  : 'Server unavailable',
            ),
            subtitle: Text(status == null ? 'Checking connection…' : 'Windows manager ${status.version}'),
            trailing: _loading
                ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                : IconButton(tooltip: 'Refresh', onPressed: _refresh, icon: const Icon(Icons.refresh_rounded)),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              child: Text(_error!, style: TextStyle(color: context.colorScheme.error)),
            ),
          if (status != null) ...[
            if (status.operation.isNotEmpty || status.progress.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.sync_rounded),
                title: Text(status.operation == 'backup' ? 'Creating full backup' : 'Working on the PC'),
                subtitle: Text(status.progress.isEmpty ? 'Please wait…' : status.progress),
              ),
            if (status.error.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.error_outline_rounded),
                title: const Text('Last operation'),
                subtitle: Text(status.error),
              ),
            const Divider(height: 30),
            const _SectionTitle('Storage'),
            for (final disk in status.disks)
              ListTile(
                leading: Icon(disk.isLibrary ? Icons.photo_library_outlined : Icons.storage_outlined),
                title: Text('Drive ${disk.root}${disk.name.isEmpty ? '' : ' · ${disk.name}'}'),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${formatHumanReadableBytes(disk.free, 1)} free of ${formatHumanReadableBytes(disk.total, 1)}'
                      '${disk.isLibrary
                          ? ' · Photo library'
                          : disk.isBackup
                          ? ' · Backup destination'
                          : ''}',
                    ),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: disk.total <= 0 ? 0 : ((disk.total - disk.free) / disk.total).clamp(0, 1),
                    ),
                  ],
                ),
              ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('Backup destination'),
              subtitle: Text(status.backupConfigured ? status.backupDestination : 'Not selected'),
              trailing: const Icon(Icons.chevron_right_rounded),
              enabled: !working && status.disks.any((disk) => disk.canUseForBackup),
              onTap: () => _chooseBackupDrive(status),
            ),
            const Divider(height: 30),
            const _SectionTitle('Protection'),
            ListTile(
              leading: Icon(status.backupPresent ? Icons.verified_outlined : Icons.backup_outlined),
              title: Text(status.backupPresent ? 'Full backup available' : 'No complete backup available'),
              subtitle: Text(
                status.backupPresent
                    ? 'Last completed ${_date(status.backupCompletedUtc)}'
                    : 'A database snapshot alone is not a photo backup.',
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: status.backupRunning
                          ? () => _act(
                              ServerManagementAction.cancelBackup,
                              'Stop backup?',
                              'Files already copied will be kept, but this backup will not be marked complete.',
                            )
                          : working || !status.backupConfigured
                          ? null
                          : () => _act(
                              ServerManagementAction.startBackup,
                              'Create full backup?',
                              'The PC will copy your photos, videos and database to the selected drive. Nothing will be deleted.',
                            ),
                      icon: Icon(status.backupRunning ? Icons.stop_rounded : Icons.backup_rounded),
                      label: Text(status.backupRunning ? 'Stop backup' : 'Back up now'),
                    ),
                  ),
                ],
              ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.event_repeat_rounded),
              title: const Text('Weekly backup'),
              subtitle: Text(
                status.weeklyBackupEnabled
                    ? 'Next check ${_date(status.nextBackupUtc)}'
                    : 'Runs when the PC and manager are on.',
              ),
              value: status.weeklyBackupEnabled,
              onChanged: working || !status.backupConfigured
                  ? null
                  : (enabled) => _act(
                      enabled ? ServerManagementAction.enableWeeklyBackup : ServerManagementAction.disableWeeklyBackup,
                      enabled ? 'Enable weekly backup?' : 'Disable weekly backup?',
                      enabled
                          ? 'Windows startup will also be enabled so scheduled backups can run.'
                          : 'This will not remove any existing backup.',
                    ),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Create database snapshot'),
              subtitle: const Text('Saves album and account metadata on the PC; it does not copy photos.'),
              enabled: !working,
              onTap: () => _act(
                ServerManagementAction.createSnapshot,
                'Create a database snapshot?',
                'This is for recovery of metadata only, not a full photo backup.',
              ),
            ),
            const Divider(height: 30),
            const _SectionTitle('Windows manager'),
            SwitchListTile(
              secondary: const Icon(Icons.power_settings_new_rounded),
              title: const Text('Start with Windows'),
              subtitle: const Text('Keeps the server and scheduled backups supervised after sign-in.'),
              value: status.startupEnabled,
              onChanged: working || !status.startupKnown
                  ? null
                  : (enabled) => _act(
                      enabled ? ServerManagementAction.enableStartup : ServerManagementAction.disableStartup,
                      enabled ? 'Start with Windows?' : 'Stop starting with Windows?',
                      enabled
                          ? 'The manager will launch automatically at sign-in.'
                          : 'The photo server will not be stopped now. Disable weekly backup first if it is active.',
                    ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 14, 18, 0),
              child: Text(
                'Physical disk and RAID changes must be confirmed on the PC. They cannot be applied remotely.',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
    child: Text(text, style: context.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
  );
}
