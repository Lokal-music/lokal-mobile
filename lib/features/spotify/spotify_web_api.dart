import 'dart:async';

import 'package:flick/core/utils/app_log.dart';

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'spotify_api.dart';
import 'spotify_http.dart';
import 'spotify_models.dart';
import 'spotify_oauth.dart';
import 'spotify_storage.dart';
import 'package:flick/services/graceful_http_client.dart';

/// Cookie sessions use the same Pathfinder operations as desktop, rather than
/// OAuth-only REST shelves that reject WebPlayer tokens with 403/429.
class SpotifyWebApi implements SpotifyLibraryApi {
  SpotifyWebApi({
    required this.store,
    required this.oauth,
    http.Client? client,
    this.likesSince,
  }) : _http = SpotifyHttp(
         client ?? GracefulHttpClient(),
         timeout: const Duration(seconds: 15),
       );
  final SpotifyTokenStore store;
  final SpotifyOAuthService oauth;
  final SpotifyHttp _http;
  final DateTime? likesSince;
  void close() => _http.client.close();
  static const hashes = {
    'searchTracks': 'bc1ca2fcd0ba1013a0fc88e6cc4f190af501851e3dafd3e1ef85840297694428',
    'home': '5fb7da7a03ee2776c0670856609cb85a189a3cecc36cc160b91cde79063b9cf1',
    'fetchPlaylist':
        '21ea11a6ac75a5f3e01fd365d29c18e0a4a8b7dc09f89bbb5d73910190c6acaf',
    'fetchLibraryTracks':
        '087278b20b743578a6262c2b0b4bcd20d879c503cc359a2285baf083ef944240',
    'libraryV3': '390c78e5b951029bad359785e69b07b536a509c581cbcd0aded5e5067f187455',
  };
  Future<Map<String, dynamic>> query(
    String operation,
    Map<String, Object?> variables, {
    SpotifyCancellation? cancellation,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      var tokens = await store.readTokens();
      if (tokens == null || tokens.sessionCookie?.isNotEmpty != true)
        throw const SpotifyApiException(
          'Add your Spotify cookie in Data → Accounts.',
        );
      if (tokens.isExpired) tokens = await oauth.refresh();
      cancellation?.check();
      if (tokens == null)
        throw const SpotifyApiException(
          'Your Spotify session expired. Update its cookie in Data → Accounts.',
        );
      final extensions = {
        'persistedQuery': {
          'version': 1,
          'sha256Hash': tokens.queryHashes[operation] ?? hashes[operation],
        },
      };
      // The desktop-proven libraryV3 operation is served on Pathfinder v1
      // as a GET. Other existing Spotify operations retain their v2 POST.
      final artistsLibrary = operation == 'libraryV3';
      final response = await _http.send(
        artistsLibrary
            ? Uri.https('api-partner.spotify.com', '/pathfinder/v1/query', {
                'operationName': operation,
                'variables': jsonEncode(variables),
                'extensions': jsonEncode(extensions),
              })
            : Uri.https('api-partner.spotify.com', '/pathfinder/v2/query'),
        jsonBody: artistsLibrary ? null : jsonEncode({
          'operationName': operation,
          'variables': variables,
          'extensions': extensions,
        }),
        headers: {
          'Authorization': 'Bearer ${tokens.accessToken}',
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'App-Platform': 'WebPlayer',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
          'Origin': 'https://open.spotify.com',
          'Referer': 'https://open.spotify.com/',
          if (tokens.clientToken != null) 'client-token': tokens.clientToken!,
        },
        cancellation: cancellation,
      );
      if (response.statusCode != 200)
        AppLog.instance.add('[Spotify] $operation HTTP ${response.statusCode}');
      if ((response.statusCode == 401 || response.statusCode == 403) &&
          attempt == 0) {
        await oauth.refresh();
        continue;
      }
      if (response.statusCode == 429)
        throw const SpotifyApiException(
          'Spotify is limiting requests. Try again later.',
          statusCode: 429,
        );
      if (response.statusCode != 200)
        throw SpotifyApiException(
          'Spotify returned HTTP ${response.statusCode}.',
          statusCode: response.statusCode,
        );
      final body = SpotifyHttp.decode(response);
      if (body['errors'] is List &&
          (body['errors'] as List).any(
            (e) => e is Map && '${e['message']}'.contains('PersistedQuery'),
          ) &&
          attempt == 0) {
        await oauth.refresh();
        continue;
      }
      if (body['data'] is Map<String, dynamic>)
        return body['data'] as Map<String, dynamic>;
      throw const SpotifyApiException(
        'Spotify could not load this shelf. Refresh or update your Spotify cookie.',
      );
    }
    throw const SpotifyApiException('Spotify could not refresh your session.');
  }

