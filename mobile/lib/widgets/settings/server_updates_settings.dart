import 'dart:async';

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/services/manager_update.service.dart';
import 'package:immich_mobile/services/runtime_update.service.dart';

class ServerUpdatesSettings extends StatefulWidget {
  const ServerUpdatesSettings({
    super.key,
    required this.managerUpdateService,
    required this.runtimeUpdateService,
    required this.managerVersion,
    required this.busy,
    required this.refreshGeneration,
    required this.onUpdatingChanged,
    required this.onUpdated,
  });

  final ManagerUpdateService managerUpdateService;
  final RuntimeUpdateService runtimeUpdateService;
  final String? managerVersion;
  final bool busy;
  final int refreshGeneration;
  final ValueChanged<bool> onUpdatingChanged;
  final VoidCallback onUpdated;

  @override
  State<ServerUpdatesSettings> createState() => _ServerUpdatesSettingsState();
}

class _ServerUpdatesSettingsState extends State<ServerUpdatesSettings> with WidgetsBindingObserver {
  ManagerUpdateStatus? _manager;
  RuntimeUpdateStatus? _runtime;
  String? _managerMessage;
  String? _runtimeMessage;
  String? _managerTarget;
  String? _runtimeTarget;
  bool _checking = false;
  bool _managerUpdating = false;
  bool _runtimeUpdating = false;
  bool _runtimeUnsupported = false;
  bool _managerReachable = false;
  bool _runtimeReachable = false;
  bool _foreground = true;
  Timer? _poll;

