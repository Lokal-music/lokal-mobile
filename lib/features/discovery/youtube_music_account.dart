import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'lastfm_discovery.dart';
import '../../core/utils/app_log.dart';

const _origin = 'https://music.youtube.com';
const _fallbackClientVersion = '1.20250901.03.00';
const _fallbackUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36';
final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');
final _clock = RegExp(r'^(?:\d+:)?\d{1,2}:\d{2}$');

/// Read JSON embedded by YouTube's page without evaluating JavaScript. Handles
/// nested braces and escaped quotes in titles/config values.
Map<String, dynamic>? youtubeMusicPageObject(String html, String variable) {
  final marker = variable == 'ytcfg'
      ? RegExp(r'ytcfg\.set\(\s*\{')
      : RegExp(r'(?:var\s+)?ytInitialData\s*=\s*\{');
  for (final match in marker.allMatches(html)) {
    final start = match.end - 1;
    var depth = 0, quoted = false, escaped = false;
    for (var at = start; at < html.length; at++) {
      final char = html[at];
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (char == r'\') {
          escaped = true;
        } else if (char == '"') {
          quoted = false;
        }
        continue;
      }
      if (char == '"') {
        quoted = true;
      } else if (char == '{') {
        depth++;
      } else if (char == '}' && --depth == 0) {
        try {
          final value = jsonDecode(html.substring(start, at + 1));
          if (value is Map<String, dynamic> &&
              (variable != 'ytcfg' ||
                  value['INNERTUBE_CLIENT_VERSION'] != null))
            return value;
        } on FormatException {
          /* Try another embedded object. */
        }
        break;
      }
    }
  }
  return null;
}

/// Account cookies and page context captured after interactive sign-in.
class YoutubeMusicSession {
  const YoutubeMusicSession({
    required this.cookies,
    this.userAgent = _fallbackUserAgent,
    this.sessionIndex,
    this.delegatedSessionId,
    this.visitorData,
    this.clientVersion,
  });

  final Map<String, String> cookies;
  final String userAgent;
  final String? sessionIndex;
  final String? delegatedSessionId;
  final String? visitorData;
  final String? clientVersion;

  static const identityCookies = [
    'SID',
    '__Secure-1PSID',
    '__Secure-3PSID',
    'SAPISID',
    '__Secure-1PAPISID',
    '__Secure-3PAPISID',
    'LOGIN_INFO',
  ];

