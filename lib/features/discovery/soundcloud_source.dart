// Native SoundCloud catalogue/stream source. Public web API keys are discovered
// from SoundCloud's own web player and never persisted to disk.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'discovery_http.dart';
import 'discovery_models.dart';
import 'discovery_sources.dart' show ResolvedDiscoveryAudio;

class SoundCloudSource {
  SoundCloudSource(this.http, {this.clientId, bool? supportsOggHls})
    : supportsOggHls = supportsOggHls ?? !Platform.isIOS;
  final DiscoveryHttp http;
  // iPhone AVPlayer HLS must use AAC/MP3; the standalone Rust Ogg fallback
  // does not establish support for an Ogg/Opus HLS playlist.
  final bool supportsOggHls;
  final Future<String> Function()? clientId;
  static const apiHost = 'api-v2.soundcloud.com';
  static final _idPattern = RegExp(r'^\d{1,20}$');
  static String? _keyCache;

  static String? clientIdIn(String content) {
    for (final expression in [
      RegExp(r'client_id\s*:\s*"([A-Za-z0-9]{32})"'),
      RegExp(r'"client_id"\s*:\s*"([A-Za-z0-9]{32})"'),
      RegExp(r'clientId\s*:\s*"([A-Za-z0-9]{32})"'),
      // SoundCloud sometimes exposes the same public key through
      // window.__sc_hydration's apiClient.data.id instead of client_id.
      RegExp(r'apiClient.{0,800}?"id"\s*:\s*"([A-Za-z0-9]{32})"', dotAll: true),
    ]) {
      final found = expression.firstMatch(content)?.group(1);
      if (found != null) return found;
    }
    return null;
  }

  Future<String> _getText(
    Uri uri, {
    int limit = 1024 * 1024,
    Map<String, String> headers = const {},
  }) async {
    final data = BytesBuilder(copy: false);
    await http.transfer(
      uri,
      headers: headers,
      maxBytes: limit,
      deadline: http.timeout,
      isMetadata: true,
      allowPartial: true,
      onChunk: data.add,
    );
    return utf8.decode(data.takeBytes());
  }

  Future<String> _key({bool fresh = false}) async {
    if (clientId != null) return clientId!();
    if (!fresh && _keyCache != null) return _keyCache!;
    final html = await _getText(Uri.https('soundcloud.com', '/'));
    final inline = clientIdIn(html);
    if (inline != null) {
      _keyCache = inline;
      return inline;
    }
    final assets = RegExp(
      r'https://a-v2\.sndcdn\.com/assets/[A-Za-z0-9_.-]+\.js',
    ).allMatches(html).map((match) => match.group(0)!).toSet().toList();
    for (final asset in assets.reversed.take(15)) {
      try {
        final script = await _getText(
          Uri.parse(asset),
          headers: const {'Range': 'bytes=0-65535'},
        );
        final found = clientIdIn(script);
        if (found != null) {
          _keyCache = found;
          return found;
        }
      } on DiscoveryException {
        // Not every bundle contains the public frontend key.
      }
    }
    throw const DiscoveryException(
      'SoundCloud public search is currently unavailable.',
    );
  }

  Future<Map<String, dynamic>> _api(
    String path,
    Map<String, String> args,
  ) async {
    for (var n = 0; n < 2; n++) {
      final key = await _key(fresh: n == 1);
      try {
        return await http.json(
          Uri.https(apiHost, path, {...args, 'client_id': key}),
        );
      } on DiscoveryException catch (error) {
        if (n == 1 || !RegExp(r'HTTP (401|403)').hasMatch(error.message))
          rethrow;
        _keyCache = null;
      }
    }
    throw const DiscoveryException('SoundCloud refused the public catalogue.');
  }

  Future<List<DiscoveryTrack>> search(String query, {int limit = 20}) async {
    final text = query.trim();
    if (text.length < 2) return const [];
    if (text.length > 200)
      throw const DiscoveryException('Search is limited to 200 characters.');
    final maximum = limit.clamp(1, 50).toInt();
    final json = await _api('/search/tracks', {'q': text, 'limit': '$maximum'});
    final rows = json['collection'];
    if (rows is! List)
      throw const DiscoveryException('Unexpected SoundCloud search response.');
    final tracks = <DiscoveryTrack>[];
    final seen = <String>{};
    for (final item in rows.take(maximum)) {
      if (item is! Map) continue;
      final id = item['id']?.toString() ?? '';
      final title = discoveryText(item['title']);
      if (!_idPattern.hasMatch(id) ||
          title == null ||
          item['access'] == 'blocked' ||
          !seen.add(id))
        continue;
      final publisher = item['publisher_metadata'];
      final uploader = item['user'];
      final artist =
          (publisher is Map ? discoveryText(publisher['artist']) : null) ??
          (uploader is Map ? discoveryText(uploader['username']) : null) ??
          'Artist not supplied';
      final rawCover = discoveryText(item['artwork_url'], maxLength: 2000);
      final cover = rawCover == null ? null : Uri.tryParse(rawCover);
      final durationMs = item['duration'];
      final preview = item['access'] == 'preview';
      tracks.add(
        DiscoveryTrack(
          id: id,
          title: title,
          artist: artist,
          album: publisher is Map
              ? discoveryText(publisher['album_title'])
              : null,
          duration: durationMs is num
              ? discoveryDuration(durationMs / 1000)
              : null,
          artwork:
              cover?.scheme == 'https' &&
                  cover?.host.isNotEmpty == true &&
                  cover?.userInfo.isEmpty == true
              ? rawCover
              : null,
          source: DiscoverySource.soundCloud,
          sourceName: preview ? 'SoundCloud (preview)' : 'SoundCloud',
          sourceUrl: Uri.https('api.soundcloud.com', '/tracks/' + id),
          inlineStream: {'preview': preview},
        ),
      );
    }
    return tracks;
  }

