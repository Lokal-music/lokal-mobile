import 'dart:async';

import '../morneye/morneye_service.dart';
import 'playlist_link_http.dart';
import 'playlist_link_importers.dart';
import 'playlist_link_models.dart';

/// Uses the same enabled link-handler add-ons as desktop playlist sync.
/// Kept injectable so fixtures can exercise payloads without a native runtime.
typedef PlaylistAddonReader = Future<Object?> Function(ParsedPlaylistLink link);

Future<Object?> readPlaylistAddon(ParsedPlaylistLink link) async {
  final packages = await MorneyeService.instance.packages;
  final host = Uri.parse(link.canonicalUrl).host.toLowerCase();
  for (final addon in packages.addons) {
    if (!addon.enabled) continue;
    final handler = addon.manifest['urlHandler'];
    if (handler is! Map || handler['enabled'] != true) continue;
    final patterns = handler['patterns'];
    if (patterns is! List ||
        !patterns.any((pattern) {
          final domain = '$pattern'.toLowerCase();
          return !domain.contains(':') &&
              (host == domain || host.endsWith('.$domain'));
        })) {
      continue;
    }
    final runtime = await packages.runtime(addon.key);
    return runtime.invoke('handleUrl', [link.canonicalUrl]);
  }
  throw PlaylistLinkHttpException(
    'To sync ${link.source.label} playlists, install and enable the matching '
    '${link.source.label} add-on in Settings → Add-ons.',
  );
}

class AddonPlaylistImporter implements PlaylistLinkImporter {
  final PlaylistAddonReader reader;
  const AddonPlaylistImporter({this.reader = readPlaylistAddon});

  Future<Object?> _read(ParsedPlaylistLink link) async {
    try {
      return await reader(link).timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw const PlaylistLinkHttpException(
        'The playlist add-on timed out. Try again.',
      );
    }
  }

  @override
  Future<RemotePlaylistSnapshot> fetch(
    ParsedPlaylistLink link, {
    PlaylistLinkCancellationToken? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final pending = _read(link);
    final result = cancellation == null
        ? await pending
        : await Future.any([
            pending,
            cancellation.future.then<Object?>(
              (_) => throw const PlaylistLinkCancelledException(),
            ),
          ]);
    cancellation?.throwIfCancelled();
    if (result is! Map) {
      throw const PlaylistLinkHttpException(
        'The add-on returned no playlist metadata.',
      );
    }
    if (result['success'] == false || result['error'] != null) {
      final error =
          '${result['error'] ?? 'The add-on could not read this playlist.'}';
      throw PlaylistLinkHttpException(
        error.contains('VERIFY_REQUIRED')
            ? 'Verify ${link.source.label} access in Settings → Add-ons, then retry.'
            : error,
      );
    }
    final playlist = result['playlist'] is Map
        ? result['playlist'] as Map
        : result;
    final raw = playlist['tracks'] ?? result['tracks'];
    if (raw is! List) {
      throw const PlaylistLinkHttpException(
        'The add-on returned no playlist songs.',
      );
    }
    String text(Object? value) => value is Map
        ? '${value['name'] ?? value['title'] ?? ''}'
        : '${value ?? ''}';
    final entries = <RemotePlaylistEntry>[];
    for (final track in raw.take(10000)) {
      if (track is! Map) continue;
      final title = text(track['name'] ?? track['title']).trim();
      if (title.isEmpty) continue;
      final artists = track['artists'] ?? track['artist'];
      final ms = num.tryParse(
        '${track['duration_ms'] ?? track['durationMs'] ?? ''}',
      );
      entries.add(
        RemotePlaylistEntry(
          title: title,
          artist: artists is List
              ? artists.map(text).where((s) => s.isNotEmpty).join(', ')
              : text(artists),
          album: text(track['album_name'] ?? track['album']),
          duration: ms != null && ms > 0
              ? Duration(milliseconds: ms.round())
              : null,
          remoteId: track['id']?.toString(),
        ),
      );
    }
    if (entries.isEmpty) {
      throw const PlaylistLinkHttpException(
        'No public playlist songs were found.',
      );
    }
    final total = num.tryParse(
      '${playlist['total'] ?? playlist['total_tracks'] ?? playlist['numberOfTracks'] ?? ''}',
    )?.toInt();
    // Link handlers do not promise a complete catalogue response. Be conservative
    // so a partial refresh can never remove or reorder local songs.
    return RemotePlaylistSnapshot(
      title: text(playlist['name'] ?? playlist['title']).trim().isEmpty
          ? '${link.source.label} Playlist'
          : text(playlist['name'] ?? playlist['title']),
      description: playlist['description'] is String
          ? playlist['description'] as String
          : null,
      thumbnailUrl: playlist['cover_url'] is String
          ? playlist['cover_url'] as String
          : null,
      entries: entries,
      totalEntries: total,
      complete: false,
      truncationReason:
          'The add-on supplied ${entries.length} tracks; a complete listing is not guaranteed.',
    );
  }
}

/// Public Deezer metadata requires neither an account nor a playback add-on.
class DeezerPlaylistImporter implements PlaylistLinkImporter {
  final PlaylistLinkTransport transport;
  const DeezerPlaylistImporter(this.transport);
  static const pageSize = 100;
  static const maxPages = 100;