  /// Spotify web-player Artists library, matching desktop's libraryV3 API.
  /// Read only: Spotify's official /me/following endpoint often rejects the
  /// cookie-backed WebPlayer session. A partial response never gets imported.
  Future<List<String>> getFollowedArtists({
    void Function(int loaded)? onProgress,
    SpotifyCancellation? cancellation,
    int pageSize = 50,
    int maxArtists = 2000,
  }) async {
    final size = pageSize.clamp(1, 50).toInt();
    final limit = maxArtists.clamp(size, 2000).toInt();
    final names = <String, String>{};
    for (var offset = 0; offset < limit; offset += size) {
      cancellation?.check();
      final data = await query('libraryV3', {
        'filters': ['Artists'],
        'order': null,
        'textFilter': null,
        'features': ['LIKED_SONGS', 'YOUR_EPISODES_V2', 'PRERELEASES', 'EVENTS'],
        'limit': size, 'offset': offset, 'flatten': false,
        'folderUri': null, 'includeFoldersWhenFlattening': true,
      }, cancellation: cancellation);
      final me = data['me'];
      final library = me is Map ? me['libraryV3'] : null;
      if (library is! Map || library['items'] is! List) {
        throw const SpotifyApiException(
          'Spotify could not read followed artists. Reconnect and retry.',
        );
      }
      final items = library['items'] as List;
      for (final row in items.whereType<Map>()) {
        final wrapper = row['item'];
        final artist = wrapper is Map ? wrapper['data'] : null;
        if (artist is! Map || artist['__typename'] != 'Artist') continue;
        final profile = artist['profile'];
        final rawName = profile is Map ? profile['name'] : null;
        final name = rawName is String ? rawName.trim() : '';
        if (name.isNotEmpty && name.length <= 200) {
          names.putIfAbsent(name.toLowerCase(), () => name);
        }
      }
      onProgress?.call(names.length);
      final total = (library['totalCount'] as num?)?.toInt();
      if (total != null && total > limit) {
        throw const SpotifyApiException('Spotify artist list exceeds the 2000-artist import limit.');
      }
      if (items.isEmpty || items.length < size ||
          (total != null && offset + size >= total)) break;
      if (offset + size >= limit) {
        throw const SpotifyApiException('Spotify artist list was incomplete. Retry later.');
      }
    }
    return names.values.toList(growable: false);
  }

