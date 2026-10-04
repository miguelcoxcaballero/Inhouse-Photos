import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/backup_config.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/utils/background_sync.dart';
import 'package:immich_mobile/pages/backup/drift_backup.page.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/backup/backup_album.provider.dart';
import 'package:immich_mobile/providers/backup/drift_backup.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/permission.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:worker_manager/worker_manager.dart';

class _User extends StateNotifier<UserDto?> implements CurrentUserProvider {
  _User() : super(UserDto(id: 'user', email: 'test@example.com', name: 'Test', profileChangedAt: DateTime(2026)));
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Albums extends StateNotifier<List<LocalAlbum>> implements BackupAlbumNotifier {
  _Albums()
    : super([
        LocalAlbum(id: 'dcim', name: 'DCIM', updatedAt: DateTime(2026), backupSelection: BackupSelection.selected),
      ]);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Backup extends StateNotifier<DriftBackupState> implements DriftBackupNotifier {
  int starts = 0;
  _Backup()
    : super(
        const DriftBackupState(
          totalCount: 87204,
          backupCount: 41415,
          remainderCount: 45789,
          processingCount: 0,
          isSyncing: false,
          uploadItems: {},
        ),
      );
  @override
  Future<void> getBackupStatus(String id) async {}
  @override
  void updateSyncing(bool value) => state = state.copyWith(isSyncing: value);
  @override
  void updateError(BackupError error) => state = state.copyWith(error: error);
  @override
  Future<void> startForegroundBackup(String id) async {
    starts++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Permission extends StateNotifier<PermissionStatus> implements NotificationPermissionNotifier {
  _Permission() : super(PermissionStatus.granted);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Battery extends BatteryOptimizationNotifier {
  @override
  Future<PermissionStatus> build() async => PermissionStatus.granted;
}

class _Translations extends AssetLoader {
  const _Translations();
  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async => {'backup_retry_sync': 'Retry backup'};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : true,
    );
    await EasyLocalization.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (_) async => const StandardMessageCodec().encodeMessage([null]),
    );
  });

  testWidgets('an enabled backup recovers on the same screen after initial sync failure', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final backup = _Backup();
    int attempts = 0;
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith((_) => _User()),
        backupAlbumProvider.overrideWith((_) => _Albums()),
        driftBackupProvider.overrideWith((_) => backup),
        appConfigProvider.overrideWithValue(const AppConfig(backup: BackupConfig(enabled: true))),
        notificationPermissionProvider.overrideWith((_) => _Permission()),
        batteryOptimizationProvider.overrideWith(_Battery.new),
      ],
    );
    final manager = BackgroundSyncManager(
      remoteSyncRunner: () => Cancelable<bool?>.fromFuture(Future.value(++attempts > 1)),
      onRemoteSyncComplete: (success) {
        backup.updateError(success == true ? BackupError.none : BackupError.syncFailed);
        if (success == true) {
          container.read(syncStatusProvider.notifier).completeRemoteSync();
        } else {
          container.read(syncStatusProvider.notifier).errorRemoteSync('Connection interrupted');
        }
      },
    );
    final scope = ProviderContainer(parent: container, overrides: [backgroundSyncProvider.overrideWithValue(manager)]);
    addTearDown(() {
      scope.dispose();
      container.dispose();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: scope,
        child: EasyLocalization(
          supportedLocales: const [Locale('en')],
          path: 'unused',
          assetLoader: const _Translations(),
          child: Builder(
            builder: (context) => MaterialApp(
              locale: context.locale,
              supportedLocales: context.supportedLocales,
              localizationsDelegates: context.localizationDelegates,
              home: const DriftBackupPage(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(attempts, 1);
    expect(backup.starts, 0);
    expect(find.text('Connection interrupted'), findsOneWidget);
    expect(find.text('Retry backup'), findsOneWidget);
    await tester.ensureVisible(find.text('Retry backup'));
    await tester.tap(find.text('Retry backup'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(backup.starts, 1);
    expect(backup.state.error, BackupError.none);
    expect(backup.state.isSyncing, isFalse);
    expect(find.text('Retry backup'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
