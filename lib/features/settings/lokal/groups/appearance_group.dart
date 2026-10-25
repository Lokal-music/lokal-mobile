import 'package:flick/features/appearance/lokal_performance_selector.dart';
import 'package:flick/features/settings/widgets/spotify_account_settings_tile.dart';

import 'dart:async';
import 'dart:io';

import 'package:flick/services/motion_art/moving_cover_settings.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flick/core/theme/lokal_appearance.dart';
import 'package:flick/core/utils/app_haptics.dart';
import 'package:flick/features/appearance/lokal_appearance_screen.dart';
import 'package:flick/features/settings/screens/widget_settings_screen.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';

void _push(BuildContext context, Widget page) => unawaited(
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)),
);

/// Theme/accent controls, plus explicit iPhone icon selection. iOS icon changes
/// are user initiated because the system presents its own confirmation alert.
List<LokalSettingsSection> themeAccentSettings(
  BuildContext context,
  WidgetRef ref,
) {
  final appearance = ref.watch(lokalAppearanceProvider);
  final look = ref.read(lokalAppearanceProvider.notifier);
  return [
    LokalSettingsSection(
      title: lokalText('Theme & accent'),
      children: [
        LokalSettingRow(
          label: lokalText('Theme'),
          description: lokalText('Desktop Lokal’s ten themes.'),
          stacked: true,
          trailing: LokalThemeGrid(
            padding: EdgeInsets.zero,
            selected: appearance.theme,
            onSelect: (id) {
              HapticFeedback.selectionClick();
              look.selectTheme(id);
            },
          ),
        ),
        LokalSettingRow(
          label: lokalText('Accent'),
          description: Platform.isIOS
              ? 'Colors inside Lokal. Choose the Home Screen icon separately below.'
              : lokalText(
                  'The app icon follows your accent after you leave Lokal with playback idle. Some launchers restart the app when updating its icon.',
                ),
          stacked: true,
          trailing: LokalAccentRow(
            padding: EdgeInsets.zero,
            selected: appearance.accent,
            onSelect: (accent) {
              HapticFeedback.selectionClick();
              look.setAccent(accent);
            },
          ),
        ),
        if (Platform.isIOS)
          LokalSettingLink(
            label: 'App icon',
            description: 'Choose a Lokal icon for your iPhone Home Screen.',
            onTap: () => unawaited(
              const MethodChannel('lokal/ios')
                  .invokeMethod<bool>('showIconPicker'),
            ),
          ),
      ],
    ),
  ];
}

