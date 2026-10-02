import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:logging/logging.dart';
import 'package:http/http.dart';
import 'package:immich_mobile/utils/debug_print.dart';

import 'package:immich_mobile/repositories/lan_upload_route.dart';

final localUploadRouteActiveProvider = StateProvider<bool>((ref) => false);
final activeUploadRouteProvider = StateProvider<LanUploadRoute?>((ref) => null);
final uploadRepositoryProvider = Provider((ref) {
  final repository = UploadRepository(
    onLocalRouteChanged: (active) => ref.read(localUploadRouteActiveProvider.notifier).state = active,
    onRouteChanged: (route) => ref.read(activeUploadRouteProvider.notifier).state = route,
  );
  ref.onDispose(repository.dispose);
  return repository;
});

class _LocalClientLease {
  _LocalClientLease(this.route, this.client);
  LanUploadRoute route;
  final Client client;
  int uses = 0;
  bool retired = false;
  bool closed = false;

  void retire() {
    retired = true;
    closeIfUnused();
  }

  void closeIfUnused() {
    if (retired && uses == 0 && !closed) {
      closed = true;
      client.close();
    }
  }
}

class UploadRepository {
  UploadRepository({
    this.onLocalRouteChanged,
    this.onRouteChanged,
    LanUploadRouteResolver? routeResolver,
    Client Function(LanUploadRoute)? localClientFactory,
    this.publicClient,
    String Function()? endpoint,
    String Function()? accessToken,
    bool registerBackgroundCallbacks = true,
    this.routeProbeInterval = const Duration(seconds: 15),
    this.uploadInactivityTimeout = const Duration(seconds: 90),
  }) : _routeResolver = routeResolver ?? LanUploadRouteResolver(),
       _localClientFactory = localClientFactory ?? ((route) => route.createClient()),
       _endpoint = endpoint ?? (() => Store.get(StoreKey.serverEndpoint)),
       _accessToken = accessToken ?? (() => Store.get(StoreKey.accessToken)) {
    if (!registerBackgroundCallbacks) {
      return;
    }
    FileDownloader().registerCallbacks(
      group: kBackupGroup,
      taskStatusCallback: handleBackgroundStatus,
      taskProgressCallback: handleBackgroundProgress,
    );
    FileDownloader().registerCallbacks(
      group: kBackupLivePhotoGroup,
      taskStatusCallback: handleBackgroundStatus,
      taskProgressCallback: handleBackgroundProgress,
    );
    FileDownloader().registerCallbacks(
      group: kManualUploadGroup,
      taskStatusCallback: handleBackgroundStatus,
      taskProgressCallback: handleBackgroundProgress,
    );
  }

  final void Function(bool active)? onLocalRouteChanged;
  final void Function(LanUploadRoute? route)? onRouteChanged;
  final Logger logger = Logger('UploadRepository');
  final LanUploadRouteResolver _routeResolver;
  final Client Function(LanUploadRoute) _localClientFactory;
  final Client? publicClient;
  final String Function() _endpoint;
  final String Function() _accessToken;
  final Duration routeProbeInterval;
  final Duration uploadInactivityTimeout;
  List<_LocalClientLease> _localClients = [];
  Future<bool>? _routeDiscovery;
  DateTime? _lastProbe;
  Uri? _origin;
  Timer? _routeTimer;
  int _monitorUsers = 0;
  final Set<String> _nativeBackgroundTransfers = {};
  bool _disposed = false;
  bool get hasLocalRoute => _localClients.isNotEmpty;
  LanUploadRoute? get activeRoute => _localClients.firstOrNull?.route;
  void Function(TaskStatusUpdate)? onUploadStatus;
  void Function(TaskProgressUpdate)? onTaskProgress;

