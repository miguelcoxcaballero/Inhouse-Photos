import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';

extension PumpConsumerWidget on WidgetTester {
  /// Wraps the provided [widget] with a localized Material app such that it
  /// becomes:
  ///
  /// EasyLocalization
  ///   |-ProviderScope
  ///     |-MaterialApp (localization delegates wired up)
  ///       |-Material
  ///         |-[widget]
  ///
  /// Set [settle] to false when the test needs to observe an intermediate
  /// state, such as a timeline whose rows are still loading; `pumpAndSettle`
  /// would otherwise wait for exactly the state under test to disappear.
  Future<void> pumpConsumerWidget(
    Widget widget, {
    Duration? duration,
    EnginePhase phase = EnginePhase.sendSemanticsUpdate,
    List<Override> overrides = const [],
    bool settle = true,
  }) async {
    await pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locales.values.first,
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: ProviderScope(
          overrides: overrides,
          child: Builder(
            builder: (context) => MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: Material(child: widget),
            ),
          ),
        ),
      ),
      duration: duration,
      phase: phase,
    );
    if (settle) {
      await pumpAndSettle();
    }
  }
}
