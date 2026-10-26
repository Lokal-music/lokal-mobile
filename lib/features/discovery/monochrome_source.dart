// First-party Monochrome catalogue integration, based on the public Tracks API.
// Protocol reference: monochrome-music/monochrome (Apache-2.0).
// No credentials, dynamic hosts, or third-party add-on manifests are involved.
import 'discovery_http.dart';
import 'discovery_models.dart';
import 'discovery_sources.dart';

abstract final class MonochromeSource {
  static const host = 'tracks.monochrome.st';
  static final RegExp _trackId = RegExp(r'^\d{15,20}$');

  static Future<List<DiscoveryTrack>> search(
    DiscoveryHttp http,
    String query, {
    int limit = 20,
  }) async {
    final text = query.trim();
    if (text.isEmpty) return const [];
    if (text.length > 200) {
      throw const DiscoveryException('Search is limited to 200 characters.');
    }
    final safeLimit = limit.clamp(1, 50).toInt();
    final endpoint = Uri.https(host, '/search/tracks', {
      'q': text,
      'limit': '$safeLimit',
    });
    Map<String, dynamic> json;
    try {
      json = await http.json(endpoint);
    } on DiscoveryException catch (error) {
      // The public API intermittently responds with Cloudflare 5xx.
      // Avoid retrying auth failures, invalid JSON or missing tracks.
      if (!RegExp(r'HTTP 5\\d\\d|rate limiting requests').hasMatch(error.message)) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
      json = await http.json(endpoint);
    }
    final rows = json['tracks'];
    if (rows is! List) {
      throw const DiscoveryException('Monochrome returned an unsupported catalogue response.');
    }
    final tracks = <DiscoveryTrack>[];
    final seen = <String>{};
    for (final entry in rows.take(safeLimit)) {
      if (entry is! Map) continue;
      final id = (entry['trackId'] ?? entry['id'])?.toString() ?? '';
      final title = discoveryText(entry['title']);
      if (!_trackId.hasMatch(id) || title == null || !seen.add(id) ||
          entry['playable'] == false) continue;

      final names = entry['artistNames'];
      final artists = names is List
          ? names.whereType<String>().map((s) => s.trim()).where((s) => s.isNotEmpty).take(8).join(', ')
          : '';
      final rawDuration = entry['duration'];
      final seconds = rawDuration is num && rawDuration.isFinite
          ? (rawDuration > 1000 ? rawDuration / 1000 : rawDuration)
          : null;
      final rawCover = discoveryText(entry['artwork'] ?? entry['cover'], maxLength: 2000);
      final coverUri = rawCover == null ? null : Uri.tryParse(rawCover);
      final artwork = coverUri?.scheme == 'https' &&
              coverUri?.host.isNotEmpty == true &&
              coverUri?.userInfo.isEmpty == true
          ? rawCover
          : null;
      tracks.add(DiscoveryTrack(
        id: id,
        title: title,
        artist: artists.isEmpty ? 'Artist not supplied' : artists,
        album: discoveryText(entry['albumTitle'] ?? entry['releaseTitle']),
        duration: seconds == null ? null : discoveryDuration(seconds),
        source: DiscoverySource.monochrome,
        sourceName: 'Monochrome',
        sourceUrl: streamUri(id),
        artwork: artwork,
        // The catalogue does not supply a verified bit depth or sample rate.
        // The actual decoder is authoritative; never invent Hi-Res values.
        catalogueQuality: 'LOSSLESS',
        catalogueCodec: 'FLAC',
      ));
    }
    return tracks;
  }

  static Uri streamUri(String trackId) {
    if (!_trackId.hasMatch(trackId)) {
      throw const DiscoveryException('Invalid Monochrome track ID.');
    }
    return Uri.https(host, '/track/$trackId');
  }

  static ResolvedDiscoveryAudio resolve(DiscoveryTrack track) {
    if (track.source != DiscoverySource.monochrome) {
      throw const DiscoveryException('This recording is not from Monochrome.');
    }
    return ResolvedDiscoveryAudio(
      streamUri(track.id),
      codec: 'FLAC',
      quality: 'LOSSLESS',
      // The upstream endpoint promises FLAC, but not a particular bit depth,
      // sample rate, bitrate or length. The player will probe the actual file.
    );
  }
}
