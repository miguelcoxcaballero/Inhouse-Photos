import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:mocktail/mocktail.dart';

import '../../infrastructure/repository.mock.dart';
import '../../repository.mocks.dart';
import '../mocks.dart';
import '../factories/local_asset_factory.dart';

void main() {
  late AssetService sut;
  late RepositoryMocks mocks;
  late MockAssetApiRepository apiRepository;
  late MockRemoteAssetRepository remoteRepository;
  late MockRemoteExifRepository exifRepository;

  setUp(() {
    mocks = RepositoryMocks();
    apiRepository = mocks.assetApi.api;
    remoteRepository = mocks.remoteAsset.repo;
    exifRepository = mocks.remoteExif.repo;

    sut = AssetService(
      remoteRepository: remoteRepository,
      exifRepository: exifRepository,
      localRepository: MockDriftLocalAssetRepository(),
      apiRepository: apiRepository,
    );
  });

  group('AssetService.getExif', () {
    test('reads Android GPS on demand when the bulk index omitted it', () async {
      final asset = LocalAssetFactory.create();
      final withLocationReader = AssetService(
        remoteRepository: remoteRepository,
        exifRepository: exifRepository,
        localRepository: MockDriftLocalAssetRepository(),
        apiRepository: apiRepository,
        localLocationReader: (opened) async {
          expect(opened, asset);
          return const ExifInfo(latitude: 0, longitude: 0);
        },
      );
      final result = await withLocationReader.getExif(asset);
      expect(result?.hasCoordinates, isTrue);
      expect(result?.latitude, 0);
      expect(result?.longitude, 0);
    });

    test('shows location before a local photo has been uploaded', () async {
      final asset = LocalAssetFactory.create().copyWith(latitude: 0, longitude: 24);
      final result = await sut.getExif(asset);

      expect(result?.hasCoordinates, isTrue);
      expect(result?.latitude, 0);
      expect(result?.longitude, 24);
      verifyZeroInteractions(remoteRepository);
    });

    test('keeps local photos without GPS unlocated', () async {
      final result = await sut.getExif(LocalAssetFactory.create());
      expect(result?.hasCoordinates, isFalse);
      expect(result?.latitude, isNull);
      expect(result?.longitude, isNull);
    });

    test('uses server metadata for the uploaded counterpart, including user location edits', () async {
      final asset = LocalAssetFactory.create(remoteId: 'remote-location').copyWith(latitude: 10, longitude: 20);
      const edited = ExifInfo(latitude: 0, longitude: 0, city: 'Edited location');
      when(() => remoteRepository.getExif('remote-location')).thenAnswer((_) async => edited);

      expect(await sut.getExif(asset), edited);
    });
  });

  group('AssetService.updateDateTime', () {
    const ids = ['asset_id_1'];

    test('sends the picked value to the api with its offset intact', () async {
      const picked = '2026-06-10T19:15:00.000+06:00';
      await sut.update(ids, dateTime: const .some(picked));

      verify(() => apiRepository.update(ids, dateTimeOriginal: const .some(picked))).called(1);
      verify(() => remoteRepository.update(ids, createdAt: .some(DateTime.parse(picked)))).called(1);
      verify(
        () => exifRepository.update(
          ids,
          dateTimeOriginal: .some(DateTime.parse(picked)),
          timeZone: const .some('UTC+06:00'),
        ),
      ).called(1);
    });

    test('handles negative offsets', () async {
      const picked = '2026-01-05T08:00:00.000-05:30';
      await sut.update(ids, dateTime: const .some(picked));

      verify(() => remoteRepository.update(ids, createdAt: .some(DateTime.parse(picked)))).called(1);
      verify(
        () => exifRepository.update(
          ids,
          dateTimeOriginal: .some(DateTime.parse(picked)),
          timeZone: const .some('UTC-05:30'),
        ),
      ).called(1);
    });

    test('writes no timezone when the value has no offset', () async {
      const picked = '2026-06-10T13:15:00.000Z';
      await sut.update(ids, dateTime: const .some(picked));

      verify(() => remoteRepository.update(ids, createdAt: .some(DateTime.parse(picked)))).called(1);
      verify(
        () => exifRepository.update(ids, dateTimeOriginal: .some(DateTime.parse(picked)), timeZone: const .none()),
      ).called(1);
    });

    test('is a no-op when there are no asset ids', () async {
      await sut.update(const [], dateTime: const .some('2026-06-10T19:15:00.000+06:00'));

      verifyZeroInteractions(apiRepository);
      verifyZeroInteractions(remoteRepository);
    });
  });
}
