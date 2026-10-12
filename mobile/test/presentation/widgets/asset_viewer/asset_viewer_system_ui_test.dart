import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';

import '../../../fixtures/asset.stub.dart';
import '../../../unit/presentation/presentation_context.dart';

class _SeededAssetViewerNotifier extends AssetViewerStateNotifier {
  @override
  AssetViewerState build() {
    super.build();
    return AssetViewerState(currentAsset: LocalAssetStub.image1);
  }
}

TimelineService _stubTimelineService() {
  return TimelineService((
    assetSource: (index, count) async => [LocalAssetStub.image1],
    bucketSource: () => Stream.value(const [Bucket(assetCount: 1)]),
    assetSourceAfter: null,
    origin: TimelineOrigin.main,
  ));
}

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  for (final brightness in Brightness.values) {
    testWidgets('viewer canvas and system icons follow the effective ${brightness.name} theme', (tester) async {
      final theme = ThemeData(brightness: brightness);
      final expectedIcons = brightness == Brightness.dark ? Brightness.light : Brightness.dark;
      // Use the opposite platform setting to ensure an explicit app theme wins.
      tester.platformDispatcher.platformBrightnessTestValue = brightness == Brightness.dark
          ? Brightness.light
          : Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);

      await tester.pumpWidget(
        EasyLocalization(
          supportedLocales: locales.values.toList(),
          path: translationsPath,
          startLocale: locales.values.first,
          fallbackLocale: locales.values.first,
          saveLocale: false,
          useFallbackTranslations: true,
          assetLoader: const CodegenLoader(),
          child: ProviderScope(
            overrides: [
              ...context.overrides,
              timelineServiceProvider.overrideWithValue(_stubTimelineService()),
              assetViewerProvider.overrideWith(_SeededAssetViewerNotifier.new),
            ],
            child: Builder(
              builder: (context) => MaterialApp(
                debugShowCheckedModeBanner: false,
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                locale: context.locale,
                theme: theme,
                home: const Material(child: AssetViewer(initialIndex: 0)),
              ),
            ),
          ),
        ),
      );

      // Let post-frame callbacks and the initial frames run without waiting for
      // infinite animations (loading spinners) to settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      // Asset thumbnails cannot load in the test environment (no platform
      // channels / real HTTP). Those image errors are irrelevant to the system
      // chrome behaviour under test, so drain them.
      tester.takeException();

      final viewerScaffold = tester.widget<Scaffold>(
        find.descendant(of: find.byType(AssetViewer), matching: find.byType(Scaffold)).first,
      );
      expect(viewerScaffold.backgroundColor, theme.colorScheme.surface);
      expect(SystemChrome.latestStyle?.statusBarIconBrightness, expectedIcons);
      expect(SystemChrome.latestStyle?.systemNavigationBarIconBrightness, expectedIcons);
    });
  }
}
