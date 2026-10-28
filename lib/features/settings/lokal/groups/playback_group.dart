import 'package:flick/features/settings/widgets/lyrics_sources_panel.dart';
import 'package:flick/l10n/l10n.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flick/features/settings/screens/bluetooth_settings_screen.dart';
import 'package:flick/features/settings/screens/casting_settings_screen.dart';
import 'package:flick/features/settings/screens/equalizer_screen.dart';
import 'package:flick/features/settings/screens/uac2_settings_screen.dart';
import 'package:flick/providers/app_preferences_provider.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/services/replaygain_service.dart';
import 'package:flick/services/uac2_preferences_service.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';

void _push(BuildContext context, Widget page) => unawaited(
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)),
);

/// The player's own switches, so pages showing them rebuild when they change
/// (from here or from Now Playing).
Listenable lokalSettingsListenable(WidgetRef ref) {
  final player = ref.watch(playerServiceProvider);
  return Listenable.merge([
    player.gaplessPlaybackEnabledNotifier,
    player.bitPerfectProcessingLockedNotifier,
    player.wrapAroundQueueNotifier,
    player.autoplayOnQueueEndNotifier,
    player.duckOnInterruptionNotifier,
    player.extendedVolumeEnabledNotifier,
  ]);
}

String _db(double db) =>
    db == 0 ? '0 dB' : '${db > 0 ? '+' : ''}${db.toStringAsFixed(1)} dB';

const _curves = [
  LokalSegment(0, 'Equal power'),
  LokalSegment(1, 'Linear'),
  LokalSegment(2, 'Square root'),
  LokalSegment(3, 'S-curve'),
];

