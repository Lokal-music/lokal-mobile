import 'dart:convert';

import 'package:http/http.dart' as http;

import 'changelog_data.dart';

/// The same notes are used for every patch/build in a major.minor line.
String? lokalMinorVersion(String? version) {
  final match = RegExp(r'^v?(\d+)\.(\d+)(?:\.|$)')
      .firstMatch(version?.trim() ?? '');
  return match == null ? null : '${match[1]}.${match[2]}';
}

/// Legacy last-seen values may contain the exact patch and build number.
bool lokalMinorHasChanged(String currentMinor, String? lastSeen) =>
    lastSeen != null &&
    lokalMinorVersion(lastSeen.split('+').first) != currentMinor;

/// Offline notes for already-shipped minor releases. The GitHub vX.Y.0
/// release is the authoritative source and also supports future minors
/// without needing an app update just to change the What's New content.
const lokalMinorReleaseFallback = <String, ChangelogEntry>{
  '4.2': ChangelogEntry(
    version: '4.2',
    date: '2026-10-28',
    sections: [
      ChangelogSection(
        title: 'Playback and USB DAC',
        bullets: [
          'Improved USB DAC PCM track transitions and recovery from USB I/O faults.',
          'Clarified idle USB DAC status and retained HTTP add-on manifest URLs.',
          'Fixed playback from the middle of a queue to include previous tracks.',
        ],
      ),
      ChangelogSection(
        title: 'Lyrics and sources',
        bullets: [
          'Export bilingual LRC lyrics with paired timestamps.',
          'Prioritize the first Morneye song before prefetching the rest of the queue.',
        ],
      ),
    ],
  ),
  '4.1': ChangelogEntry(
    version: '4.1',
    date: '2026-10-27',
    sections: [
      ChangelogSection(
        title: 'Flow performance',
        bullets: [
          'Replaced the rotating Flow ornament with a simpler static motif.',
          'Stopped unnecessary progress-driven Flow rebuilds.',
        ],
      ),
    ],
  ),
  '4.0': ChangelogEntry(
    version: '4.0',
    date: '2026-10-27',
    sections: [
      ChangelogSection(
        title: 'Player and navigation',
        bullets: [
          'Improved footer Search keyboard behavior and queue reordering.',
          'Redesigned mobile Home navigation and configurable Discovery shelves.',
          'Matched Cover Flow backgrounds to every Lokal theme.',
        ],
      ),
    ],
  ),
};

/// iPhone releases have their own notes and tag namespace. Android's USB/DSD
/// release notes must never be presented as features of the iPhone port.
const lokalIosMinorReleaseFallback = <String, ChangelogEntry>{
  '1.0': ChangelogEntry(
    version: '1.0',
    date: '2026-10-29',
    sections: [
      ChangelogSection(
        title: 'Your library on iPhone',
        bullets: [
          'Import music from Files and organize your library and playlists.',
          'Read synchronized lyrics and manage playback from Now Playing.',
        ],
      ),
      ChangelogSection(
        title: 'Player and discovery',
        bullets: [
          'Reorder the queue, explore Cover Flow and choose your online sources.',
          'Connect your desktop to sync your library and copy music to your phone.',
        ],
      ),
    ],
  ),
};

/// Parse the tagged minor release's "What's Changed" section. Patch releases
/// deliberately do not change the notes for the current minor line.
ChangelogEntry? parseLokalMinorRelease(String minor, String body, String date) {
  final start = body.indexOf("## What's Changed");
  if (start < 0) return null;
  final bullets = <String>[];
  for (final raw in body.substring(start).split('\n').skip(1)) {
    final line = raw.trim();
    if (line.startsWith('## ') || line.startsWith('**Full Changelog**')) {
      break;
    }
    if (!line.startsWith('* ')) continue;
    var description = line.substring(2).trim();
    description = description.replaceFirst(
      RegExp(r'\s+by\s+@[^\s]+\s+in\s+https?://\S+$'),
      '',
    );
    description = description.replaceFirst(
      RegExp(r'\s+in\s+https?://\S+$'),
      '',
    );
    if (description.isNotEmpty) bullets.add(description);
  }
  if (bullets.isEmpty) return null;
  return ChangelogEntry(
    version: minor,
    date: date,
    sections: [
      ChangelogSection(title: 'What changed in $minor', bullets: bullets),
    ],
  );
}

/// The release tag is pinned at the first patch of the minor version. Never
/// substitute previous-minor notes if this minor has not been published yet.
Future<ChangelogEntry?> loadLokalMinorRelease(
  String minor, {
  http.Client? client,
  bool forIos = false,
}) async {
  if (!RegExp(r'^\d+\.\d+$').hasMatch(minor)) return null;
  final fallback = (forIos
      ? lokalIosMinorReleaseFallback
      : lokalMinorReleaseFallback)[minor];
  final requestClient = client ?? http.Client();
  try {
    final uri = Uri.https(
      'api.github.com',
      '/repos/lokal-music/lokal-mobile/releases/tags/${forIos ? 'ios-v' : 'v'}$minor.0',
    );
    final response = await requestClient
        .get(uri, headers: {'Accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) return fallback;
    final release = jsonDecode(response.body);
    if (release is! Map<String, dynamic>) return fallback;
    final body = release['body'];
    final date = (release['published_at'] as String?)?.split('T').first ?? '';
    if (body is! String) return fallback;
    return parseLokalMinorRelease(minor, body, date) ?? fallback;
  } catch (_) {
    return fallback;
  } finally {
    if (client == null) requestClient.close();
  }
}
