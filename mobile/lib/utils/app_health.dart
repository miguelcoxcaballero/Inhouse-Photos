import 'package:immich_mobile/domain/models/log.model.dart';

String redactServerEndpoint(String? value) {
  if (value == null || value.trim().isEmpty) {
    return 'Not configured';
  }
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.host.isEmpty || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return 'Configured endpoint is invalid';
  }
  return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null).toString();
}

({int warnings, int severe}) summarizeLogHealth(Iterable<LogMessage> messages) {
  var warnings = 0;
  var severe = 0;
  for (final message in messages) {
    if (message.level == LogLevel.warning) {
      warnings++;
    }
    if (message.level == LogLevel.severe || message.level == LogLevel.shout) {
      severe++;
    }
  }
  return (warnings: warnings, severe: severe);
}

String buildAppHealthReport({
  required String appVersion,
  required String buildNumber,
  required String platform,
  required String endpoint,
  required String serverVersion,
  required String serverStatus,
  required String diskSummary,
  required int backupTotal,
  required int backupComplete,
  required int backupRemaining,
  required int backupErrors,
  required int imageCacheItems,
  required int imageCacheBytes,
  required int logWarnings,
  required int logSevere,
  required int offlineAlbumCount,
  required int originalBytes,
  required int storedBytes,
}) {
  final savedBytes = (originalBytes - storedBytes).clamp(0, originalBytes);
  return '''Inhouse Photos diagnostics
Generated: ${DateTime.now().toUtc().toIso8601String()}

App
Version: $appVersion ($buildNumber)
Platform: $platform

Server
Endpoint: $endpoint
Version: $serverVersion
Status: $serverStatus
Storage: $diskSummary

Backup
Complete: $backupComplete / $backupTotal
Remaining: $backupRemaining
Errors: $backupErrors
Original bytes processed: $originalBytes
Stored bytes: $storedBytes
Bytes saved: $savedBytes

Offline and cache
Offline albums: $offlineAlbumCount
Memory cache items: $imageCacheItems
Memory cache bytes: $imageCacheBytes

Recent log summary
Warnings: $logWarnings
Severe: $logSevere

No access token, password, custom header, file name, or photo metadata is included.
''';
}
