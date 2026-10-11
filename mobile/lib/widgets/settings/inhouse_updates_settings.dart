// Shared updater: users default to B; A requires warning acknowledgement and slide confirmation.
// Automatic releases go to A; B publication or promotion requires an explicit user request.
// A includes A+B and offers the highest global versionCode; B includes only B.
// Edit canonical inhouse-services-updater and sync all five apps.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Host wiring only. Canonical source: github.com/miguelcoxcaballero/inhouse-services-updater.
// Sync all apps after changes. Keep a tiny changelog for every release.
class InhouseUpdatesSettings extends StatelessWidget {
  const InhouseUpdatesSettings({super.key});
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      const Text('A: cambios recientes. B: versiones revisadas.'),
      const SizedBox(height: 16),
      FilledButton.tonal(
        onPressed: () async {
          try {
            await const MethodChannel('com.inhousesoftware.photos/updates').invokeMethod<void>('openUpdater');
          } on PlatformException {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No se pudo abrir el actualizador.')));
            }
          }
        },
        child: const Text('Elegir canal y buscar actualizaciones'),
      ),
    ],
  );
}