  bool get _updating => _managerUpdating || _runtimeUpdating;
  bool get _blocking => _updating || _runtime?.recoveryRequired == true;
  String? get _token => Store.tryGet(StoreKey.accessToken);
  String? get _endpoint => Store.tryGet(StoreKey.serverEndpoint);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(ServerUpdatesSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshGeneration != oldWidget.refreshGeneration) {
      unawaited(_refresh());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _poll?.cancel();
    if (_foreground) {
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  static bool _active(String phase) =>
      const {'downloading', 'verifying', 'waiting', 'installing', 'restarting'}.contains(phase);

  void _notifyUpdating(bool previous) {
    if (previous != _blocking) {
      widget.onUpdatingChanged(_blocking);
    }
  }

  Future<void> _refresh() async {
    if (!mounted || !_foreground || _checking) {
      return;
    }
    final managerUrl = ManagerUpdateService.urlForEndpoint(_endpoint);
    final runtimeUrl = RuntimeUpdateService.urlForEndpoint(_endpoint);
    final token = _token;
    if (managerUrl == null || runtimeUrl == null || token == null || token.isEmpty) {
      return;
    }
    _poll?.cancel();
    setState(() => _checking = true);
    await Future.wait([_checkManager(managerUrl, token), _checkRuntime(runtimeUrl, token)]);
    if (mounted) {
      setState(() => _checking = false);
      if (_foreground) {
        _poll = Timer(Duration(seconds: _updating ? 3 : 15), () => unawaited(_refresh()));
      }
    }
  }

  Future<void> _checkManager(Uri url, String token) async {
    try {
      final status = await widget.managerUpdateService.check(url, token);
      if (!mounted) {
        return;
      }
      final previous = _blocking;
      var completed = false;
      setState(() {
        _manager = status;
        _managerReachable = true;
        _managerMessage = status.error.isEmpty ? null : status.error;
        if (status.phase == 'error') {
          _managerUpdating = false;
          _managerTarget = null;
          _managerMessage = status.error.isEmpty ? 'The Windows manager update failed. Try again.' : status.error;
        } else if (_active(status.phase)) {
          _managerUpdating = true;
          _managerTarget ??= status.latestVersion;
        } else if (_managerUpdating &&
            (status.phase == 'idle' || status.phase == 'completed') &&
            status.currentVersion == _managerTarget) {
          _managerUpdating = false;
          _managerTarget = null;
          completed = true;
        }
      });
      _notifyUpdating(previous);
      if (completed) {
        widget.onUpdated();
      }
    } on ManagerUpdateException catch (error) {
      if (mounted) {
        setState(() {
          _managerReachable = false;
          _managerMessage = _managerUpdating ? 'Reconnecting to the Windows manager update…' : error.message;
        });
      }
    }
  }

  Future<void> _checkRuntime(Uri url, String token) async {
    try {
      final status = await widget.runtimeUpdateService.check(url, token);
      if (!mounted) {
        return;
      }
      final previous = _blocking;
      var completed = false;
      setState(() {
        _runtime = status;
        _runtimeReachable = true;
        _runtimeUnsupported = false;
        _runtimeMessage = status.error.isEmpty ? null : status.error;
        if (status.phase == 'error') {
          _runtimeUpdating = false;
          _runtimeTarget = null;
          _runtimeMessage = status.error.isEmpty ? 'The server engine update failed. Try again.' : status.error;
        } else if (_active(status.phase)) {
          _runtimeUpdating = true;
          _runtimeTarget ??= status.latestVersion;
        } else if (_runtimeUpdating &&
            (status.phase == 'completed' || status.phase == 'idle') &&
            status.currentVersion == _runtimeTarget) {
          _runtimeUpdating = false;
          _runtimeTarget = null;
          completed = true;
        }
      });
      _notifyUpdating(previous);
      if (completed) {
        widget.onUpdated();
      }
    } on RuntimeUpdateException catch (error) {
      if (mounted) {
        setState(() {
          _runtimeReachable = false;
          _runtimeUnsupported = error.unsupported;
          _runtimeMessage = _runtimeUpdating ? 'Reconnecting to the server engine update…' : error.message;
        });
      }
    }
  }

  Future<void> _start({required bool runtime}) async {
    final status = runtime ? _runtime : _manager;
    final url = runtime
        ? RuntimeUpdateService.urlForEndpoint(_endpoint)
        : ManagerUpdateService.urlForEndpoint(_endpoint);
    final token = _token;
    if (_updating ||
        (!runtime && _runtime?.recoveryRequired == true) ||
        widget.busy ||
        _checking ||
        !(runtime ? _runtimeReachable : _managerReachable) ||
        status?.available != true ||
        url == null ||
        token == null) {
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(runtime ? 'Update server engine?' : 'Update Windows manager?'),
        content: Text(
          runtime
              ? 'Install server engine ${status!.latestVersion} on your PC. '
                    'Uploads briefly reconnect while the engine restarts. '
                    'Photos, albums, accounts and queued processing are preserved.'
              : 'Install Windows manager ${status!.latestVersion} on your PC. '
                    'The manager restarts, then you can update the server engine from this screen.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Continue')),
        ],
      ),
    );
    if (approved != true || !mounted || _updating || widget.busy) {
      return;
    }
    final previous = _blocking;
    setState(() {
      if (runtime) {
        _runtimeUpdating = true;
        _runtimeTarget = status!.latestVersion;
        _runtimeMessage = null;
      } else {
        _managerUpdating = true;
        _managerTarget = status!.latestVersion;
        _managerMessage = null;
      }
    });
    _notifyUpdating(previous);
    try {
      if (runtime) {
        await widget.runtimeUpdateService.start(url, token);
      } else {
        await widget.managerUpdateService.start(url, token);
      }
    } catch (error) {
      if (mounted) {
        final wasUpdating = _blocking;
        setState(() {
          if (runtime) {
            _runtimeUpdating = false;
            _runtimeMessage = error.toString();
          } else {
            _managerUpdating = false;
            _managerMessage = error.toString();
          }
        });
        _notifyUpdating(wasUpdating);
      }
    }
    if (mounted) {
      // Even a lost POST response can have started the operation on the PC.
      // Read-only checks determine the outcome; do not repeat the request.
      unawaited(_refresh());
    }
  }

  String _description(ManagerUpdateStatus? status, String? message, bool updating, bool runtime) {
    if (message != null) {
      return message;
    }
    final subject = runtime ? 'server engine' : 'Windows manager';
    if (updating) {
      return switch (status?.phase) {
        'downloading' => 'Downloading $subject on your PC · ${status!.progress}%',
        'verifying' => 'Verifying the $subject update…',
        'waiting' => 'Waiting for current processing to finish… Uploaded originals stay saved.',
        'installing' => 'Installing the $subject update…',
        'restarting' => 'Restarting the $subject…',
        _ => 'Updating the $subject on your PC…',
      };
    }
    if (status == null) {
      return runtime
          ? 'Checking the installed server engine…'
          : 'Windows manager ${widget.managerVersion ?? 'version unknown'} · Checking updates…';
    }
    if (status.available) {
      return '${status.currentVersion.isEmpty ? 'Installed version unknown' : status.currentVersion} → ${status.latestVersion} available';
    }
    if (status.currentVersion.isEmpty) {
      return 'The installed $subject version could not be verified.';
    }
    if (status.latestVersion.isEmpty) {
      return 'Version ${status.currentVersion} · Update check unavailable';
    }
    if (status.currentVersion != status.latestVersion) {
      return 'Version ${status.currentVersion} · No compatible update available';
    }
    return 'Version ${status.currentVersion} · Up to date';
  }

  Widget _section({required bool runtime}) {
    final status = runtime ? _runtime : _manager;
    final updating = runtime ? _runtimeUpdating : _managerUpdating;
    final message = runtime ? _runtimeMessage : _managerMessage;
    final enabled =
        !_checking &&
        !_updating &&
        !widget.busy &&
        (runtime ? _runtimeReachable && !_runtimeUnsupported : _managerReachable && _runtime?.recoveryRequired != true);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: Icon(runtime ? Icons.memory_rounded : Icons.desktop_windows_outlined),
          title: Text(runtime ? 'Server engine updates' : 'Windows manager updates'),
          subtitle: Text(_description(status, message, updating, runtime)),
          trailing: IconButton(
            tooltip: runtime ? 'Refresh server engine updates' : 'Refresh Windows manager updates',
            onPressed: _checking ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ),
        if (updating || (_checking && status == null && message == null))
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 18, 8),
            child: LinearProgressIndicator(
              value: updating && status?.phase == 'downloading' ? status!.progress / 100 : null,
            ),
          ),
        if (status?.available == true && !updating)
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 18, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                onPressed: enabled ? () => _start(runtime: runtime) : null,
                child: Text(
                  runtime
                      ? status is RuntimeUpdateStatus && status.recoveryRequired
                            ? 'Resume server engine update'
                            : 'Update server engine'
                      : 'Update Windows manager',
                ),
              ),
            ),
          ),
        if (status?.available == true && status!.notes.isNotEmpty && !updating)
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 18, 8),
            child: Text(status.notes, maxLines: 4, overflow: TextOverflow.ellipsis),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Column(children: [_section(runtime: false), _section(runtime: true)]);
}
