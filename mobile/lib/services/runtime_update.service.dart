import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/services/manager_update.service.dart';

class RuntimeUpdateStatus extends ManagerUpdateStatus {
  const RuntimeUpdateStatus({
    required super.currentVersion,
    required super.latestVersion,
    required super.available,
    required super.phase,
    required super.progress,
    super.error,
    super.notes,
    this.recoveryRequired = false,
  });

  final bool recoveryRequired;

  factory RuntimeUpdateStatus.fromJson(Object? value) {
    final status = ManagerUpdateStatus.fromJson(value);
    return RuntimeUpdateStatus(
      currentVersion: status.currentVersion,
      latestVersion: status.latestVersion,
      available: status.available,
      phase: status.phase,
      progress: status.progress,
      error: status.error,
      notes: status.notes,
      recoveryRequired: value is Map && (value['RecoveryRequired'] ?? value['recoveryRequired']) == true,
    );
  }
}

class RuntimeUpdateException implements Exception {
  const RuntimeUpdateException(this.message, {this.unsupported = false});

  final String message;
  final bool unsupported;

  @override
  String toString() => message;
}

/// The PC chooses and verifies the published runtime. The phone requests only
/// the fixed operation; it cannot supply an image, installer URL or command.
class RuntimeUpdateService {
  const RuntimeUpdateService(this.client);

  final http.Client client;

  static Uri? urlForEndpoint(String? endpoint) =>
      ManagerUpdateService.urlForEndpoint(endpoint)?.resolve('/inhouse-manager/v1/runtime-update');

  Future<RuntimeUpdateStatus> check(Uri url, String accessToken) async {
    try {
      final response = await client.get(url, headers: _headers(accessToken)).timeout(const Duration(seconds: 12));
      if (response.statusCode == 404 ||
          (response.statusCode == 200 &&
              (response.headers['content-type']?.toLowerCase().contains('text/html') == true ||
                  response.body.trimLeft().startsWith('<')))) {
        throw const RuntimeUpdateException(
          'Update the Windows manager to enable server engine updates here.',
          unsupported: true,
        );
      }
      if (response.statusCode != 200) {
        throw RuntimeUpdateException(_message(response, 'The server engine update status is unavailable.'));
      }
      return RuntimeUpdateStatus.fromJson(jsonDecode(response.body));
    } on RuntimeUpdateException {
      rethrow;
    } catch (_) {
      throw const RuntimeUpdateException('Could not check the server engine update. Retry the connection.');
    }
  }

  Future<void> start(Uri url, String accessToken) async {
    try {
      final response = await client.post(url, headers: _headers(accessToken)).timeout(const Duration(seconds: 15));
      if (response.statusCode != 202) {
        throw RuntimeUpdateException(_message(response, 'The PC did not confirm starting the server engine update.'));
      }
    } on RuntimeUpdateException {
      rethrow;
    } catch (_) {
      // A request can reach the PC before its response is lost. The UI checks
      // status again instead of assuming that retrying the POST is safe.
      throw const RuntimeUpdateException('The update request could not be confirmed. Refresh to check its status.');
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
      final message = value is Map ? value['message'] ?? value['Message'] : null;
      if (message is String && message.isNotEmpty) {
        return message;
      }
    } catch (_) {}
    return fallback;
  }
}
