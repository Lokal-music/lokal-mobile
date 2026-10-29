import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../discovery/lastfm_discovery.dart';
import '../discovery/spotify_discovery.dart';

/// A bounded, metadata-only cache. Never store provider credentials, signed
/// media URLs, artwork bytes, or decoded images in these snapshots.
class DiscoveryCached<T> {
  const DiscoveryCached(this.data, this.savedAt);
  final T data;
  final DateTime savedAt;

  bool isFresh(Duration ttl, {DateTime? now}) {
    final age = (now ?? DateTime.now().toUtc()).difference(savedAt);
    return !age.isNegative && age <= ttl;
  }
}

class DiscoverySnapshotCache {
  const DiscoverySnapshotCache({this.directory});

  /// An app-support directory survives an Android force-stop or process death.
  final Directory? directory;
  static const maxBytes = 20 * 1024 * 1024;
  static const maxEntryBytes = 4 * 1024 * 1024;
  static const youtubeTtl = Duration(hours: 6);
  static const lastfmTtl = Duration(hours: 24);
  static const spotifyTtl = Duration(hours: 24);

  Future<Directory> _root() async => directory ??
      Directory(p.join((await getApplicationSupportDirectory()).path,
          'discovery_snapshots_v1'));

  Future<File> _file(String source, String account) async {
    // Stable, opaque filenames: no usernames or account cookies in paths.
    final key = sha256.convert(utf8.encode(source + '\u0000' + account));
    return File(p.join((await _root()).path, '$key.json'));
  }

  Future<DiscoveryCached<LokalDiscovery>?> readLokal(
      String source, String account) async {
    final entry = await _read(source, account);
    if (entry == null) return null;
    try {
      final data = _lokalFromJson(entry.$1);
      return data.isEmpty ? null : DiscoveryCached(data, entry.$2);
    } catch (_) {
      return null;
    }
  }

  Future<DiscoveryCached<SpotifyDiscoveryData>?> readSpotify(
      String account) async {
    final entry = await _read('spotify', account);
    if (entry == null) return null;
    try {
      final data = _spotifyFromJson(entry.$1);
      return data.isEmpty ? null : DiscoveryCached(data, entry.$2);
    } catch (_) {
      return null;
    }
  }