  String? get _sapisid {
    for (final name in ['SAPISID', '__Secure-3PAPISID', '__Secure-1PAPISID']) {
      final value = cookies[name];
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  bool get signedIn => _sapisid != null;

  /// Non-reversible account identity for caches; raw cookies aren't cache keys.
  String get accountKey => sha256
      .convert(
        utf8.encode(
          [
            for (final name in identityCookies)
              name + '=' + (cookies[name] ?? ''),
          ].join(';'),
        ),
      )
      .toString()
      .substring(0, 24);

  YoutubeMusicSession withCookies(Map<String, String> updated) =>
      YoutubeMusicSession(
        cookies: {...cookies, ...updated},
        userAgent: userAgent,
        sessionIndex: sessionIndex,
        delegatedSessionId: delegatedSessionId,
        visitorData: visitorData,
        clientVersion: clientVersion,
      );

  static Map<String, String> parseCookieHeader(String header) => {
    for (final part in header.split(';'))
      if (part.indexOf('=') case final at when at > 0)
        part.substring(0, at).trim(): part.substring(at + 1).trim(),
  };

  Map<String, Object?> toJson() => {
    'version': 1,
    'cookies': cookies,
    'userAgent': userAgent,
    'sessionIndex': sessionIndex,
    'delegatedSessionId': delegatedSessionId,
    'visitorData': visitorData,
    'clientVersion': clientVersion,
  };

  static YoutubeMusicSession? fromJson(Object? value) {
    if (value is! Map || value['version'] != 1 || value['cookies'] is! Map) {
      return null;
    }
    String? text(Object? item) =>
        item is String && item.trim().isNotEmpty ? item.trim() : null;
    return YoutubeMusicSession(
      cookies: {
        for (final MapEntry(:key, :value) in (value['cookies'] as Map).entries)
          if (key is String && value is String) key: value,
      },
      userAgent: text(value['userAgent']) ?? _fallbackUserAgent,
      sessionIndex: text(value['sessionIndex']),
      delegatedSessionId: text(value['delegatedSessionId']),
      visitorData: text(value['visitorData']),
      clientVersion: text(value['clientVersion']),
    );
  }
}

/// Builds the signed request headers. [now] is injectable for deterministic tests.
Map<String, String>? youtubeMusicHeaders(
  YoutubeMusicSession session, {
  DateTime? now,
}) {
  final sapisid = session._sapisid;
  if (sapisid == null) return null;
  final timestamp = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  String signed(String scheme, String value) {
    final digest = sha1.convert(
      utf8.encode(timestamp.toString() + ' ' + value + ' ' + _origin),
    );
    return scheme + ' ' + timestamp.toString() + '_' + digest.toString();
  }

  final authorization = [signed('SAPISIDHASH', sapisid)];
  for (final entry in [
    ('SAPISID1PHASH', '__Secure-1PAPISID'),
    ('SAPISID3PHASH', '__Secure-3PAPISID'),
  ]) {
    final value = session.cookies[entry.$2];
    if (value != null && value.isNotEmpty) {
      authorization.add(signed(entry.$1, value));
    }
  }
  final cookies = {...session.cookies};
  cookies.putIfAbsent('SAPISID', () => sapisid);
  return {
    'Content-Type': 'application/json',
    'Origin': _origin,
    'Referer': _origin + '/',
    // WEB_REMIX account browsing uses desktop's web surface. Interactive
    // sign-in keeps the real WebView UA; it is a separate request path.
    'User-Agent': _fallbackUserAgent,
    'Cookie': [
      for (final MapEntry(:key, :value) in cookies.entries) key + '=' + value,
    ].join('; '),
    'Authorization': authorization.join(' '),
    'X-Origin': _origin,
    'X-YouTube-Client-Name': '67',
    'X-YouTube-Client-Version': session.clientVersion ?? _fallbackClientVersion,
    'X-Goog-AuthUser': session.sessionIndex ?? '0',
    if (session.visitorData != null) 'X-Goog-Visitor-Id': session.visitorData!,
    if (session.delegatedSessionId != null)
      'X-Goog-PageId': session.delegatedSessionId!,
  };
}

List<Object?> _list(Object? value) => value is List ? value : const [];

Object? _at(Object? value, List<Object> path) {
  var node = value;
  for (final step in path) {
    if (step is int) {
      if (node is! List || step < 0 || step >= node.length) return null;
      node = node[step];
    } else {
      if (node is! Map) return null;
      node = node[step];
    }
  }
  return node;
}

String _text(Object? value) {
  if (value is String) return value;
  if (value is! Map) return '';
  if (value['text'] != null) return value['text'].toString();
  if (value['simpleText'] != null) return value['simpleText'].toString();
  return [
    for (final run in _list(value['runs']))
      if (run is Map) (run['text'] ?? '').toString(),
  ].join();
}

String _thumbnail(Object? value) {
  final urls = <String>[];
  void visit(Object? node, int depth) {
    if (depth > 14) return;
    if (node is Map) {
      if (node['url'] is String) {
        urls.add(node['url'] as String);
      }
      for (final child in node.values) {
        visit(child, depth + 1);
      }
    } else if (node is List) {
      for (final child in node) {
        visit(child, depth + 1);
      }
    }
  }

  visit(value, 0);
  if (urls.isEmpty) return '';
  return urls.last.replaceFirst(
    RegExp(r'=w\d+-h\d+[^&?]*$'),
    '=w544-h544-l90-rj',
  );
}

String _pageType(Object? endpoint) =>
    (_at(endpoint, [
              'browseEndpointContextSupportedConfigs',
              'browseEndpointContextMusicConfig',
              'pageType',
            ]) ??
            '')
        .toString();

Duration? _duration(Object? raw) {
  final value = _text(raw).trim();
  if (!_clock.hasMatch(value)) return null;
  final parts = value.split(':').map(int.tryParse).toList();
  if (parts.any((part) => part == null)) return null;
  if (parts.skip(1).any((part) => part! >= 60)) return null;
  return Duration(seconds: parts.fold<int>(0, (n, p) => n * 60 + p!));
}

void _walk(
  Object? root,
  void Function(Map node) visit, {
  int maxNodes = 200000,
}) {
  var count = 0, total = 0;
  void walk(Object? value, int depth) {
    if (++count > maxNodes || ++total > maxNodes * 20 || depth > 45) return;
    if (value is Map) {
      visit(value);
      for (final child in value.values) {
        walk(child, depth + 1);
      }
    } else if (value is List) {
      for (final child in value) {
        walk(child, depth + 1);
      }
    }
  }

  if (root is List) {
    // Callers pass independently bounded response pages. Spending one shared
    // budget on the first page made all later continuation pages invisible.
    for (final page in root) {
      if (total > maxNodes * 20) break;
      count = 0;
      walk(page, 0);
    }
  } else {
    walk(root, 0);
  }
}

typedef _Metadata = ({
  String artist,
  String album,
  Duration? duration,
  String? kind,
});

_Metadata _metadata(Iterable<Object?> rawRuns) {
  final artists = <String>[];
  final loose = <String>[];
  String? album;
  Duration? duration;
  String? kind;
  for (final run in rawRuns) {
    final text = _text(run).trim();
    if (text.isEmpty || text == '•') continue;
    final browse = _at(run, ['navigationEndpoint', 'browseEndpoint']);
    final type = _pageType(browse);
    final id = (_at(browse, ['browseId']) ?? '').toString();
    if (type.endsWith('_ARTIST') ||
        type.endsWith('_USER_CHANNEL') ||
        id.startsWith('UC')) {
      artists.add(text);
    } else if (type.endsWith('_ALBUM') || id.startsWith('MPRE')) {
      album = text;
    } else if (_duration(text) case final length?) {
      duration = length;
    } else if (!RegExp(
      r'\b(views|plays|listeners|subscribers)$',
      caseSensitive: false,
    ).hasMatch(text)) {
      loose.add(text);
    }
  }
  if (loose.isNotEmpty &&
      RegExp(
        r'^(song|video|episode)$',
        caseSensitive: false,
      ).hasMatch(loose.first)) {
    kind = loose.removeAt(0).toLowerCase();
  }
  if (artists.isEmpty && loose.isNotEmpty) artists.add(loose.removeAt(0));
  album ??= loose.where((text) => !artists.contains(text)).firstOrNull;
  return (
    artist: artists.toSet().join(', '),
    album: album ?? '',
    duration: duration,
    kind: kind,
  );
}

List<Object?> _columnRuns(Map renderer, int index) => _list(
  _at(renderer, [
    'flexColumns',
    index,
    'musicResponsiveListItemFlexColumnRenderer',
    'text',
    'runs',
  ]),
);

List<Object?> _bylineRuns(Object? byline) {
  final runs = _list(_at(byline, ['runs']));
  if (runs.any((run) => run is Map && run['navigationEndpoint'] != null)) {
    return runs;
  }
  return [
    for (final line in _text(byline).split('•')) {'text': line},
  ];
}

LokalDiscoveryTrack? _listItem(Map renderer) {
  final titleRuns = _columnRuns(renderer, 0);
  final watch =
      _at(titleRuns.firstOrNull, ['navigationEndpoint', 'watchEndpoint']) ??
      _at(renderer, ['navigationEndpoint', 'watchEndpoint']);
  final rawId =
      _at(renderer, ['playlistItemData', 'videoId']) ?? _at(watch, ['videoId']);
  final id = rawId?.toString() ?? '';
  if (!_videoId.hasMatch(id)) return null;
  final columns = _list(renderer['flexColumns']);
  final runs = <Object?>[
    for (var i = 1; i < columns.length; i++) ..._columnRuns(renderer, i),
    for (final column in _list(renderer['fixedColumns']))
      ..._list(
        _at(column, [
          'musicResponsiveListItemFixedColumnRenderer',
          'text',
          'runs',
        ]),
      ),
  ];
  final meta = _metadata(runs);
  if (meta.kind == 'episode') return null;
  return _track(
    id,
    titleRuns.map(_text).join().trim(),
    meta.artist,
    meta.album,
    meta.duration,
    _thumbnail(renderer['thumbnail']),
  );
}

LokalDiscoveryTrack? _panelItem(Map panel) {
  final id = (panel['videoId'] ?? '').toString();
  if (!_videoId.hasMatch(id)) return null;
  final meta = _metadata(
    _bylineRuns(panel['longBylineText'] ?? panel['shortBylineText']),
  );
  return _track(
    id,
    _text(panel['title']),
    meta.artist,
    meta.album,
    _duration(panel['lengthText']) ?? meta.duration,
    _thumbnail(panel['thumbnail']),
  );
}

LokalDiscoveryTrack? _trackCard(Map renderer) {
  final endpoints = [
    renderer['navigationEndpoint'],
    renderer['onTap'],
    for (final run in _list(_at(renderer, ['title', 'runs'])))
      _at(run, ['navigationEndpoint']),
  ];
  if (endpoints.any(
    (endpoint) =>
        _at(endpoint, ['watchPlaylistEndpoint']) != null ||
        (_at(endpoint, ['browseEndpoint', 'browseId']) ?? '')
            .toString()
            .startsWith('VL'),
  )) {
    return null;
  }
  final id = endpoints
      .map(
        (endpoint) =>
            (_at(endpoint, ['watchEndpoint', 'videoId']) ?? '').toString(),
      )
      .firstWhere(_videoId.hasMatch, orElse: () => '');
  final title = _text(renderer['title']);
  if (id.isEmpty || title.isEmpty) return null;
  final meta = _metadata(_bylineRuns(renderer['subtitle']));
  if (meta.kind == 'episode') return null;
  return _track(
    id,
    title,
    meta.artist.isEmpty ? 'Unknown Artist' : meta.artist,
    meta.album,
    meta.duration,
    _thumbnail(renderer['thumbnailRenderer'] ?? renderer['thumbnail']),
  );
}

LokalDiscoveryTrack _track(
  String id,
  String title,
  String artist,
  String album,
  Duration? duration,
  String artwork,
) => LokalDiscoveryTrack(
  title: title,
  artist: artist,
  album: album,
  artworkUrl: artwork,
  url: _origin + '/watch?v=' + id,
  videoId: id,
  duration: duration,
);

/// Parses songs from account shelves and playlist pages, preserving order.
List<LokalDiscoveryTrack> parseYoutubeMusicTracks(
  Object? root, {
  int limit = 100,
}) {
  final tracks = <LokalDiscoveryTrack>[];
  final seen = <String>{};
  _walk(root, (node) {
    if (tracks.length >= limit) return;
    final row = node['musicResponsiveListItemRenderer'];
    final panel = node['playlistPanelVideoRenderer'];
    final card = node['musicTwoRowItemRenderer'];
    final track = row is Map
        ? _listItem(row)
        : panel is Map
        ? _panelItem(panel)
        : card is Map
        ? _trackCard(card)
        : null;
    if (track == null || track.title.isEmpty || track.videoId == null) return;
    if (seen.add(track.videoId!)) tracks.add(track);
  });
  return tracks;
}

/// Parses playlist cards, including provider-owned radio mixes.
List<LokalDiscoveryMix> parseYoutubeMusicPlaylists(
  Object? root, {
  int limit = 100,
}) {
  final playlists = <String, LokalDiscoveryMix>{};
  _walk(root, (node) {
    if (playlists.length >= limit) return;
    final renderer =
        node['gridPlaylistRenderer'] ??
        node['musicTwoRowItemRenderer'] ??
        node['musicResponsiveListItemRenderer'];
    if (renderer is! Map) return;
    final endpoints = <Object?>[
      for (final run in _list(_at(renderer, ['title', 'runs'])))
        _at(run, ['navigationEndpoint']),
      for (final run in _list(
        _at(renderer, [
          'flexColumns',
          0,
          'musicResponsiveListItemFlexColumnRenderer',
          'text',
          'runs',
        ]),
      ))
        _at(run, ['navigationEndpoint']),
      renderer['navigationEndpoint'],
      renderer['onTap'],
      _at(renderer['thumbnailOverlay'] ?? renderer['overlay'], [
        'musicItemThumbnailOverlayRenderer',
        'content',
        'musicPlayButtonRenderer',
        'playNavigationEndpoint',
      ]),
    ];
    final browse = endpoints
        .map((endpoint) => _at(endpoint, ['browseEndpoint']))
        .whereType<Map>()
        .firstOrNull;
    final type = _pageType(browse);
    final rawId =
        renderer['playlistId'] ??
        _at(browse, ['browseId']) ??
        endpoints
            .map(
              (endpoint) =>
                  _at(endpoint, ['watchPlaylistEndpoint', 'playlistId']) ??
                  _at(endpoint, ['watchEndpoint', 'playlistId']),
            )
            .firstWhere((value) => value != null, orElse: () => null);
    var id = rawId?.toString() ?? '';
    if (id.startsWith('VL')) id = id.substring(2);
    if (id.isEmpty ||
        id.startsWith('UC') ||
        id.startsWith('MPRE') ||
        id.startsWith('FE') ||
        (type.isNotEmpty &&
            !type.endsWith('_PLAYLIST') &&
            !id.startsWith('RD')) ||
        (id.startsWith('RD') && id.length < 8)) {
      return;
    }
    if (browse == null &&
        renderer['isPlaylist'] != true &&
        !endpoints.any(
          (endpoint) =>
              _at(endpoint, ['watchPlaylistEndpoint']) != null ||
              '${_at(endpoint, ['watchEndpoint', 'playlistId']) ?? ''}'
                  .startsWith('RDTMAK'),
        ) &&
        endpoints.any(
          (endpoint) => _at(endpoint, ['watchEndpoint', 'videoId']) != null,
        ))
      return;
    final title = _text(
      renderer['title'] ??
          _at(renderer, [
            'flexColumns',
            0,
            'musicResponsiveListItemFlexColumnRenderer',
            'text',
          ]),
    );
    if (title.isEmpty) return;
    playlists.putIfAbsent(
      id,
      () => LokalDiscoveryMix(
        id: id,
        title: title,
        author: _text(renderer['shortBylineText'] ?? renderer['subtitle']),
        artworkUrl: _thumbnail(
          renderer['thumbnailRenderer'] ?? renderer['thumbnail'],
        ),
      ),
    );
  });
  return playlists.values.toList();
}

final _mixTitle = RegExp(
  r'^(mixed for you|mixes for you|your mixes|mix pour vous|mix pour toi|mixes pour vous|vos mix|für dich gemixt|mixes für dich|mixes para ti|mezclas para ti|mix per te|mixes para você|ミックスリスト|あなたへのミックス|나만을 위한 믹스|为你精选的混合播放列表)$',
  caseSensitive: false,
);

String _shelfTitle(Map shelf) => _text(
  _at(shelf, ['header', 'musicCarouselShelfBasicHeaderRenderer', 'title']) ??
      _at(shelf, ['header', 'musicShelfHeaderRenderer', 'title']) ??
      shelf['title'],
).trim();

bool _isPersonalMixShelf(Map shelf) {
  if (_mixTitle.hasMatch(_shelfTitle(shelf))) return true;
  var personal = false;
  _walk(shelf['header'], (node) {
    final id = node['browseId'];
    if (id is String &&
        RegExp(r'(mixed_for_you|mixes_for_you|your_mixes)').hasMatch(id))
      personal = true;
  });
  return personal;
}

bool _hasPersonalMixShelf(Object? root) {
  var found = false;
  _walk(root, (node) {
    final shelf =
        node['musicCarouselShelfRenderer'] ?? node['musicShelfRenderer'];
    if (shelf is Map &&
        _isPersonalMixShelf(shelf) &&
        parseYoutubeMusicPlaylists(shelf['contents']).isNotEmpty)
      found = true;
  });
  return found;
}

List<({Map shelf, bool named})> _personalMixShelves(Object? root) {
  final shelves = <({Map shelf, bool named})>[];
  _walk(root, (node) {
    final shelf =
        node['musicCarouselShelfRenderer'] ?? node['musicShelfRenderer'];
    if (shelf is! Map) return;
    final named = _isPersonalMixShelf(shelf);
    if (named ||
        parseYoutubeMusicPlaylists(shelf['contents'])
            .any((mix) => mix.id.startsWith('RDTMAK'))) {
      shelves.add((shelf: shelf, named: named));
    }
  });
  return shelves;
}

List<LokalDiscoveryMix> parseYoutubeMusicMixes(Object? root) {
  final mixes = <String, LokalDiscoveryMix>{};
  _walk(root, (node) {
    final shelf =
        node['musicCarouselShelfRenderer'] ?? node['musicShelfRenderer'];
    if (shelf is! Map) return;
    final named = _isPersonalMixShelf(shelf);
    for (final mix in parseYoutubeMusicPlaylists(
      shelf['contents'],
      limit: 200,
    )) {
      if (named || mix.id.startsWith('RDTMAK')) {
        mixes.putIfAbsent(mix.id, () => mix);
      }
    }
  });
  // Native radio cards may be returned in a grid or flat continuation without
  // the carousel wrapper. Only provider-owned mix IDs qualify here.
  for (final mix in parseYoutubeMusicPlaylists(root, limit: 500)) {
    if (mix.id.startsWith('RDTMAK')) mixes.putIfAbsent(mix.id, () => mix);
  }
  return mixes.values.toList();
}

/// The "More" browse endpoint attached to a named personal-mixes shelf.
List<({String browseId, String? params})> _mixShelfBrowseEndpoints(
  Object? root,
) {
  final endpoints = <String, ({String browseId, String? params})>{};
  _walk(root, (node) {
    final shelf =
        node['musicCarouselShelfRenderer'] ?? node['musicShelfRenderer'];
    if (shelf is! Map || !_isPersonalMixShelf(shelf)) return;
    _walk(shelf['header'], (headerNode) {
      final candidates = [
        headerNode['browseEndpoint'],
        _at(headerNode, ['navigationEndpoint', 'browseEndpoint']),
        _at(headerNode, [
          'moreContentButton',
          'buttonRenderer',
          'navigationEndpoint',
          'browseEndpoint',
        ]),
      ];
      for (final candidate in candidates.whereType<Map>()) {
        final id = candidate['browseId'];
        if (id is! String || id.isEmpty) continue;
        final params = candidate['params'];
        final key = id + '\u0000' + (params is String ? params : '');
        endpoints[key] = (
          browseId: id,
          params: params is String ? params : null,
        );
      }
    });
  });
  _walk(root, (node) {
    final chip =
        node['chipCloudChipRenderer'] ?? node['musicNavigationButtonRenderer'];
    if (chip is! Map ||
        !_mixTitle.hasMatch(_text(chip['text'] ?? chip['buttonText']).trim()))
      return;
    final endpoint = _at(
      chip['navigationEndpoint'] ?? chip['onTap'] ?? chip['clickCommand'],
      ['browseEndpoint'],
    );
    if (endpoint is! Map || endpoint['browseId'] is! String) return;
    final id = endpoint['browseId'] as String;
    final params = endpoint['params'] is String
        ? endpoint['params'] as String
        : null;
    endpoints['$id\u0000${params ?? ''}'] = (browseId: id, params: params);
  });
  return endpoints.values.toList();
}

/// Parse YouTube Music album cards without treating arbitrary tracks as albums.
List<LokalDiscoveryAlbum> parseYoutubeMusicAlbums(Object? root) {
  final albums = <String, LokalDiscoveryAlbum>{};
  _walk(root, (node) {
    final row = node['musicTwoRowItemRenderer'] ??
        node['musicResponsiveListItemRenderer'];
    if (row is! Map) return;
    final titleRuns = _columnRuns(row, 0);
    final browse = _at(row, ['navigationEndpoint', 'browseEndpoint']) ??
        _at(titleRuns.firstOrNull, ['navigationEndpoint', 'browseEndpoint']);
    final id = (_at(browse, ['browseId']) ?? '').toString();
    if (!id.startsWith('MPRE') && !_pageType(browse).endsWith('_ALBUM')) return;
    final title = _text(row['title']).isNotEmpty
        ? _text(row['title'])
        : titleRuns.map(_text).join();
    if (id.isEmpty || title.isEmpty) return;
    final byline = _bylineRuns(row['subtitle'] ?? row['shortBylineText']);
    // YouTube Music prefixes some release cards with "Single", "Album"
    // or "EP"; that release type is not the recording artist.
    final isReleaseType = const {'single', 'album', 'ep'}.contains(
      _text(byline.firstOrNull).trim().toLowerCase(),
    );
    final artist = _metadata(isReleaseType ? byline.skip(1) : byline).artist;
    albums.putIfAbsent(id, () => LokalDiscoveryAlbum(
      title: title,
      artist: artist,
      artworkUrl: _thumbnail(row['thumbnailRenderer'] ?? row['thumbnail']),
      url: 'https://music.youtube.com/browse/$id',
    ));
  });
  return albums.values.toList();
}

/// Match real, named provider shelves, not fabricated search recommendations.
String? youtubeMusicHomeCategory(String title) {
  final value = title.toLowerCase().trim();
  if (value.contains('community')) return 'community';
  if (value.contains('new release') ||
      value.contains('new album') ||
      value.contains('recently released')) return 'newReleases';
  if (value.contains('trending')) return 'trending';
  if (value.contains('featured playlist')) return 'featuredPlaylists';
  if (value.contains('daily discover') ||
      value.contains('discover mix')) return 'dailyDiscover';
  return null;
}

List<LokalDiscoveryCategory> parseYoutubeMusicHomeCategories(Object? root) {
  final groups = <String, List<LokalDiscoveryCategory>>{};
  _walk(root, (node) {
    final shelf = node['musicCarouselShelfRenderer'] ??
        node['musicShelfRenderer'];
    if (shelf is! Map) return;
    final id = youtubeMusicHomeCategory(_shelfTitle(shelf));
    if (id == null) return;
    final contents = shelf['contents'];
    final category = LokalDiscoveryCategory(
      id: id,
      tracks: parseYoutubeMusicTracks(contents),
      mixes: parseYoutubeMusicPlaylists(contents),
      albums: parseYoutubeMusicAlbums(contents),
    );
    if (!category.isEmpty) groups.putIfAbsent(id, () => []).add(category);
  });
  return [
    for (final entry in groups.entries)
      LokalDiscoveryCategory(
        id: entry.key,
        tracks: <String, LokalDiscoveryTrack>{
          for (final group in entry.value)
            for (final track in group.tracks)
              (track.videoId ?? track.key): track,
        }.values.toList(),
        mixes: <String, LokalDiscoveryMix>{
          for (final group in entry.value)
            for (final mix in group.mixes) mix.id: mix,
        }.values.toList(),
        albums: <String, LokalDiscoveryAlbum>{
          for (final group in entry.value)
            for (final album in group.albums) album.url: album,
        }.values.toList(),
      ),
  ];
}

List<LokalDiscoveryArtist> parseYoutubeMusicArtists(Object? root) {
  final artists = <String, LokalDiscoveryArtist>{};
  _walk(root, (node) {
    final row =
        node['musicTwoRowItemRenderer'] ??
        node['musicResponsiveListItemRenderer'];
    if (row is! Map) return;
    final titleRuns = _columnRuns(row, 0);
    final endpoint =
        _at(row, ['navigationEndpoint', 'browseEndpoint']) ??
        _at(titleRuns.firstOrNull, ['navigationEndpoint', 'browseEndpoint']);
    final id = (_at(endpoint, ['browseId']) ?? '').toString();
    final title = _text(row['title']).isNotEmpty
        ? _text(row['title'])
        : titleRuns.map(_text).join();
    if (title.isEmpty ||
        (!_pageType(endpoint).endsWith('_ARTIST') && !id.startsWith('UC'))) {
      return;
    }
    artists.putIfAbsent(
      id,
      () => LokalDiscoveryArtist(
        name: title,
        image: _thumbnail(row['thumbnailRenderer'] ?? row['thumbnail']),
      ),
    );
  });
  return artists.values.take(30).toList();
}

bool youtubeMusicLoggedOut(Map<String, dynamic> json) {
  final context = json['responseContext'];
  if (context is! Map) return false;
  final web = context['mainAppWebResponseContext'];
  if (web is Map && web['loggedOut'] == true) return true;
  final loginStates = <String>{};
  for (final service in _list(context['serviceTrackingParams'])) {
    if (service is! Map) continue;
    for (final param in _list(service['params'])) {
      if (param is Map && param['key'] == 'logged_in') {
        loginStates.add((param['value'] ?? '').toString());
      }
    }
  }
  return loginStates.contains('0') && !loginStates.contains('1');
}

bool _confirmsSignedIn(Map<String, dynamic> json) {
  final context = json['responseContext'];
  if (context is! Map) return false;
  final web = context['mainAppWebResponseContext'];
  if (web is Map && web['loggedOut'] == false) return true;
  for (final service in _list(context['serviceTrackingParams'])) {
    if (service is! Map) continue;
    for (final param in _list(service['params'])) {
      if (param is Map &&
          param['key'] == 'logged_in' &&
          (param['value'] ?? '').toString() == '1') {
        return true;
      }
    }
  }
  return false;
}

class YoutubeMusicSignedOut implements Exception {
  const YoutubeMusicSignedOut([
    this.message = 'YouTube Music rejected the saved session. Sign in again in Data → Accounts.',
  ]);
  final String message;
  @override
  String toString() => message;
}

class YoutubeMusicAccountData {
  const YoutubeMusicAccountData({
    required this.liked,
    required this.home,
    required this.homePlaylists,
    required this.mixes,
    required this.history,
    required this.artists,
    this.categories = const [],
    this.homeError,
    this.mixError,
  });

  final List<LokalDiscoveryTrack>? liked;
  final List<LokalDiscoveryTrack> home;
  final List<LokalDiscoveryMix> homePlaylists;
  final List<LokalDiscoveryMix> mixes;
  final List<LokalDiscoveryTrack>? history;
  final List<LokalDiscoveryArtist> artists;
  final List<LokalDiscoveryCategory> categories;
  final String? homeError;
  final String? mixError;
}

const _homeContinuationTypes = {
  'sectionListRenderer',
  'sectionListContinuation',
  'appendContinuationItemsAction',
  'reloadContinuationItemsCommand',
};
const _mixContinuationTypes = {
  ..._homeContinuationTypes,
  'musicCarouselShelfRenderer',
  'musicCarouselShelfContinuation',
  'musicShelfRenderer',
  'musicShelfContinuation',
  'gridRenderer',
  'gridContinuation',
};
List<String> _continuations(Object? root, {Set<String>? types}) {
  final tokens = <String>{};
  void collect(Map node) {
    for (final item in _list(node['continuations'])) {
      final token = _at(item, ['nextContinuationData', 'continuation']);
      if (token is String && token.isNotEmpty) tokens.add(token);
    }
    for (final item in _list(
      node['contents'] ?? node['items'] ?? node['continuationItems'],
    )) {
      final endpoint = _at(item, [
        'continuationItemRenderer',
        'continuationEndpoint',
      ]);
      for (final command in [
        endpoint,
        ..._list(_at(endpoint, ['commandExecutorCommand', 'commands'])),
      ]) {
        final token = _at(command, ['continuationCommand', 'token']);
        if (token is String && token.isNotEmpty) tokens.add(token);
      }
    }
  }

  _walk(root, (node) {
    if (types == null) {
      collect(node);
    } else {
      for (final type in types) {
        if (node[type] case final Map container) collect(container);
      }
    }
  });
  return tokens.toList();
}

/// Makes signed-in account requests and persists rotated non-identity cookies.
class YoutubeMusicAccount {
  YoutubeMusicAccount(
    this.client,
    this.session, {
    this.onSessionChanged,
    this.timeout = const Duration(seconds: 12),
  });

  final http.Client client;
  YoutubeMusicSession session;
  final void Function(YoutubeMusicSession session)? onSessionChanged;
  final Duration timeout;
  Map<String, Object?> _clientContext = const {};

  Future<Map<String, dynamic>> request(
    String endpoint,
    Map<String, Object?> body, {
    String? continuation,
    Duration? timeout,
    DateTime? deadline,
  }) async {
    var allowedTime = timeout ?? this.timeout;
    if (deadline != null) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero)
        throw TimeoutException('YouTube Music loading deadline reached.');
      if (remaining < allowedTime) allowedTime = remaining;
    }
    final headers = youtubeMusicHeaders(session);
    if (headers == null) {
      throw const YoutubeMusicSignedOut(
        'Sign in to YouTube Music in Data → Accounts.',
      );
    }
    final uri = Uri.https('music.youtube.com', '/youtubei/v1/' + endpoint, {
      'prettyPrint': 'false',
      if (continuation != null) 'continuation': continuation,
      if (continuation != null) 'ctoken': continuation,
    });
    final response = await client
        .post(
          uri,
          headers: headers,
          body: jsonEncode({
            'context': {
              'client': {
                'clientName': 'WEB_REMIX',
                ..._clientContext,
                'clientVersion':
                    session.clientVersion ?? _fallbackClientVersion,
                'hl': 'en',
                if (session.visitorData != null)
                  'visitorData': session.visitorData,
              },
              'user': {
                if (session.delegatedSessionId != null)
                  'onBehalfOfUser': session.delegatedSessionId,
              },
            },
            ...body,
            if (continuation != null) 'continuation': continuation,
          }),
        )
        .timeout(allowedTime);
    _keepCookies(response.headers['set-cookie']);
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const YoutubeMusicSignedOut();
    }
    if (response.statusCode != 200) {
      throw LokalDiscoveryFailure(
        'YouTube Music account request failed (' +
            response.statusCode.toString() +
            ').',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const LokalDiscoveryFailure(
        'YouTube Music returned an unreadable answer.',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const LokalDiscoveryFailure(
        'YouTube Music returned an unreadable answer.',
      );
    }
    if (youtubeMusicLoggedOut(decoded)) throw const YoutubeMusicSignedOut();
    return decoded;
  }

  Future<Map<String, dynamic>> browse(
    String browseId, {
    String? params,
    String? continuation,
    Duration? timeout,
    DateTime? deadline,
  }) => request(
    'browse',
    {'browseId': browseId, if (params != null) 'params': params},
    continuation: continuation,
    timeout: timeout,
    deadline: deadline,
  );

  Future<Map<String, dynamic>> _firstPage(
    String browseId, {
    DateTime? deadline,
  }) => browse(
    browseId,
    timeout: const Duration(seconds: 10),
    deadline: deadline,
  );

  void _keepCookies(String? header) {
    if (header == null || header.isEmpty) return;
    final updated = <String, String>{};
    for (final raw in header.split(RegExp(r',(?=\s*[\w.-]+=)'))) {
      final pair = raw.split(';').first;
      final at = pair.indexOf('=');
      if (at <= 0) continue;
      final name = pair.substring(0, at).trim();
      final value = pair.substring(at + 1).trim();
      if (value.isEmpty || YoutubeMusicSession.identityCookies.contains(name)) {
        continue;
      }
      if (session.cookies[name] != value) updated[name] = value;
    }
    if (updated.isNotEmpty) {
      session = session.withCookies(updated);
      onSessionChanged?.call(session);
    }
  }

  Future<({List<Object?> pages, String? error})> _pages(
    String browseId,
    Object? first, {
    bool stopAtMixShelf = false,
    String? params,
    Set<String> types = _mixContinuationTypes,
    DateTime? deadline,
  }) async {
    final pages = <Object?>[first];
    final seen = <String>{};
    final pending = _continuations(first, types: types);
    final pageDeadline = DateTime.now().add(const Duration(seconds: 10));
    final stopAt = deadline != null && deadline.isBefore(pageDeadline)
        ? deadline
        : pageDeadline;
    while (pending.isNotEmpty && seen.length < 20) {
      if (stopAtMixShelf && _hasPersonalMixShelf(pages)) break;
      final token = pending.removeAt(0);
      if (!seen.add(token)) continue;
      final left = stopAt.difference(DateTime.now());
      if (left <= Duration.zero) {
        return (
          pages: pages,
          error: 'YouTube Music loading timed out. Refresh to retry.',
        );
      }
      try {
        final page = await browse(
          browseId,
          params: params,
          continuation: token,
          timeout: left < const Duration(seconds: 5)
              ? left
              : const Duration(seconds: 5),
        );
        pages.add(page);
        pending.addAll(
          _continuations(
            page,
            types: types,
          ).where((value) => !seen.contains(value)),
        );
      } on YoutubeMusicSignedOut {
        rethrow;
      } catch (_) {
        return (
          pages: pages,
          error: 'Some YouTube Music recommendations could not be loaded.',
        );
      }
    }
    if (pending.isNotEmpty && seen.length >= 20) {
      return (
        pages: pages,
        error: 'YouTube Music returned too many pages. Refresh to retry.',
      );
    }
    return (pages: pages, error: null);
  }

  Future<Map<String, dynamic>?> _refreshPage() async {
    try {
      final headers = youtubeMusicHeaders(session);
      if (headers == null) return null;
      final response = await client
          .get(
            Uri.parse('$_origin/').replace(
              queryParameters: {
                if (session.sessionIndex != null)
                  'authuser': session.sessionIndex!,
              },
            ),
            headers: {
              'Cookie': headers['Cookie']!,
              'User-Agent': _fallbackUserAgent,
              'Accept-Language': 'en-US,en;q=0.9',
            },
          )
          .timeout(const Duration(seconds: 6));
      if (response.statusCode != 200 ||
          response.bodyBytes.length > 8 * 1024 * 1024)
        return null;
      _keepCookies(response.headers['set-cookie']);
      final html = utf8.decode(response.bodyBytes);
      final config = youtubeMusicPageObject(html, 'ytcfg');
      if (config != null) {
        final context = _at(config, ['INNERTUBE_CONTEXT', 'client']);
        _clientContext = context is Map
            ? context.cast<String, Object?>()
            : const {};
        session = YoutubeMusicSession(
          cookies: session.cookies,
          userAgent: session.userAgent,
          // Preserve the profile explicitly selected at sign-in.
          sessionIndex:
              session.sessionIndex ?? config['SESSION_INDEX']?.toString(),
          delegatedSessionId:
              session.delegatedSessionId ??
              config['DELEGATED_SESSION_ID']?.toString(),
          visitorData:
              config['VISITOR_DATA']?.toString() ?? session.visitorData,
          clientVersion:
              config['INNERTUBE_CLIENT_VERSION']?.toString() ??
              session.clientVersion,
        );
        onSessionChanged?.call(session);
      }
      return youtubeMusicPageObject(html, 'ytInitialData');
    } on Object {
      return null;
    } // API browsing can still work without HTML.
  }

  Future<YoutubeMusicAccountData> fetch({
    int limit = 100,
    Duration budget = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(budget);
    final initialPage = await _refreshPage();
    final errors = <Object>[];
    Future<Map<String, dynamic>?> attempt(String id) async {
      try {
        return await _firstPage(id, deadline: deadline);
      } catch (error) {
        errors.add(error);
        return null;
      }
    }

    final results = await Future.wait([
      attempt('VLLM'),
      attempt('FEmusic_home'),
      attempt('FEmusic_history'),
      attempt('FEmusic_liked_playlists'),
    ]);
    final liked = results[0];
    final home = results[1];
    final history = results[2];
    final playlistsPage = results[3];
    final answered = results.whereType<Map<String, dynamic>>().toList();
    if (!answered.any(_confirmsSignedIn)) {
      final signedOut = errors.whereType<YoutubeMusicSignedOut>().firstOrNull;
      if (signedOut != null || answered.isNotEmpty) {
        throw signedOut ?? const YoutubeMusicSignedOut();
      }
      throw LokalDiscoveryFailure(
        errors.isEmpty
            ? 'YouTube Music did not answer.'
            : _message(errors.first),
      );
    }

    final homePages = <Object?>[if (initialPage != null) initialPage];
    String? mixError;
    if (home != null) {
      final result = await _pages(
        'FEmusic_home',
        home,
        // Mixed-for-you cards can be in later home pages, even after a
        // populated first shelf. Preserve the older continuation recovery.
        stopAtMixShelf: false,
        types: _homeContinuationTypes,
        deadline: deadline,
      );
      homePages.addAll(result.pages);
      mixError = result.error;
    }
    final mixes = <String, LokalDiscoveryMix>{
      for (final mix in parseYoutubeMusicMixes(homePages)) mix.id: mix,
      for (final mix in parseYoutubeMusicPlaylists(playlistsPage))
        if (mix.id.startsWith('RDTMAK')) mix.id: mix,
    };
    // Home may contain only a header/seed card. Follow that shelf's own
    // continuation, whose response omits its parent title and shelf renderer.
    final visitedMixTokens = <String>{};
    final shelfContexts = _personalMixShelves(homePages)
        .where((context) {
          final tokens = _continuations(context.shelf);
          if (tokens.isEmpty || tokens.every(visitedMixTokens.contains))
            return false;
          visitedMixTokens.addAll(tokens);
          return true;
        })
        .take(6)
        .toList();
    final shelfResults = Future.wait(
      shelfContexts.map(
        (context) async => (
          named: context.named,
          result: await _pages('FEmusic_home', {
            'musicCarouselShelfRenderer': context.shelf,
          }, deadline: deadline),
        ),
      ),
    );
    final moreResults = await Future.wait(
      _mixShelfBrowseEndpoints(homePages).take(6).map((endpoint) async {
        try {
          final first = await browse(
            endpoint.browseId,
            params: endpoint.params,
            deadline: deadline,
          );
          return await _pages(
            endpoint.browseId,
            first,
            params: endpoint.params,
            deadline: deadline,
          );
        } on YoutubeMusicSignedOut {
          rethrow;
        } catch (_) {
          return (
            pages: <Object?>[],
            error: 'YouTube Music could not load every personal mix. Refresh to retry.',
          );
        }
      }),
    );
    for (final expanded in await shelfResults) {
      mixError ??= expanded.result.error;
      for (final mix in parseYoutubeMusicPlaylists(
        expanded.result.pages.skip(1).toList(),
        limit: 500,
      )) {
        if (expanded.named || mix.id.startsWith('RDTMAK'))
          mixes.putIfAbsent(mix.id, () => mix);
      }
    }
    for (final result in moreResults) {
      mixError ??= result.error;
      for (final mix in parseYoutubeMusicPlaylists(result.pages, limit: 500)) {
        mixes.putIfAbsent(mix.id, () => mix);
      }
    }
    if (mixes.isEmpty) {
      mixError ??= home == null
          ? 'YouTube Music could not load your home page. Refresh or reconnect your account in Data.'
          : 'YouTube Music returned no personal mix cards for this profile. Refresh, or check the selected account in Data.';
    }
    // Counts and status only: never write account cookies, IDs, tokens or pages.
    AppLog.instance.add(
      '[YouTube discovery] home=${home != null} embedded=${initialPage != null} '
      'pages=${homePages.length} shelves=${_personalMixShelves(homePages).length} '
      'mixRoutes=${_mixShelfBrowseEndpoints(homePages).length} '
      'library=${playlistsPage != null} mixes=${mixes.length} partial=${mixError != null}',
    );
    final likedTracks = liked == null
        ? null
        : parseYoutubeMusicTracks(liked, limit: limit);
    final homeTracks = parseYoutubeMusicTracks(homePages, limit: limit);
    final historyTracks = history == null
        ? null
        : parseYoutubeMusicTracks(history, limit: limit);
    return YoutubeMusicAccountData(
      liked: likedTracks,
      home: homeTracks,
      homePlaylists: parseYoutubeMusicPlaylists(homePages),
      mixes: mixes.values.toList(),
      history: historyTracks,
      artists: parseYoutubeMusicArtists(homePages),
      categories: parseYoutubeMusicHomeCategories(homePages),
      homeError: home == null && errors.isNotEmpty
          ? _message(errors.first)
          : null,
      mixError: mixError,
    );
  }

  Future<List<LokalDiscoveryTrack>> playlist(String id) async {
    final root = id.startsWith('RD')
        ? await request('next', {
            'playlistId': id,
            'enablePersistentPlaylistPanel': true,
            'isAudioOnly': true,
            'tunerSettingValue': 'AUTOMIX_SETTING_NORMAL',
          })
        : await browse('VL' + id);
    return parseYoutubeMusicTracks(root, limit: 500);
  }
}

String _message(Object error) => switch (error) {
  YoutubeMusicSignedOut(:final message) => message,
  LokalDiscoveryFailure(:final message) => message,
  TimeoutException() => 'YouTube Music took too long to answer.',
  _ => 'YouTube Music couldn’t be reached. Check your connection.',
};

class _Cached {
  const _Cached(this.at, this.data);
  final DateTime at;
  final YoutubeMusicAccountData data;
}

final _cache = <String, _Cached>{};
final _playlistCache = <String, List<LokalDiscoveryTrack>>{};

void forgetYoutubeMusicAccount() {
  _cache.clear();
  _playlistCache.clear();
}

Future<LokalDiscovery> loadYoutubeMusicDiscovery(
  YoutubeMusicAccount account, {
  int page = 0,
  bool force = false,
  DateTime? now,
}) async {
  final at = now ?? DateTime.now();
  final key = account.session.accountKey;
  final cached = _cache[key];
  final YoutubeMusicAccountData data;
  if (!force &&
      cached != null &&
      !at.isBefore(cached.at) &&
      at.difference(cached.at) < const Duration(minutes: 5)) {
    data = cached.data;
  } else {
    if (force) _playlistCache.removeWhere((id, _) => id.startsWith('$key:'));
    data = await account.fetch().timeout(const Duration(seconds: 35));
    _cache.remove(key);
    if (data.homeError == null &&
        data.mixError == null &&
        data.mixes.isNotEmpty) {
      _cache[key] = _Cached(at, data);
    }
    while (_cache.length > 4) {
      _cache.remove(_cache.keys.first);
    }
  }

  final warnings = <String>[];
  final picks = <LokalDiscoveryTrack>[];
  final playlists = data.homePlaylists;
  if (playlists.isNotEmpty) {
    final start = (page * 2) % playlists.length;
    final selected = <LokalDiscoveryMix>{
      playlists[start],
      playlists[(start + 1) % playlists.length],
    };
    final picked = await Future.wait(
      selected.map((mix) async {
        final cacheKey = key + ':' + mix.id;
        try {
          return _playlistCache[cacheKey] ??= await account
              .playlist(mix.id)
              .timeout(const Duration(seconds: 4));
        } on YoutubeMusicSignedOut {
          rethrow;
        } catch (error) {
          warnings.add(mix.title + ': ' + _message(error));
          return <LokalDiscoveryTrack>[];
        }
      }),
    );
    picks.addAll(picked.expand((tracks) => tracks));
  }
  final seen = <String>{};
  final candidates = [
    for (final track in [...data.home, ...picks])
      if (track.title.isNotEmpty &&
          track.artist.isNotEmpty &&
          seen.add(track.key))
        track,
  ];
  final artists = <String, LokalDiscoveryArtist>{
    for (final artist in data.artists) artist.name.toLowerCase(): artist,
  };
  for (final track in candidates) {
    if (artists.length >= 30) break;
    final name = track.artist.trim();
    if (name.isNotEmpty) {
      artists.putIfAbsent(
        name.toLowerCase(),
        () => LokalDiscoveryArtist(name: name),
      );
    }
  }
  if (data.homeError != null) warnings.add(data.homeError!);
  return LokalDiscovery(
    account: key,
    page: page,
    warnings: warnings,
    mixes: data.mixes,
    mixError: data.mixError,
    categories: data.categories,
    liked: data.liked?.take(30).toList(),
    history: data.history,
    artists: artists.values.take(30).toList(),
    freshFinds: candidates.take(30).toList(),
    candidates: candidates,
  );
}

Future<List<LokalDiscoveryTrack>> youtubeMusicMix(
  YoutubeMusicAccount account,
  String id,
) async => _playlistCache[account.session.accountKey + ':' + id] ??=
    await account.playlist(id);
