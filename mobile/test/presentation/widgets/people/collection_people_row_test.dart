import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/people/collection_people_row.widget.dart';
import 'package:immich_mobile/providers/infrastructure/people.provider.dart';

import '../../../widget_tester_extensions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : true,
    );
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('people names fit with doubled text size on a narrow phone', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    addTearDown(tester.view.reset);
    await tester.pumpConsumerWidget(
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
          child: const Scaffold(body: CollectionPeopleRow(showNames: true)),
        ),
      ),
      overrides: [driftGetAllPeopleProvider.overrideWith((ref) async => [])],
    );
    expect(tester.getSize(find.byType(CollectionPeopleRow)).height, greaterThan(96));
    expect(tester.takeException(), isNull);
  });
}