List<LokalSettingsSection> playbackSettings(
  BuildContext context,
  WidgetRef ref,
) {
  final prefs = ref.watch(appPreferencesProvider);
  final notifier = ref.read(appPreferencesProvider.notifier);
  final player = ref.watch(playerServiceProvider);
  final locked = player.bitPerfectProcessingLockedNotifier.value;
  final lockedHint = Uac2PreferencesService.is432HzTuningEnabledSync
      ? 'Turn off 432 Hz tuning to use this.'
      : 'Not available in bit-perfect mode.';

  Future<void> crossfade({bool? enabled, double? secs, int? curve}) async {
    if (enabled != null) await notifier.setCrossfadeEnabled(enabled);
    if (secs != null) await notifier.setCrossfadeDurationSecs(secs);
    if (curve != null) await notifier.setCrossfadeCurveIndex(curve);
    final now = ref.read(appPreferencesProvider);
    await player.applyCrossfadeSettings(
      enabled: now.crossfadeEnabled,
      durationSecs: now.crossfadeDurationSecs,
    );
  }

  return [
    LokalSettingsSection(
      title: lokalText('Playback'),
      children: [
        LokalSettingRow(
          label: lokalText('ReplayGain'),
          description: lokalText(
            'Use ReplayGain tags to bring songs closer in loudness. Songs without tags are unchanged.',
          ),
          trailing: LokalSegmented<String>(
            expand: true,
            segments: [
              LokalSegment(ReplayGainMode.off, lokalText('Off')),
              LokalSegment(ReplayGainMode.track, lokalText('Track')),
              LokalSegment(ReplayGainMode.album, lokalText('Album')),
              LokalSegment(ReplayGainMode.smart, lokalText('Smart')),
            ],
            value: prefs.replayGainMode,
            onChanged: (mode) async {
              await notifier.setReplayGainMode(mode);
              await player.applyReplayGainFromSettings();
            },
          ),
          stacked: true,
        ),
        LokalSettingSlider(
          label: lokalText('ReplayGain pre-amp'),
          description: lokalText('Raise or lower every song by this much.'),
          value: prefs.replayGainPreampDb,
          min: replayGainPreampMinDb,
          max: replayGainPreampMaxDb,
          divisions: 36,
          valueLabel: _db,
          onChanged: prefs.replayGainMode == 'off'
              ? null
              : (db) async {
                  await notifier.setReplayGainPreampDb(db);
                  await player.applyReplayGainFromSettings();
                },
        ),
        LokalSettingRow.toggle(
          label: lokalText('Prevent clipping'),
          description: lokalText(
            'Peak tags limit boosts so loud songs don’t distort.',
          ),
          value: prefs.replayGainPreventClipping,
          enabled: prefs.replayGainMode != 'off',
          onChanged: (value) async {
            await notifier.setReplayGainPreventClipping(value);
            await player.applyReplayGainFromSettings();
          },
        ),
        LokalSettingRow.toggle(
          label: lokalText('Gapless playback'),
          description: player.isBitPerfectModeEnabled
              ? lokalText('Off in bit-perfect mode.')
              : lokalText(
                  'Play one song straight into the next when the output format can stay open.',
                ),
          value: player.gaplessPlaybackEnabledNotifier.value,
          onChanged: player.setGaplessPlaybackEnabled,
        ),
      ],
    ),
    LokalSettingsSection(
      title: lokalText('Song transitions'),
      children: [
        LokalSettingRow.toggle(
          label: lokalText('Crossfade'),
          description: locked
              ? lockedHint
              : lokalText('Start the next song before the current one ends.'),
          value: !locked && prefs.crossfadeEnabled,
          enabled: !locked,
          onChanged: (value) => crossfade(enabled: value),
        ),
        if (Platform.isAndroid)
          LokalSettingRow.toggle(
            label: lokalText('Prepared stem mixes (experimental)'),
            description: lokalText(
              'Play verified offline Demucs transition clips for matching local songs. No model runs during playback; unsupported tracks use normal crossfade.',
            ),
            value: !locked && prefs.automixStemClipsEnabled,
            enabled: !locked && prefs.crossfadeEnabled,
            onChanged: notifier.setAutomixStemClipsEnabled,
          ),
        LokalSettingSlider(
          label: lokalText('Crossfade length'),
          description: lokalText('How long the two songs overlap.'),
          value: prefs.crossfadeDurationSecs,
          min: .5,
          max: 12,
          divisions: 23,
          valueLabel: (s) => '${s.toStringAsFixed(1)} s',
          onChanged: locked || !prefs.crossfadeEnabled
              ? null
              : (secs) => crossfade(secs: secs),
        ),
        LokalSettingChoice<int>(
          label: lokalText('Fade curve'),
          description: lokalText('Equal power fades evenly to the ear.'),
          options: _curves,
          value: prefs.crossfadeCurveIndex.clamp(0, 3),
          enabled: !locked && prefs.crossfadeEnabled,
          onChanged: (curve) => crossfade(curve: curve),
        ),
      ],
    ),
    LokalSettingsSection(
      title: lokalText('Queue'),
      children: [
        LokalSettingRow.toggle(
          label: lokalText('Autoplay'),
          description: lokalText(
            'When the queue ends, keep playing songs from your library.',
          ),
          value: player.autoplayOnQueueEndNotifier.value,
          onChanged: player.setAutoplayOnQueueEnd,
        ),
      ],
    ),
    LokalSettingsSection(
      title: lokalText('Equalizer'),
      children: [
        LokalSettingLink(
          label: lokalText('Equalizer'),
          description: lokalText(
            'Bands, presets, AutoEQ headphone correction and effects.',
          ),
          onTap: () => _push(context, const EqualizerScreen()),
        ),
      ],
    ),
    LokalSettingsSection(
      title: lokalText('Lyrics'),
      children: [
        const LokalSettingCustom(
          label: 'Lyrics sources',
          description: 'Source priority, enabled providers and word timing',
          child: LyricsSourcesPanel(),
        ),
        LokalSettingRow.toggle(
          label: lokalText('Fetch lyrics automatically'),
          description: lokalText(
            'Off: songs only show the lyrics they carry themselves. Searching from the lyrics view still looks online.',
          ),
          value: prefs.lyricsAutoFetch,
          onChanged: notifier.setLyricsAutoFetch,
        ),
        LokalSettingRow.toggle(
          label: lokalText('Name lyrics after the song file'),
          description: lokalText(
            'Lyrics Lokal saves take the song’s file name instead of its title.',
          ),
          value: prefs.lyricsMatchAudioFilename,
          onChanged: notifier.setLyricsMatchAudioFilename,
        ),
        LokalSettingRow.toggle(
          label: lokalText('Word-by-word sync'),
          description: lokalText(
            'In the classic player, light up each word as it’s sung when the lyrics have word timing.',
          ),
          value: prefs.karaokeEnabled,
          onChanged: notifier.setKaraokeEnabled,
        ),
        LokalSettingRow(
          label: lokalText('Alignment'),
          description: lokalText(
            'Where lyric lines sit in the classic player.',
          ),
          trailing: LokalSegmented<String>(
            segments: [
              LokalSegment('left', lokalText('Left')),
              LokalSegment('center', lokalText('Centre')),
              LokalSegment('right', lokalText('Right')),
            ],
            value: prefs.lyricsTextAlign,
            onChanged: notifier.setLyricsTextAlign,
          ),
          stacked: true,
        ),
      ],
    ),
    LokalSettingsSection(
      title: lokalText('Casting'),
      children: [
        LokalSettingLink(
          label: lokalText('Casting'),
          description: lokalText(
            'Find DLNA, UPnP and Chromecast receivers on your network.',
          ),
          onTap: () => _push(context, const CastingSettingsScreen()),
        ),
      ],
    ),
  ];
}

