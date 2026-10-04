import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/sync_event.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/sync_api.repository.dart';
import 'package:immich_mobile/utils/semver.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

import '../../api.mocks.dart';
import '../../service.mocks.dart';

class MockHttpClient extends Mock implements http.Client {}

class MockApiClient extends Mock implements ApiClient {}

class MockStreamedResponse extends Mock implements http.StreamedResponse {}

class FakeBaseRequest extends Fake implements http.BaseRequest {}

String _createJsonLine(String type, Map<String, dynamic> data, String ack) {
  return '${jsonEncode({'type': type, 'data': data, 'ack': ack})}\n';
}

void main() {
  late SyncApiRepository sut;
  late MockApiService mockApiService;
  late MockApiClient mockApiClient;
  late MockSyncApi mockSyncApi;
  late MockHttpClient mockHttpClient;
  late MockStreamedResponse mockStreamedResponse;
  late StreamController<List<int>> responseStreamController;
  late int testBatchSize = 3;

  setUpAll(() async {
    final db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: DriftStoreRepository(db));
  });

  setUp(() {
    mockApiService = MockApiService();
    mockApiClient = MockApiClient();
    mockSyncApi = MockSyncApi();
    mockHttpClient = MockHttpClient();
    mockStreamedResponse = MockStreamedResponse();
    responseStreamController = StreamController<List<int>>.broadcast(sync: true);

    registerFallbackValue(FakeBaseRequest());

    when(() => mockApiService.apiClient).thenReturn(mockApiClient);
    when(() => mockApiService.syncApi).thenReturn(mockSyncApi);
    when(() => mockApiClient.basePath).thenReturn('http://demo.immich.app/api');
    // Mock HTTP client behavior
    when(() => mockHttpClient.send(any())).thenAnswer((_) async => mockStreamedResponse);
    when(() => mockStreamedResponse.statusCode).thenReturn(200);
    when(() => mockStreamedResponse.stream).thenAnswer((_) => http.ByteStream(responseStreamController.stream));

    sut = SyncApiRepository(mockApiService);
  });

  tearDown(() async {
    if (!responseStreamController.isClosed) {
      await responseStreamController.close();
    }
  });

  Future<void> streamChanges(
    Future<void> Function(List<SyncEvent>, Function() abort, Function() reset) onDataCallback,
    SemVer serverVersion,
  ) {
    return sut.streamChanges(
      onDataCallback,
      batchSize: testBatchSize,
      httpClient: mockHttpClient,
      serverVersion: serverVersion,
    );
  }

  test('streamChanges stops processing stream when abort is called', () async {
    int onDataCallCount = 0;
    bool abortWasCalledInCallback = false;
    List<SyncEvent> receivedEventsBatch1 = [];
    final Completer<void> firstBatchReceived = Completer<void>();

    Future<void> onDataCallback(List<SyncEvent> events, Function() abort, Function() _) async {
      onDataCallCount++;
      if (onDataCallCount == 1) {
        receivedEventsBatch1 = events;
        abort();
        abortWasCalledInCallback = true;
        firstBatchReceived.complete();
      } else {
        fail("onData called more than once after abort was invoked");
      }
    }

    final streamChangesFuture = streamChanges(onDataCallback, const SemVer(major: 2, minor: 5, patch: 0));

    // Give the stream subscription time to start (longer delay to account for mock delay)
    await Future.delayed(const Duration(milliseconds: 50));

    for (int i = 0; i < testBatchSize; i++) {
      responseStreamController.add(
        utf8.encode(
          _createJsonLine(SyncEntityType.userDeleteV1.toString(), SyncUserDeleteV1(userId: "user$i").toJson(), 'ack$i'),
        ),
      );
    }

    await firstBatchReceived.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail('First batch was not processed within timeout'),
    );

    for (int i = testBatchSize; i < testBatchSize * 2; i++) {
      responseStreamController.add(
        utf8.encode(
          _createJsonLine(SyncEntityType.userDeleteV1.toString(), SyncUserDeleteV1(userId: "user$i").toJson(), 'ack$i'),
        ),
      );
    }

    await responseStreamController.close();
    await expectLater(streamChangesFuture, completes);

    expect(onDataCallCount, 1);
    expect(abortWasCalledInCallback, isTrue);
    expect(receivedEventsBatch1.length, testBatchSize);
  });

  test('streamChanges does not process remaining lines in finally block if aborted', () async {
    int onDataCallCount = 0;
    bool abortWasCalledInCallback = false;
    final Completer<void> firstBatchReceived = Completer<void>();

    Future<void> onDataCallback(List<SyncEvent> _, Function() abort, Function() _) async {
      onDataCallCount++;
      if (onDataCallCount == 1) {
        abort();
        abortWasCalledInCallback = true;
        firstBatchReceived.complete();
      } else {
        fail("onData called more than once after abort was invoked");
      }
    }

    final streamChangesFuture = streamChanges(onDataCallback, const SemVer(major: 2, minor: 5, patch: 0));

    await Future.delayed(const Duration(milliseconds: 50));

    for (int i = 0; i < testBatchSize; i++) {
      responseStreamController.add(
        utf8.encode(
          _createJsonLine(SyncEntityType.userDeleteV1.toString(), SyncUserDeleteV1(userId: "user$i").toJson(), 'ack$i'),
        ),
      );
    }

    await firstBatchReceived.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail('First batch was not processed within timeout'),
    );

    // emit a single event to skip batching and trigger finally
    responseStreamController.add(
      utf8.encode(
        _createJsonLine(SyncEntityType.userDeleteV1.toString(), SyncUserDeleteV1(userId: "user100").toJson(), 'ack100'),
      ),
    );

    await responseStreamController.close();
    await expectLater(streamChangesFuture, completes);

    expect(onDataCallCount, 1);
    expect(abortWasCalledInCallback, isTrue);
  });

  test('streamChanges processes remaining lines in finally block if not aborted', () async {
    int onDataCallCount = 0;
    List<SyncEvent> receivedEventsBatch1 = [];
    List<SyncEvent> receivedEventsBatch2 = [];
    final Completer<void> firstBatchReceived = Completer<void>();
    final Completer<void> secondBatchReceived = Completer<void>();

    Future<void> onDataCallback(List<SyncEvent> events, Function() _, Function() __) async {
      onDataCallCount++;
      if (onDataCallCount == 1) {
        receivedEventsBatch1 = events;
        firstBatchReceived.complete();
      } else if (onDataCallCount == 2) {
        receivedEventsBatch2 = events;
        secondBatchReceived.complete();
      } else {
        fail("onData called more than expected");
      }
    }

    final streamChangesFuture = streamChanges(onDataCallback, const SemVer(major: 2, minor: 5, patch: 0));

    await Future.delayed(const Duration(milliseconds: 50));

    // Batch 1
    for (int i = 0; i < testBatchSize; i++) {
      responseStreamController.add(
        utf8.encode(
          _createJsonLine(SyncEntityType.userDeleteV1.toString(), SyncUserDeleteV1(userId: "user$i").toJson(), 'ack$i'),
        ),
      );
    }

    await firstBatchReceived.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail('First batch was not processed within timeout'),
    );

    responseStreamController.add(
      utf8.encode(
        _createJsonLine(SyncEntityType.userDeleteV1.toString(), SyncUserDeleteV1(userId: "user100").toJson(), 'ack100'),
      ),
    );

    await responseStreamController.close();

    await secondBatchReceived.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail('Second batch was not processed within timeout'),
    );

    await expectLater(streamChangesFuture, completes);

    expect(onDataCallCount, 2);
    expect(receivedEventsBatch1.length, testBatchSize);
    expect(receivedEventsBatch2.length, 1);
  });

  test('streamChanges handles stream error gracefully', () async {
    final streamError = Exception("Network Error");
    int onDataCallCount = 0;

    Future<void> onDataCallback(List<SyncEvent> _, Function() _, Function() __) async {
      onDataCallCount++;
    }

    final streamChangesFuture = streamChanges(onDataCallback, const SemVer(major: 2, minor: 5, patch: 0));

    await Future.delayed(const Duration(milliseconds: 50));

    responseStreamController.add(
      utf8.encode(
        _createJsonLine(SyncEntityType.userDeleteV1.toString(), SyncUserDeleteV1(userId: "user1").toJson(), 'ack1'),
      ),
    );

    responseStreamController.addError(streamError);
    await expectLater(streamChangesFuture, throwsA(streamError));

    expect(onDataCallCount, 0);
  });

  test('streamChanges throws ApiException on non-200 status code', () async {
    when(() => mockStreamedResponse.statusCode).thenReturn(401);
    final errorBodyController = StreamController<List<int>>(sync: true);
    when(() => mockStreamedResponse.stream).thenAnswer((_) => http.ByteStream(errorBodyController.stream));

    int onDataCallCount = 0;
    Future<void> onDataCallback(List<SyncEvent> _, Function() _, Function() __) async {
      onDataCallCount++;
    }

    final future = streamChanges(onDataCallback, const SemVer(major: 2, minor: 5, patch: 0));

    errorBodyController.add(utf8.encode('{"error":"Unauthorized"}'));
    await errorBodyController.close();

    await expectLater(
      future,
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', 401)
            .having((e) => e.message, 'message', contains('Unauthorized')),
      ),
    );

    expect(onDataCallCount, 0);
  });
  test('a library-sized HTTP chunk stays within the database batch limit', () async {
    const count = 87204;
    int processed = 0;
    final sizes = <int>[];
    final payload =
        List.generate(
          count,
          (i) => _createJsonLine(
            SyncEntityType.userDeleteV1.toString(),
            SyncUserDeleteV1(userId: 'user$i').toJson(),
            'ack$i',
          ),
        ).join() +
        _createJsonLine('SyncCompleteV1', {}, 'complete');
    when(() => mockStreamedResponse.stream).thenAnswer((_) => http.ByteStream.fromBytes(utf8.encode(payload)));
    await sut.streamChanges(
      (events, _, _) async {
        sizes.add(events.length);
        processed += events.length;
      },
      httpClient: mockHttpClient,
      serverVersion: const SemVer(major: 3, minor: 1, patch: 97),
    );
    expect(processed, count + 1);
    expect(sizes.every((size) => size <= 5000), isTrue);
    expect(sizes.length, 18);
  });

  test('handles fragmented UTF-8, CRLF and a final event without newline', () async {
    final payload = utf8.encode(
      _createJsonLine('UserDeleteV1', {'userId': 'café'}, 'ack').replaceAll('\n', '\r\n') +
          jsonEncode({'type': 'SyncCompleteV1', 'data': {}, 'ack': 'done'}),
    );
    when(
      () => mockStreamedResponse.stream,
    ).thenAnswer((_) => http.ByteStream(Stream.fromIterable(payload.map((byte) => [byte]))));
    final received = <SyncEvent>[];
    await streamChanges((events, _, _) async => received.addAll(events), const SemVer(major: 3, minor: 1, patch: 97));
    expect(received.length, 2);
    expect((received.first.data as SyncUserDeleteV1).userId, 'café');
    expect(received.last.type, SyncEntityType.syncCompleteV1);
  });

  test('an interrupted modern stream cannot be reported as successful', () async {
    when(() => mockStreamedResponse.stream).thenAnswer(
      (_) => http.ByteStream.fromBytes(utf8.encode(_createJsonLine('UserDeleteV1', {'userId': 'user'}, 'ack'))),
    );
    final received = <SyncEvent>[];
    await expectLater(
      streamChanges((events, _, _) async => received.addAll(events), const SemVer(major: 3, minor: 1, patch: 97)),
      throwsA(isA<http.ClientException>()),
    );
    expect(received.single.ack, 'ack');
  });

  test('malformed final JSON fails rather than silently discarding records', () async {
    when(() => mockStreamedResponse.stream).thenAnswer((_) => http.ByteStream.fromBytes(utf8.encode('{"type":')));
    await expectLater(
      streamChanges((_, _, _) async {}, const SemVer(major: 3, minor: 1, patch: 97)),
      throwsA(isA<FormatException>()),
    );
  });

  test('server reset is a valid stream terminator', () async {
    when(
      () => mockStreamedResponse.stream,
    ).thenAnswer((_) => http.ByteStream.fromBytes(utf8.encode(_createJsonLine('SyncResetV1', {}, 'reset'))));
    await expectLater(streamChanges((_, _, _) async {}, const SemVer(major: 3, minor: 1, patch: 97)), completes);
  });
}
