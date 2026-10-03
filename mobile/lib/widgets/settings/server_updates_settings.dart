import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/services/manager_update.service.dart';
import 'package:immich_mobile/services/runtime_update.service.dart';
import 'package:immich_mobile/services/system_update.service.dart';

class ServerUpdatesSettings extends StatefulWidget {
  const ServerUpdatesSettings({
    super.key,
    required this.managerUpdateService,
    required this.runtimeUpdateService,
    required this.systemUpdateService,
    required this.busy,
    required this.refreshGeneration,
    required this.onUpdatingChanged,
    required this.onUpdated,
  });

  final ManagerUpdateService managerUpdateService;
  final RuntimeUpdateService runtimeUpdateService;
  final SystemUpdateService systemUpdateService;
  final bool busy;
  final int refreshGeneration;
  final ValueChanged<bool> onUpdatingChanged;
  final VoidCallback onUpdated;

  @override
  State<ServerUpdatesSettings> createState() => _ServerUpdatesSettingsState();
}

class _ServerUpdatesSettingsState extends State<ServerUpdatesSettings> with WidgetsBindingObserver {
  static const _publicVersion = '3.1.96';
  static const _repairInstaller =
      'https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/server-v3.1.96/Inhouse-Photos-Server-Setup.exe';
  SystemUpdateStatus? _status;
  ManagerUpdateStatus? _legacyStatus;
  RuntimeUpdateStatus? _legacyRuntime;
  ({String endpoint, String token})? _session;
  bool _legacy = false;
  bool _checking = false;
  bool _reachable = false;
  bool _authenticationError = false;
  bool _connectionError = false;
  bool _requestPending = false;
  bool _foreground = true;
  String? _target;
  DateTime? _requestStartedAt;
  DateTime? _lastSuccessfulCheck;
  int _epoch = 0;
  Timer? _poll;

  String? get _token => Store.tryGet(StoreKey.accessToken);
  String? get _endpoint => Store.tryGet(StoreKey.serverEndpoint);
  bool get _localRepair =>
      _status?.requiresLocalRecovery == true || (_legacy && _legacyRuntime?.recoveryRequired == true);
  bool get _recovering => _status?.recoveryRequired == true || (_legacy && _legacyRuntime?.recoveryRequired == true);
  bool get _active =>
      _requestPending || _activePhase(_status?.phase) || (_legacy && _activePhase(_legacyStatus?.phase));
  bool get _blocking => _active || _recovering;