  @override
  Future<List<SpotifyPlaylist>> getPlaylists({
    void Function(int)? onProgress,
    SpotifyCancellation? cancellation,
  }) async {
    final data = await query('home', {
      'homeEndUserIntegration': 'INTEGRATION_WEB_PLAYER',
      'timeZone': 'UTC',
      'sp_t': '',
      'facet': '',
      'sectionItemsLimit': 20,
      'includeHomeChapterVideoCards': false,
      'includeEpisodeContentRatingsV2': false,
    }, cancellation: cancellation);
    final home = data['home'];
    if (home is! Map || home['sectionContainer'] is! Map)
      throw const SpotifyApiException('Spotify could not read your Home.');
    final mixes = <String, SpotifyPlaylist>{};
    for (final section
        in (home['sectionContainer']['sections']?['items'] as List? ?? [])
            .whereType<Map>()) {
      for (final item
          in (section['sectionItems']?['items'] as List? ?? [])
              .whereType<Map>()) {
        final playlist = item['content']?['data'];
        if (playlist is! Map || playlist['__typename'] != 'Playlist') continue;
        final uri = '${playlist['uri'] ?? item['uri'] ?? ''}';
        if (!RegExp(r'^spotify:playlist:[A-Za-z0-9]{22}$').hasMatch(uri))
          continue;
        final personal = RegExp(r'^spotify:playlist:37i9dQZ(?:EVX|F1E)')
            .hasMatch(uri);
        if (!personal && playlist['ownerV2']?['data']?['name'] != 'Spotify')
          continue;
        final images = playlist['images']?['items'];
        final sources = images is List && images.isNotEmpty
            ? images.first['sources']
            : null;
        mixes.putIfAbsent(
          uri,
          () => SpotifyPlaylist(
            id: uri.split(':').last,
            name: '${playlist['name'] ?? 'Spotify Mix'}',
            owner: personal ? 'Spotify personal mix' : 'Spotify',
            imageUrl: biggestImage(sources),
          ),
        );
      }
    }
    // Desktop preserves Home order within each group, and keeps the first
    // occurrence when Spotify repeats a card in another section.
    final result = [
      ...mixes.values.where((mix) => mix.owner == 'Spotify personal mix'),
      ...mixes.values.where((mix) => mix.owner != 'Spotify personal mix'),
    ];
    onProgress?.call(result.length);
    return result;
  }

  static String? biggestImage(Object? sources) {
    if (sources is! List) return null;
    final images = sources.whereType<Map>().toList()
      ..sort(
        (a, b) =>
            ((b['width'] as num?) ?? 0).compareTo((a['width'] as num?) ?? 0),
      );
    final url = images.firstOrNull?['url']?.toString();
    return Uri.tryParse(url ?? '')?.scheme == 'https' ? url : null;
  }

  static SpotifyTrack? track(Object? object) {
    if (object is! Map || object['__typename'] != 'Track') return null;
    final uri = '${object['uri'] ?? ''}';
    if (!RegExp(r'^spotify:track:[A-Za-z0-9]{22}$').hasMatch(uri)) return null;
    final artists = (object['artists']?['items'] as List? ?? [])
        .whereType<Map>()
        .map((a) => a['profile']?['name']?.toString())
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toList();
    final title = '${object['name'] ?? ''}';
    if (title.isEmpty || artists.isEmpty) return null;
    return SpotifyTrack(
      id: uri.split(':').last,
      title: title,
      artist: artists.join(', '),
      album: object['albumOfTrack']?['name']?.toString(),
      durationMs:
          ((object['trackDuration']?['totalMilliseconds'] ??
                      object['duration']?['totalMilliseconds'])
                  as num?)
              ?.toInt() ??
          0,
      imageUrl: biggestImage(object['albumOfTrack']?['coverArt']?['sources']),
    );
  }

  @override
  Future<List<SpotifyTrack>> getPlaylistTracks(
    String playlistId, {
    void Function(int)? onProgress,
    SpotifyCancellation? cancellation,
    int max = 200,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9]{22}$').hasMatch(playlistId))
      throw const SpotifyApiException('Invalid Spotify playlist.');
    final tracks = <SpotifyTrack>[];
    for (var offset = 0; offset < max; offset += 100) {
      final data = await query('fetchPlaylist', {
        'uri': 'spotify:playlist:$playlistId',
        'offset': offset,
        'limit': 100,
        'enableWatchFeedEntrypoint': false,
        'includeEpisodeContentRatingsV2': false,
      }, cancellation: cancellation);
      final playlist = data['playlistV2'];
      if (playlist is! Map || playlist['__typename'] != 'Playlist')
        throw const SpotifyApiException(
          'Spotify could not read that playlist.',
        );
      final items = playlist['content']?['items'] as List? ?? [];
      for (final item in items.whereType<Map>()) {
        final row = track(item['itemV2']?['data']);
        if (row != null) tracks.add(row);
      }
      onProgress?.call(tracks.length);
      if (items.length < 100 || tracks.length >= max) break;
    }
    return tracks.take(max).toList();
  }

