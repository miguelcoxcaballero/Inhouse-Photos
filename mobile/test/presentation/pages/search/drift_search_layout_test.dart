import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/search_result.model.dart';
import 'package:immich_mobile/domain/services/search.service.dart';
import 'package:immich_mobile/models/search/search_filter.model.dart';
import 'package:immich_mobile/presentation/pages/search/drift_search.page.dart';
import 'package:immich_mobile/providers/infrastructure/people.provider.dart';
import 'package:immich_mobile/providers/infrastructure/search.provider.dart';
import 'package:immich_mobile/providers/infrastructure/user_metadata.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/services/server_info.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../../widget_tester_extensions.dart';

class _ServerService extends Mock implements ServerInfoService {}

class _SearchService extends Mock implements SearchService {
  final requests = <SearchFilter>[];

  @override
  Future<SearchResult?> search(SearchFilter filter, int page) async {
    requests.add(filter);
    return const SearchResult(assets: []);
  }
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

  Future<void> pumpSearch(WidgetTester tester, _SearchService service) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);
    await tester.pumpConsumerWidget(
      const DriftSearchPage(),
      overrides: [
        serverInfoProvider.overrideWith((ref) => ServerInfoNotifier(_ServerService())),
        userMetadataPreferencesProvider.overrideWith((ref) async => null),
        driftGetAllPeopleProvider.overrideWith((ref) async => []),
        searchServiceProvider.overrideWithValue(service),
      ],
    );
  }

  testWidgets('bottom search field remains above the keyboard on a phone', (tester) async {
    await pumpSearch(tester, _SearchService());
    final field = find.byKey(const Key('search_text_field'));
    expect(tester.getTopLeft(field).dy, greaterThan(700));

    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pumpAndSettle();

    expect(tester.getBottomRight(field).dy, lessThanOrEqualTo(915 - 320));
    expect(tester.takeException(), isNull);
    expect(find.byType(BackButton), findsOneWidget);
  });

  testWidgets('filename search, clearing and real recent-query replay remain functional', (tester) async {
    final service = _SearchService();
    await pumpSearch(tester, service);
    final field = find.byKey(const Key('search_text_field'));
    await tester.enterText(field, '  IMG_2026.jpg  ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(service.requests.single.filename, 'IMG_2026.jpg');

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.text('IMG_2026.jpg'), findsOneWidget);
    expect(service.requests, hasLength(1));

    await tester.tap(find.text('IMG_2026.jpg'));
    await tester.pumpAndSettle();
    expect(service.requests, hasLength(2));
    expect(service.requests.last.filename, 'IMG_2026.jpg');
    expect(tester.takeException(), isNull);
  });
}
