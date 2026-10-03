import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/services/manager_update.service.dart';

class SystemUpdateStatus extends ManagerUpdateStatus {
  const SystemUpdateStatus({
    required super.currentVersion,
    required super.latestVersion,
    required super.available,
    required super.phase,
    required super.progress,
    super.error,
    super.notes,
    this.recoveryRequired = false,
    this.requiresLocalRecovery = false,
    this.busy = false,
  });

  final bool recoveryRequired;
  final bool requiresLocalRecovery;
  final bool busy;

  factory SystemUpdateStatus.fromJson(Object? value) {
    final status = ManagerUpdateStatus.fromJson(value);
    final json = value as Map;
    return SystemUpdateStatus(
      currentVersion: status.currentVersion,
      latestVersion: status.latestVersion,
      available: status.available,
      phase: status.phase,
      progress: status.progress,
      error: status.error,
      notes: status.notes,
      recoveryRequired: (json['RecoveryRequired'] ?? json['recoveryRequired']) == true,
      requiresLocalRecovery: (json['RequiresLocalRecovery'] ?? json['requiresLocalRecovery']) == true,
      busy: (json['Busy'] ?? json['busy']) == true,
    );
  }
}

class SystemUpdateException implements Exception {
  const SystemUpdateException(
    this.message, {
    this.unsupported = false,
    this.authentication = false,
    this.uncertain = false,
  });

  final String message;
  final bool unsupported;
  final bool authentication;
  final bool uncertain;

  @override
  String toString() => message;
}

/// A single product update, selected and verified by the PC. The phone never
/// supplies versions, Docker images, download URLs or commands to this API.
class SystemUpdateService {
  const SystemUpdateService(this.client);

  final http.Client client;

  static Uri? urlForEndpoint(String? endpoint) =>
      ManagerUpdateService.urlForEndpoint(endpoint)?.resolve('/inhouse-manager/v1/system-update');

  Future<SystemUpdateStatus> check(Uri url, String token) async {
    _requireToken(token);
    try {
      final response = await client.get(url, headers: _headers(token)).timeout(const Duration(seconds: 12));
      if (response.statusCode == 404 ||
          (response.statusCode == 200 &&
              (response.headers['content-type']?.toLowerCase().contains('text/html') == true ||
                  response.body.trimLeft().startsWith('<')))) {
        throw const SystemUpdateException('This PC needs the compatibility update.', unsupported: true);
      }
      if (response.statusCode != 200) {
        throw _failure(response);
      }
      return SystemUpdateStatus.fromJson(jsonDecode(response.body));
    } on SystemUpdateException {
      rethrow;
    } catch (_) {
      throw const SystemUpdateException('Could not check your PC. Retry the connection.');
    }
  }

  Future<void> start(Uri url, String token) async {
    _requireToken(token);
    try {
      final response = await client.post(url, headers: _headers(token)).timeout(const Duration(seconds: 15));
      if (response.statusCode != 202) {
        throw _failure(response, action: true);
      }
    } on SystemUpdateException {
      rethrow;
    } catch (_) {
      // The PC may already be working. Only status reads follow this error;
      // repeating the operation requires another deliberate user action.
      throw const SystemUpdateException(
        'The update request could not be confirmed. Checking its status.',
        uncertain: true,
      );
    }
  }

  static void _requireToken(String token) {
    if (token.trim().isEmpty) {
      throw const SystemUpdateException('Sign in again as an administrator.', authentication: true);
    }
  }

  static Map<String, String> _headers(String token) => {
    'Authorization': 'Bearer $token',
    'Accept': 'application/json',
    'Cache-Control': 'no-store',
  };

  static SystemUpdateException _failure(http.Response response, {bool action = false}) {
    var message = action ? 'The PC did not accept this update.' : 'The PC update status is unavailable.';
    try {
      final body = jsonDecode(response.body);
      final detail = body is Map ? body['message'] ?? body['Message'] : null;
      if (detail is String && detail.isNotEmpty) {
        message = detail;
      }
    } catch (_) {}
    return SystemUpdateException(
      message,
      authentication: response.statusCode == 401 || response.statusCode == 403,
      uncertain: action && const {502, 503, 504}.contains(response.statusCode),
    );
  }
}
