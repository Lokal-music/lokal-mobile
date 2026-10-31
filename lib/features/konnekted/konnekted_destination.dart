import 'package:flutter/foundation.dart';

import 'package:flick/features/settings/lokal/lokal_settings_group.dart';

/// UI destinations, deliberately independent from Flick's legacy tab indices.
///
/// Settings is one destination, [settings], optionally opened at a group and
/// a section with [KonnektedDestination.settingsAt].
@immutable
final class KonnektedDestination {
  const KonnektedDestination._(this.name)
    : settingsGroup = null,
      settingsSection = null,
      aboutDataOnly = false;

  /// Settings, opened at [group] and scrolled to its [section] (a section
  /// title such as "Lyrics").
  const KonnektedDestination.settingsAt(
    LokalSettingsGroup group, {
    String? section,
  }) : name = 'settings',
       settingsGroup = group,
       settingsSection = section,
       aboutDataOnly = false;

  /// Settings opened as a single page with every About and Data section shown.
  const KonnektedDestination.aboutDataSettings()
    : name = 'settings',
      settingsGroup = null,
      settingsSection = null,
      aboutDataOnly = true;

  /// The route name's last segment.
  final String name;
  final LokalSettingsGroup? settingsGroup;
  final String? settingsSection;
  final bool aboutDataOnly;

  static const flow = KonnektedDestination._('flow');
  static const search = KonnektedDestination._('search');
  static const songs = KonnektedDestination._('songs');
  static const albums = KonnektedDestination._('albums');
  static const artists = KonnektedDestination._('artists');
  static const folders = KonnektedDestination._('folders');
  static const playlists = KonnektedDestination._('playlists');
  static const favorites = KonnektedDestination._('favorites');
  static const recentlyPlayed = KonnektedDestination._('recentlyPlayed');
  static const recentlyAdded = KonnektedDestination._('recentlyAdded');
  static const queue = KonnektedDestination._('queue');
  static const linkedPlaylists = KonnektedDestination._('linkedPlaylists');
  static const spotifyPlaylists = KonnektedDestination._('spotifyPlaylists');
  static const youtubeMusicPlaylists = KonnektedDestination._('youtubeMusicPlaylists');
  static const genres = KonnektedDestination._('genres');
  static const downloads = KonnektedDestination._('downloads');
  static const recap = KonnektedDestination._('recap');

  /// The searchable main Settings page.
  static const settings = KonnektedDestination._('settings');

  static const values = <KonnektedDestination>[
    flow,
    search,
    songs,
    albums,
    artists,
    folders,
    playlists,
    favorites,
    recentlyPlayed,
    recentlyAdded,
    queue,
    linkedPlaylists,
    spotifyPlaylists,
    youtubeMusicPlaylists,
    genres,
    downloads,
    recap,
    settings,
  ];

  bool get isSettings => name == settings.name;

  @override
  bool operator ==(Object other) =>
      other is KonnektedDestination &&
      other.name == name &&
      other.settingsGroup == settingsGroup &&
      other.settingsSection == settingsSection &&
      other.aboutDataOnly == aboutDataOnly;

  @override
  int get hashCode =>
      Object.hash(name, settingsGroup, settingsSection, aboutDataOnly);

  @override
  String toString() {
    if (aboutDataOnly) return 'KonnektedDestination.aboutDataSettings()';
    if (settingsGroup == null) return 'KonnektedDestination.$name';
    return 'KonnektedDestination.settingsAt(${settingsGroup!.name}'
        '${settingsSection == null ? '' : ', $settingsSection'})';
  }
}