  /// Resolves the chosen track's currently playable transcoding. A signed
  /// CDN URL is returned only to Media3 and never written to saved queues.
  Future<ResolvedDiscoveryAudio> resolve(
    DiscoveryTrack track, {
    bool forDownload = false,
  }) async {
    if (track.source != DiscoverySource.soundCloud ||
        !_idPattern.hasMatch(track.id)) {
      throw const DiscoveryException('Invalid SoundCloud track identity.');
    }
    final record = await _api('/tracks/' + track.id, const {});
    if (record['id']?.toString() != track.id || record['access'] == 'blocked') {
      throw const DiscoveryException(
        'This SoundCloud recording is unavailable.',
      );
    }
    final preview =
        record['access'] == 'preview' || track.inlineStream?['preview'] == true;
    if (preview && forDownload)
      throw const DiscoveryException(
        'This track is available as a SoundCloud preview only.',
      );
    final media = record['media'];
    final encodings = media is Map ? media['transcodings'] : null;
    if (encodings is! List)
      throw const DiscoveryException('No SoundCloud audio streams.');
    final available = encodings.whereType<Map>().toList()
      ..sort((a, b) => _rank(a).compareTo(_rank(b)));
    for (final candidate in available) {
      final format = candidate['format'];
      final protocol = format is Map ? format['protocol']?.toString() : null;
      if (protocol != 'progressive' && protocol != 'hls') continue;
      // A playlist is not an audio file: never cache it as an MP3 download.
      if (forDownload && protocol != 'progressive') continue;
      if (!preview &&
          (candidate['snipped'] == true ||
              (candidate['preset']?.toString().contains('preview') ?? false)))
        continue;
      final mime = format is Map
          ? (format['mime_type']?.toString() ?? '').toLowerCase()
          : '';
      // Show the *chosen stream* codec, not a guessed bitrate or the
      // uploader's original lossless format.
      final codec = mime.contains('mpeg') || mime.contains('mp3')
          ? 'MP3'
          : mime.contains('mp4a') ||
                mime.contains('aac') ||
                mime.contains('mp4')
          ? 'AAC'
          : mime.contains('opus')
          ? 'OPUS'
          : mime.contains('vorbis')
          ? 'VORBIS'
          : null;
      if (codec == null) continue;
      if (protocol == 'hls' &&
          !supportsOggHls &&
          (codec == 'OPUS' || codec == 'VORBIS'))
        continue;
      final endpoint = Uri.tryParse(candidate['url']?.toString() ?? '');
      if (endpoint == null ||
          endpoint.scheme != 'https' ||
          endpoint.userInfo.isNotEmpty ||
          !const {
            'api.soundcloud.com',
            'api-v2.soundcloud.com',
          }.contains(endpoint.host))
        continue;
      final resolved = await http.json(
        endpoint.replace(
          queryParameters: {
            ...endpoint.queryParameters,
            'client_id': await _key(),
          },
        ),
      );
      final mediaUrl = Uri.tryParse(resolved['url']?.toString() ?? '');
      if (mediaUrl == null ||
          mediaUrl.scheme != 'https' ||
          mediaUrl.userInfo.isNotEmpty ||
          mediaUrl.hasFragment ||
          mediaUrl.host.isEmpty ||
          !(mediaUrl.host == 'sndcdn.com' ||
              mediaUrl.host.endsWith('.sndcdn.com') ||
              mediaUrl.host == 'soundcloud.com' ||
              mediaUrl.host.endsWith('.soundcloud.com')))
        continue;
      return ResolvedDiscoveryAudio(
        mediaUrl,
        codec: codec,
        quality: codec,
        isPreview: preview,
      );
    }
    throw DiscoveryException(
      forDownload
          ? 'SoundCloud offers no downloadable progressive audio for this recording.'
          : 'No public playable SoundCloud stream was returned.',
    );
  }

  static int _rank(Map entry) {
    final format = entry['format'];
    final protocol = format is Map ? format['protocol'] : null;
    if (protocol == 'progressive') return 0;
    if (protocol == 'hls') return 1;
    return 2;
  }
}
