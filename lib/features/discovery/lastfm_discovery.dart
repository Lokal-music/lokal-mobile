import 'dart:async';

import 'package:flick/services/lastfm/lastfm_api_client.dart';

/// Last.fm Discovery, ported from desktop Lokal (`electron/lastfmDiscovery.js`):
/// the account shelves (Quick Picks, Scrobble History, Albums and Artists For
/// You) and Fresh Finds, songs like the ones you play that you haven't heard.
///
/// What Last.fm recommends doesn't depend on whether a song can be played: a
/// song that can't be found to play stays on its shelf.

/// One Last.fm method call. Throws on failure, as [LastFmApiClient.get] does.
typedef LastfmCall = Future<Map<String, dynamic>> Function(
  String method,
  Map<String, String> params,
);

class LokalDiscoveryTrack {
  const LokalDiscoveryTrack({
    required this.title,
    required this.artist,
    this.album = '',
    this.artworkUrl = '',
    this.url = '',
    this.playcount = 0,
    this.scrobbledAt,
    this.reason,
    this.scrobbleCount,
    this.seedArtist,
    this.videoId,
    this.duration,
  });

  final String title;
  final String artist;
  final String album;
  final String artworkUrl;
  final String url;
  final int playcount;

  /// When it was scrobbled, in seconds since 1970.
  final int? scrobbledAt;

  /// Why it's here, e.g. "Similar to Artist — Song".
  final String? reason;
  final int? scrobbleCount;
  final String? seedArtist;

  /// Direct YouTube recording ID; avoids a catalog search on playback.
  final String? videoId;

  /// Duration supplied by the source, when available.
  final Duration? duration;

  /// One per artist and title, as desktop's `songKey`.
  String get key => lastfmSongKey(artist, title);

  LokalDiscoveryTrack copyWith({
    String? reason,
    int? scrobbleCount,
    String? seedArtist,
  }) => LokalDiscoveryTrack(
    title: title,
    artist: artist,
    album: album,
    artworkUrl: artworkUrl,
    url: url,
    playcount: playcount,
    scrobbledAt: scrobbledAt,
    reason: reason ?? this.reason,
    scrobbleCount: scrobbleCount ?? this.scrobbleCount,
    seedArtist: seedArtist ?? this.seedArtist,
    videoId: videoId,
    duration: duration,
  );
}

class LokalDiscoveryArtist {
  const LokalDiscoveryArtist({
    required this.name,
    this.image = '',
    this.playcount = 0,
    this.url = '',
  });

  final String name;
  final String image;
  final int playcount;
  final String url;
}

class LokalDiscoveryAlbum {
  const LokalDiscoveryAlbum({
    required this.title,
    required this.artist,
    this.artworkUrl = '',
    this.playcount = 0,
    this.url = '',
  });

  final String title;
  final String artist;
  final String artworkUrl;
  final int playcount;
  final String url;
}

/// A provider-owned mix or radio, such as YouTube Music's "My Supermix".
class LokalDiscoveryMix {
  const LokalDiscoveryMix({
    required this.id,
    required this.title,
    this.author = '',
    this.artworkUrl = '',
  });

  final String id;
  final String title;
  final String author;
  final String artworkUrl;
}

/// A named category returned by the source, with no synthesized content.
class LokalDiscoveryCategory {
  const LokalDiscoveryCategory({
    required this.id,
    this.tracks = const [],
    this.mixes = const [],
    this.albums = const [],
  });
  final String id;
  final List<LokalDiscoveryTrack> tracks;
  final List<LokalDiscoveryMix> mixes;
  final List<LokalDiscoveryAlbum> albums;
  bool get isEmpty => tracks.isEmpty && mixes.isEmpty && albums.isEmpty;
}

/// Discovery's shelves. A shelf whose request failed is null, so the app can
/// keep showing the last one that loaded.
class LokalDiscovery {
  const LokalDiscovery({
    required this.account,
    required this.page,
    this.warnings = const [],
    this.mixes,
    this.mixError,
    this.categories,
    this.liked,
    this.quickPicks,
    this.history,
    this.artists,
    this.albums,
    this.freshFinds,
    this.candidates = const [],
  });

