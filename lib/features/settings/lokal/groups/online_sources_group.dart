import 'package:flick/l10n/l10n.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flick/features/internet_radio/radio_providers.dart';
import 'package:flick/providers/opt_in_source_provider.dart';
import 'package:flick/features/settings/screens/network_sources_screen.dart';
import 'package:flick/features/settings/widgets/http_addons_settings_panel.dart';
import 'package:flick/features/settings/widgets/playback_source_priority_panel.dart';
import 'package:flick/features/settings/widgets/global_catalogue_selector.dart';
import 'package:flick/features/morneye/morneye_addons_screen.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';

import '../lokal_settings_group.dart';

void _push(BuildContext context, Widget page) => unawaited(
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)),
);

/// Online sources controls playback search, add-ons, servers and radio.
/// Account connections live under Data → Accounts.
List<LokalSettingsSection> onlineSourcesSettings(
  BuildContext context,
  WidgetRef ref,
) => [
  LokalSettingsSection(
    title: LokalOnlineSections.streaming,
    children: [
      LokalSettingRow.toggle(
        key: const ValueKey('monochrome-source-toggle'),
        label: 'Monochrome',
        description: lokalText('Search and stream FLAC from Monochrome.'),
        value: ref.watch(monochromeEnabledProvider),
        onChanged: (enabled) => unawaited(() async {
          try {
            await ref.read(monochromeEnabledProvider.notifier).set(enabled);
          } catch (_) {
            if (context.mounted) {
              LokalToast.fromSnackBar(
                context,
                SnackBar(
                  content: Text(
                    lokalText('Could not save source settings. Try again.'),
                  ),
                ),
              );
            }
          }
        }()),
      ),
      LokalSettingRow.toggle(
        key: const ValueKey('soundcloud-source-toggle'),
        label: 'SoundCloud',
        description: lokalText('Search and stream audio from SoundCloud.'),
        value: ref.watch(soundCloudEnabledProvider),
        onChanged: (enabled) => unawaited(() async {
          try {
            await ref.read(soundCloudEnabledProvider.notifier).set(enabled);
          } catch (_) {
            if (context.mounted) {
              LokalToast.fromSnackBar(
                context,
                SnackBar(
                  content: Text(
                    lokalText('Could not save source settings. Try again.'),
                  ),
                ),
              );
            }
          }
        }()),
      ),
      LokalSettingCustom(
        label: lokalText('Global search catalogue'),
        description: lokalText(
          'Choose the source of Global results; this does not affect playback source priority.',
        ),
        child: const GlobalCatalogueSelector(),
      ),
      LokalSettingCustom(
        label: lokalText('Playback search priority'),
        description: lokalText(
          'Try sources from top to bottom when finding a song to play. Installed add-ons appear here too.',
        ),
        child: PlaybackSourcePriorityPanel(
          key: ValueKey((ref.watch(monochromeEnabledProvider), ref.watch(soundCloudEnabledProvider))),
        ),
      ),
      LokalSettingLink(
        label: lokalText('Network servers'),
        description: lokalText(
          'Subsonic, Jellyfin, WebDAV and other servers you run.',
        ),
        onTap: () => _push(context, const NetworkSourcesScreen()),
      ),
    ],
  ),
  LokalSettingsSection(
    title: LokalOnlineSections.addons,
    children: [
      const MorneyeAddonsPanel(),
      LokalSettingCustom(
        label: lokalText('HTTP music add-ons'),
        description: lokalText(
          'Add HTTPS music catalogues using their manifest.json link.',
        ),
        child: HttpAddonsSettingsPanel(),
      ),
    ],
  ),
  const LokalSettingsSection(
    title: LokalOnlineSections.repositories,
    children: [MorneyeRepositoriesPanel()],
  ),
  LokalSettingsSection(
    title: LokalOnlineSections.radioVideos,
    children: [
      LokalSettingLink(
        label: lokalText('Station list'),
        description: ref.watch(radioCatalogUrlProvider),
        onTap: () => unawaited(_editCatalogUrl(context, ref)),
      ),
    ],
  ),
];

/// Desktop's "station list link": any https JSON in its radios.json format.
/// Empty goes back to Lokal's own list.
Future<void> _editCatalogUrl(BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController(
    text: ref.read(radioCatalogUrlProvider),
  );
  final url = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(lokalText('Station list')),
      content: TextField(
        controller: controller,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: const InputDecoration(
          hintText: 'https://…/radios.json',
          helperText: 'Leave empty for Lokal’s own list.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(lokalText('Cancel')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: Text(lokalText('Save')),
        ),
      ],
    ),
  );
  controller.dispose();
  if (url == null) return;
  final uri = Uri.tryParse(url.trim());
  if (url.trim().isNotEmpty && (uri == null || uri.scheme != 'https')) {
    if (!context.mounted) return;
    LokalToast.fromSnackBar(
      context,
      SnackBar(content: Text(lokalText('Use an https link to a JSON file.'))),
    );
    return;
  }
  await ref.read(radioCatalogUrlProvider.notifier).set(url);
}