List<LokalSettingsSection> appearanceSettings(
  BuildContext context,
  WidgetRef ref,
) {
  final appearance = ref.watch(lokalAppearanceProvider);
  final look = ref.read(lokalAppearanceProvider.notifier);
  final prefs = ref.watch(appPreferencesProvider);
  final notifier = ref.read(appPreferencesProvider.notifier);
  final moving = ref.watch(movingCoverSettingsProvider);
  final motion = ref.read(movingCoverSettingsProvider.notifier);
  return [
    LokalSettingsSection(
      title: lokalText('Theme'),
      children: [
        ...themeAccentSettings(context, ref).single.children,
        LokalSettingSlider(
          label: lokalText('Text size'),
          description: lokalText('Bigger or smaller text across Lokal.'),
          value: appearance.textScale,
          min: LokalAppearance.minTextScale,
          max: LokalAppearance.maxTextScale,
          divisions: 16,
          valueLabel: (v) => '${(v * 100).round()}%',
          semanticFormatter: (v) => '${(v * 100).round()} percent',
          onChanged: look.setTextScale,
        ),
        lokalPerformanceSelector(ref),
      ],
    ),
    LokalSettingsSection(
      title: lokalText('Now Playing'),
      children: [
        LokalSettingRow.toggle(
          label: lokalText('Unboxed player controls'),
          description: lokalText(
            'Remove button backgrounds while keeping the same icons and layout.',
          ),
          value: appearance.unboxedPlayerControls,
          onChanged: look.setUnboxedPlayerControls,
        ),
        LokalSettingRow.toggle(
          label: lokalText('Fullscreen cover'),
          description: lokalText(
            'Extend album covers behind the header and fade them into the player. Spotify Canvas fills the screen.',
          ),
          value: appearance.fullscreenCover,
          onChanged: look.setFullscreenCover,
        ),
        LokalSettingRow.toggle(
          label: lokalText('Moving covers'),
          description: lokalText(
            'Play an animated cover or Canvas in either player, when one is available.',
          ),
          value: prefs.animatedAlbumArt,
          onChanged: notifier.setAnimatedAlbumArt,
        ),
        if (prefs.animatedAlbumArt) ...[
          for (final source in movingCoverSources.entries)
            LokalSettingRow.toggle(
              label: source.value,
              description: source.key == 'spotify'
                  ? lokalText(
                      'Uses your Spotify account in You → Data → Accounts.',
                    )
                  : source.key == 'apple'
                  ? lokalText(
                      'Animated album covers, with Apple lookup fallback.',
                    )
                  : source.key == 'tidal'
                  ? lokalText('Video album covers.')
                  : source.key == 'community'
                  ? lokalText('Clips shared by other listeners.')
                  : lokalText(
                      'Apple animated artwork through artwork.m8tec.top.',
                    ),
              value: moving.sources.contains(source.key),
              onChanged: (value) => motion.setSource(source.key, value),
            ),
          LokalSettingRow.toggle(
            label: lokalText('Prioritize Spotify Canvas'),
            description: lokalText(
              'Ask Spotify before album covers. Tall videos are cropped to fit the cover.',
            ),
            value: moving.spotifyFirst,
            onChanged: motion.prioritizeSpotify,
          ),
        ],
      ],
    ),
    LokalSettingsSection(
      title: lokalText('Interface'),
      children: [
        LokalSettingRow(
          label: lokalText('Language'),
          description: lokalText(
            'The phone’s language, or one Lokal is translated into.',
          ),
          stacked: true,
          trailing: ValueListenableBuilder<Locale?>(
            valueListenable: LocaleController.instance,
            builder: (context, locale, _) => DropdownButtonFormField<String>(
              initialValue: locale == null ? 'system' : locale.languageCode,
              isExpanded: true,
              items: [
                DropdownMenuItem(
                  value: 'system',
                  child: Text(
                    lokalText('Phone'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: 'en',
                  child: Text(lokalText('English')),
                ),
                DropdownMenuItem(
                  value: 'fr',
                  child: Text(lokalText('Français')),
                ),
                DropdownMenuItem(
                  value: 'de',
                  child: Text(lokalText('Deutsch')),
                ),
                DropdownMenuItem(
                  value: 'es',
                  child: Text(lokalText('Español')),
                ),
                DropdownMenuItem(
                  value: 'it',
                  child: Text(lokalText('Italiano')),
                ),
                DropdownMenuItem(
                  value: 'pt',
                  child: Text(lokalText('Português (Brasil)')),
                ),
                DropdownMenuItem(
                  value: 'nl',
                  child: Text(lokalText('Nederlands')),
                ),
                DropdownMenuItem(value: 'pl', child: Text(lokalText('Polski'))),
                DropdownMenuItem(
                  value: 'sv',
                  child: Text(lokalText('Svenska')),
                ),
                DropdownMenuItem(value: 'zh', child: Text('简体中文')),
              ],
              onChanged: (code) =>
                  LocaleController.instance.select(switch (code) {
                    'system' || null => null,
                    'zh' => const Locale('zh', 'CN'),
                    'pt' => const Locale('pt', 'BR'),
                    _ => Locale(code!),
                  }),
            ),
          ),
        ),
        LokalSettingRow.toggle(
          label: lokalText('Haptics'),
          description: lokalText(
            'A light tap under your finger as you use Lokal.',
          ),
          value: prefs.hapticsEnabled,
          onChanged: (value) {
            notifier.setHapticsEnabled(value);
            AppHaptics.setEnabled(value);
          },
        ),
        LokalSettingRow(
          label: lokalText('Refresh rate'),
          description: lokalText(
            'Adaptive lets the phone decide. 120 Hz is smoothest and uses more battery.',
          ),
          stacked: true,
          trailing: LokalSegmented<String>(
            expand: true,
            segments: [
              LokalSegment('adaptive', lokalText('Adaptive')),
              LokalSegment('standard', lokalText('60 Hz')),
              LokalSegment('high', lokalText('120 Hz')),
            ],
            value: prefs.refreshRateMode,
            onChanged: notifier.setRefreshRateMode,
          ),
        ),
      ],
    ),
    LokalSettingsSection(
      title: lokalText('Spotify Canvas'),
      children: [
        LokalSettingCustom(
          label: lokalText('Spotify cookie'),
          description: lokalText(
            'Connect Spotify for Discovery and Canvas artwork.',
          ),
          child: const SpotifyAccountSettingsTile(showLikesSync: false),
        ),
      ],
    ),
    LokalSettingsSection(
      title: lokalText('Home-screen widget'),
      children: [
        LokalSettingLink(
          label: lokalText('Home-screen widget'),
          description: lokalText('What the widget on your home screen shows.'),
          onTap: () => _push(context, const WidgetSettingsScreen()),
        ),
      ],
    ),
  ];
}
