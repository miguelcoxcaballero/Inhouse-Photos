import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/repositories/lan_upload_route.dart';

void main() {
  final origin = Uri.parse('https://fotos.miguelcoxcaballero.com/');

  test('accepts only a private LAN address for the current HTTPS origin', () {
    final route = LanUploadRoute.fromHint(origin, {
      'origin': 'https://fotos.miguelcoxcaballero.com',
      'ipv4': '192.168.1.237',
      'port': 443,
    });
    expect(route, isNotNull);
    expect(route!.address.address, '192.168.1.237');
  });

  test('rejects a different origin, public address and insecure endpoint', () {
    for (final hint in [
      {'origin': 'https://other.example.com', 'ipv4': '192.168.1.237', 'port': 443},
      {'origin': 'https://fotos.miguelcoxcaballero.com', 'ipv4': '8.8.8.8', 'port': 443},
      {'origin': 'https://fotos.miguelcoxcaballero.com', 'ipv4': '127.0.0.1', 'port': 443},
      {'origin': 'https://fotos.miguelcoxcaballero.com', 'ipv4': '192.168.1.237', 'port': 2283},
    ]) {
      expect(LanUploadRoute.fromHint(origin, hint), isNull);
    }
    expect(
      LanUploadRoute.fromHint(Uri.parse('http://fotos.miguelcoxcaballero.com/'), {
        'origin': 'http://fotos.miguelcoxcaballero.com',
        'ipv4': '192.168.1.237',
        'port': 443,
      }),
      isNull,
    );
  });
}
