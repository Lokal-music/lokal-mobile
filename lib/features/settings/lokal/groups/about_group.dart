import 'package:flick/features/updates/lokal_update_sheet.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flick/providers/app_build_info_provider.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/settings/lokal/lokal_licences_page.dart';
import 'package:flick/features/settings/screens/logs_screen.dart';
import 'package:flick/features/settings/screens/privacy_policy_screen.dart';
import 'package:flick/features/whats_new/widgets/whats_new_bottom_sheet.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';

void _push(BuildContext context, Widget page) => unawaited(
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)),
);

/// Where Lokal for Android's releases are published.
const lokalReleasesUrl =
    'https://github.com/Lokal-Konnekt/lokal-mobile/releases';

bool _licencesRegistered = false;

/// The open-source licences, with Flick's MIT licence (the upstream project
/// this app grew from) and the bundled Chinese font's added to the packages'
/// own.
void openLokalLicences(BuildContext context) {
  if (!_licencesRegistered) {
    _licencesRegistered = true;
    LicenseRegistry.addLicense(() async* {
      yield LicenseEntryWithLineBreaks([
        lokalUpstreamPackage,
      ], l10n.mitLicenseCopyrightC2026Flick);
      yield LicenseEntryWithLineBreaks([
        'Noto Sans SC',
      ], await rootBundle.loadString('assets/fonts/NotoSansSC-OFL.txt'));
      yield LicenseEntryWithLineBreaks(
        ['libsmb2 (native SMB2/3 library)'],
        await rootBundle.loadString('assets/licenses/libsmb2.txt'),
      );
    });
  }
  _push(context, const LokalLicencesPage());
}

/// About: version, updates, what's new, licences, privacy and logs.
List<LokalSettingsSection> aboutSettings(BuildContext context, WidgetRef ref) {
  final t = context.lokal;
  final build = ref.watch(appBuildInfoProvider);
  return [
    LokalSettingsSection(
      title: lokalText('About'),
      children: [
        LokalSettingRow(
          label: lokalText('Version'),
          description: lokalText('The version you’re running.'),
          trailing: Text(
            build.when(
              data: (info) => info.label,
              loading: () => '…',
              error: (_, _) => lokalText('Unavailable'),
            ),
            style: LokalTheme.label(t, size: 12, color: t.text),
          ),
        ),
        if (defaultTargetPlatform == TargetPlatform.android)
          LokalSettingLink(
            label: lokalText('Updates'),
            description: lokalText(
              'Check for updates, download and install a newer APK.',
            ),
            onTap: () => unawaited(showLokalUpdates(context, check: true)),
          ),
        LokalSettingLink(
          label: lokalText('What’s new'),
          description: lokalText('What changed in this version.'),
          onTap: () => unawaited(WhatsNewBottomSheet.show<void>(context)),
        ),
      ],
    ),
    LokalSettingsSection(
      title: lokalText('Legal'),
      children: [
        LokalSettingLink(
          label: lokalText('Licences'),
          description: lokalText(
            'The open-source software Lokal is built with.',
          ),
          onTap: () => openLokalLicences(context),
        ),
        LokalSettingLink(
          label: lokalText('Privacy'),
          description: lokalText('What Lokal keeps and what it sends.'),
          onTap: () => _push(context, const PrivacyPolicyScreen()),
        ),
      ],
    ),
    LokalSettingsSection(
      title: lokalText('Debug'),
      children: [
        LokalSettingLink(
          label: lokalText('Debug logs'),
          description: lokalText('Lokal’s logs, to attach to a bug report.'),
          onTap: () => _push(context, const LogsScreen()),
        ),
      ],
    ),
  ];
}
