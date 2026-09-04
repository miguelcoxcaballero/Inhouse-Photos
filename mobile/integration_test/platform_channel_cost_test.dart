// How fast the platform channel can carry the grid's per-cell requests.
//
// Every cell in the zoomed-out grid is one round trip into native code to fetch
// and decode a photo. Filling one dense screen measured flat at roughly two
// hundred cells a second no matter how many the client asked for at once, and
// per-cell latency rose in exact step with the extra parallelism - a queue with
// a fixed service rate somewhere past the channel. Doubling the native decode
// pool did not move it, and turning pixels into images was measured with three
// times the headroom needed, so this checks what is left: the channel itself.
//
// `cancelRequest` for an id that was never issued does nothing on the native
// side, so what it times is the round trip and nothing else.
// ignore_for_file: avoid_print

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('platform channel round trips per second', (tester) async {
    await tester.runAsync(() async {
      // Warm the channel so first-call setup is not counted.
      await remoteImageApi.cancelRequest(1 << 40);

      const calls = 800;
      for (final inFlight in [1, 8, 32]) {
        final clock = Stopwatch()..start();
        var issued = 0;
        while (issued < calls) {
          final batch = <Future<void>>[];
          for (var i = 0; i < inFlight && issued + i < calls; i++) {
            batch.add(remoteImageApi.cancelRequest((1 << 40) + issued + i));
          }
          await Future.wait(batch);
          issued += batch.length;
        }
        clock.stop();
        final perSecond = calls * 1000 / clock.elapsedMilliseconds;
        print(
          'CHANCOST $calls round trips, $inFlight at a time: ${clock.elapsedMilliseconds} ms '
          '(${perSecond.toStringAsFixed(0)}/sec, ${(clock.elapsedMicroseconds / calls / 1000).toStringAsFixed(2)} ms each)',
        );
      }
    });
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
