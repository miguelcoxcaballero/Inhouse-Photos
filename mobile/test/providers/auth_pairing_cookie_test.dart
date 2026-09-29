import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/services/auth.service.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';
import 'package:immich_mobile/services/widget.service.dart';
import 'package:mocktail/mocktail.dart';

import '../service.mocks.dart';

class MockAuthService extends Mock implements AuthService {}

class MockSecureStorageService extends Mock implements SecureStorageService {}

class MockWidgetService extends Mock implements WidgetService {}

class MockRef extends Mock implements Ref {}

void main() {
  late Drift db;

  setUpAll(() async {
    WidgetsFlutterBinding.ensureInitialized();
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: DriftStoreRepository(db));
  });

  tearDownAll(() async {
    await Store.dispose();
    await db.close();
  });

  test('a redeemed access token is handed to the native HTTP cookie jar before fetching the account', () async {
    const token = 'redeemed-pairing-session';
    final apiService = MockApiService();
    final stop = StateError('stop at native cookie seeding');
    when(() => apiService.updateHeaders(token: token)).thenThrow(stop);

    final auth = AuthNotifier(
      MockAuthService(),
      apiService,
      MockUserService(),
      MockSecureStorageService(),
      MockWidgetService(),
      MockRef(),
    );
    addTearDown(auth.dispose);

    await expectLater(auth.saveAuthInfo(accessToken: token), throwsA(same(stop)));

    expect(Store.get(StoreKey.accessToken), token);
    verify(() => apiService.updateHeaders(token: token)).called(1);
  });
}