  /// A verified direct route is safe even when USB tethering makes Android
  /// report its default Internet network as cellular. Never infer a cable
  /// merely from charging or an OS transport flag.
  Future<bool> prepareLocalRoute({required bool isUnmetered, bool forceRefresh = false}) async {
    if (_disposed) {
      return false;
    }
    final origin = LanUploadRouteResolver.publicOriginForApiEndpoint(_endpoint());
    if (origin == null) {
      _disableLocalRoute();
      return false;
    }
    final pending = _routeDiscovery;
    if (pending != null && _origin == origin) {
      return pending;
    }
    if (_origin == origin &&
        !forceRefresh &&
        _lastProbe != null &&
        DateTime.now().difference(_lastProbe!) < routeProbeInterval) {
      return hasLocalRoute;
    }
    if (_origin != origin) {
      _disableLocalRoute();
    }
    _origin = origin;
    final discovery = _refreshRoutes(origin);
    _routeDiscovery = discovery;
    try {
      return await discovery;
    } finally {
      if (identical(_routeDiscovery, discovery)) {
        _routeDiscovery = null;
      }
    }
  }

  Future<bool> _refreshRoutes(Uri origin) async {
    final routes = await _routeResolver.resolveAll(origin);
    _lastProbe = DateTime.now();
    if (_disposed || _origin != origin) {
      return false;
    }
    final old = List<_LocalClientLease>.of(_localClients);
    final next = <_LocalClientLease>[];
    for (final route in routes) {
      final existing = old.where((lease) => lease.route.sameDestination(route)).firstOrNull;
      if (existing != null) {
        old.remove(existing);
        existing.route = route;
        next.add(existing);
      } else {
        next.add(_LocalClientLease(route, _localClientFactory(route)));
      }
    }
    _localClients = next;
    for (final lease in old) {
      // A USB unplug/reprobe must not abort an upload already using Wi-Fi.
      lease.retire();
    }
    if (!_disposed) {
      _publishRoute();
    }
    return hasLocalRoute;
  }

  void startLocalRouteMonitoring() {
    if (_disposed) {
      return;
    }
    _monitorUsers++;
    _publishRoute();
    _routeTimer ??= Timer.periodic(routeProbeInterval, (_) {
      unawaited(prepareLocalRoute(isUnmetered: false, forceRefresh: true));
    });
  }

  void stopLocalRouteMonitoring() {
    if (_monitorUsers > 0) {
      _monitorUsers--;
    }
    if (_monitorUsers == 0) {
      _routeTimer?.cancel();
      _routeTimer = null;
    }
    _publishRoute();
  }

  void _publishRoute() {
    if (_disposed) {
      return;
    }
    // A discovered address is not proof that the native background uploader
    // uses it. Native tasks currently retain their public HTTPS URL/session.
    // Prefer an honest public/mixed indicator whenever any native task runs,
    // and clear the foreground indicator when its last run has finished.
    final displayedRoute = _monitorUsers > 0 && _nativeBackgroundTransfers.isEmpty ? activeRoute : null;
    onLocalRouteChanged?.call(displayedRoute != null);
    onRouteChanged?.call(displayedRoute);
  }

  void handleBackgroundStatus(TaskStatusUpdate update) {
    if (update.status == TaskStatus.running) {
      _nativeBackgroundTransfers.add(update.task.taskId);
    } else {
      _nativeBackgroundTransfers.remove(update.task.taskId);
    }
    _publishRoute();
    onUploadStatus?.call(update);
  }

  void handleBackgroundProgress(TaskProgressUpdate update) {
    // A restored native session can report progress before its running event.
    if (update.progress >= 0 && update.progress < 1) {
      _nativeBackgroundTransfers.add(update.task.taskId);
      _publishRoute();
    }
    onTaskProgress?.call(update);
  }

  void _disableLocalRoute() {
    final old = _localClients;
    _localClients = [];
    for (final lease in old) {
      lease.retire();
    }
    if (!_disposed) {
      _publishRoute();
    }
  }

  void dispose() {
    _disposed = true;
    _routeTimer?.cancel();
    _routeTimer = null;
    _disableLocalRoute();
  }

  Future<void> enqueueBackground(UploadTask task) {
    return FileDownloader().enqueue(task);
  }

  Future<List<bool>> enqueueBackgroundAll(List<UploadTask> tasks) {
    return FileDownloader().enqueueAll(tasks);
  }

