import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/services/server_management.service.dart';
import 'package:immich_mobile/services/manager_update.service.dart';
import 'package:immich_mobile/services/runtime_update.service.dart';
import 'package:immich_mobile/services/system_update.service.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:immich_mobile/widgets/settings/server_updates_settings.dart';

class ServerManagementSettings extends ConsumerStatefulWidget {
  const ServerManagementSettings({
    super.key,
    this.service,
    this.managerUpdateService,
    this.runtimeUpdateService,
    this.systemUpdateService,
    this.updateElapsed,
  });

  final ServerManagementService? service;
  final ManagerUpdateService? managerUpdateService;
  final RuntimeUpdateService? runtimeUpdateService;
  final SystemUpdateService? systemUpdateService;
  final Duration Function()? updateElapsed;

  @override
  ConsumerState<ServerManagementSettings> createState() => _ServerManagementSettingsState();
}

class _ServerManagementSettingsState extends ConsumerState<ServerManagementSettings> with WidgetsBindingObserver {
  http.Client? _client;
  late final ServerManagementService _service;
  late final ManagerUpdateService _managerUpdateService;
  late final RuntimeUpdateService _runtimeUpdateService;
  late final SystemUpdateService _systemUpdateService;
  ServerManagementStatus? _status;
  ServerManagementException? _error;
  bool _loading = false;
  bool _acting = false;
  bool _updating = false;
  int _refreshGeneration = 0;
  Timer? _poll;
  bool _foreground = true;
  int _failures = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client = widget.service == null ? http.Client() : null;
    _service = widget.service ?? ServerManagementService(_client!);
    _managerUpdateService = widget.managerUpdateService ?? ManagerUpdateService(_service.client);
    _runtimeUpdateService = widget.runtimeUpdateService ?? RuntimeUpdateService(_service.client);
    _systemUpdateService = widget.systemUpdateService ?? SystemUpdateService(_service.client);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _client?.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _poll?.cancel();
    if (_foreground) {
      unawaited(_refresh());
    }
  }

  void _scheduleRefresh() {
    _poll?.cancel();
    if (!mounted || !_foreground || (_error != null && !_error!.canRetry)) {
      return;
    }
    final seconds = _error != null ? (15 * _failures).clamp(15, 60) : (_status?.busy == true ? 5 : 15);
    _poll = Timer(Duration(seconds: seconds), () => unawaited(_refresh()));
  }

  Uri? get _url => ServerManagementService.urlForEndpoint(Store.tryGet(StoreKey.serverEndpoint));
  String? get _token => Store.tryGet(StoreKey.accessToken);
  String _text(String en, String es) => Localizations.localeOf(context).languageCode == 'es' ? es : en;

  Future<void> _refresh() async {
    if (!mounted || !_foreground || _loading || !ref.read(authProvider).isAdmin) {
      return;
    }
    _poll?.cancel();
    final url = _url;
    final token = _token;
    if (url == null || token == null || token.isEmpty) {
      if (mounted && _url == url && _token == token) {
        setState(() {
          _error = const ServerManagementException(
            'Connect to your HTTPS server as an administrator.',
            failure: ServerManagementFailure.authentication,
          );
        });
      }
      return;
    }
    setState(() {
      _loading = true;
      _refreshGeneration++;
    });
    try {
      final status = await _service.read(url, token);
      if (mounted && _url == url && _token == token) {
        setState(() {
          _status = status;
          _error = null;
          _failures = 0;
        });
      }
    } on ServerManagementException catch (error) {
      if (mounted && _url == url && _token == token) {
        setState(() {
          _error = error;
          _failures++;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        if (_url != url || _token != token) {
          unawaited(_refresh());
        } else {
          _scheduleRefresh();
        }
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
    if (_acting ||
        _updating ||
        _loading ||
        _error != null ||
        url == null ||
        token == null ||
        !await _confirm(title, detail) ||
        !mounted) {
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
    if (_acting || _updating || _loading || _error != null) {
      return;
    }
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
        ) ||
        !mounted) {
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
    ref.listen<bool>(authProvider.select((auth) => auth.isAdmin), (_, isAdmin) {
      if (isAdmin) {
        unawaited(_refresh());
      }
    });
    if (!ref.watch(authProvider).isAdmin) {
      return const Center(child: Text('Administrator access is required to manage the PC.'));
    }
    final status = _status;
    final unavailable = _loading || _error != null;
    final working = _acting || _updating || unavailable || status?.busy == true;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 80),
        children: [
          ListTile(
            leading: Icon(
              _error != null
                  ? Icons.cloud_off_rounded
                  : status?.serverOnline == true
                  ? Icons.check_circle_rounded
                  : Icons.dns_outlined,
              color: _error != null
                  ? context.colorScheme.error
                  : status?.serverOnline == true
                  ? context.colorScheme.primary
                  : context.colorScheme.onSurfaceVariant,
            ),
            title: Text(
              _error != null
                  ? _text('PC unavailable', 'PC no disponible')
                  : status == null
                  ? 'Windows server'
                  : status.serverOnline
                  ? 'Server online'
                  : 'Server unavailable',
            ),
            subtitle: Text(
              _loading
                  ? 'Checking connection…'
                  : _error != null
                  ? status == null
                        ? 'Connection could not be confirmed'
                        : _text(
                            'Last known status · Reconnecting to your PC',
                            'Último estado conocido · Reconectando con el PC',
                          )
                  : status == null
                  ? 'Connection not checked yet'
                  : _text('Connected to your PC', 'Conectado al PC'),
            ),
            trailing: _loading
                ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                : IconButton(tooltip: 'Refresh', onPressed: _refresh, icon: const Icon(Icons.refresh_rounded)),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              child: Text(_error!.message, style: TextStyle(color: context.colorScheme.error)),
            ),
          ServerUpdatesSettings(
            managerUpdateService: _managerUpdateService,
            runtimeUpdateService: _runtimeUpdateService,
            systemUpdateService: _systemUpdateService,
            elapsed: widget.updateElapsed,
            pcVersion: status?.version,
            busy: _acting || status?.busy == true,
            refreshGeneration: _refreshGeneration,
            onUpdatingChanged: (updating) {
              if (mounted) {
                setState(() => _updating = updating);
              }
            },
            onUpdated: () => unawaited(_refresh()),
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
                      onPressed: unavailable || _acting || _updating
                          ? null
                          : status.backupRunning
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
            _SectionTitle(_text('Startup', 'Inicio')),
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
