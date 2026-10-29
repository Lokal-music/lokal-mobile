import 'package:flick/features/discovery/discovery_sources.dart';
import 'package:flick/features/discovery/youtube_music_account.dart'
    show parseYoutubeMusicAlbums, parseYoutubeMusicTracks;
import 'package:flick/features/konnekted/library/lokal_online_catalogue.dart'
    show LokalCatalogueAlbum, LokalReleaseKind, catalogueArtistCredit,
         cataloguePrimaryArtist;
import 'package:flick/features/discovery/recommendation_match.dart'
    show recommendationKey;

/// Desktop parity: load an artist's own YouTube Music channel instead of
/// relying on a capped, relevance-ranked album search. The guest endpoint
/// works without account cookies; failures leave Apple Music results intact.
const youtubeArtistFilter = 'EgWKAQIgAWoKEAkQChAFEAMQBA==';

void _walkMaps(Object? value, void Function(Map node) visit) {
  var nodes = 0;
  void walk(Object? item, int depth) {
    if (depth > 40 || ++nodes > 40000) return;
    if (item is Map) {
      visit(item);
      for (final child in item.values) {
        walk(child, depth + 1);
      }
    } else if (item is List) {
      for (final child in item) {
        walk(child, depth + 1);
      }
    }
  }
  walk(value, 0);
}

Object? _at(Object? node, List<String> path) {
  for (final key in path) {
    if (node is! Map) return null;
    node = node[key];
  }
  return node;
}

String _text(Object? node) {
  if (node is String) return node.trim();
  if (node is! Map) return '';
  final simple = node['simpleText'];
  if (simple is String) return simple.trim();
  final runs = node['runs'];
  if (runs is List) {
    return runs.whereType<Map>()
        .map((run) => (run['text'] ?? '').toString()).join().trim();
  }
  return '';
}

String _columnTitle(Map row) {
  final direct = _text(row['title']);
  if (direct.isNotEmpty) return direct;
  final columns = row['flexColumns'];
  if (columns is List && columns.isNotEmpty) {
    return _text(_at(columns.first, [
      'musicResponsiveListItemFlexColumnRenderer', 'text',
    ]));
  }
  return '';
}

String _browseId(Map row) {
  final endpoints = <Object?>[
    _at(row, ['navigationEndpoint', 'browseEndpoint']),
    for (final value in [
      row['title'],
      if (row['flexColumns'] is List &&
          (row['flexColumns'] as List).isNotEmpty)
        _at((row['flexColumns'] as List).first, [
          'musicResponsiveListItemFlexColumnRenderer', 'text',
        ]),
    ])
      if (value is Map && value['runs'] is List)
        for (final run in value['runs'] as List)
          _at(run, ['navigationEndpoint', 'browseEndpoint']),
  ];
  for (final endpoint in endpoints) {
    final id = _at(endpoint, ['browseId']);
    if (id is String && id.startsWith('UC') && id.length >= 12) return id;
  }
  return '';
}

/// A candidate must be an actual artist-channel browse endpoint with an exact
/// name, never the first approximate result (e.g. a similarly named artist).
List<String> youtubeArtistChannelCandidates(Object? response, String artist) {
  final requested = recommendationKey(artist);
  final ids = <String>[];
  _walkMaps(response, (node) {
    final row = node['musicTwoRowItemRenderer'] ??
        node['musicResponsiveListItemRenderer'];
    if (row is! Map) return;
    final name = _columnTitle(row);
    if (recommendationKey(name) != requested) return;
    final id = _browseId(row);
    if (id.isNotEmpty && !ids.contains(id)) ids.add(id);
  });
  return ids.take(2).toList();
}

typedef _Shelf = ({Object? contents, LokalReleaseKind kind, List<({String id, String? params})> more});

List<_Shelf> _releaseShelves(Object? root) {
  final shelves = <_Shelf>[];
  _walkMaps(root, (node) {
    final shelf = node['musicCarouselShelfRenderer'];
    if (shelf is! Map) return;
    final name = recommendationKey(_text(_at(shelf, [
      'header', 'musicCarouselShelfBasicHeaderRenderer', 'title',
    ])));
    final kind = switch (name) {
      'albums' => LokalReleaseKind.album,
      'eps' || 'ep' => LokalReleaseKind.ep,
      'singles' || 'singles and eps' || 'singles eps' =>
        LokalReleaseKind.single,
      _ => null,
    };
    if (kind == null) return;
    final more = <({String id, String? params})>[];
    _walkMaps(shelf['header'], (header) {
      final endpoint = header['browseEndpoint'];
      if (endpoint is! Map) return;
      final id = endpoint['browseId'];
      if (id is String && id.startsWith('MPRE') == false &&
          id.isNotEmpty && id.length < 150) {
        final params = endpoint['params'];
        if (!more.any((value) => value.id == id)) {
          more.add((id: id, params: params is String ? params : null));
        }
      }
    });
    shelves.add((
      contents: shelf['contents'],
      kind: kind,
      more: more.take(2).toList(),
    ));
  });
  return shelves;
}