const _crossfeed = [
  LokalSegment(0, 'Off'),
  LokalSegment(1, 'Default'),
  LokalSegment(2, 'Crossfeed'),
  LokalSegment(3, 'Easy'),
];

/// Advanced output: USB DAC and engine, Bluetooth, volume and crossfeed.
List<LokalSettingsSection> outputSettings(BuildContext context, WidgetRef ref) {
  final prefs = ref.watch(appPreferencesProvider);
  final notifier = ref.read(appPreferencesProvider.notifier);
  final player = ref.watch(playerServiceProvider);
  final locked = player.bitPerfectProcessingLockedNotifier.value;
  return [
    if (Platform.isIOS)
      LokalSettingsSection(
        title: 'Audio output',
        children: [
          LokalSettingLink(
            label: 'AirPlay and headphones',
            description: 'Choose an output using the iPhone audio controls.',
            onTap: () => unawaited(
              const MethodChannel('lokal/ios')
                  .invokeMethod<void>('showRoutePicker'),
            ),
          ),
        ],
      ),
    if (!Platform.isIOS)
      LokalSettingsSection(
        title: lokalText('USB DAC'),
        children: [
          LokalSettingLink(
            label: lokalText('USB DAC'),
            description: lokalText(
              "Devices, playback engine, bit-perfect output, format, DSD and 432 Hz tuning.",
            ),
            onTap: () => _push(context, const Uac2SettingsScreen()),
          ),
        ],
      ),
    if (!Platform.isIOS)
      LokalSettingsSection(
        title: lokalText('Bluetooth'),
        children: [
          LokalSettingLink(
            label: lokalText('Bluetooth'),
            description: lokalText(
              'Codec, and what happens when headphones connect or drop.',
            ),
            onTap: () => _push(context, const BluetoothSettingsScreen()),
          ),
        ],
      ),
    LokalSettingsSection(
      title: lokalText('Volume'),
      children: [
        if (!Platform.isIOS)
          LokalSettingRow.toggle(
            label: lokalText('Extended volume'),
            description: lokalText(
              'Let the volume go past 100 %, up to 200 %.',
            ),
            value: prefs.extendedVolumeEnabled,
            onChanged: (value) async {
              await notifier.setExtendedVolumeEnabled(value);
              await player.setExtendedVolumeEnabled(value);
            },
          ),
        LokalSettingChoice<int>(
          label: lokalText('Crossfeed'),
          description: locked
              ? lokalText('Not available in bit-perfect mode.')
              : lokalText(
                  'Blend a little of each channel into the other, for easier listening on headphones.',
                ),
          options: _crossfeed,
          value: prefs.crossfeedLevel.clamp(0, 3),
          enabled: !locked,
          onChanged: (level) async {
            await notifier.setCrossfeedLevel(level);
            await player.applyCrossfeedSettings();
          },
        ),
      ],
    ),
    if (!Platform.isIOS)
      LokalSettingsSection(
        title: lokalText('Background'),
        children: [
          LokalSettingRow.toggle(
            label: lokalText('Background playback anchor'),
            description: lokalText(
              'Help keep bit-perfect audio alive in the background. Some phones and routes may still stop it.',
            ),
            value: prefs.priorityAnchorEnabled,
            onChanged: (value) {
              player.setPriorityAnchorEnabled(value);
              notifier.setPriorityAnchorEnabled(value);
            },
          ),
          LokalSettingRow.toggle(
            label: lokalText('Moving covers in bit-perfect'),
            description: lokalText(
              'Play moving covers during bit-perfect output. Off: a still cover instead.',
            ),
            value: prefs.motionArtDuringBitPerfect,
            onChanged: (value) {
              player.setMotionArtDuringBitPerfect(value);
              notifier.setMotionArtDuringBitPerfect(value);
            },
          ),
        ],
      ),
  ];
}