  Future<Map<String, dynamic>> _get(
    Uri uri,
    PlaylistLinkCancellationToken? cancellation,
  ) async {
    final response = await transport.request(
      'GET',
      uri,
      headers: const {'Accept': 'application/json'},
      maxBytes: 4 * 1024 * 1024,
      timeout: const Duration(seconds: 15),
      cancellation: cancellation,
    );
    final data = decodePlaylistJson(response.body);
    if (response.statusCode != 200 || data['error'] != null) {
      throw const PlaylistLinkHttpException(
        'Deezer could not read this public playlist. It may be private or unavailable.',
      );
    }
    return data;
  }

  @override
  Future<RemotePlaylistSnapshot> fetch(
    ParsedPlaylistLink link, {
    PlaylistLinkCancellationToken? cancellation,
  }) async {
    final metadata = await _get(
      Uri.https('api.deezer.com', '/playlist/${link.remoteId}'),
      cancellation,
    );
    final entries = <RemotePlaylistEntry>[];
    int? total = (metadata['nb_tracks'] as num?)?.toInt();
    String? partial;
    for (var page = 0; page < maxPages; page++) {
      cancellation?.throwIfCancelled();
      Map<String, dynamic> data;
      try {
        data = await _get(
          Uri.https('api.deezer.com', '/playlist/${link.remoteId}/tracks', {
            'index': '${page * pageSize}',
            'limit': '$pageSize',
          }),
          cancellation,
        );
      } on PlaylistLinkCancelledException {
        rethrow;
      } catch (_) {
        if (page == 0) rethrow;
        partial = 'Deezer pagination failed after $page pages.';
        break;
      }
      if (data['data'] is! List) {
        throw const PlaylistLinkHttpException(
          'Deezer returned invalid playlist tracks.',
        );
      }
      final rows = data['data'] as List;
      total = (data['total'] as num?)?.toInt() ?? total;
      for (final track in rows) {
        if (track is! Map) continue;
        final title = track['title'];
        if (title is! String || title.trim().isEmpty) continue;
        final artist = track['artist'];
        final album = track['album'];
        entries.add(
          RemotePlaylistEntry(
            title: title.trim(),
            artist: artist is Map ? '${artist['name'] ?? ''}' : '',
            album: album is Map ? album['title'] as String? : null,
            remoteId: track['id']?.toString(),
            duration: track['duration'] is num
                ? Duration(seconds: (track['duration'] as num).round())
                : null,
          ),
        );
      }
      if (data['next'] == null || rows.isEmpty) {
        if (data['next'] != null || (total != null && entries.length < total)) {
          partial =
              'Deezer returned an incomplete playlist (${entries.length} songs).';
        }
        break;
      }
      // Build the next request ourselves; never follow a server-supplied host.
      if (page == maxPages - 1) {
        partial = 'Deezer playlist cap reached (10000 songs).';
      }
    }
    return RemotePlaylistSnapshot(
      title: metadata['title'] as String? ?? 'Deezer Playlist',
      description: metadata['description'] as String?,
      thumbnailUrl:
          metadata['picture_xl'] as String? ?? metadata['picture'] as String?,
      entries: entries,
      totalEntries: total,
      complete: partial == null,
      truncationReason: partial,
    );
  }
}
