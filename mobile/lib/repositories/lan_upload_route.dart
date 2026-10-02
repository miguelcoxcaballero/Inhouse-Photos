import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path_provider/path_provider.dart';

enum UploadTransport { lan, usb }

/// A private-network socket for the *same* public HTTPS origin. The URL,
/// Host header, SNI name and normal certificate validation never change.
/// This avoids sending credentials or photos to an unauthenticated HTTP IP.
class LanUploadRoute {
  const LanUploadRoute({
    required this.origin,
    required this.address,
    required this.port,
    this.kind = UploadTransport.lan,
    this.linkMbps,
  });

  final Uri origin;
  final InternetAddress address;
  final int port;
  final UploadTransport kind;

  /// Negotiated adapter rate, not measured upload throughput.
  final int? linkMbps;
  bool get isUsb => kind == UploadTransport.usb;

  bool sameDestination(LanUploadRoute other) =>
      origin == other.origin && address.address == other.address.address && port == other.port && kind == other.kind;

  static bool _validOrigin(Uri origin) =>
      origin.scheme == 'https' &&
      origin.host.isNotEmpty &&
      origin.port == 443 &&
      origin.userInfo.isEmpty &&
      (origin.path.isEmpty || origin.path == '/') &&
      !origin.hasQuery &&
      !origin.hasFragment;

  static LanUploadRoute? fromHint(Uri expectedOrigin, Object? document) =>
      fromHints(expectedOrigin, document).firstOrNull;

