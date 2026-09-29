import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// A private-network socket for the *same* public HTTPS origin. The URL,
/// Host header, SNI name and normal certificate validation never change.
/// This avoids sending credentials or photos to an unauthenticated HTTP IP.
class LanUploadRoute {
  const LanUploadRoute({required this.origin, required this.address, required this.port});

  final Uri origin;
  final InternetAddress address;
  final int port;

  static LanUploadRoute? fromHint(Uri expectedOrigin, Object? document) {
    if (expectedOrigin.scheme != 'https' ||
        expectedOrigin.port != 443 ||
        (expectedOrigin.path.isNotEmpty && expectedOrigin.path != '/')) {
      return null;
    }
    if (document is! Map<String, dynamic>) {
      return null;
    }
    final hintedOrigin = Uri.tryParse(document['origin'] is String ? document['origin'] as String : '');
    final ip = InternetAddress.tryParse(document['ipv4'] is String ? document['ipv4'] as String : '');
    final port = document['port'];
    if (hintedOrigin == null ||
        hintedOrigin.scheme != 'https' ||
        hintedOrigin.host != expectedOrigin.host ||
        hintedOrigin.port != expectedOrigin.port ||
        (hintedOrigin.path.isNotEmpty && hintedOrigin.path != '/') ||
        hintedOrigin.hasQuery ||
        hintedOrigin.hasFragment ||
        ip == null ||
        ip.type != InternetAddressType.IPv4 ||
        !_isPrivateIpv4(ip) ||
        port != 443) {
      return null;
    }
    return LanUploadRoute(origin: expectedOrigin, address: ip, port: port as int);
  }

  static bool _isPrivateIpv4(InternetAddress ip) {
    final octets = ip.rawAddress;
    return octets[0] == 10 ||
        (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
        (octets[0] == 192 && octets[1] == 168);
  }

  IOClient createClient({Duration connectTimeout = const Duration(seconds: 2)}) {
    final client = HttpClient();
    client.findProxy = (_) => 'DIRECT';
    client.connectionTimeout = connectTimeout;
    client.maxConnectionsPerHost = 16;
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      if (proxyHost != null ||
          proxyPort != null ||
          uri.scheme != 'https' ||
          uri.host != origin.host ||
          uri.port != origin.port) {
        throw const SocketException('Invalid local upload destination');
      }
      final task = await Socket.startConnect(address, port);
      Socket? plainSocket;
      final secureSocket = task.socket.then((socket) async {
        plainSocket = socket;
        // SecureSocket verifies the public hostname against the server's
        // certificate. Never bypass certificate errors on a LAN connection.
        return SecureSocket.secure(socket, host: origin.host);
      });
      return ConnectionTask.fromSocket<Socket>(secureSocket, () {
        task.cancel();
        plainSocket?.destroy();
      });
    };
    return IOClient(client);
  }
}

class LanUploadRouteResolver {
  const LanUploadRouteResolver();

  Future<LanUploadRoute?> resolve(Uri origin) async {
    if (origin.scheme != 'https' || origin.port != 443 || (origin.path.isNotEmpty && origin.path != '/')) {
      return null;
    }
    final hintUrl = origin.resolve('/.well-known/inhouse-photos/lan.json');
    try {
      final response = await http
          .get(hintUrl, headers: {'Cache-Control': 'no-cache'})
          .timeout(const Duration(seconds: 3));
      if (response.statusCode != 200 || response.bodyBytes.length > 2048) {
        return null;
      }
      final route = LanUploadRoute.fromHint(origin, jsonDecode(response.body));
      if (route == null) {
        return null;
      }
      final client = route.createClient(connectTimeout: const Duration(milliseconds: 900));
      try {
        final ping = await client.get(origin.resolve('/api/server/ping')).timeout(const Duration(seconds: 2));
        final body = jsonDecode(ping.body);
        return ping.statusCode == 200 && body is Map && body['res'] == 'pong' ? route : null;
      } finally {
        client.close();
      }
    } catch (_) {
      return null;
    }
  }
}
