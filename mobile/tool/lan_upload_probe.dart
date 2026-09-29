import 'dart:convert';
import 'dart:io';

import 'package:immich_mobile/repositories/lan_upload_route.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length > 2) {
    stderr.writeln('Usage: dart run tool/lan_upload_probe.dart https://your-domain.example [192.168.1.10]');
    exitCode = 2;
    return;
  }
  final origin = LanUploadRouteResolver.publicOriginForApiEndpoint(args[0]);
  if (origin == null) {
    stderr.writeln('The server endpoint must be an HTTPS URL');
    exitCode = 2;
    return;
  }
  final route = args.length == 1
      ? await const LanUploadRouteResolver().resolve(origin)
      : LanUploadRoute.fromHint(origin, {'origin': origin.toString(), 'ipv4': args[1], 'port': 443});
  if (route == null) {
    stderr.writeln('Not a valid HTTPS origin/private LAN address');
    exitCode = 2;
    return;
  }
  final client = route.createClient();
  try {
    final clock = Stopwatch()..start();
    final response = await client.get(origin.resolve('/api/server/ping')).timeout(const Duration(seconds: 4));
    final body = jsonDecode(response.body);
    if (response.statusCode != 200 || body is! Map || body['res'] != 'pong') {
      throw StateError('LAN server did not answer the expected ping');
    }
    stdout.writeln('Verified HTTPS to ${origin.host} via ${route.address.address} in ${clock.elapsedMilliseconds} ms');
  } finally {
    client.close();
  }
}