  Future<void> deleteDatabaseRecords(String group) {
    return FileDownloader().database.deleteAllRecords(group: group);
  }

  Future<bool> cancelAll(String group) {
    return FileDownloader().cancelAll(group: group);
  }

  Future<int> reset(String group) {
    return FileDownloader().reset(group: group);
  }

  /// Get a list of tasks that are ENQUEUED or RUNNING
  Future<List<Task>> getActiveTasks(String group) {
    return FileDownloader().allTasks(group: group);
  }

  Future<void> start() {
    return FileDownloader().start();
  }

  Future<void> getUploadInfo() async {
    final [enqueuedTasks, runningTasks, canceledTasks, waitingTasks, pausedTasks] = await Future.wait([
      FileDownloader().database.allRecordsWithStatus(TaskStatus.enqueued, group: kBackupGroup),
      FileDownloader().database.allRecordsWithStatus(TaskStatus.running, group: kBackupGroup),
      FileDownloader().database.allRecordsWithStatus(TaskStatus.canceled, group: kBackupGroup),
      FileDownloader().database.allRecordsWithStatus(TaskStatus.waitingToRetry, group: kBackupGroup),
      FileDownloader().database.allRecordsWithStatus(TaskStatus.paused, group: kBackupGroup),
    ]);

    dPrint(
      () =>
          """
      Upload Info:
      Enqueued: ${enqueuedTasks.length}
      Running: ${runningTasks.length}
      Canceled: ${canceledTasks.length}
      Waiting: ${waitingTasks.length}
      Paused: ${pausedTasks.length}
    """,
    );
  }

  Future<UploadResult> uploadFile({
    required File file,
    required String originalFileName,
    required Map<String, String> fields,
    required Completer<void>? cancelToken,
    void Function(int bytes, int totalBytes)? onProgress,
    required String logContext,
    Future<bool> Function()? canUsePublicRoute,
  }) async {
    UploadResult? lastResult;
    const retryDelays = [Duration(seconds: 2), Duration(seconds: 5), Duration(seconds: 15), Duration(seconds: 45)];

    for (var attempt = 0; attempt <= retryDelays.length; attempt++) {
      if (cancelToken?.isCompleted ?? false) {
        return UploadResult.cancelled();
      }

      final result = await _uploadFileOnce(
        file: file,
        originalFileName: originalFileName,
        fields: fields,
        cancelToken: cancelToken,
        onProgress: onProgress,
        logContext: '$logContext#$attempt',
        canUsePublicRoute: canUsePublicRoute,
      );
      lastResult = result;
      if (!_shouldRetry(result) || attempt == retryDelays.length) {
        return result;
      }

      logger.warning('Transient upload failure for $logContext; retrying in ${retryDelays[attempt].inSeconds}s');
      final cancellation = cancelToken?.future;
      if (cancellation == null) {
        await Future<void>.delayed(retryDelays[attempt]);
      } else {
        await Future.any<void>([Future<void>.delayed(retryDelays[attempt]), cancellation]);
      }
    }
    return lastResult ?? UploadResult.error(errorMessage: 'Upload failed before it could start');
  }

  bool _shouldRetry(UploadResult result) {
    if (result.isSuccess || result.isCancelled || result.isNetworkPolicyBlocked) {
      return false;
    }
    final status = result.statusCode;
    // Network errors do not have an HTTP status. Retry only responses that are
    // normally transient; validation and quota failures must surface at once.
    return status == null || status == 408 || status == 429 || (status >= 500 && status <= 599);
  }

