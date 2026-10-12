import 'dart:io';
import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/widgets/settings/inhouse_updates_settings.dart';
import 'package:flutter_hooks/flutter_hooks.dart' hide Store;
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/settings/advanced_settings.dart';
import 'package:immich_mobile/widgets/settings/app_health_settings.dart';
import 'package:immich_mobile/widgets/settings/asset_list_settings/asset_list_settings.dart';
import 'package:immich_mobile/widgets/settings/asset_viewer_settings/asset_viewer_settings.dart';
import 'package:immich_mobile/widgets/settings/backup_settings/drift_backup_settings.dart';
import 'package:immich_mobile/widgets/settings/beta_sync_settings/sync_status_and_actions.dart';
import 'package:immich_mobile/widgets/settings/free_up_space_settings.dart';
import 'package:immich_mobile/widgets/settings/language_settings.dart';
import 'package:immich_mobile/widgets/settings/networking_settings/networking_settings.dart';
import 'package:immich_mobile/widgets/settings/notification_setting.dart';
import 'package:immich_mobile/widgets/settings/preference_settings/preference_setting.dart';
import 'package:immich_mobile/widgets/settings/settings_card.dart';
import 'package:immich_mobile/widgets/settings/server_management_settings.dart';

enum SettingSection {
  updates('Actualizaciones A/B', Icons.system_update_outlined, 'A: cambios recientes. B: versiones revisadas.'),
  health('App Health', Icons.health_and_safety_outlined, 'Connection, backup, storage and diagnostics'),
  server('Server management', Icons.dns_outlined, 'Disks, backups and Windows settings'),
  advanced('advanced', Icons.build_outlined, "advanced_settings_tile_subtitle"),
  assetViewer('asset_viewer_settings_title', Icons.image_outlined, "asset_viewer_settings_subtitle"),
  backup('backup', Icons.cloud_upload_outlined, "backup_settings_subtitle"),
  freeUpSpace('free_up_space', Icons.cleaning_services_outlined, "free_up_space_settings_subtitle"),
  languages('language', Icons.language, "setting_languages_subtitle"),
  networking('networking_settings', Icons.wifi, "networking_subtitle"),
  notifications('notifications', Icons.notifications_none_rounded, "setting_notifications_subtitle"),
  preferences('preferences_settings_title', Icons.interests_outlined, "preferences_settings_subtitle"),
  timeline('asset_list_settings_title', Icons.auto_awesome_mosaic_outlined, "asset_list_settings_subtitle"),
  beta('sync_status', Icons.sync_outlined, "sync_status_subtitle");

  final String title;
  final String subtitle;
  final IconData icon;

  Widget get widget => switch (this) {
    SettingSection.updates => const InhouseUpdatesSettings(),
    SettingSection.health => const AppHealthSettings(),
    SettingSection.server => const ServerManagementSettings(),
    SettingSection.advanced => const AdvancedSettings(),
    SettingSection.assetViewer => const AssetViewerSettings(),
    SettingSection.backup => const DriftBackupSettings(),
    SettingSection.freeUpSpace => const FreeUpSpaceSettings(),
    SettingSection.languages => const LanguageSettings(),
    SettingSection.networking => const NetworkingSettings(),
    SettingSection.notifications => const NotificationSetting(),
    SettingSection.preferences => const PreferenceSetting(),
    SettingSection.timeline => const AssetListSettings(),
    SettingSection.beta => const SyncStatusAndActions(),
  };

  const SettingSection(this.title, this.icon, this.subtitle);
}

const _settingGroups = [
  (title: 'backup', sections: [SettingSection.backup, SettingSection.freeUpSpace, SettingSection.server]),
  (
    title: 'preferences_settings_title',
    sections: [
      SettingSection.preferences,
      SettingSection.timeline,
      SettingSection.assetViewer,
      SettingSection.notifications,
      SettingSection.languages,
    ],
  ),
  (
    title: 'advanced',
    sections: [
      SettingSection.updates,
      SettingSection.health,
      SettingSection.networking,
      SettingSection.beta,
      SettingSection.advanced,
    ],
  ),
];

bool _isSectionAvailable(SettingSection section) => section != SettingSection.updates || Platform.isAndroid;

@RoutePage()
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    context.locale;
    return Scaffold(
      appBar: AppBar(centerTitle: false, title: context.isMobile ? null : const Text('settings').tr()),
      body: context.isMobile ? const _MobileLayout() : const _TabletLayout(),
    );
  }
}

class _MobileLayout extends StatelessWidget {
  const _MobileLayout();
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 60),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
          child: Text('settings'.tr(), style: context.textTheme.headlineLarge),
        ),
        for (final group in _settingGroups) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
            child: Text(group.title.tr(), style: context.textTheme.labelLarge?.copyWith(color: context.primaryColor)),
          ),
          SettingsGroup(
            children: [
              for (final setting in group.sections.where(_isSectionAvailable))
                SettingsCard(
                  title: setting.title.tr(),
                  subtitle: setting.subtitle.tr(),
                  icon: setting.icon,
                  settingRoute: setting == SettingSection.beta
                      ? const SyncStatusRoute()
                      : SettingsSubRoute(section: setting),
                ),
              if (group == _settingGroups.last)
                SettingsCard(
                  icon: Icons.auto_awesome_outlined,
                  title: context.t.whats_new,
                  subtitle: context.t.whats_new_settings_subtitle,
                  settingRoute: const WhatsNewRoute(),
                ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _TabletLayout extends HookWidget {
  const _TabletLayout();
  @override
  Widget build(BuildContext context) {
    final selectedSection = useState<SettingSection>(SettingSection.backup);

    return Row(
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: CustomScrollView(
            slivers: [
              for (final group in _settingGroups) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 16, 8),
                    child: Text(group.title.tr(), style: context.textTheme.labelLarge),
                  ),
                ),
                ...group.sections
                    .where(_isSectionAvailable)
                    .map(
                      (s) => SliverToBoxAdapter(
                        child: ListTile(
                          title: Text(s.title).tr(),
                          leading: Icon(s.icon),
                          selected: s == selectedSection.value,
                          selectedColor: context.primaryColor,
                          selectedTileColor: context.themeData.highlightColor,
                          onTap: () => selectedSection.value = s,
                        ),
                      ),
                    ),
              ],
              SliverToBoxAdapter(
                child: ListTile(
                  title: Text('whats_new'.tr()),
                  leading: const Icon(Icons.auto_awesome_outlined),
                  onTap: () => context.pushRoute(const WhatsNewRoute()),
                ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(flex: 4, child: selectedSection.value.widget),
      ],
    );
  }
}

@RoutePage()
class SettingsSubPage extends StatelessWidget {
  const SettingsSubPage(this.section, {super.key});

  final SettingSection section;

  @override
  Widget build(BuildContext context) {
    context.locale;
    return Scaffold(
      appBar: AppBar(centerTitle: false, title: Text(section.title).tr()),
      body: section.widget,
    );
  }
}
