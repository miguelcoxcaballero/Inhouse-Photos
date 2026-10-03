import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/services/runtime_update.service.dart';

enum ServerManagementFailure {
  connection,
  timeout,
  unavailable,
  notPublished,
  authentication,
  configuration,
  invalidResponse,
  rejected,
}

class ServerManagementException implements Exception {
  const ServerManagementException(this.message, {this.failure = ServerManagementFailure.unavailable});
  final String message;
  final ServerManagementFailure failure;

  bool get canRetry => switch (failure) {
    ServerManagementFailure.connection ||
    ServerManagementFailure.timeout ||
    ServerManagementFailure.unavailable ||
    ServerManagementFailure.notPublished => true,
    _ => false,
  };

  @override
  String toString() => message;
}

class ManagedDisk {
  const ManagedDisk({
    required this.root,
    required this.name,
    required this.total,
    required this.free,
    required this.isLibrary,
    required this.isBackup,
    required this.canUseForBackup,
  });

  final String root;
  final String name;
  final int total;
  final int free;
  final bool isLibrary;
  final bool isBackup;
  final bool canUseForBackup;

  factory ManagedDisk.fromJson(Map<String, dynamic> json) => ManagedDisk(
    root: json['Root'] as String? ?? '',
    name: json['Name'] as String? ?? '',
    total: json['Total'] as int? ?? 0,
    free: json['Free'] as int? ?? 0,
    isLibrary: json['IsLibrary'] == true,
    isBackup: json['IsBackup'] == true,
    canUseForBackup: json['CanUseForBackup'] == true,
  );
}

class ServerManagementStatus {
  const ServerManagementStatus({
    required this.version,
    required this.serverOnline,
    required this.busy,
    required this.operation,
    required this.progress,
    required this.error,
    required this.backupDestination,
    required this.backupConfigured,
    required this.backupRunning,
    required this.backupPresent,
    required this.backupCompletedUtc,
    required this.weeklyBackupEnabled,
    required this.nextBackupUtc,
    required this.startupEnabled,
    required this.startupKnown,
    required this.disks,
    this.runtimeUpdate,
  });

  final String version;
  final bool serverOnline;
  final bool busy;
  final String operation;
  final String progress;
  final String error;
  final String backupDestination;
  final bool backupConfigured;
  final bool backupRunning;
  final bool backupPresent;
  final String backupCompletedUtc;
  final bool weeklyBackupEnabled;
  final String nextBackupUtc;
  final bool startupEnabled;
  final bool startupKnown;
  final List<ManagedDisk> disks;
  final RuntimeUpdateStatus? runtimeUpdate;

  factory ServerManagementStatus.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['Version'] is! String ||
        value['ServerOnline'] is! bool ||
        value['Busy'] is! bool ||
        value['Disks'] is! List) {
      throw const FormatException('Invalid server management status');
    }
    RuntimeUpdateStatus? runtimeUpdate;
    if (value['RuntimeUpdate'] != null) {
      try {
        runtimeUpdate = RuntimeUpdateStatus.fromJson(value['RuntimeUpdate']);
      } on FormatException {
        // Engine status is an optional extension. Its dedicated endpoint can
        // report incompatibility without hiding existing backup management.
      }
    }
    return ServerManagementStatus(
      version: value['Version'] as String,
      serverOnline: value['ServerOnline'] as bool,
      busy: value['Busy'] as bool,
      operation: value['Operation'] as String? ?? '',
      progress: value['Progress'] as String? ?? '',
      error: value['Error'] as String? ?? '',
      backupDestination: value['BackupDestination'] as String? ?? '',
      backupConfigured: value['BackupConfigured'] == true,
      backupRunning: value['BackupRunning'] == true,
      backupPresent: value['BackupPresent'] == true,
      backupCompletedUtc: value['BackupCompletedUtc'] as String? ?? '',
      weeklyBackupEnabled: value['WeeklyBackupEnabled'] == true,
      nextBackupUtc: value['NextBackupUtc'] as String? ?? '',
      startupEnabled: value['StartupEnabled'] == true,
      startupKnown: value['StartupKnown'] == true,
      disks: (value['Disks'] as List)
          .map((disk) => ManagedDisk.fromJson(Map<String, dynamic>.from(disk as Map)))
          .toList(growable: false),
      runtimeUpdate: runtimeUpdate,
    );
  }
}

enum ServerManagementAction {
  startBackup('backup/start'),
  cancelBackup('backup/cancel'),
  enableWeeklyBackup('backup/schedule/enable'),
  disableWeeklyBackup('backup/schedule/disable'),
  enableStartup('startup/enable'),
  disableStartup('startup/disable'),
  createSnapshot('snapshot');