  Future<UploadResult> _uploadFileOnce({
    required File file,
    required String originalFileName,
    required Map<String, String> fields,
    required Completer<void>? cancelToken,
    void Function(int bytes, int totalBytes)? onProgress,
    required String logContext,
    Future<bool> Function()? canUsePublicRoute,
  }) async {
    // Try verified USB first, then another verified LAN socket. Keep each
    // client alive until its in-flight request has released its lease.
    for (final lease in List<_LocalClientLease>.of(_localClients)) {
      if (lease.retired) {
        continue;
      }
      lease.uses++;
      UploadResult localResult;
      try {
        localResult = await _sendFileOnce(
          file: file,
          originalFileName: originalFileName,
          fields: fields,
          cancelToken: cancelToken,
          onProgress: onProgress,
          logContext: '$logContext/${lease.route.kind.name}',
          client: lease.client,
          useBearerToken: true,
        );
      } finally {
        lease.uses--;
        lease.closeIfUnused();
      }
      if (localResult.isSuccess || localResult.isCancelled || localResult.statusCode != null) {
        return localResult;
      }
      _localClients.remove(lease);
      lease.retire();
      _publishRoute();
    }
    // The default network can switch to mobile data while a cable/local
    // socket is failing. Recheck policy immediately before every public send.
    if (canUsePublicRoute != null && !await canUsePublicRoute()) {
      return UploadResult.networkPolicyBlocked();
    }
    return _sendFileOnce(
      file: file,
      originalFileName: originalFileName,
      fields: fields,
      cancelToken: cancelToken,
      onProgress: onProgress,
      logContext: logContext,
      client: publicClient ?? NetworkRepository.client,
      useBearerToken: false,
    );
  }

  Future<UploadResult> _sendFileOnce({
    required File file,
    required String originalFileName,
    required Map<String, String> fields,
    required Completer<void>? cancelToken,
    void Function(int bytes, int totalBytes)? onProgress,
    required String logContext,
    required Client client,
    required bool useBearerToken,
  }) async {
    final String savedEndpoint = _endpoint();
    final abort = Completer<void>();
    var stalled = false;
    var finished = false;
    var lastActivity = DateTime.now();
    var lastBytes = 0;
    void completeAbort() {
      if (!finished && !abort.isCompleted) {
        abort.complete();
      }
    }

    if (cancelToken != null) {
      unawaited(cancelToken.future.then((_) => completeAbort()));
    }
    final watchdog = Timer.periodic(
      uploadInactivityTimeout < const Duration(seconds: 5) ? uploadInactivityTimeout : const Duration(seconds: 5),
      (_) {
        if (DateTime.now().difference(lastActivity) >= uploadInactivityTimeout) {
          stalled = true;
          completeAbort();
        }
      },
    );
    final baseRequest = ProgressMultipartRequest(
      'POST',
      Uri.parse('$savedEndpoint/assets'),
      abortTrigger: abort.future,
      onActivity: () => lastActivity = DateTime.now(),
      onProgress: (bytes, total) {
        if (bytes > lastBytes) {
          lastBytes = bytes;
          lastActivity = DateTime.now();
        }
        if (!finished) {
          onProgress?.call(bytes, total);
        }
      },
    );
    baseRequest.followRedirects = false;
    if (useBearerToken) {
      baseRequest.headers[HttpHeaders.authorizationHeader] = 'Bearer ${_accessToken()}';
    }

    Future<UploadResult> send() async {
      try {
        final fileStream = file.openRead();
        final assetRawUploadData = MultipartFile(
          "assetData",
          fileStream,
          file.lengthSync(),
          filename: originalFileName,
        );

        baseRequest.fields.addAll(fields);
        baseRequest.files.add(assetRawUploadData);

        final response = await client.send(baseRequest);
        lastActivity = DateTime.now();
        final responseBodyString = await ByteStream(
          response.stream.map((chunk) {
            lastActivity = DateTime.now();
            return chunk;
          }),
        ).bytesToString();

        if (![200, 201].contains(response.statusCode)) {
          String? errorMessage;

          if (response.statusCode == 413) {
            errorMessage = 'Error(413) File is too large to upload';
            return UploadResult.error(statusCode: response.statusCode, errorMessage: errorMessage);
          }

          try {
            final error = jsonDecode(responseBodyString);
            errorMessage = error['message'] ?? error['error'];
          } catch (_) {
            errorMessage = responseBodyString.isNotEmpty
                ? responseBodyString
                : 'Upload failed with status ${response.statusCode}';
          }

          return UploadResult.error(statusCode: response.statusCode, errorMessage: errorMessage);
        }

        try {
          final responseBody = jsonDecode(responseBodyString);
          return UploadResult.success(remoteAssetId: responseBody['id'] as String);
        } catch (e) {
          return UploadResult.error(errorMessage: 'Failed to parse server response');
        }
      } on RequestAbortedException {
        logger.warning("Upload $logContext was cancelled");
        return stalled
            ? UploadResult.error(errorMessage: 'Upload stalled; reconnecting to the server.')
            : UploadResult.cancelled();
      } catch (error, stackTrace) {
        logger.warning("Error uploading $logContext: ${error.toString()}: $stackTrace");
        return UploadResult.error(errorMessage: error.toString());
      }
    }

    try {
      // This is an inactivity deadline, never a total-duration limit. A large
      // video may run for hours while bytes keep moving. Also bound a broken
      // client's await if it ignores the Abortable request signal.
      return await Future.any<UploadResult>([
        send(),
        abort.future.then(
          (_) => stalled
              ? UploadResult.error(errorMessage: 'Upload stalled; reconnecting to the server.')
              : UploadResult.cancelled(),
        ),
      ]);
    } finally {
      finished = true;
      watchdog.cancel();
    }
  }
}