  /// Desktop policy: null cursor reads one row to establish a baseline only.
  Future<SpotifyLikesBatch> likedSince(
    int? since, {
    SpotifyCancellation? cancellation,
  }) async {
    final fresh = <SpotifyLikedTrack>[];
    var newest = since ?? 0;
    final limit = since == null ? 1 : 50;
    for (var page = 0; page < 50; page++) {
      final data = await query('fetchLibraryTracks', {
        'offset': page * limit,
        'limit': limit,
      }, cancellation: cancellation);
      final library = data['me']?['library']?['tracks'];
      if (library is! Map)
        throw const SpotifyApiException(
          'Spotify could not read your Liked Songs.',
        );
      final items = library['items'] as List? ?? [];
      var older = false;
      for (final item in items.whereType<Map>()) {
        final at =
            DateTime.tryParse('${item['addedAt']?['isoString'] ?? ''}')
                ?.millisecondsSinceEpoch ??
            0;
        if (at > newest) newest = at;
        if (since == null) continue;
        if (at <= since) {
          older = true;
          break;
        }
        final wrapper = item['track'];
        final raw = wrapper is Map ? wrapper['data'] : null;
        final parsed = track(
          raw is Map ? {...raw, 'uri': wrapper['_uri'] ?? raw['uri']} : raw,
        );
        if (parsed != null) fresh.add(SpotifyLikedTrack(parsed, at));
      }
      if (since == null || older || items.length < limit) break;
    }
    return SpotifyLikesBatch(fresh, newest);
  }

  @override
  Future<List<SpotifyTrack>> getLikedSongs({
    void Function(int)? onProgress,
    SpotifyCancellation? cancellation,
    int max = 10000,
  }) async {
    final tracks = <SpotifyTrack>[];
    for (var offset = 0; offset < max; offset += 100) {
      final data = await query('fetchLibraryTracks', {
        'offset': offset,
        'limit': 100,
      }, cancellation: cancellation);
      final library = data['me']?['library']?['tracks'];
      if (library is! Map)
        throw const SpotifyApiException(
          'Spotify could not read your Liked Songs.',
        );
      final items = library['items'] as List? ?? [];
      var older = false;
      for (final item in items.whereType<Map>()) {
        final added = DateTime.tryParse(
          '${item['addedAt']?['isoString'] ?? ''}',
        );
        if (likesSince != null &&
            added != null &&
            !added.isAfter(likesSince!)) {
          older = true;
          break;
        }
        final wrapper = item['track'];
        final raw = wrapper is Map ? wrapper['data'] ?? wrapper : null;
        final row = raw is Map
            ? {
                ...raw,
                'uri': (wrapper is Map ? wrapper['_uri'] : null) ?? raw['uri'],
              }
            : raw;
        final parsed = track(row);
        if (parsed != null) tracks.add(parsed);
      }
      onProgress?.call(tracks.length);
      if (older || items.length < 100 || tracks.length >= max) break;
    }
    return tracks.take(max).toList();
  }
}

class SpotifyLikedTrack {
  const SpotifyLikedTrack(this.track, this.addedAt);
  final SpotifyTrack track;
  final int addedAt;
}

class SpotifyLikesBatch {
  const SpotifyLikesBatch(this.items, this.newest);
  final List<SpotifyLikedTrack> items;
  final int newest;
}
