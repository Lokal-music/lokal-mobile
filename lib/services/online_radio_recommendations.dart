import 'dart:convert';

import 'package:http/http.dart' as http;

import '../features/discovery/lastfm_discovery.dart';
import '../features/discovery/youtube_music_account.dart';
import '../features/discovery/youtube_music_store.dart';
import '../features/konnekted/konnekted_discovery.dart' show discoveryPendingSong;
import '../models/song.dart';
import 'lastfm/lastfm_api_client.dart';

/// Online radio returns catalogue metadata; the normal QueuePreResolver
/// resolves actual audio as the tracks approach playback, never in bulk.
class OnlineRadioRecommendations {
  const OnlineRadioRecommendations();

  static const _clientVersion = '1.20250901.03.00';
  static const _maxBatch = 20;
  static String? _liveVersion;
  static DateTime? _versionReadAt;

  /// YouTube retires old WEB_REMIX client versions. Use the live published
  /// version for anonymous requests, caching it to avoid a homepage lookup on
  /// every track change.
  Future<String> _guestVersion(http.Client client) async {
    final at = _versionReadAt;
    if (at != null && DateTime.now().difference(at) < const Duration(hours: 1)) {
      return _liveVersion ?? _clientVersion;
    }
    _versionReadAt = DateTime.now();
    try {
      final response = await client.get(
        Uri.parse('https://music.youtube.com/'),
        headers: const {'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/142.0.0.0 Safari/537.36'},
      ).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        _liveVersion = RegExp(r'"INNERTUBE_CLIENT_VERSION"\s*:\s*"([^"]+)"')
            .firstMatch(response.body)?.group(1) ?? _liveVersion;
      }
    } catch (_) {
      // A stale-but-known fallback is preferable to no radio at all.
    }
    return _liveVersion ?? _clientVersion;
  }

  static final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');

  Future<List<Song>> recommend(
    Song seed, {
    int count = 10,
    Iterable<Song> existing = const [],
  }) async {
    if (count <= 0 || seed.artist.trim().isEmpty || seed.title.trim().isEmpty) {
      return const [];
    }
    final transport = http.Client();
    try {
      YoutubeMusicSession? session;
      try {
        session = await YoutubeMusicSessionStore().read();
      } catch (_) {
        // Anonymous YouTube Music still works without secure storage.
      }
      final youtube = <LokalDiscoveryTrack>[];
      try {
        final videoId = _seedId(seed) ??
            await _searchSeed(transport, session, seed);
        if (videoId != null) {
          if (session != null && session.signedIn) {
            youtube.addAll(await YoutubeMusicAccount(transport, session)
                .playlist('RDAMVM$videoId')
                .timeout(const Duration(seconds: 9)));
          } else {
            final root = await _guestRequest(transport, 'next', {
              'playlistId': 'RDAMVM$videoId',
              'isAudioOnly': true,
              'enablePersistentPlaylistPanel': true,
              'tunerSettingValue': 'AUTOMIX_SETTING_NORMAL',
            });
            youtube.addAll(parseYoutubeMusicTracks(root, limit: 75));
          }
        }
      } catch (_) {
        // Radio can fail transiently. Next try Last.fm then the local fallback.
      }

      var related = <LokalDiscoveryTrack>[];
      if (youtube.length < count) {
        try {
          final response = await LastFmApiClient().get({
            'method': 'track.getSimilar',
            'artist': seed.artist,
            'track': seed.title,
            'autocorrect': '1',
            'limit': '50',
          }).timeout(const Duration(seconds: 6));
          final tracks = (response['similartracks'] as Map?)?['track'];
          if (tracks is List) {
            related = [
              for (final entry in tracks)
                if (entry is Map)
                  LokalDiscoveryTrack(
                    title: (entry['name'] ?? '').toString(),
                    artist: _lastFmArtist(entry['artist']),
                  ),
            ];
          }
        } catch (_) {
          // Last.fm is optional.
        }
      }
      final candidates = pickOnlineRadio(
        seed: seed,
        existing: existing,
        candidates: [...youtube, ...related],
        count: count.clamp(0, _maxBatch),
      );
      return [for (final item in candidates) discoveryPendingSong(item)];
    } finally {
      transport.close();
    }
  }

  String? _seedId(Song seed) {
    for (final raw in [seed.remoteId, seed.id]) {
      if (raw == null) continue;
      final suffix = raw.split(':').last;
      if (_videoId.hasMatch(suffix)) return suffix;
    }
    return null;
  }

  Future<String?> _searchSeed(
    http.Client client,
    YoutubeMusicSession? session,
    Song seed,
  ) async {
    final query = seed.artist + ' ' + seed.title;
    final Object? root = session != null && session.signedIn
        ? await YoutubeMusicAccount(client, session)
            .request('search', {'query': query})
            .timeout(const Duration(seconds: 7))
        : await _guestRequest(client, 'search', {'query': query});
    final candidates = parseYoutubeMusicTracks(root, limit: 20);
    final target = radioRecordingKey(seed.artist, seed.title);
    for (final track in candidates) {
      if (radioRecordingKey(track.artist, track.title) == target &&
          track.videoId != null) return track.videoId;
    }
    return null; // Never seed an unrelated artist via a fuzzy text match.
  }

  Future<Map<String, dynamic>> _guestRequest(
    http.Client client,
    String endpoint,
    Map<String, Object?> body,
  ) async {
    final version = await _guestVersion(client);
    final response = await client.post(
      Uri.https('music.youtube.com', '/youtubei/v1/$endpoint', {
        'prettyPrint': 'false',
      }),
      headers: {
        'Content-Type': 'application/json',
        'Origin': 'https://music.youtube.com',
        'Referer': 'https://music.youtube.com/',
        'X-YouTube-Client-Name': '67',
        'X-YouTube-Client-Version': version,
      },
      body: jsonEncode({
        'context': {
          'client': {
            'clientName': 'WEB_REMIX',
            'clientVersion': version,
            'hl': 'en',
            'gl': 'US',
          },
        },
        ...body,
      }),
    ).timeout(const Duration(seconds: 7));
    if (response.statusCode != 200) {
      throw StateError('YouTube Music radio HTTP ' + response.statusCode.toString());
    }
    final root = jsonDecode(response.body);
    if (root is! Map<String, dynamic>) {
      throw const FormatException('Invalid YouTube Music radio response');
    }
    return root;
  }
}

