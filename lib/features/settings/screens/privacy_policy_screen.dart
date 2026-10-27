import 'package:flutter/material.dart';

import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';

/// What Lokal keeps and what it sends: a local player first, with every
/// online service off until you turn it on.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  static const _sections = <(String, String)>[
    (
      'Your library stays on your phone',
      'Lokal plays the music files in the folders you choose. Your library, '
          'play counts, playlists, favourites and settings are stored only on '
          'this device. Lokal has no account of its own, no ads and no '
          'analytics, and it doesn’t send your library anywhere.',
    ),
    (
      'Online services are opt-in',
      'YouTube Music, Spotify, Last.fm, ListenBrainz, Monochrome, network servers and '
          'add-ons are contacted when you choose to use or configure them in '
          'Settings › Online sources. Once you do, Lokal talks to that '
          'service on your behalf: for example to load your mixes, import '
          'playlists or scrobble what you play. Each service handles that '
          'data under its own privacy policy. Sign-in sessions and tokens '
          'are kept on this device, and signing out removes them.',
    ),
    (
      'Add-ons',
      'Add-ons are made and run by third parties. When you search or play '
          'through one, it contacts its own service. Lokal doesn’t host, '
          'check or vouch for add-ons; only install the ones you trust.',
    ),
    (
      'Lyrics and artwork',
      'When Lokal looks up lyrics or artwork, automatically if you leave '
          'those lookups on or when you search yourself, it sends the song’s '
          'title, artist and album to public services such as LRCLIB and '
          'Apple’s iTunes search. Nothing else about you is sent.',
    ),
    (
      'Updates',
      'Lokal checks for a newer version through Google Play when it was '
          'installed from there, otherwise through its GitHub releases page.',
    ),
    (
      'Permissions',
      'Storage or media access lets Lokal read your music. USB access is '
          'used only for a DAC you plug in. Photo access is used only when you '
          'pick an image yourself, such as custom artwork. Notifications show '
          'the playback controls.',
    ),
    (
      'Debug logs',
      'Logs stay on this device. They leave it only if you share or export '
          'them yourself, for example to attach to a bug report.',
    ),
    (
      'Children',
      'Lokal doesn’t knowingly collect personal information from anyone, '
          'including children.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return LokalSettingsScaffold(
      title: 'Privacy',
      subtitle: 'What Lokal keeps and what it sends.',
      children: [
        for (final (title, body) in _sections)
          LokalSettingsSection(
            title: title,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  body,
                  style: TextStyle(
                    fontFamily: LokalTheme.sans,
                    fontSize: 14,
                    height: 1.5,
                    color: t.text,
                  ),
                ),
              ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          child: Text(
            'LAST UPDATED OCTOBER 2026',
            style: LokalTheme.label(t, size: 10.5),
          ),
        ),
      ],
    );
  }
}
