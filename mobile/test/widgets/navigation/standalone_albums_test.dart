import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/models/albums/album_search.model.dart';
import 'package:immich_mobile/presentation/pages/drift_album.page.dart';
import 'package:immich_mobile/providers/album/album_sort_by_options.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/remote_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/routing/router.dart';

final _album = RemoteAlbum(
  id: 'album',
  name: 'Weekend photos',
  ownerId: 'owner',
  description: '',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  isActivityEnabled: false,
  order: AlbumAssetOrder.desc,
  assetCount: 4,
  ownerName: 'Owner',
  isShared: false,
);

class _Albums extends RemoteAlbumNotifier {
  @override
  RemoteAlbumState build() => const RemoteAlbumState(albums: []);

  @override
  Future<void> refresh() async => state = RemoteAlbumState(albums: [_album]);

  @override
  Future<List<RemoteAlbum>> sortAlbums(
    List<RemoteAlbum> albums,
    AlbumSortMode sortMode, {
    bool isReverse = false,
  }) async => albums;

  @override
  List<RemoteAlbum> searchAlbums(
    List<RemoteAlbum> albums,
    String query,
    String? userId, [
    QuickFilterMode filterMode = QuickFilterMode.all,
  ]) => albums.where((album) => album.name.toLowerCase().contains(query.toLowerCase())).toList();
}

class _User extends StateNotifier<UserDto?> implements CurrentUserProvider {
  _User() : super(null);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Assets implements AssetService {
  @override
  Future<RemoteAsset?> getRemoteAsset(String id) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Translations extends AssetLoader {
  const _Translations();
  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async => {
    'albums': 'Albums',
    'create_album': 'Create album',
    'search_albums': 'Search albums',
    'all': 'All',
    'shared_with_me': 'Shared with me',
    'my_albums': 'My albums',
    'library_page_sort_title': 'Title',
    'library_page_sort_asset_count': 'Number of photos',
    'library_page_sort_last_modified': 'Last modified',
    'library_page_sort_created': 'Date created',
    'sort_recent': 'Most recent',
    'sort_oldest': 'Oldest',
    'items_count': '{count} items',
    'shared_by_user': 'Shared by {user}',
    'album_search_not_found': 'No albums found',
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : true,
    );
    await EasyLocalization.ensureInitialized();
  });
  for (final textScale in [1.0, 2.0]) {
    testWidgets('standalone albums has Material, a usable search and back at 320px / text $textScale', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 800);
      addTearDown(tester.view.reset);
      final router = RootStackRouter.build(
        routes: [
          AutoRoute(
            initial: true,
            page: PageInfo('Collections', builder: (_) => const Scaffold(body: Text('Collections body'))),
          ),
          AutoRoute(page: PageInfo(DriftAlbumsRoute.name, builder: (_) => const DriftAlbumsPage())),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            remoteAlbumProvider.overrideWith(_Albums.new),
            currentUserProvider.overrideWith((_) => _User()),
            appConfigProvider.overrideWithValue(const AppConfig()),
            assetServiceProvider.overrideWithValue(_Assets()),
          ],
          child: EasyLocalization(
            supportedLocales: const [Locale('en')],
            path: 'unused',
            assetLoader: const _Translations(),
            child: Builder(
              builder: (context) => MaterialApp.router(
                locale: context.locale,
                supportedLocales: context.supportedLocales,
                localizationsDelegates: context.localizationDelegates,
                routerConfig: router.config(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
                  child: child!,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      unawaited(router.push(const DriftAlbumsRoute()));
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.text('Weekend photos'), findsOneWidget);
      expect(find.ancestor(of: find.byType(TextField), matching: find.byType(Material)), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField), 'missing');
      await tester.pumpAndSettle();
      expect(find.text('Weekend photos'), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Collections body'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
