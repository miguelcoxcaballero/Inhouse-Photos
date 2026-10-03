import 'dart:convert';

import 'package:http/http.dart' as http;

class ManagerUpdateStatus {
  const ManagerUpdateStatus({
    required this.currentVersion,
    required this.latestVersion,
    required this.available,
    required this.phase,
    required this.progress,
    this.error = '',
    this.notes = '',
  });

  final String currentVersion;
  final String latestVersion;
  final bool available;
  final String phase;
  final int progress;
  final String error;
  final String notes;

  factory ManagerUpdateStatus.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid Windows manager update status');
    }
    // The Windows bridge uses .NET's PascalCase JSON serializer. Accept both
    // forms so older and newer manager builds remain compatible.
    final currentVersion = value['currentVersion'] ?? value['CurrentVersion'];
    final latestVersion = value['latestVersion'] ?? value['LatestVersion'];
    final available = value['available'] ?? value['Available'];
    final phase = value['phase'] ?? value['Phase'];
    final progress = value['progress'] ?? value['Progress'];
    final error = value['error'] ?? value['Error'];
    final notes = value['notes'] ?? value['Notes'];
    if (currentVersion is! String ||
        latestVersion is! String ||
        available is! bool ||
        phase is! String ||
        progress is! int) {
      throw const FormatException('Invalid Windows manager update status');
    }
    return ManagerUpdateStatus(
      currentVersion: currentVersion,
      latestVersion: latestVersion,
      available: available,
      phase: phase,
      progress: progress.clamp(0, 100),
      error: error is String ? error : '',
      notes: notes is String ? notes : '',
    );
  }
}

class ManagerUpdateException implements Exception {
  const ManagerUpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Calls the PC manager through the same public HTTPS origin as the photo API.
/// The manager independently verifies that the bearer token belongs to an
/// administrator. It never accepts a version, URL or command from the phone.
class ManagerUpdateService {
  const ManagerUpdateService(this.client);
  final http.Client client;

  static Uri? urlForEndpoint(String? endpoint) {
    final uri = endpoint == null ? null : Uri.tryParse(endpoint);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.port != 443 || uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri.resolve('/inhouse-manager/v1/update');
  }

  Future<ManagerUpdateStatus> check(Uri url, String accessToken) async {
    try {
      final response = await client.get(url, headers: _headers(accessToken)).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        throw ManagerUpdateException(_message(response, 'The PC manager is not available right now.'));
      }
      return ManagerUpdateStatus.fromJson(jsonDecode(response.body));
    } on ManagerUpdateException {
      rethrow;
    } catch (_) {
      throw const ManagerUpdateException('Could not reach the Windows manager. Photos remain available.');
    }
  }

  Future<void> start(Uri url, String accessToken) async {
    try {
      final response = await client.post(url, headers: _headers(accessToken)).timeout(const Duration(seconds: 15));
      if (response.statusCode != 202) {
        throw ManagerUpdateException(_message(response, 'The PC could not start the update.'));
      }
    } on ManagerUpdateException {
      rethrow;
    } catch (_) {
      throw const ManagerUpdateException('The update request could not be confirmed. Refresh to check its status.');
    }
  }

  static Map<String, String> _headers(String token) => {
    'Authorization': 'Bearer $token',
    'Accept': 'application/json',
    'Cache-Control': 'no-store',
  };

  static String _message(http.Response response, String fallback) {
    try {
      final value = jsonDecode(response.body);
      if (value is Map && value['message'] is String) {
        return value['message'] as String;
      }
    } catch (_) {}
    return fallback;
  }
}