  const ServerManagementAction(this.path);
  final String path;
}

/// Deliberately fixed endpoints: neither a URL nor a command is supplied by
/// the phone. The Windows manager authorizes every request against the photo
/// server's current administrator session.
class ServerManagementService {
  const ServerManagementService(this.client, {this.readTimeout = const Duration(seconds: 15)});
  final http.Client client;
  final Duration readTimeout;

  static Uri? urlForEndpoint(String? endpoint) {
    final uri = endpoint == null ? null : Uri.tryParse(endpoint);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.port != 443 || uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri.resolve('/inhouse-manager/v1/status');
  }

  Future<ServerManagementStatus> read(Uri url, String token) async {
    _requireToken(token);
    try {
      final response = await client.get(url, headers: _headers(token)).timeout(readTimeout);
      if (response.statusCode != 200) {
        throw _failure(response);
      }
      // A missing proxy route can return the photo web app with HTTP 200.
      // It is not a successful manager connection.
      if (response.headers['content-type']?.toLowerCase().contains('text/html') == true ||
          response.body.trimLeft().startsWith('<')) {
        throw _notPublished;
      }
      return ServerManagementStatus.fromJson(jsonDecode(response.body));
    } on ServerManagementException {
      rethrow;
    } on TimeoutException {
      throw const ServerManagementException(
        'The Windows manager took too long to respond. Retrying the connection…',
        failure: ServerManagementFailure.timeout,
      );
    } on FormatException {
      throw _invalidResponse;
    } on TypeError {
      throw _invalidResponse;
    } catch (_) {
      throw const ServerManagementException(
        'Could not connect to the Windows manager. Check your connection; retrying automatically.',
        failure: ServerManagementFailure.connection,
      );
    }
  }

  Future<void> act(Uri url, String token, ServerManagementAction action) =>
      _post(url.resolve('${url.path}/${action.path}'), token);

  Future<void> selectBackupDrive(Uri url, String token, String root) async {
    final match = RegExp(r'^([A-Z]):\\$').firstMatch(root.toUpperCase());
    if (match == null) {
      throw const ServerManagementException('Select a connected Windows drive.');
    }
    await _post(url.resolve('${url.path}/backup/destination/${match.group(1)}'), token);
  }

  Future<void> _post(Uri url, String token) async {
    _requireToken(token);
    try {
      final response = await client.post(url, headers: _headers(token)).timeout(const Duration(seconds: 20));
      if (response.statusCode != 202) {
        throw _failure(response, action: true);
      }
    } on ServerManagementException {
      rethrow;
    } catch (_) {
      throw const ServerManagementException('Could not reach the Windows manager. No change was confirmed.');
    }
  }

  static Map<String, String> _headers(String token) => {
    'Authorization': 'Bearer $token',
    'Accept': 'application/json',
    'Cache-Control': 'no-store',
  };

  static void _requireToken(String token) {
    if (token.trim().isEmpty) {
      throw const ServerManagementException(
        'Sign in again as an administrator to manage your PC.',
        failure: ServerManagementFailure.authentication,
      );
    }
  }

  static const _notPublished = ServerManagementException(
    'Remote management is not set up yet. Open or update Inhouse Photos Server on your PC to enable it.',
    failure: ServerManagementFailure.notPublished,
  );

  static const _invalidResponse = ServerManagementException(
    'The Windows manager returned an incompatible response. Update the manager on your PC, then try again.',
    failure: ServerManagementFailure.invalidResponse,
  );

  static ServerManagementException _failure(http.Response response, {bool action = false}) {
    return switch (response.statusCode) {
      401 => const ServerManagementException(
        'The PC could not verify your administrator session. Sign in again, then retry.',
        failure: ServerManagementFailure.authentication,
      ),
      403 => const ServerManagementException(
        'Remote management was refused by the PC. Open Inhouse Photos Server on your PC to repair its connection.',
        failure: ServerManagementFailure.configuration,
      ),
      404 => _notPublished,
      502 || 503 || 504 => ServerManagementException(
        action
            ? 'The Windows manager is offline or restarting. This change was not confirmed. Refresh the connection before trying again.'
            : 'The Windows manager is offline or restarting. Retrying automatically; open Inhouse Photos Server on the PC if this continues.',
        failure: ServerManagementFailure.unavailable,
      ),
      _ => ServerManagementException(
        _message(
          response,
          action ? 'The PC did not accept this change.' : 'Could not read the Windows manager status.',
        ),
        failure: ServerManagementFailure.rejected,
      ),
    };
  }

  static String _message(http.Response response, String fallback) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['message'] is String) {
        return body['message'] as String;
      }
    } catch (_) {}
    return fallback;
  }
}