class ProgressMultipartRequest extends MultipartRequest with Abortable {
  ProgressMultipartRequest(super.method, super.url, {this.abortTrigger, this.onProgress, this.onActivity});

  // With up to 16 active transfers, emitting progress more often than this can
  // spend a measurable amount of UI-isolate time rebuilding the details view.
  // Completion is always emitted immediately, so this does not delay state.
  static const progressUpdateInterval = Duration(milliseconds: 400);

  @override
  final Future<void>? abortTrigger;

  final void Function(int bytes, int totalBytes)? onProgress;
  final void Function()? onActivity;

  @override
  ByteStream finalize() {
    final byteStream = super.finalize();
    if (onProgress == null && onActivity == null) {
      return byteStream;
    }

    final total = contentLength;
    var bytes = 0;
    var lastProgressUpdateMs = -progressUpdateInterval.inMilliseconds;
    final progressClock = Stopwatch()..start();
    final stream = byteStream.transform(
      StreamTransformer.fromHandlers(
        handleData: (List<int> data, EventSink<List<int>> sink) {
          onActivity?.call();
          bytes += data.length;
          final elapsedMs = progressClock.elapsedMilliseconds;
          if (bytes >= total || elapsedMs - lastProgressUpdateMs >= progressUpdateInterval.inMilliseconds) {
            lastProgressUpdateMs = elapsedMs;
            onProgress?.call(bytes, total);
          }
          sink.add(data);
        },
      ),
    );
    return ByteStream(stream);
  }
}

class UploadResult {
  final bool isSuccess;
  final bool isCancelled;
  final String? remoteAssetId;
  final String? errorMessage;
  final int? statusCode;
  final bool isNetworkPolicyBlocked;

  const UploadResult({
    required this.isSuccess,
    required this.isCancelled,
    this.remoteAssetId,
    this.errorMessage,
    this.statusCode,
    this.isNetworkPolicyBlocked = false,
  });

  factory UploadResult.success({required String remoteAssetId}) {
    return UploadResult(isSuccess: true, isCancelled: false, remoteAssetId: remoteAssetId);
  }

  factory UploadResult.error({String? errorMessage, int? statusCode}) {
    return UploadResult(isSuccess: false, isCancelled: false, errorMessage: errorMessage, statusCode: statusCode);
  }

  factory UploadResult.cancelled() {
    return const UploadResult(isSuccess: false, isCancelled: true);
  }

  factory UploadResult.networkPolicyBlocked() => const UploadResult(
    isSuccess: false,
    isCancelled: false,
    isNetworkPolicyBlocked: true,
    errorMessage: 'Local connection lost. Waiting for Wi-Fi or a verified USB connection.',
  );
}