  Future<(Map<String, dynamic>, DateTime)?> _read(
      String source, String account) async {
    try {
      final file = await _file(source, account);
      if (!await file.exists() || await file.length() > maxEntryBytes) {
        return null;
      }
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic> ||
          json['version'] != 1 ||
          json['source'] != source ||
          json['data'] is! Map<String, dynamic> ||
          json['savedAt'] is! String) return null;
      final date = DateTime.tryParse(json['savedAt'] as String)?.toUtc();
      if (date == null || date.isAfter(DateTime.now().toUtc())) return null;
      return (json['data'] as Map<String, dynamic>, date);
    } catch (_) {
      // Disk failures and older/corrupt schemas must never block Discovery.
      return null;
    }
  }

  Future<void> writeLokal(
      String source, String account, LokalDiscovery data) async {
    if (data.isEmpty) return;
    await _write(source, account, _lokalToJson(data));
  }

  Future<void> writeSpotify(String account, SpotifyDiscoveryData data) async {
    if (data.isEmpty) return;
    await _write('spotify', account, _spotifyToJson(data));
  }

  Future<void> _write(
      String source, String account, Map<String, dynamic> data) async {
    try {
      final json = utf8.encode(jsonEncode({
        'version': 1,
        'source': source,
        'savedAt': DateTime.now().toUtc().toIso8601String(),
        'data': data,
      }));
      if (json.length > maxEntryBytes) return;
      final file = await _file(source, account);
      await file.parent.create(recursive: true);
      final temporary = File(file.path + '.tmp');
      await temporary.writeAsBytes(json, flush: true);
      await temporary.rename(file.path);
      await _prune(file.parent);
    } catch (_) {
      // Cache writes are best effort. Do not mask successful network loads.
    }
  }

  Future<void> _prune(Directory root) async {
    final files = <({File file, int size, DateTime changed})>[];
    var total = 0;
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final stat = await entity.stat();
        total += stat.size;
        files.add((file: entity, size: stat.size, changed: stat.modified));
      } catch (_) {}
    }
    files.sort((a, b) => a.changed.compareTo(b.changed));
    for (final file in files) {
      if (total <= maxBytes) break;
      try {
        await file.file.delete();
        total -= file.size;
      } catch (_) {}
    }
  }

  Future<void> invalidate(String source, String account) async {
    try {
      final file = await _file(source, account);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

Map<String, dynamic> _track(LokalDiscoveryTrack t) => {
  'title': t.title, 'artist': t.artist, 'album': t.album,
  'artworkUrl': t.artworkUrl, 'url': t.url, 'playcount': t.playcount,
  'scrobbledAt': t.scrobbledAt, 'reason': t.reason,
  'scrobbleCount': t.scrobbleCount, 'seedArtist': t.seedArtist,
  'videoId': t.videoId, 'durationMs': t.duration?.inMilliseconds,
};

LokalDiscoveryTrack _readTrack(Map<String, dynamic> v) => LokalDiscoveryTrack(
  title: _string(v['title']), artist: _string(v['artist']),
  album: _string(v['album']), artworkUrl: _string(v['artworkUrl']),
  url: _string(v['url']), playcount: _integer(v['playcount']) ?? 0,
  scrobbledAt: _integer(v['scrobbledAt']), reason: v['reason'] as String?,
  scrobbleCount: _integer(v['scrobbleCount']),
  seedArtist: v['seedArtist'] as String?, videoId: v['videoId'] as String?,
  duration: _integer(v['durationMs']) == null ? null :
      Duration(milliseconds: _integer(v['durationMs'])!),
);

Map<String, dynamic> _artist(LokalDiscoveryArtist a) => {
  'name': a.name, 'image': a.image, 'playcount': a.playcount, 'url': a.url,
};
LokalDiscoveryArtist _readArtist(Map<String, dynamic> v) =>
    LokalDiscoveryArtist(name: _string(v['name']),
      image: _string(v['image']), playcount: _integer(v['playcount']) ?? 0,
      url: _string(v['url']));

Map<String, dynamic> _album(LokalDiscoveryAlbum a) => {
  'title': a.title, 'artist': a.artist, 'artworkUrl': a.artworkUrl,
  'playcount': a.playcount, 'url': a.url,
};
LokalDiscoveryAlbum _readAlbum(Map<String, dynamic> v) =>
    LokalDiscoveryAlbum(title: _string(v['title']),
      artist: _string(v['artist']), artworkUrl: _string(v['artworkUrl']),
      playcount: _integer(v['playcount']) ?? 0, url: _string(v['url']));

Map<String, dynamic> _mix(LokalDiscoveryMix m) => {
  'id': m.id, 'title': m.title, 'author': m.author, 'artworkUrl': m.artworkUrl,
};
LokalDiscoveryMix _readMix(Map<String, dynamic> v) => LokalDiscoveryMix(
  id: _string(v['id']), title: _string(v['title']),
  author: _string(v['author']), artworkUrl: _string(v['artworkUrl']),
);

Map<String, dynamic> _category(LokalDiscoveryCategory c) => {
  'id': c.id, 'tracks': c.tracks.map(_track).toList(),
  'mixes': c.mixes.map(_mix).toList(),
  'albums': c.albums.map(_album).toList(),
};
LokalDiscoveryCategory _readCategory(Map<String, dynamic> v) =>
    LokalDiscoveryCategory(id: _string(v['id']),
      tracks: _readList(v['tracks'], _readTrack) ?? const [],
      mixes: _readList(v['mixes'], _readMix) ?? const [],
      albums: _readList(v['albums'], _readAlbum) ?? const []);

String _string(Object? value) => value is String ? value : '';
int? _integer(Object? value) => value is int ? value : null;
List<T>? _readList<T>(
    Object? raw, T Function(Map<String, dynamic>) decoder) {
  if (raw == null) return null;
  if (raw is! List || raw.length > 5000) throw const FormatException();
  return [
    for (final value in raw)
      if (value is Map<String, dynamic>) decoder(value)
      else throw const FormatException(),
  ];
}

Map<String, dynamic> _lokalToJson(LokalDiscovery v) => {
  'account': v.account, 'page': v.page,
  'mixes': v.mixes?.map(_mix).toList(), 'mixError': v.mixError,
  'categories': v.categories?.map(_category).toList(),
  'liked': v.liked?.map(_track).toList(),
  'quickPicks': v.quickPicks?.map(_track).toList(),
  'history': v.history?.map(_track).toList(),
  'artists': v.artists?.map(_artist).toList(),
  'albums': v.albums?.map(_album).toList(),
  'freshFinds': v.freshFinds?.map(_track).toList(),
  'candidates': v.candidates.map(_track).toList(),
};

LokalDiscovery _lokalFromJson(Map<String, dynamic> v) => LokalDiscovery(
  account: _string(v['account']), page: _integer(v['page']) ?? 0,
  mixes: _readList(v['mixes'], _readMix), mixError: v['mixError'] as String?,
  categories: _readList(v['categories'], _readCategory),
  liked: _readList(v['liked'], _readTrack),
  quickPicks: _readList(v['quickPicks'], _readTrack),
  history: _readList(v['history'], _readTrack),
  artists: _readList(v['artists'], _readArtist),
  albums: _readList(v['albums'], _readAlbum),
  freshFinds: _readList(v['freshFinds'], _readTrack),
  candidates: _readList(v['candidates'], _readTrack) ?? const [],
);

Map<String, dynamic> _spotifyToJson(SpotifyDiscoveryData v) => {
  'account': v.account,
  'quickPicks': v.quickPicks.map(_track).toList(),
  'recentlyPlayed': v.recentlyPlayed.map(_track).toList(),
  'likedSongs': v.likedSongs.map(_track).toList(),
  'artists': v.artists.map(_artist).toList(),
  'albums': v.albums.map(_album).toList(),
  'freshFinds': v.freshFinds.map(_track).toList(),
  'mixes': v.mixes.map(_mix).toList(),
};

SpotifyDiscoveryData _spotifyFromJson(Map<String, dynamic> v) =>
    SpotifyDiscoveryData(
      account: _string(v['account']),
      quickPicks: _readList(v['quickPicks'], _readTrack) ?? const [],
      recentlyPlayed: _readList(v['recentlyPlayed'], _readTrack) ?? const [],
      likedSongs: _readList(v['likedSongs'], _readTrack) ?? const [],
      artists: _readList(v['artists'], _readArtist) ?? const [],
      albums: _readList(v['albums'], _readAlbum) ?? const [],
      freshFinds: _readList(v['freshFinds'], _readTrack) ?? const [],
      mixes: _readList(v['mixes'], _readMix) ?? const [],
    );
