import 'package:flick/l10n/l10n.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flick/features/settings/library_scan/library_scan_flow.dart';
import 'package:flick/features/settings/screens/artwork_repair_screen.dart';
import 'package:flick/features/settings/screens/duplicate_cleaner_screen.dart';
import 'package:flick/features/settings/screens/library_settings_screen.dart';
import 'package:flick/features/settings/screens/library_organizer_screen.dart';
import 'package:flick/features/settings/screens/missing_metadata_screen.dart';
import 'package:flick/providers/app_preferences_provider.dart';
import 'package:flick/providers/library_scan_preferences_provider.dart';
import 'package:flick/services/apple_music/apple_music_settings.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';

void _push(BuildContext context, Widget page) => unawaited(
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)),
);

/// Minimum length's three stops over the two scan switches it replaces:
/// keep everything, skip files under 500 KB, and also skip songs under 60 s.
const _minimumLengthLabels = ['Off', '500 KB', '60 s'];

List<LokalSettingsSection> librarySettings(
  BuildContext context,
  WidgetRef ref,
) {
  final scan = ref.watch(libraryScanPreferencesProvider);
  final notifier = ref.read(libraryScanPreferencesProvider.notifier);
  final minimum = scan.ignoreTracksShorterThan60Seconds
      ? 2
      : scan.ignoreTracksSmallerThan500Kb
      ? 1
      : 0;
  return [
    LokalSettingsSection(
      title: lokalText('Folders'),
      children: [
        LokalSettingRow(
          key: const ValueKey('library-add-folder'),
          icon: Icons.create_new_folder_rounded,
          label: lokalText('Add folder'),
          description: lokalText(
            'Pick a folder on your phone; Lokal scans it straight away.',
          ),
          onTap: () => unawaited(LibraryScanFlow.addFolder(context)),
        ),
        LokalSettingLink(
          label: lokalText('Manage folders'),
          description: lokalText(
            'See and remove your folders, rescan (quick, full or deep), full library access.',
          ),
          onTap: () => _push(context, const LibrarySettingsScreen()),
        ),
        if (Platform.isAndroid)
          LokalSettingRow.toggle(
            label: lokalText('Deep scan'),
            description: lokalText(
              'Read folders directly instead of asking Android’s media index, to find everything.',
            ),
            value: scan.useDeepScan,
            onChanged: notifier.setUseDeepScan,
          ),
      ],
    ),
    LokalSettingsSection(
      title: lokalText('Scanning'),
      children: [
        LokalSettingRow.toggle(
          label: lokalText('Skip non-music files'),
          description: lokalText(
            'Leave out unsupported files and folders marked hidden or .nomedia.',
          ),
          value: scan.filterNonMusicFilesAndFolders,
          onChanged: notifier.setFilterNonMusicFilesAndFolders,
        ),
        LokalSettingSlider(
          label: lokalText('Minimum length'),
          description: lokalText(
            'Leave out tiny files when scanning, like clips, ringtones and voice notes. Off keeps everything.',
          ),
          value: minimum.toDouble(),
          min: 0,
          max: 2,
          divisions: 2,
          valueLabel: (v) => _minimumLengthLabels[v.round()],
          onChanged: (v) async {
            final stop = v.round();
            await notifier.setIgnoreTracksSmallerThan500Kb(stop >= 1);
            await notifier.setIgnoreTracksShorterThan60Seconds(stop >= 2);
          },
        ),
        LokalSettingRow.toggle(
          label: lokalText('Import M3U'),
          description: lokalText(
            'Make playlists from the M3U and M3U8 files in your folders, and keep them up to date.',
          ),
          value: scan.createPlaylistsFromM3uFiles,
          onChanged: notifier.setCreatePlaylistsFromM3uFiles,
        ),
      ],
    ),
    LokalSettingsSection(
      title: lokalText('Covers'),
      children: [
        LokalSettingLink(
          label: lokalText('Refresh low-quality covers'),
          description: lokalText(
            'Check covers smaller than 640 px and replace only exact album matches. Custom artwork is preserved.',
          ),
          onTap: () => _push(context, const ArtworkRepairScreen()),
        ),
        LokalSettingRow.toggle(
          label: lokalText('Stretch non-square covers'),
          description: lokalText(
            'Fill the square with covers that aren’t square. Off crops them instead.',
          ),
          value: ref.watch(appPreferencesProvider).albumsStretchArtwork,
          onChanged: ref
              .read(appPreferencesProvider.notifier)
              .setAlbumsStretchArtwork,
        ),
      ],
    ),
    const LokalSettingsSection(
      title: 'Look up missing info',
      children: [_LookUpMissingInfo()],
    ),
    LokalSettingsSection(
      title: lokalText('Maintenance'),
      children: [
        LokalSettingLink(
          label: lokalText('Organize existing library'),
          description: lokalText(
            'Preview moving your existing music into Artist/Album folders while keeping likes, playlists and history.',
          ),
          onTap: () => _push(context, const LibraryOrganizerScreen()),
        ),
        LokalSettingLink(
          label: lokalText('Find duplicates'),
          description: lokalText(
            'Find matching library entries by title and artist. Removing one only removes its Lokal entry; your files stay untouched.',
          ),
          onTap: () => _push(context, const DuplicateCleanerScreen()),
        ),
        LokalSettingLink(
          label: lokalText('Missing metadata'),
          description: lokalText(
            'Albums with an unknown artist or no cover, to fix.',
          ),
          onTap: () => _push(context, const MissingMetadataScreen()),
        ),
      ],
    ),
  ];
}

/// Apple Music's catalogue fills in untagged albums after a scan.
class _LookUpMissingInfo extends StatefulWidget implements LokalSearchable {
  const _LookUpMissingInfo();

  static const _label = 'Look up missing info';
  static const _description =
      'After a scan, match files with missing tags against Apple Music. Only confident matches apply.';

  @override
  String get searchText => '$_label $_description Apple Music';

  @override
  State<_LookUpMissingInfo> createState() => _LookUpMissingInfoState();
}

class _LookUpMissingInfoState extends State<_LookUpMissingInfo> {
  final _settings = AppleMusicSettings();
  bool? _enabled;

  @override
  void initState() {
    super.initState();
    unawaited(
      _settings.autoEnrichEnabled().then((value) {
        if (mounted) setState(() => _enabled = value);
      }),
    );
  }

  Future<void> _set(bool value) async {
    setState(() => _enabled = value);
    await _settings.setAutoEnrichEnabled(value);
  }

  @override
  Widget build(BuildContext context) => LokalSettingRow.toggle(
    label: _LookUpMissingInfo._label,
    description: _LookUpMissingInfo._description,
    value: _enabled ?? false,
    enabled: _enabled != null,
    onChanged: _set,
  );
}
