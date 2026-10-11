import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Host wiring only. Canonical source: github.com/miguelcoxcaballero/inhouse-services-updater.
// Sync all apps after changes. A + tiny changelog by default; B only on explicit user request.
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
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No se pudo abrir el actualizador.')));
          }
        },
        child: const Text('Elegir canal y buscar actualizaciones'),
      ),
    ],
  );
}