  String _text(String en, String es) => Localizations.localeOf(context).languageCode == 'es' ? es : en;
  static bool _activePhase(String? phase) =>
      const {'downloading', 'verifying', 'waiting', 'installing', 'restarting'}.contains(phase);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onUpdatingChanged(_blocking);
      }
    });
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(ServerUpdatesSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshGeneration != oldWidget.refreshGeneration ||
        _session?.endpoint != _endpoint ||
        _session?.token != _token) {
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

  bool _sameSession(String endpoint, String token, int epoch) =>
      mounted && epoch == _epoch && _endpoint == endpoint && _token == token;

  void _notifyBlocking(bool previous) {
    if (previous != _blocking) {
      // didUpdateWidget can discover an account change while the parent is
      // building. Notify after that frame rather than mutate its state now.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.onUpdatingChanged(_blocking);
        }
      });
    }
  }

  Future<void> _refresh() async {
    if (!mounted || !_foreground) {
      return;
    }
    final endpoint = _endpoint;
    final token = _token;
    final url = SystemUpdateService.urlForEndpoint(endpoint);
    if (endpoint == null || token == null || token.isEmpty || url == null) {
      return;
    }
    final session = (endpoint: endpoint, token: token);
    if (_session != session) {
      final wasBlocking = _blocking;
      setState(() {
        _epoch++;
        _session = session;
        _status = null;
        _legacyStatus = null;
        _legacyRuntime = null;
        _legacy = false;
        _checking = false;
        _reachable = false;
        _authenticationError = false;
        _connectionError = false;
        _requestPending = false;
        _target = null;
        _requestStartedAt = null;
        _lastSuccessfulCheck = null;
      });
      _notifyBlocking(wasBlocking);
    }
    if (_checking) {
      return;
    }
    final epoch = _epoch;
    _poll?.cancel();
    setState(() => _checking = true);
    try {
      final status = await widget.systemUpdateService.check(url, token);
      if (!_sameSession(endpoint, token, epoch)) {
        return;
      }
      final wasBlocking = _blocking;
      var completed = false;
      setState(() {
        _status = status;
        _legacy = false;
        _legacyStatus = null;
        _legacyRuntime = null;
        _reachable = true;
        _authenticationError = false;
        _connectionError = false;
        _lastSuccessfulCheck = DateTime.now();
        if (status.phase == 'error') {
          _requestPending = false;
          _target = null;
        } else if (_activePhase(status.phase)) {
          _requestPending = true;
          _requestStartedAt ??= DateTime.now();
          _target ??= status.latestVersion;
        } else if (_requestPending &&
            (status.phase == 'idle' || status.phase == 'completed') &&
            status.currentVersion == _target) {
          _requestPending = false;
          _target = null;
          completed = true;
        } else if (_requestPending &&
            _requestStartedAt != null &&
            DateTime.now().difference(_requestStartedAt!) > const Duration(seconds: 30)) {
          // A successful receipt alone is not an installed update. If the PC
          // keeps reporting no active work and the old version, offer another
          // deliberate attempt instead of displaying Pending indefinitely.
          _requestPending = false;
          _target = null;
        }
      });
      _notifyBlocking(wasBlocking);
      if (completed) {
        widget.onUpdated();
      }
    } on SystemUpdateException catch (error) {
      if (!_sameSession(endpoint, token, epoch)) {
        return;
      }
      if (error.unsupported) {
        await _checkLegacy(endpoint, token, epoch);
      } else {
        _recordConnectionError(error.authentication);
      }
    } finally {
      if (_sameSession(endpoint, token, epoch)) {
        setState(() => _checking = false);
        if (_foreground && !_authenticationError) {
          _poll = Timer(Duration(seconds: _active ? 3 : 15), () => unawaited(_refresh()));
        }
      } else if (mounted && epoch == _epoch) {
        setState(() => _checking = false);
        unawaited(_refresh());
      }
    }
  }

  Future<void> _checkLegacy(String endpoint, String token, int epoch) async {
    try {
      final manager = await widget.managerUpdateService.check(ManagerUpdateService.urlForEndpoint(endpoint)!, token);
      RuntimeUpdateStatus? runtime;
      try {
        runtime = await widget.runtimeUpdateService.check(RuntimeUpdateService.urlForEndpoint(endpoint)!, token);
      } on RuntimeUpdateException {
        // 1.2.16 has no runtime endpoint. Its existing installer update still
        // provides the compatibility path to the single product update.
      }
      if (!_sameSession(endpoint, token, epoch)) {
        return;
      }
      final wasBlocking = _blocking;
      setState(() {
        _legacy = true;
        _status = null;
        _legacyStatus = manager;
        _legacyRuntime = runtime;
        _reachable = true;
        _authenticationError = false;
        _connectionError = false;
        _lastSuccessfulCheck = DateTime.now();
        if (manager.phase == 'error' || runtime?.recoveryRequired == true) {
          _requestPending = false;
          _target = null;
        } else if (_activePhase(manager.phase)) {
          _requestPending = true;
          _requestStartedAt ??= DateTime.now();
          _target ??= _publicVersion;
        } else if (_requestPending &&
            _requestStartedAt != null &&
            DateTime.now().difference(_requestStartedAt!) > const Duration(minutes: 2)) {
          _requestPending = false;
          _target = null;
        }
      });
      _notifyBlocking(wasBlocking);
    } on ManagerUpdateException {
      if (_sameSession(endpoint, token, epoch)) {
        _recordConnectionError(false);
      }
    }
  }

  void _recordConnectionError(bool authentication) {
    final wasBlocking = _blocking;
    setState(() {
      _reachable = false;
      _connectionError = true;
      _authenticationError = authentication;
      if (authentication ||
          (_requestPending &&
              _lastSuccessfulCheck != null &&
              DateTime.now().difference(_lastSuccessfulCheck!) > const Duration(minutes: 2))) {
        _requestPending = false;
      }
    });
    _notifyBlocking(wasBlocking);
  }

  Future<void> _showPcRepair() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_text('Finish the update on your PC', 'Completa la actualización en el PC')),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _text(
                  'Your current PC installation has an interrupted update that cannot be repaired from the phone. '
                      'On the PC, first open the tray menu and choose “Salir del gestor” to close Inhouse Photos. '
                      'Then download and run this Inhouse Photos installer once. '
                      'It preserves your photos, accounts and queued processing. Then return here; future updates use this button.',
                  'La instalación del PC tiene una actualización interrumpida que no se puede reparar desde el móvil. '
                      'En el PC, abre primero el menú del icono de la bandeja y elige «Salir del gestor» para cerrar Inhouse Photos. '
                      'Después descarga y ejecuta este instalador una vez en el PC. '
                      'Conserva las fotos, las cuentas y el procesamiento pendiente. Después vuelve aquí; las próximas actualizaciones usan este botón.',
                ),
              ),
              const SizedBox(height: 12),
              const SelectableText(_repairInstaller),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(const ClipboardData(text: _repairInstaller)),
            child: Text(_text('Copy PC download link', 'Copiar enlace para el PC')),
          ),
          FilledButton(onPressed: () => Navigator.pop(context), child: Text(_text('Close', 'Cerrar'))),
        ],
      ),
    );
  }

  Future<void> _update() async {
    if (_active || _checking || widget.busy || _status?.busy == true || _authenticationError) {
      return;
    }
    if (!_reachable) {
      await _refresh();
    }
    if (!mounted || !_reachable || _active || widget.busy || _status?.busy == true) {
      return;
    }
    if (_localRepair) {
      return _showPcRepair();
    }
    if (!_legacy && _status?.available != true) {
      await _refresh();
      return;
    }
    final endpoint = _endpoint;
    final token = _token;
    final epoch = _epoch;
    if (endpoint == null || token == null || (!_legacy && _status?.available != true)) {
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_text('Update Inhouse Photos?', '¿Actualizar Inhouse Photos?')),
        content: Text(
          _text(
            'The PC installs the update and the photo server briefly restarts. Photos, albums, accounts and queued processing are preserved. '
                'Once started, it continues on the PC even if you disconnect the phone.',
            'El PC instala la actualización y el servidor de fotos se reinicia brevemente. Se conservan las fotos, los álbumes, las cuentas y el procesamiento pendiente. '
                'Una vez iniciada, continúa en el PC aunque desconectes el móvil.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(_text('Cancel', 'Cancelar'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(_text('Update', 'Actualizar'))),
        ],
      ),
    );
    if (approved != true ||
        !_sameSession(endpoint, token, epoch) ||
        _active ||
        widget.busy ||
        _status?.busy == true ||
        _authenticationError) {
      return;
    }
    final wasBlocking = _blocking;
    setState(() {
      _requestPending = true;
      _requestStartedAt = DateTime.now();
      _target = _legacy ? _publicVersion : _status!.latestVersion;
      _connectionError = false;
    });
    _notifyBlocking(wasBlocking);
    try {
      if (_legacy) {
        await widget.managerUpdateService.start(ManagerUpdateService.urlForEndpoint(endpoint)!, token);
      } else {
        await widget.systemUpdateService.start(SystemUpdateService.urlForEndpoint(endpoint)!, token);
      }
    } catch (error) {
      if (_sameSession(endpoint, token, epoch)) {
        // A lost response can still have started installation. Retain the
        // receipt expectation until a status read reports the actual outcome.
        final uncertain =
            (error is SystemUpdateException && error.uncertain) || (error is ManagerUpdateException && error.uncertain);
        if (!uncertain) {
          final wasBlocking = _blocking;
          setState(() => _requestPending = false);
          _notifyBlocking(wasBlocking);
        }
        _recordConnectionError(error is SystemUpdateException && error.authentication);
      }
    }
    if (_sameSession(endpoint, token, epoch)) {
      unawaited(_refresh());
    }
  }

  String get _description {
    if (_authenticationError) {
      return _text(
        'Sign in again as an administrator to update.',
        'Vuelve a iniciar sesión como administrador para actualizar.',
      );
    }
    if (_localRepair) {
      return _text(
        'This PC needs a one-time repair. Tap Update for instructions.',
        'Este PC necesita una reparación inicial. Pulsa Actualizar para ver cómo.',
      );
    }
    if (_connectionError) {
      return _active
          ? _text('Reconnecting to your PC…', 'Reconectando con el PC…')
          : _text(
              'Could not check the PC. Tap Update to reconnect.',
              'No se pudo comprobar el PC. Pulsa Actualizar para reconectar.',
            );
    }
    if (_status?.busy == true && !_active) {
      return _text(
        'The PC is finishing another operation. Update when it completes.',
        'El PC está terminando otra tarea. Actualiza cuando termine.',
      );
    }
    final phase = _legacy ? _legacyStatus?.phase : _status?.phase;
    final progress = _legacy ? _legacyStatus?.progress : _status?.progress;
    if (_active) {
      return switch (phase) {
        'downloading' => _text(
          'Downloading update on your PC · $progress%',
          'Descargando la actualización en el PC · $progress%',
        ),
        'verifying' => _text('Checking the update…', 'Comprobando la actualización…'),
        'waiting' => _text(
          'Finishing current processing before the restart…',
          'Terminando el procesamiento actual antes de reiniciar…',
        ),
        'installing' => _text('Installing Inhouse Photos…', 'Instalando Inhouse Photos…'),
        'restarting' => _text('Restarting Inhouse Photos…', 'Reiniciando Inhouse Photos…'),
        _ => _text('Updating Inhouse Photos…', 'Actualizando Inhouse Photos…'),
      };
    }
    if (_status?.phase == 'error' || _legacyStatus?.phase == 'error') {
      return _text(
        'The update did not finish. Tap Update to resume safely.',
        'La actualización no terminó. Pulsa Actualizar para continuar de forma segura.',
      );
    }
    if (_legacy || _status?.available == true) {
      final version = _legacy ? _publicVersion : _status!.latestVersion;
      return _text('Version $version available', 'Versión $version disponible');
    }
    if (_status == null) {
      return _text('Checking for updates…', 'Buscando actualizaciones…');
    }
    if (_status!.currentVersion.isEmpty || _status!.currentVersion != _status!.latestVersion) {
      return _text(
        'Installation not confirmed. Tap Update to check again.',
        'Instalación sin confirmar. Pulsa Actualizar para comprobarla.',
      );
    }
    final version = _status!.currentVersion;
    return _text('Version $version · Up to date', 'Versión $version · Actualizado');
  }

  @override
  Widget build(BuildContext context) {
    final phase = _legacy ? _legacyStatus?.phase : _status?.phase;
    final progress = _legacy ? _legacyStatus?.progress : _status?.progress;
    final canUpdate =
        !_checking &&
        !_active &&
        !widget.busy &&
        _status?.busy != true &&
        !_authenticationError &&
        (_localRepair ||
            _legacy ||
            _status?.available == true ||
            !_reachable ||
            _status?.currentVersion != _status?.latestVersion ||
            _status?.currentVersion == '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: const Icon(Icons.system_update_alt_rounded),
          title: const Text('Inhouse Photos'),
          subtitle: Text(_description),
          trailing: _checking && !_active
              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : null,
        ),
        if (_active)
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 18, 8),
            child: LinearProgressIndicator(value: phase == 'downloading' ? (progress ?? 0) / 100 : null),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(72, 0, 18, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonal(
              onPressed: canUpdate ? _update : null,
              child: Text(_text('Update', 'Actualizar')),
            ),
          ),
        ),
      ],
    );
  }
}