  static List<LanUploadRoute> fromHints(Uri expectedOrigin, Object? document) {
    if (!_validOrigin(expectedOrigin) || document is! Map<String, dynamic>) {
      return [];
    }
    final hintedOrigin = Uri.tryParse(document['origin'] is String ? document['origin'] as String : '');
    if (hintedOrigin == null ||
        !_validOrigin(hintedOrigin) ||
        hintedOrigin.host != expectedOrigin.host ||
        hintedOrigin.port != expectedOrigin.port) {
      return [];
    }
    final hints = document['routes'];
    if (hints != null && (hints is! List || hints.length > 8)) {
      return [];
    }
    // An old manager only publishes the top-level IPv4. Keep that contract.
    final entries = hints is List ? hints : [document];
    final routes = <LanUploadRoute>[];
    for (final entry in entries) {
      if (entry is! Map) {
        continue;
      }
      final ip = InternetAddress.tryParse(entry['ipv4'] is String ? entry['ipv4'] as String : '');
      final kind = entry['kind'] ?? 'lan';
      if (ip == null ||
          ip.type != InternetAddressType.IPv4 ||
          !_isPrivateIpv4(ip) ||
          entry['port'] != 443 ||
          (kind != 'lan' && kind != 'usb')) {
        continue;
      }
      final link = entry['linkMbps'];
      final route = LanUploadRoute(
        origin: expectedOrigin,
        address: ip,
        port: 443,
        kind: kind == 'usb' ? UploadTransport.usb : UploadTransport.lan,
        linkMbps: link is int && link > 0 && link <= 100000 ? link : null,
      );
      if (!routes.any(route.sameDestination)) {
        routes.add(route);
      }
    }
    return [...routes.where((route) => route.isUsb), ...routes.where((route) => !route.isUsb)];
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

typedef LocalRouteProbe = Future<bool> Function(LanUploadRoute route);

class LanUploadRouteResolver {
  LanUploadRouteResolver({
    this.hintClient,
    LocalRouteProbe? probe,
    Future<Directory> Function()? cacheDirectory,
    this.hintFetchTimeout = const Duration(seconds: 3),
  }) : _probe = probe ?? _probeTls,
       _cacheDirectory = cacheDirectory ?? getApplicationSupportDirectory;

  static const maximumHintBytes = 8192;
  static const cacheMaximumAge = Duration(days: 30);
  final http.Client? hintClient;
  final Duration hintFetchTimeout;
  final LocalRouteProbe _probe;
  final Future<Directory> Function() _cacheDirectory;
  final Map<Uri, List<LanUploadRoute>> _memoryHints = {};

  static Uri? publicOriginForApiEndpoint(String? endpoint) {
    final apiEndpoint = endpoint == null ? null : Uri.tryParse(endpoint);
    if (apiEndpoint == null ||
        apiEndpoint.scheme != 'https' ||
        apiEndpoint.host.isEmpty ||
        apiEndpoint.userInfo.isNotEmpty) {
      return null;
    }
    final origin = apiEndpoint.resolve('/');
    return LanUploadRoute._validOrigin(origin) ? origin : null;
  }

  Future<LanUploadRoute?> resolve(Uri origin) async => (await resolveAll(origin)).firstOrNull;

  Future<List<LanUploadRoute>> resolveAll(Uri origin) async {
    if (!LanUploadRoute._validOrigin(origin)) {
      return [];
    }
    var candidates = _memoryHints[origin] ?? await _readCache(origin);
    final client = hintClient ?? http.Client();
    try {
      final bytes = await _readHint(client, origin);
      if (bytes != null) {
        final fresh = LanUploadRoute.fromHints(origin, jsonDecode(utf8.decode(bytes)));
        if (fresh.isNotEmpty) {
          candidates = fresh;
          _memoryHints[origin] = fresh;
          await _writeCache(origin, bytes);
        }
      }
    } catch (_) {
      // Cached addresses still require fresh public-hostname TLS and pong.
    } finally {
      if (hintClient == null) {
        client.close();
      }
    }
    final verified = await Future.wait(
      candidates.map((route) async {
        try {
          return await _probe(route).timeout(const Duration(seconds: 2)) ? route : null;
        } catch (_) {
          return null;
        }
      }),
    );
    return verified.whereType<LanUploadRoute>().toList();
  }

  Future<List<int>?> _readHint(http.Client client, Uri origin) async {
    final abort = Completer<void>();
    StreamIterator<List<int>>? body;
    Future<List<int>?> receive() async {
      final request = http.AbortableRequest('GET', origin.resolve('/descargas/lan.json'), abortTrigger: abort.future);
      request.followRedirects = false;
      request.headers['Cache-Control'] = 'no-cache';
      final response = await client.send(request);
      if (abort.isCompleted || response.statusCode != 200) {
        return null;
      }
      final iterator = StreamIterator(response.stream);
      body = iterator;
      final bytes = <int>[];
      while (await iterator.moveNext()) {
        bytes.addAll(iterator.current);
        if (bytes.length > maximumHintBytes) {
          throw const FormatException('Local route hint exceeds the size limit');
        }
      }
      return bytes;
    }

    try {
      // Bound the whole hint fetch, not just gaps between chunks. A trickling
      // response must not prevent cached cable routes from being reprobed.
      return await receive().timeout(hintFetchTimeout);
    } finally {
      abort.complete();
      final iterator = body;
      if (iterator != null) {
        unawaited(iterator.cancel());
      }
    }
  }

  static Future<bool> _probeTls(LanUploadRoute route) async {
    final client = route.createClient(connectTimeout: const Duration(milliseconds: 900));
    Future<bool> ping() async {
      final request = http.Request('GET', route.origin.resolve('/api/server/ping'))..followRedirects = false;
      final response = await client.send(request);
      if (response.statusCode != 200) {
        return false;
      }
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        bytes.addAll(chunk);
        if (bytes.length > 1024) {
          return false;
        }
      }
      final body = jsonDecode(utf8.decode(bytes));
      return body is Map && body['res'] == 'pong';
    }

    try {
      return await ping().timeout(const Duration(seconds: 2));
    } finally {
      client.close();
    }
  }

  Future<File> _cacheFile(Uri origin) async {
    final directory = await _cacheDirectory();
    // No access token, headers or account information enter this cache.
    return File('${directory.path}/inhouse-local-routes-${base64Url.encode(utf8.encode(origin.host))}.json');
  }

  Future<List<LanUploadRoute>> _readCache(Uri origin) async {
    try {
      final file = await _cacheFile(origin);
      final stat = await file.stat();
      if (stat.size > maximumHintBytes || DateTime.now().difference(stat.modified) > cacheMaximumAge) {
        return [];
      }
      final routes = LanUploadRoute.fromHints(origin, jsonDecode(await file.readAsString()));
      _memoryHints[origin] = routes;
      return routes;
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeCache(Uri origin, List<int> bytes) async {
    try {
      final file = await _cacheFile(origin);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
    } catch (_) {
      // Discovery also works when persisting the optional cache is impossible.
    }
  }
}
