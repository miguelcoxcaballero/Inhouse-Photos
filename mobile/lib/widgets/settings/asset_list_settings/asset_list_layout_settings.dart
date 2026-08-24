import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/config/timeline_config.dart';
import 'package:immich_mobile/extensions/translate_extensions.dart';
import 'package:immich_mobile/providers/app_settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/widgets/settings/setting_group_title.dart';
import 'package:immich_mobile/widgets/settings/settings_slider_list_tile.dart';

class LayoutSettings extends HookConsumerWidget {
  const LayoutSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final initialColumns = normalizeTimelineTilesPerRow(
      ref.read(appConfigProvider.select((s) => s.timeline.tilesPerRow)),
    );
    final selectedStep = useState(timelineTilesPerRowStepIndex(initialColumns));
    final tilesPerRow = timelineTilesPerRowSteps[selectedStep.value];
    useValueChanged<int, void>(selectedStep.value, (_, __) {
      ref.read(settingsProvider).write(.timelineTilesPerRow, timelineTilesPerRowSteps[selectedStep.value]);
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingGroupTitle(
          title: "asset_list_layout_sub_title".t(context: context),
          icon: Icons.view_module_outlined,
        ),
        SettingsSliderListTile(
          valueNotifier: selectedStep,
          text: 'theme_setting_asset_list_tiles_per_row_title'.tr(namedArgs: {'count': '$tilesPerRow'}),
          label: '$tilesPerRow',
          maxValue: (timelineTilesPerRowSteps.length - 1).toDouble(),
          minValue: 0,
          noDivisons: timelineTilesPerRowSteps.length - 1,
          onChangeEnd: (value) {
            ref.invalidate(appSettingsServiceProvider);
          },
        ),
      ],
    );
  }
}
