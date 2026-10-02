import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/backup/drift_backup.provider.dart';
import 'package:immich_mobile/repositories/lan_upload_route.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/utils/upload_speed_calculator.dart';

/// The selected, TLS-verified upload path, not the charging-cable state.
/// Its small timer never rebuilds the upload list or launches a speed test.
class UploadConnectionIndicator extends ConsumerStatefulWidget {
  const UploadConnectionIndicator({super.key, this.readBytesPerSecond});

  final double? Function()? readBytesPerSecond;

  @override
  ConsumerState<UploadConnectionIndicator> createState() => _UploadConnectionIndicatorState();
}

class _UploadConnectionIndicatorState extends ConsumerState<UploadConnectionIndicator> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String text(BuildContext context, String en, String es) =>
      Localizations.localeOf(context).languageCode == 'es' ? es : en;

  double? get rate => widget.readBytesPerSecond != null
      ? widget.readBytesPerSecond!()
      : ref.read(driftBackupProvider.notifier).currentUploadBytesPerSecond;

  String routeLabel(BuildContext context, LanUploadRoute? route) => route?.isUsb == true
      ? text(context, 'USB cable', 'Cable USB')
      : route != null
      ? text(context, 'Local Wi-Fi', 'Wi-Fi local')
      : 'Internet';

  @override
  Widget build(BuildContext context) {
    final route = ref.watch(activeUploadRouteProvider);
    final currentRate = rate;
    final label = routeLabel(context, route);
    final speed = currentRate == null
        ? text(context, 'Idle', 'En reposo')
        : '↑ ${formatAggregateUploadSpeed(currentRate)}';
    final icon = route?.isUsb == true
        ? Icons.cable_rounded
        : route != null
        ? Icons.lan_rounded
        : Icons.public_rounded;
    final measured = currentRate == null ? '' : ' · ${(currentRate * 8 / 1000000).toStringAsFixed(1)} Mb/s';
    return Tooltip(
      message: '$label · $speed$measured',
      child: Semantics(
        label: '$label, $speed',
        button: true,
        child: InkWell(
          onTap: () => _showConnection(context),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.only(left: 8, right: 16),
            child: SizedBox(
              width: 118,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 140),
                        child: Icon(icon, key: ValueKey(icon), size: 15, color: Theme.of(context).colorScheme.primary),
                      ),
                      const SizedBox(width: 5),
                      Flexible(child: Text(label, maxLines: 1, style: Theme.of(context).textTheme.labelSmall)),
                    ],
                  ),
                  Text(
                    speed,
                    maxLines: 1,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showConnection(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      final route = ref.read(activeUploadRouteProvider);
      final link = route?.linkMbps;
      final isIPhone = Theme.of(context).platform == TargetPlatform.iOS;
      final currentRate = rate;
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                text(context, 'Server connection', 'Conexión con el servidor'),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              Text(routeLabel(context, route), style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                currentRate == null
                    ? text(
                        context,
                        'Speed is measured while uploading, not estimated.',
                        'La velocidad se mide al subir archivos, no se estima.',
                      )
                    : '${formatAggregateUploadSpeed(currentRate)} · ${(currentRate * 8 / 1000000).toStringAsFixed(1)} Mb/s',
              ),
              if (link != null && route?.isUsb != true) ...[
                const SizedBox(height: 12),
                Text(text(context, 'PC network link: $link Mb/s', 'Enlace de red del PC: $link Mb/s')),
                if (link <= 100)
                  Text(
                    text(
                      context,
                      'For faster Wi-Fi uploads, connect the PC to a Gigabit port with a suitable Ethernet cable. Software cannot exceed this physical link.',
                      'Para subir más rápido por Wi-Fi, conecta el PC a un puerto Gigabit con un cable Ethernet adecuado. El software no puede superar este enlace físico.',
                    ),
                  ),
              ],
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 12),
              Text(text(context, 'Upload by cable', 'Subir por cable'), style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                text(
                  context,
                  '1. Connect the phone to the server PC using a USB data cable.',
                  '1. Conecta el móvil al PC del servidor con un cable USB de datos.',
                ),
              ),
              const SizedBox(height: 10),
              Text(
                isIPhone
                    ? text(
                        context,
                        '2. Enable Personal Hotspot and trust this PC. Windows needs Apple Devices or iTunes.',
                        '2. Activa Punto de acceso personal y confía en este PC. Windows necesita Dispositivos Apple o iTunes.',
                      )
                    : text(
                        context,
                        '2. Enable USB tethering in Android Settings → Hotspot & tethering.',
                        '2. Activa Compartir conexión por USB en Ajustes de Android → Zona Wi-Fi y compartir conexión.',
                      ),
              ),
              const SizedBox(height: 10),
              Text(
                text(
                  context,
                  '3. In the Windows server app, choose Prepare USB to keep the PC’s Internet on Ethernet. Keep Inhouse Photos open on the phone.',
                  '3. En el programa del servidor de Windows, pulsa Preparar USB para mantener Internet por Ethernet. Mantén Inhouse Photos abierta en el móvil.',
                ),
              ),
              const SizedBox(height: 12),
              Text(
                text(
                  context,
                  'The cable icon appears only after the app verifies the server over USB. Wi-Fi or Internet remains the fallback. Charging-only cables cannot transfer photos. Keep Wi-Fi on for initial discovery; hotspot use can incur mobile data charges.',
                  'El icono de cable aparece solo tras verificar el servidor por USB. Wi-Fi o Internet quedan como alternativas. Los cables de solo carga no transfieren fotos. Mantén Wi-Fi activo para la primera detección; compartir conexión puede consumir datos móviles.',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    },
  );
}
