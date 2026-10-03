import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:immich_mobile/providers/backup/drift_backup.provider.dart';
import 'package:immich_mobile/utils/upload_speed_calculator.dart';
import 'package:mocktail/mocktail.dart';

import '../api.mocks.dart';
import '../fixtures/asset.stub.dart';
import '../infrastructure/repository.mock.dart';
import '../mocks/asset_entity.mock.dart';
import '../repository.mocks.dart';

class MockBackgroundUploadService extends Mock implements BackgroundUploadService {}

void main() {
  late ForegroundUploadService sut;
  late MockUploadRepository mockUploadRepository;
  late MockStorageRepository mockStorageRepository;
  late MockDriftBackupRepository mockBackupRepository;
  late MockConnectivityApi mockConnectivityApi;
  late MockAssetMediaRepository mockAssetMediaRepository;
  late Drift db;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async => 'test',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (MethodCall methodCall) async => null,
    );
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: DriftStoreRepository(db));
    await SettingsRepository.ensureInitialized(db);

    await Store.put(StoreKey.serverEndpoint, 'http://demo.immich.app');
    await Store.put(StoreKey.deviceId, 'device-id');

    registerFallbackValue(File('file'));
    registerFallbackValue(<String, String>{});
    registerFallbackValue(LocalAssetStub.image1);
  });

  setUp(() {
    mockUploadRepository = MockUploadRepository();
    mockStorageRepository = MockStorageRepository();
    mockBackupRepository = MockDriftBackupRepository();
    mockConnectivityApi = MockConnectivityApi();
    mockAssetMediaRepository = MockAssetMediaRepository();

    sut = ForegroundUploadService(
      mockUploadRepository,
      mockStorageRepository,
      mockBackupRepository,
      mockConnectivityApi,
      mockAssetMediaRepository,
    );
  });

  List<Map<String, String>> captureFields() {
    final captured = <Map<String, String>>[];
    when(
      () => mockUploadRepository.uploadFile(
        file: any(named: 'file'),
        originalFileName: any(named: 'originalFileName'),
        fields: any(named: 'fields'),
        cancelToken: any(named: 'cancelToken'),
        onProgress: any(named: 'onProgress'),
        logContext: any(named: 'logContext'),
        canUsePublicRoute: any(named: 'canUsePublicRoute'),
      ),
    ).thenAnswer((invocation) async {
      final fields = invocation.namedArguments[#fields] as Map<String, String>;
      captured.add(Map.of(fields));
      return UploadResult.success(remoteAssetId: 'remote-${captured.length}');
    });
    return captured;
  }

  List<String> captureOriginalFileNames() {
    final captured = <String>[];
    when(
      () => mockUploadRepository.uploadFile(
        file: any(named: 'file'),
        originalFileName: any(named: 'originalFileName'),
        fields: any(named: 'fields'),
        cancelToken: any(named: 'cancelToken'),
        onProgress: any(named: 'onProgress'),
        logContext: any(named: 'logContext'),
        canUsePublicRoute: any(named: 'canUsePublicRoute'),
      ),
    ).thenAnswer((invocation) async {
      captured.add(invocation.namedArguments[#originalFileName] as String);
      return UploadResult.success(remoteAssetId: 'remote-${captured.length}');
    });
    return captured;
  }

  test('stores 200 uploads without any compression acknowledgement and bounds the processing display', () async {
    final temp = await Directory.systemTemp.createTemp('durable-upload-backlog-');
    final original = await File('${temp.path}/photo.jpg').writeAsBytes(List.filled(1024, 1));
    final assets = List.generate(200, (index) => LocalAssetStub.image1.copyWith(id: 'photo-$index'));
    final localAssets = MockDriftLocalAssetRepository();
    final remoteAssets = MockRemoteAssetRepository();
    final entity = MockAssetEntity();
    when(() => entity.isLivePhoto).thenReturn(false);
    when(() => mockStorageRepository.clearCache()).thenAnswer((_) async {});
    when(() => mockStorageRepository.getAssetEntityForAsset(any())).thenAnswer((_) async => entity);
    when(() => mockStorageRepository.isAssetAvailableLocally(any())).thenAnswer((_) async => true);
    when(() => mockStorageRepository.getFileForAsset(any())).thenAnswer((_) async => original);
    when(() => mockAssetMediaRepository.getOriginalFilename(any())).thenAnswer((_) async => 'photo.jpg');
    when(() => mockConnectivityApi.getCapabilities()).thenAnswer((_) async => [NetworkCapability.unmetered]);
    when(
      () => mockUploadRepository.prepareLocalRoute(isUnmetered: any(named: 'isUnmetered')),
    ).thenAnswer((_) async => true);
    when(() => mockBackupRepository.getCandidates('owner')).thenAnswer((_) async => assets);
    when(
      () => mockBackupRepository.getAllCounts('owner'),
    ).thenAnswer((_) async => (total: assets.length, remainder: assets.length, processing: 0));
    when(() => localAssets.getById(any())).thenAnswer((invocation) async {
      return assets.firstWhere((asset) => asset.id == invocation.positionalArguments.first);
    });
    when(
      () => remoteAssets.registerCompletedUpload(
        remoteId: any(named: 'remoteId'),
        ownerId: any(named: 'ownerId'),
        source: any(named: 'source'),
      ),
    ).thenAnswer((_) async {});
    final captured = captureFields();
    final notifier = DriftBackupNotifier(
      sut,
      MockBackgroundUploadService(),
      UploadSpeedManager(),
      localAssets,
      remoteAssets,
      SettingsRepository.instance,
    );
    try {
      await notifier.getBackupStatus('owner');
      // No websocket connection/event is provided: an arbitrarily slow or
      // paused compressor must not stop this complete backup pass.
      await notifier.startForegroundBackup('owner').timeout(const Duration(seconds: 5));
      expect(captured, hasLength(assets.length));
      expect(captured.every((fields) => fields['storageSaver'] == 'true'), isTrue);
      expect(notifier.state.backupCount, assets.length);
      expect(notifier.state.remainderCount, 0);
      expect(notifier.state.uploadItems, hasLength(128));
      expect(notifier.state.uploadItems.values.every((item) => item.progress == 1 && item.isCloudProcessing), isTrue);
      expect(await original.exists(), isTrue);
      verify(
        () => remoteAssets.registerCompletedUpload(
          remoteId: any(named: 'remoteId'),
          ownerId: 'owner',
          source: any(named: 'source'),
        ),
      ).called(assets.length);

      // The receipt remains complete while late processing events are still
      // reflected for recent uploads after the backup pass has returned.
      EventStream.shared.emit(
        const ServerCompressionProgressEvent(
          assetId: 'remote-200',
          progress: 0.5,
          state: 'processing',
          originalBytes: 1024,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(notifier.state.uploadItems['photo-199']?.preparationProgress, 0.5);
      expect(notifier.state.uploadItems['photo-199']?.progress, 1);
      expect(notifier.state.backupCount, assets.length);

      // Encoding failure keeps the acknowledged original backed up. It is a
      // server processing result, not a failed phone transfer to retry.
      EventStream.shared.emit(
        const ServerCompressionProgressEvent(assetId: 'remote-200', progress: 1, state: 'failed', originalBytes: 1024),
      );
      await Future<void>.delayed(Duration.zero);
      final storedItem = notifier.state.uploadItems['photo-199'];
      expect(storedItem?.compressionState, 'failed');
      expect(storedItem?.progress, 1);
      expect(storedItem?.isFailed, isNot(true));
      expect(notifier.state.backupCount, assets.length);
      expect(notifier.state.remainderCount, 0);
      expect(notifier.state.errorCount, 0);
    } finally {
      notifier.stopForegroundBackup();
      notifier.dispose();
      await temp.delete(recursive: true);
    }
  });

  group('uploadSingleAsset', () {
    test('should upload the motion part hidden and keep the still image visible', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/still.heic');
      final videoFile = File('/path/to/motion.mov');

      when(() => mockEntity.isLivePhoto).thenReturn(true);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockStorageRepository.getMotionFileForAsset(asset)).thenAnswer((_) async => videoFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'live.heic');

      final captured = captureFields();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      expect(captured, hasLength(2));
      expect(captured[0]['visibility'], equals('hidden'));
      expect(captured[0].containsKey('livePhotoVideoId'), isFalse);
      expect(captured[1].containsKey('visibility'), isFalse);
      expect(captured[1]['livePhotoVideoId'], equals('remote-1'));
      expect(captured[0]['storageSaver'], equals('true'));
      expect(captured[1]['storageSaver'], equals('true'));
    });

    test('should not set visibility for a regular photo', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/photo.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'photo.jpg');

      final captured = captureFields();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      expect(captured, hasLength(1));
      expect(captured[0].containsKey('visibility'), isFalse);
      expect(captured[0]['storageSaver'], equals('true'));
    });

    test('backup fallback checks the actual current network before permitting public upload', () async {
      final asset = LocalAssetStub.image1;
      final entity = MockAssetEntity();
      when(() => entity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => entity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => File('/path/photo.jpg'));
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'photo.jpg');
      when(() => mockConnectivityApi.getCapabilities()).thenAnswer((_) async => [NetworkCapability.cellular]);
      bool? permitted;
      when(
        () => mockUploadRepository.uploadFile(
          file: any(named: 'file'),
          originalFileName: any(named: 'originalFileName'),
          fields: any(named: 'fields'),
          cancelToken: any(named: 'cancelToken'),
          onProgress: any(named: 'onProgress'),
          logContext: any(named: 'logContext'),
          canUsePublicRoute: any(named: 'canUsePublicRoute'),
        ),
      ).thenAnswer((invocation) async {
        final policy = invocation.namedArguments[#canUsePublicRoute] as Future<bool> Function();
        permitted = await policy();
        return UploadResult.networkPolicyBlocked();
      });
      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks(), enforceBackupNetworkPolicy: true);
      expect(permitted, isFalse);
      verify(() => mockConnectivityApi.getCapabilities()).called(1);
    });

    test('explicit manual asset uploads do not inherit the automatic backup cellular restriction', () async {
      final asset = LocalAssetStub.image1;
      final entity = MockAssetEntity();
      when(() => entity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => entity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => File('/path/photo.jpg'));
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'photo.jpg');
      final captured = captureFields();
      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());
      expect(captured, hasLength(1));
      verifyNever(() => mockConnectivityApi.getCapabilities());
    });

    test('waits for the successful-upload callback before completing', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/photo.jpg');
      var callbackCompleted = false;

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'photo.jpg');
      captureFields();

      await sut.uploadSingleAsset(
        asset,
        null,
        callbacks: UploadCallbacks(
          onSuccess: (localId, remoteId) async {
            expect(localId, asset.localId);
            expect(remoteId, 'remote-1');
            await Future<void>.delayed(const Duration(milliseconds: 10));
            callbackCompleted = true;
          },
        ),
      );

      expect(callbackCompleted, isTrue);
    });

    test('corrects the extension when iOS returns a rendered file for a .dng asset', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/IMG_6499.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'IMG_6499.dng');

      final names = captureOriginalFileNames();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      expect(names, equals(['IMG_6499.jpg']));
    });

    test('keeps the .dng extension for a genuine RAW original', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/IMG_5210.dng');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'IMG_5210.dng');

      final names = captureOriginalFileNames();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      expect(names, equals(['IMG_5210.dng']));
    });

    test('borrows the extension from the asset name for an extensionless name (DJI/Fusion)', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/DJI_0001');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'DJI_0001');

      final names = captureOriginalFileNames();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      expect(names, equals(['DJI_0001.jpg']));
    });
  });
}