  final String account;
  final int page;
  final List<String> warnings;
  final List<LokalDiscoveryMix>? mixes;
  final String? mixError;
  final List<LokalDiscoveryCategory>? categories;
  final List<LokalDiscoveryTrack>? liked;
  final List<LokalDiscoveryTrack>? quickPicks;
  final List<LokalDiscoveryTrack>? history;
  final List<LokalDiscoveryArtist>? artists;
  final List<LokalDiscoveryAlbum>? albums;
  final List<LokalDiscoveryTrack>? freshFinds;
  final List<LokalDiscoveryTrack> candidates;

  /// This load's shelves, with the ones that failed taken from [previous].
  LokalDiscovery keeping(LokalDiscovery? previous) => previous == null
      ? this
      : LokalDiscovery(
          account: account,
          page: page,
          warnings: warnings,
          mixes: mixes ?? previous.mixes,
          mixError: mixError,
          categories: categories ?? previous.categories,
          liked: liked ?? previous.liked,
          quickPicks: quickPicks ?? previous.quickPicks,
          history: history ?? previous.history,
          artists: artists ?? previous.artists,
          albums: albums ?? previous.albums,
          freshFinds: freshFinds ?? previous.freshFinds,
          candidates: candidates.isEmpty ? previous.candidates : candidates,
        );

  bool get isEmpty =>
      (categories ?? const []).every((category) => category.isEmpty) &&
      (mixes ?? const []).isEmpty &&
      (liked ?? const []).isEmpty &&
      (quickPicks ?? const []).isEmpty &&
      (history ?? const []).isEmpty &&
      (artists ?? const []).isEmpty &&
      (albums ?? const []).isEmpty &&
      (freshFinds ?? const []).isEmpty;
}

