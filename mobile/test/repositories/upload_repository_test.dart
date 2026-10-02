import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/repositories/lan_upload_route.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';

class _Resolver extends LanUploadRouteResolver {
  List<LanUploadRoute> routes = [];
  int probes = 0;

  @override
  Future<List<LanUploadRoute>> resolveAll(Uri origin) async {
    probes++;
    return List.of(routes);
  }
}

class _Client extends http.BaseClient {
  _Client(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest request) handler;
  int sends = 0;
  int closes = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sends++;
    return handler(request);
  }

  @override
  void close() => closes++;
}

http.StreamedResponse _success() => http.StreamedResponse(Stream.value(' {"id":"asset-1"}'.codeUnits), 201);

void main() {
  test('multipart upload throttles UI progress without delaying streamed bytes or watchdog activity', () async {
    final updates = <({int bytes, int total})>[];
    var activity = 0;
    final request = ProgressMultipartRequest(
      'POST',
      Uri.parse('https://example.test/assets'),
      onProgress: (bytes, total) => updates.add((bytes: bytes, total: total)),
      onActivity: () => activity++,
    );
    const chunkCount = 500;
    request.files.add(
      http.MultipartFile(
        'assetData',
        Stream<List<int>>.fromIterable(List.generate(chunkCount, (index) => [index % 256])),
        chunkCount,
        filename: 'photo.jpg',
      ),
    );
    final streamedBytes = await request.finalize().fold<int>(0, (total, chunk) => total + chunk.length);
    expect(streamedBytes, request.contentLength);
    expect(updates, isNotEmpty);
    expect(updates.last.bytes, request.contentLength);
    expect(updates.last.total, request.contentLength);
    expect(updates.length, lessThan(10));
    expect(activity, greaterThanOrEqualTo(chunkCount));
  });

  final origin = Uri.parse('https://photos.example.com/');
  late Directory temp;
  late File photo;
  late _Resolver resolver;
  late _Client publicClient;
  late _Client lanClient;
  late _Client usbClient;
  late UploadRepository repository;
  final changes = <LanUploadRoute?>[];
  final lan = LanUploadRoute(origin: origin, address: InternetAddress('192.168.1.3'), port: 443);
  final usb = LanUploadRoute(
    origin: origin,
    address: InternetAddress('192.168.42.4'),
    port: 443,
    kind: UploadTransport.usb,
    linkMbps: 480,
  );

  Future<UploadResult> upload({Future<bool> Function()? allowPublic, Completer<void>? cancelToken}) =>
      repository.uploadFile(
        file: photo,
        originalFileName: 'photo.jpg',
        fields: const {'deviceAssetId': 'local-1', 'deviceId': 'phone-1'},
        cancelToken: cancelToken,
        logContext: 'test',
        canUsePublicRoute: allowPublic,
      );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('inhouse-upload-test-');
    photo = await File('${temp.path}/photo.jpg').writeAsBytes(List.filled(4096, 1));
    resolver = _Resolver();
    publicClient = _Client((_) async => _success());
    lanClient = _Client((_) async => _success());
    usbClient = _Client((_) async => _success());
    changes.clear();
    repository = UploadRepository(
      routeResolver: resolver,
      publicClient: publicClient,
      localClientFactory: (route) => route.isUsb ? usbClient : lanClient,
      endpoint: () => '${origin}api',
      accessToken: () => 'test-token',
      onRouteChanged: changes.add,
      registerBackgroundCallbacks: false,
      routeProbeInterval: const Duration(milliseconds: 30),
      uploadInactivityTimeout: const Duration(milliseconds: 100),
    );
  });
  tearDown(() async {
    repository.dispose();
    await temp.delete(recursive: true);
  });

  test('verified USB works with a cellular default and does not consult mobile-data permission', () async {
    resolver.routes = [usb, lan];
    var policyChecks = 0;
    expect(await repository.prepareLocalRoute(isUnmetered: false), isTrue);
    expect(repository.activeRoute?.isUsb, isTrue);
    expect(
      (await upload(
        allowPublic: () async {
          policyChecks++;
          return false;
        },
      )).isSuccess,
      isTrue,
    );
    expect(usbClient.sends, 1);
    expect(lanClient.sends, 0);
    expect(publicClient.sends, 0);
    expect(policyChecks, 0);
  });

  test('USB failure tries verified LAN before the public route', () async {
    resolver.routes = [usb, lan];
    usbClient = _Client((_) async => throw const SocketException('USB disconnected'));
    await repository.prepareLocalRoute(isUnmetered: false);
    expect((await upload(allowPublic: () async => false)).isSuccess, isTrue);
    expect(usbClient.sends, 1);
    expect(usbClient.closes, 1);
    expect(lanClient.sends, 1);
    expect(publicClient.sends, 0);
    expect(repository.activeRoute?.kind, UploadTransport.lan);
  });

  test('USB unplug never leaks a Wi-Fi-only backup onto mobile data', () async {
    resolver.routes = [usb];
    usbClient = _Client((_) async => throw const SocketException('USB disconnected'));
    await repository.prepareLocalRoute(isUnmetered: false);
    final result = await upload(allowPublic: () async => false);
    expect(result.isNetworkPolicyBlocked, isTrue);
    expect(result.isCancelled, isFalse);
    expect(publicClient.sends, 0);
    expect(repository.activeRoute, isNull);
    expect(usbClient.sends, 1); // Policy denial must not enter the retry loop.
  });

  test('explicit manual upload retains its permitted public fallback', () async {
    resolver.routes = [usb];
    usbClient = _Client((_) async => throw const SocketException('USB disconnected'));
    await repository.prepareLocalRoute(isUnmetered: false);
    expect((await upload()).isSuccess, isTrue);
    expect(publicClient.sends, 1);
  });

  test('a refreshed route never closes an in-flight client', () async {
    final response = Completer<http.StreamedResponse>();
    final started = Completer<void>();
    lanClient = _Client((_) async {
      started.complete();
      return response.future;
    });
    resolver.routes = [lan];
    await repository.prepareLocalRoute(isUnmetered: true);
    final pending = upload();
    await started.future;
    resolver.routes = [usb];
    await repository.prepareLocalRoute(isUnmetered: true, forceRefresh: true);
    expect(lanClient.closes, 0);
    expect(repository.activeRoute?.isUsb, isTrue);
    response.complete(_success());
    expect((await pending).isSuccess, isTrue);
    expect(lanClient.closes, 1);
  });

  test('foreground monitoring detects cable connection without restarting', () async {
    resolver.routes = [lan];
    await repository.prepareLocalRoute(isUnmetered: true);
    repository.startLocalRouteMonitoring();
    resolver.routes = [usb, lan];
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(repository.activeRoute?.isUsb, isTrue);
    expect(resolver.probes, greaterThan(1));
    expect(changes.last?.isUsb, isTrue);
    repository.stopLocalRouteMonitoring();
    expect(changes.last, isNull);
  });

  test('cached direct addresses never leave a stale USB indicator after foreground backup ends', () async {
    resolver.routes = [usb];
    await repository.prepareLocalRoute(isUnmetered: false);
    expect(repository.hasLocalRoute, isTrue);
    expect(changes.last, isNull);
    repository.startLocalRouteMonitoring();
    expect(changes.last?.isUsb, isTrue);
    repository.stopLocalRouteMonitoring();
    expect(changes.last, isNull);
    expect(repository.hasLocalRoute, isTrue); // Keep the reusable verified cache.
  });

  test('native background tasks show the public route even with a verified foreground USB candidate', () async {
    resolver.routes = [usb];
    await repository.prepareLocalRoute(isUnmetered: false);
    repository.startLocalRouteMonitoring();
    expect(changes.last?.isUsb, isTrue);
    final task = UploadTask(url: '${origin}api/assets', filename: 'photo.jpg', taskId: 'native-1');
    final forwarded = <TaskStatus>[];
    repository.onUploadStatus = (update) => forwarded.add(update.status);
    repository.handleBackgroundStatus(TaskStatusUpdate(task, TaskStatus.running));
    expect(changes.last, isNull);
    await repository.prepareLocalRoute(isUnmetered: false, forceRefresh: true);
    expect(changes.last, isNull); // A periodic probe must not relabel native uploads.
    repository.handleBackgroundStatus(TaskStatusUpdate(task, TaskStatus.complete));
    expect(changes.last?.isUsb, isTrue);
    expect(forwarded, [TaskStatus.running, TaskStatus.complete]);
    repository.stopLocalRouteMonitoring();
    expect(changes.last, isNull);
  });

  test('restored native progress clears the local indicator before a running status arrives', () async {
    resolver.routes = [lan];
    await repository.prepareLocalRoute(isUnmetered: true);
    repository.startLocalRouteMonitoring();
    expect(changes.last?.kind, UploadTransport.lan);
    final task = UploadTask(url: '${origin}api/assets', filename: 'photo.jpg', taskId: 'restored-1');
    repository.handleBackgroundProgress(TaskProgressUpdate(task, .25));
    expect(changes.last, isNull);
    repository.handleBackgroundStatus(TaskStatusUpdate(task, TaskStatus.paused));
    expect(changes.last?.kind, UploadTransport.lan);
    repository.stopLocalRouteMonitoring();
  });

  test('all local uploads retain the same HTTPS URL, host, token and no redirects', () async {
    resolver.routes = [usb];
    usbClient = _Client((request) async {
      expect(request.url, origin.resolve('/api/assets'));
      expect(request.followRedirects, isFalse);
      expect(request.headers[HttpHeaders.authorizationHeader], 'Bearer test-token');
      await request.finalize().drain<void>();
      return _success();
    });
    await repository.prepareLocalRoute(isUnmetered: false);
    expect((await upload()).isSuccess, isTrue);
  });

  test('a stalled cable transfer aborts and releases the asset for permitted LAN failover', () async {
    resolver.routes = [usb, lan];
    usbClient = _Client((request) {
      final aborted = (request as http.Abortable).abortTrigger!;
      return aborted.then((_) => throw http.RequestAbortedException());
    });
    await repository.prepareLocalRoute(isUnmetered: false);
    expect((await upload(allowPublic: () async => false)).isSuccess, isTrue);
    expect(usbClient.sends, 1);
    expect(lanClient.sends, 1);
    expect(publicClient.sends, 0);
  });

  test('healthy long transfers are not limited by total elapsed time', () async {
    resolver.routes = [usb];
    usbClient = _Client((request) async {
      final multipart = request as ProgressMultipartRequest;
      for (var chunk = 0; chunk < 8; chunk++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        multipart.onActivity?.call();
      }
      return _success();
    });
    await repository.prepareLocalRoute(isUnmetered: false);
    expect((await upload()).isSuccess, isTrue);
    expect(publicClient.sends, 0);
  });

  test('user cancellation is not a timeout and never falls back', () async {
    resolver.routes = [usb, lan];
    final started = Completer<void>();
    usbClient = _Client((request) {
      started.complete();
      return (request as http.Abortable).abortTrigger!.then((_) => throw http.RequestAbortedException());
    });
    await repository.prepareLocalRoute(isUnmetered: false);
    final cancel = Completer<void>();
    final result = upload(cancelToken: cancel);
    await started.future;
    cancel.complete();
    expect((await result).isCancelled, isTrue);
    expect(lanClient.sends, 0);
    expect(publicClient.sends, 0);
  });
}