List<LokalCatalogueAlbum> parseYoutubeArtistChannelReleases(
  Object? root, String artist,
) {
  final releases = <LokalCatalogueAlbum>[];
  final seen = <String>{};
  final shelves = _releaseShelves(root);
  for (final shelf in shelves) {
    for (final album in parseYoutubeMusicAlbums(shelf.contents)) {
      final credited = album.artist.trim().isEmpty ? artist : album.artist;
      if (!catalogueArtistCredit(credited, artist)) continue;
      final key = recommendationKey(album.title);
      if (key.isEmpty || !seen.add(key)) continue;
      releases.add(LokalCatalogueAlbum(
        title: album.title,
        artist: credited,
        artwork: album.artworkUrl,
        url: album.url,
        releaseKind: !cataloguePrimaryArtist(credited, artist)
            ? LokalReleaseKind.feature : shelf.kind,
      ));
    }
  }
  // Channel songs can advertise a release absent from the visible carousel.
  for (final song in parseYoutubeMusicTracks(root, limit: 50)) {
    final album = song.album?.trim() ?? '';
    if (album.isEmpty || !catalogueArtistCredit(song.artist, artist) ||
        !seen.add(recommendationKey(album))) continue;
    releases.add(LokalCatalogueAlbum(
      title: album,
      artist: song.artist,
      artwork: song.artworkUrl,
      releaseKind: !cataloguePrimaryArtist(song.artist, artist)
          ? LokalReleaseKind.feature : null,
    ));
  }
  return releases;
}

/// Fetch the exact artist channel, plus up to two channel-owned "See all"
/// sections. All requests share a bounded deadline. No playback is triggered.
Future<List<LokalCatalogueAlbum>> loadYoutubeArtistReleases(
  String artist, {
  required YoutubeMusicCatalog catalogue,
}) async {
  if (artist.trim().isEmpty) return const [];
  final deadline = DateTime.now().add(const Duration(seconds: 22));
  final search = await catalogue
      .rawSearch(artist, params: youtubeArtistFilter)
      .timeout(const Duration(seconds: 9));
  final candidates = youtubeArtistChannelCandidates(search, artist);
  for (final id in candidates) {
    if (DateTime.now().isAfter(deadline)) break;
    try {
      final root = await catalogue.rawBrowse(id).timeout(const Duration(seconds: 8));
      final parsed = parseYoutubeArtistChannelReleases(root, artist);
      if (parsed.isEmpty) continue;
      final seen = parsed.map((item) => recommendationKey(item.title)).toSet();
      final all = <LokalCatalogueAlbum>[...parsed];
      var fetched = 0;
      for (final shelf in _releaseShelves(root)) {
        for (final more in shelf.more) {
          if (fetched++ >= 2 || DateTime.now().isAfter(deadline)) break;
          try {
            final remaining = deadline.difference(DateTime.now());
            final page = await catalogue
                .rawBrowse(more.id, params: more.params)
                .timeout(remaining < const Duration(seconds: 6)
                    ? remaining : const Duration(seconds: 6));
            for (final release in parseYoutubeMusicAlbums(page)) {
              final credited = release.artist.trim().isEmpty
                  ? artist : release.artist;
              if (!catalogueArtistCredit(credited, artist) ||
                  !seen.add(recommendationKey(release.title))) continue;
              all.add(LokalCatalogueAlbum(
                title: release.title,
                artist: credited,
                artwork: release.artworkUrl,
                url: release.url,
                releaseKind: !cataloguePrimaryArtist(credited, artist)
                    ? LokalReleaseKind.feature : shelf.kind,
              ));
            }
          } catch (_) { /* Keep the verified artist releases already loaded. */ }
        }
      }
      return all;
    } catch (_) { /* Try another exact-named channel, if available. */ }
  }
  return const [];
}