/// Discovery couldn't load at all: [message] says why.
class LokalDiscoveryFailure implements Exception {
  const LokalDiscoveryFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

String _key(String value) => value.trim().toLowerCase();

/// Desktop's Last.fm `songKey`: one key per artist and title.
String lastfmSongKey(String artist, String title) =>
    '${_key(artist)}\u0000${_key(title)}';

List<Object?> _list(Object? value) => value is List
    ? value
    : value is Map
    ? [value]
    : const [];

String _nameOf(Object? value) => value is String
    ? value
    : value is Map
    ? '${value['name'] ?? value['#text'] ?? ''}'
    : '';

int _number(Object? value) => value is num
    ? value.toInt()
    : value is String
    ? int.tryParse(value) ?? double.tryParse(value)?.toInt() ?? 0
    : 0;

final _placeholderImage = RegExp(
  '2a96cbd8|default_album|noimage',
  caseSensitive: false,
);

String _imageOf(Object? images) {
  final usable = [
    for (final image in _list(images))
      if (image is Map &&
          '${image['#text'] ?? ''}'.isNotEmpty &&
          !_placeholderImage.hasMatch('${image['#text']}'))
        image,
  ];
  Map? sized(String size) {
    for (final image in usable) {
      if (image['size'] == size) return image;
    }
    return null;
  }

  final picked =
      sized('extralarge') ??
      sized('large') ??
      (usable.isEmpty ? null : usable.first);
  return '${picked?['#text'] ?? ''}'.replaceFirst(RegExp('^http:'), 'https:');
}

LokalDiscoveryTrack _trackOf(Object? raw) {
  final track = raw is Map ? raw : const {};
  final date = track['date'];
  final at = date is Map ? _number(date['uts']) : 0;
  return LokalDiscoveryTrack(
    title: '${track['name'] ?? track['title'] ?? ''}',
    artist: _nameOf(track['artist']),
    album: _nameOf(track['album']),
    artworkUrl: _imageOf(track['image']),
    url: '${track['url'] ?? ''}',
    playcount: _number(track['playcount']),
    scrobbledAt: at > 0 ? at : null,
  );
}

List<T> _unique<T>(Iterable<T> items, String Function(T) identify) {
  final seen = <String>{};
  return [
    for (final item in items)
      if (seen.add(identify(item))) item,
  ];
}

List<LokalDiscoveryTrack> _uniqueSongs(Iterable<LokalDiscoveryTrack> items) =>
    _unique(items, (track) => track.key);

/// Quick Picks: what you scrobbled most often over the seven days to [now],
/// most plays first, then the latest.
List<LokalDiscoveryTrack> quickPicksFromHistory(
  List<LokalDiscoveryTrack> history,
  DateTime now,
) {
  final end = now.millisecondsSinceEpoch ~/ 1000;
  final cutoff = end - 7 * 24 * 60 * 60;
  final grouped = <String, ({LokalDiscoveryTrack track, int count})>{};
  for (final track in history) {
    final at = track.scrobbledAt ?? 0;
    if (at <= 0 ||
        at < cutoff ||
        at > end ||
        track.title.isEmpty ||
        track.artist.isEmpty) {
      continue;
    }
    final current = grouped[track.key];
    grouped[track.key] = current == null
        ? (track: track, count: 1)
        : (
            track: at > (current.track.scrobbledAt ?? 0)
                ? track
                : current.track,
            count: current.count + 1,
          );
  }
  final ranked = grouped.values.toList()
    ..sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      return byCount != 0
          ? byCount
          : (b.track.scrobbledAt ?? 0).compareTo(a.track.scrobbledAt ?? 0);
    });
  return [
    for (final entry in ranked)
      entry.track.copyWith(
        scrobbleCount: entry.count,
        reason: 'Scrobbled most often · past week',
      ),
  ];
}

List<LokalDiscoveryTrack> _scrobbles(Map<String, dynamic>? root) {
  final recent = root?['recenttracks'];
  return [
        for (final raw in _list(recent is Map ? recent['track'] : null))
          if (raw is Map &&
              !(raw['@attr'] is Map &&
                  '${(raw['@attr'] as Map)['nowplaying']}' == 'true') &&
              _number(raw['date'] is Map ? (raw['date'] as Map)['uts'] : 0) > 0)
            _trackOf(raw),
      ]
      .where((track) => track.title.isNotEmpty && track.artist.isNotEmpty)
      .toList();
}

/// Round-robin across [groups]: the first of each, then the second of each.
List<T> _weave<T>(List<List<T>> groups) {
  final longest = groups.fold(
    0,
    (n, group) => group.length > n ? group.length : n,
  );
  return [
    for (var i = 0; i < longest; i++)
      for (final group in groups)
        if (i < group.length) group[i],
  ];
}

/// [items] rotated to start at [start].
List<T> _rotate<T>(List<T> items, int start) =>
    items.isEmpty ? items : [...items.skip(start), ...items.take(start)];

Future<List<R>> _mapLimited<T, R>(
  List<T> items,
  Future<R> Function(T item) callback,
) async {
  final out = List<R?>.filled(items.length, null);
  var index = 0;
  Future<void> worker() async {
    while (index < items.length) {
      final at = index++;
      out[at] = await callback(items[at]);
    }
  }

  await Future.wait([
    for (var i = 0; i < (items.length < 4 ? items.length : 4); i++) worker(),
  ]);
  return out.cast<R>();
}

class _Seeds {
  const _Seeds(this.at, this.cacheKey, this.values);
  final DateTime at;
  final String cacheKey;
  final List<Object?> values;
}

/// The account requests behind the shelves, kept for five minutes so
/// Refresh only asks for new recommendations, as on desktop.
final _seeds = <String, _Seeds>{};
const _seedTtl = Duration(minutes: 5);

/// Forgets the cached account requests (tests, or after signing out).
void forgetLastfmSeeds() => _seeds.clear();

/// Loads Discovery for [username]. [page] is how many times you've pressed
/// Refresh: each press brings other seeds and other similar songs. Throws
/// [LokalDiscoveryFailure] when Last.fm answers nothing at all.
///
/// [cacheKey] identifies the API key, so a changed key never reuses seeds.
Future<LokalDiscovery> loadLastfmDiscovery({
  required String username,
  required LastfmCall call,
  String cacheKey = '',
  int page = 0,
  bool force = false,
  DateTime? now,
}) async {
  final user = username.trim();
  if (user.isEmpty) {
    throw const LokalDiscoveryFailure(
      'Connect Last.fm in Integrations to load your account shelves.',
    );
  }
  final at = now ?? DateTime.now();
  page = page.clamp(0, 1000);
  final warnings = <String>[];

  Future<Map<String, dynamic>?> ask(
    String method,
    Map<String, String> params,
  ) async {
    try {
      return await call(method, params);
    } on LastFmApiException catch (error) {
      // Uncatalogued songs are normal in scrobbles (soundtracks, uploads,
      // regional releases); artist catalogues still fill in.
      if (method == 'track.getSimilar' && error.code == 6) {
        return {
          'similartracks': {'track': []},
        };
      }
      warnings.add('$method: ${error.message}');
    } catch (error) {
      warnings.add('$method: $error');
    }
    return null;
  }

  Future<List<LokalDiscoveryTrack>?> weeklyScrobbles() async {
    final to = at.millisecondsSinceEpoch ~/ 1000;
    final params = {
      'user': user,
      'from': '${to - 7 * 86400}',
      'to': '$to',
      'limit': '200',
      'extended': '1',
    };
    final events = <LokalDiscoveryTrack>[];
    // A fixed upper bound keeps the pages stable while new plays arrive.
    for (var p = 1; p <= 50; p++) {
      final response = await ask('user.getRecentTracks', {
        ...params,
        'page': '$p',
      });
      if (response == null) return null;
      events.addAll(_scrobbles(response));
      final recent = response['recenttracks'];
      final attr = recent is Map ? recent['@attr'] : null;
      final totalPages = attr is Map ? _number(attr['totalPages']) : 0;
      final count = _list(recent is Map ? recent['track'] : null).length;
      if (totalPages > 0 ? p >= totalPages : count < 200) return events;
    }
    // Never show a part of the week's plays as the whole week.
    warnings.add(
      'Quick Picks: the seven-day scrobble window exceeded the page limit.',
    );
    return null;
  }

  final cached = _seeds[user];
  final reusable =
      page > 0 &&
      !force &&
      cached != null &&
      cached.cacheKey == cacheKey &&
      !at.isBefore(cached.at) &&
      at.difference(cached.at) < _seedTtl;
  final List<Object?> values = reusable
      ? cached.values
      : await Future.wait<Object?>([
          weeklyScrobbles(),
          ask('user.getTopTracks', {
            'user': user,
            'period': '1month',
            'limit': '60',
          }),
          ask('user.getRecentTracks', {
            'user': user,
            'limit': '101',
            'extended': '1',
          }),
          ask('user.getTopArtists', {
            'user': user,
            'period': '1month',
            'limit': '30',
          }),
          ask('user.getTopAlbums', {
            'user': user,
            'period': '1month',
            'limit': '30',
          }),
        ]);
  if (!reusable) {
    _seeds.remove(user);
    if (values.every((value) => value != null)) {
      _seeds[user] = _Seeds(at, cacheKey, values);
      while (_seeds.length > 20) {
        _seeds.remove(_seeds.keys.first);
      }
    }
  }
  final week = values[0] as List<LokalDiscoveryTrack>?;
  final month = values[1] as Map<String, dynamic>?;
  final recent = values[2] as Map<String, dynamic>?;
  final artists = values[3] as Map<String, dynamic>?;
  final albums = values[4] as Map<String, dynamic>?;
  if (values.every((value) => value == null)) {
    throw LokalDiscoveryFailure(
      warnings.isEmpty ? 'Last.fm did not answer.' : warnings.first,
    );
  }

  List<LokalDiscoveryTrack> tracks(Object? root) =>
      [for (final raw in _list(root)) _trackOf(raw)]
          .where((track) => track.title.isNotEmpty && track.artist.isNotEmpty)
          .toList();
  Object? field(Map<String, dynamic>? root, String outer, String inner) {
    final value = root?[outer];
    return value is Map ? value[inner] : null;
  }

  final history = _scrobbles(recent).take(100).toList();
  final weekly = quickPicksFromHistory(week ?? const [], at);
  final monthly = tracks(field(month, 'toptracks', 'track'));
  final topArtists = [
    for (final raw in _list(field(artists, 'topartists', 'artist')))
      if (raw is Map && '${raw['name'] ?? ''}'.isNotEmpty)
        LokalDiscoveryArtist(
          name: '${raw['name']}',
          image: _imageOf(raw['image']),
          playcount: _number(raw['playcount']),
          url: '${raw['url'] ?? ''}',
        ),
  ].take(30).toList();
  final topAlbums =
      [
            for (final raw in _list(field(albums, 'topalbums', 'album')))
              if (raw is Map)
                LokalDiscoveryAlbum(
                  title: '${raw['name'] ?? ''}',
                  artist: _nameOf(raw['artist']),
                  artworkUrl: _imageOf(raw['image']),
                  playcount: _number(raw['playcount']),
                  url: '${raw['url'] ?? ''}',
                ),
          ]
          .where((album) => album.title.isNotEmpty && album.artist.isNotEmpty)
          .take(30)
          .toList();

  // Seeds spread across your artists, so one soundtrack can't take the shelf.
  final seedPool = _uniqueSongs(_weave([weekly, history, monthly]));
  final byArtist = <String, List<LokalDiscoveryTrack>>{};
  for (final track in seedPool) {
    byArtist.putIfAbsent(_key(track.artist), () => []).add(track);
  }
  final artistSeeds = [
    for (final songs in byArtist.values) songs[page % songs.length],
  ];
  final seeds = _rotate(
    artistSeeds,
    artistSeeds.isEmpty ? 0 : page * 8 % artistSeeds.length,
  ).take(12).toList();
  final groups = await _mapLimited(seeds, (seed) async {
    final result = await ask('track.getSimilar', {
      'artist': seed.artist,
      'track': seed.title,
      'autocorrect': '1',
      'limit': '40',
    });
    final similar = tracks(field(result, 'similartracks', 'track'));
    return [
      for (final track in _rotate(
        similar,
        similar.isEmpty ? 0 : page * 5 % similar.length,
      ))
        track.copyWith(
          reason: 'Similar to ${seed.artist} — ${seed.title}',
          seedArtist: seed.artist,
        ),
    ];
  });
  final topStart = page % (topArtists.isEmpty ? 1 : topArtists.length);
  final related = await _mapLimited(
    [...topArtists.skip(topStart), ...topArtists].take(4).toList(),
    (artist) async {
      final result = await ask('artist.getSimilar', {
        'artist': artist.name,
        'autocorrect': '1',
        'limit': '5',
      });
      return [
        for (final raw in _list(field(result, 'similarartists', 'artist')))
          if (_nameOf(raw).isNotEmpty) _nameOf(raw),
      ];
    },
  );
  // Sparse similar-song coverage is common for new or regional music: your
  // artists' own Last.fm catalogues fill the pool, never global charts.
  final catalogArtists = _unique(
    _weave([
      related.expand((names) => names).toList(),
      [for (final artist in topArtists) artist.name],
      [for (final seed in seeds) seed.artist],
    ]),
    _key,
  );
  final selectedArtists = _rotate(
    catalogArtists,
    catalogArtists.isEmpty ? 0 : page * 6 % catalogArtists.length,
  ).take(12).toList();
  final catalogs = await _mapLimited(selectedArtists, (artist) async {
    final result = await ask('artist.getTopTracks', {
      'artist': artist,
      'autocorrect': '1',
      'limit': '30',
      'page': '${1 + page}',
    });
    return [
      for (final track in tracks(field(result, 'toptracks', 'track')))
        track.copyWith(
          reason: 'More from $artist on Last.fm',
          seedArtist: artist,
        ),
    ];
  });
  final heard = {
    for (final track in [...history, ...weekly]) track.key,
  };
  final pool = _uniqueSongs(
    _weave([_uniqueSongs(_weave(groups)), _uniqueSongs(_weave(catalogs))]),
  );
  final fresh = pool.where((track) => !heard.contains(track.key)).toList();
  final anySimilar =
      groups.any((group) => group.isNotEmpty) ||
      catalogs.any((group) => group.isNotEmpty);
  return LokalDiscovery(
    account: user,
    page: page,
    warnings: warnings.toSet().toList(),
    quickPicks: week == null ? null : weekly.take(12).toList(),
    history: recent == null ? null : history,
    artists: artists == null ? null : topArtists,
    albums: albums == null ? null : topAlbums,
    freshFinds: anySimilar
        ? fresh.take(30).toList()
        : warnings.isNotEmpty
        ? null
        : const [],
    candidates: pool,
  );
}