String _lastFmArtist(Object? value) {
  if (value is String) return value;
  if (value is Map) return (value['name'] ?? '').toString();
  return '';
}

String _radioNormalize(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'\((?:official|audio|video|lyrics|lyric)[^)]*\)', caseSensitive: false), ' ')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

/// The same recording has different local/YouTube IDs. Preserve live and
/// remix variants but collapse official-video and catalogue-audio duplicates.
String radioRecordingKey(String artist, String title) {
  final lead = artist.split(RegExp(r',|&| feat\.? | ft\.? ', caseSensitive: false)).first;
  return _radioNormalize(lead) + '\u001f' + _radioNormalize(title);
}

/// Bounded, de-duplicated online suggestions with per-artist diversity caps.
List<LokalDiscoveryTrack> pickOnlineRadio({
  required Song seed,
  required Iterable<Song> existing,
  required Iterable<LokalDiscoveryTrack> candidates,
  int count = 10,
}) {
  if (count <= 0) return const [];
  final seen = <String>{
    radioRecordingKey(seed.artist, seed.title),
    for (final song in existing) radioRecordingKey(song.artist, song.title),
  };
  final perArtist = <String, int>{};
  final result = <LokalDiscoveryTrack>[];
  final seedArtist = _radioNormalize(seed.artist.split(',').first);
  for (final track in candidates) {
    if (result.length >= count) break;
    if (track.title.trim().isEmpty || track.artist.trim().isEmpty ||
        track.artist == 'Unknown Artist') continue;
    final recording = radioRecordingKey(track.artist, track.title);
    if (!seen.add(recording)) continue;
    final artist = _radioNormalize(track.artist.split(',').first);
    final cap = artist == seedArtist ? 4 : 2;
    if ((perArtist[artist] ?? 0) >= cap) continue;
    perArtist[artist] = (perArtist[artist] ?? 0) + 1;
    result.add(track);
  }
  return List.unmodifiable(result);
}
