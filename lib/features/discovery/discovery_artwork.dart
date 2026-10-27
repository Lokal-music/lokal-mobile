/// Lazy artwork fallback for Discovery, ported from desktop Lokal
/// (`electron/discoveryArtwork.js`, `src/components/DiscoveryImage.jsx`).
///
/// Last.fm no longer serves artist pictures or most track covers, so a
/// recommendation often arrives without artwork, or with a URL that no longer
/// loads. In that case the cover is looked up, in desktop's order: a match in
/// your library, then Deezer, then iTunes. A lookup only ever changes the
/// picture, never which recording is recommended. Matching retains recording
/// versions while allowing harmless remaster labels and featured credits.
///
/// Lookups only happen inside Discovery, which is already opt-in: it shows
/// nothing until you connect Last.fm (or sign in to YouTube Music).
library;

import 'dart:async';

import '../../core/utils/album_match.dart';
import '../../core/utils/artist_credits.dart';

import 'dart:collection';

import 'package:flick/features/konnekted/konnekted_data.dart';
import 'package:flick/models/song.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:flick/services/graceful_http_client.dart';

import 'discovery_http.dart';
import 'discovery_sources.dart';
import 'discovery_models.dart';
import '../library_jobs/artist_metadata.dart';
import '../../services/apple_music/apple_music_metadata_service.dart';
import 'recommendation_match.dart';

enum DiscoveryArtworkKind { track, album, artist }

/// What a cover is wanted for. [exclude] is a URL that already failed to load.
@immutable
class DiscoveryArtworkRequest {
  const DiscoveryArtworkRequest({
    required this.kind,
    required this.artist,
    this.title = '',
    this.exclude = '',
  });

  final DiscoveryArtworkKind kind;
  final String title;
  final String artist;
  final String exclude;

  bool get isComplete =>
      artist.trim().isNotEmpty &&
      (kind == DiscoveryArtworkKind.artist || title.trim().isNotEmpty);

  String get cacheKey =>
      '${kind.name}\u0000${recommendationKey(artist)}\u0000'
      '${recommendationKey(title)}\u0000$exclude';

  @override
  bool operator ==(Object other) =>
      other is DiscoveryArtworkRequest &&
      other.kind == kind &&
      other.title == title &&
      other.artist == artist &&
      other.exclude == exclude;

  @override
  int get hashCode => Object.hash(kind, title, artist, exclude);
}

final _https = RegExp('^https://', caseSensitive: false);
final _insecure = RegExp('^http:', caseSensitive: false);
final _placeholder = RegExp(
  r'2a96cbd8|default_album|noimage|/artist//',
  caseSensitive: false,
);

/// Desktop's `imageUrl`: an https image that isn't a Last.fm placeholder, or
/// '' when there is none.
String discoveryImageUrl(String? value) {
  final url = (value ?? '').trim().replaceFirst(_insecure, 'https:');
  return _https.hasMatch(url) && !_placeholder.hasMatch(url) ? url : '';
}

class _Cached {
  const _Cached(this.image, this.at);
  final String image;
  final DateTime at;
}

/// Looks covers up on Deezer and iTunes, with desktop's limits: hits kept for
/// a day, misses for five minutes, at most 1000 entries, one request per
/// cover at a time and at most four lookups running together.
class DiscoveryArtworkResolver {
  DiscoveryArtworkResolver(
    this._http, {
    DateTime Function()? now,
    this.artistPortrait,
    this.searchSongs,
    this.onSourceFailure,
    this.allowCollaborations = false,
  }) : _now = now ?? DateTime.now;

  final DiscoveryHttp _http;
  final Future<List<DiscoveryTrack>> Function(String query)? searchSongs;
  final Future<String?> Function(String name)? artistPortrait;

  /// Optional diagnostics; source domains only, never request URLs or tokens.
  final void Function(String source, String reason)? onSourceFailure;

  /// Only Discord opts in to official multi-artist credits such as
  /// "Big Data & Joywave" for a file tagged "Big Data".
  final bool allowCollaborations;
  final DateTime Function() _now;

  static const maxEntries = 1000;
  static const maxConcurrent = 4;
  static const hitLifetime = Duration(hours: 24);
  static const missLifetime = Duration(minutes: 5);

  final _cache = <String, _Cached>{};
  final _pending = <String, Future<String>>{};
  final _waiting = Queue<Completer<void>>();
  int _running = 0;

  /// The cover for [request], or '' when none matches.
  /// Allow an explicit retry to requery a previous miss. Rich Presence may
  /// need to recover after a transient API timeout, while Discovery's ordinary
  /// five-minute miss cache should remain unchanged.
  void invalidateMiss(DiscoveryArtworkRequest request) {
    final id = request.cacheKey;
    if (_cache[id]?.image.isEmpty == true) _cache.remove(id);
  }

  Future<String> resolve(DiscoveryArtworkRequest request) {
    if (!request.isComplete) return Future.value('');
    final id = request.cacheKey;
    final cached = _cache[id];
    if (cached != null) {
      final lifetime = cached.image.isEmpty ? missLifetime : hitLifetime;
      if (_now().difference(cached.at) < lifetime) {
        return Future.value(cached.image);
      }
      _cache.remove(id);
    }
    return _pending[id] ??= _lookup(request)
        .then((image) {
          _cache[id] = _Cached(image, _now());
          while (_cache.length > maxEntries) {
            _cache.remove(_cache.keys.first);
          }
          return image;
        })
        .whenComplete(() {
          // A block body: returning the removed future would await itself.
          _pending.remove(id);
        });
  }

  Future<String> _lookup(DiscoveryArtworkRequest request) async {
    if (_running >= maxConcurrent) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _running++;
    try {
      return await _remote(request);
    } catch (_) {
      return '';
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }

  Future<List<Map>> _rows(Uri url, String field) async {
    try {
      final data = (await _http.json(url))[field];
      return data is List ? data.whereType<Map>().toList() : const [];
    } catch (error) {
      final failure = error.toString();
      onSourceFailure?.call(
        url.host,
        failure.contains('429')
            ? 'rate limited'
            : failure.contains('403') || failure.contains('401')
            ? 'access refused'
            : failure.contains('timed out') || failure.contains('timeout')
            ? 'timed out'
            : 'request failed',
      );
      return const [];
    }
  }

  Future<String> _remote(DiscoveryArtworkRequest request) async {
    String allowed(Object? value) {
      final image = discoveryImageUrl(value is String ? value : null);
      return image.isNotEmpty && image != request.exclude ? image : '';
    }

    String first(List<Object?> values) => values
        .map(allowed)
        .firstWhere((image) => image.isNotEmpty, orElse: () => '');

    bool same(Object? a, String b) =>
        recommendationKey(a is String ? a : '') == recommendationKey(b);

    String nameOf(Object? value) =>
        value is Map && value['name'] is String ? value['name'] as String : '';

    if (request.kind == DiscoveryArtworkKind.artist) {
      final artists = await _rows(
        Uri.https('api.deezer.com', '/search/artist', {
          'q': request.artist,
          'limit': '10',
        }),
        'data',
      );
      for (final row in artists) {
        final image = first([row['picture_xl'], row['picture_big']]);
        if (same(row['name'], request.artist) && image.isNotEmpty) {
          return image;
        }
      }
      final songs = await _rows(
        Uri.https('api.deezer.com', '/search', {
          'q': 'artist:"${request.artist}"',
          'limit': '10',
        }),
        'data',
      );
      for (final row in songs) {
        final artist = row['artist'] is Map ? row['artist'] as Map : const {};
        final image = first([artist['picture_xl'], artist['picture_big']]);
        if (same(artist['name'], request.artist) && image.isNotEmpty) {
          return image;
        }
      }
      final lookup = artistPortrait;
      return lookup == null ? '' : allowed(await lookup(request.artist));
    }

    final album = request.kind == DiscoveryArtworkKind.album;
    bool matchingTitle(Object? value) => album
        ? value is String && albumTitlesMatch(value, request.title)
        : value is String && titleKey(value) == titleKey(request.title);
    bool matchingArtist(Object? value) =>
        (album &&
            value is String &&
            albumArtistsMatch(request.artist, value)) ||
        same(value, request.artist) ||
        value is String &&
            same(mainArtist(value), mainArtist(request.artist)) ||
        (!album &&
            allowCollaborations &&
            value is String &&
            artworkArtistsMatch(
              request.artist,
              value,
              allowCollaborations: true,
            ));
    final deezer = await _rows(
      Uri.https('api.deezer.com', album ? '/search/album' : '/search', {
        'q': album
            ? 'artist:"${splitArtistCredits(request.artist).firstOrNull ?? request.artist}" album:"${request.title}"'
            : 'artist:"${request.artist}" track:"${request.title}"',
        'limit': '15',
      }),
      'data',
    );
    for (final row in deezer) {
      final source = album ? row : (row['album'] is Map ? row['album'] : null);
      final cover = source is Map
          ? first([source['cover_xl'], source['cover_big']])
          : '';
      if (matchingTitle(row['title']) &&
          matchingArtist(nameOf(row['artist'])) &&
          cover.isNotEmpty) {
        return cover;
      }
    }

    // Storefront availability differs even for well-known original recordings.
    // US can return only covers (e.g. Plastic Love); GB has the original.
    for (final country in ['us', 'gb', if (album) 'in']) {
      final itunes = await _rows(
        Uri.https('itunes.apple.com', '/search', {
          'term': album
              ? '${request.title} ${splitArtistCredits(request.artist).firstOrNull ?? request.artist}'
              : '${request.artist} ${request.title}',
          'country': country,
          'entity': album ? 'album' : 'song',
          'limit': '15',
        }),
        'results',
      );
      for (final row in itunes) {
        final small = row['artworkUrl100'];
        final cover = allowed(
          small is String
              ? small.replaceFirst(
                  '100x100bb',
                  album ? '1500x1500bb' : '600x600bb',
                )
              : null,
        );
        if (matchingTitle(album ? row['collectionName'] : row['trackName']) &&
            matchingArtist(row['artistName']) &&
            cover.isNotEmpty) {
          return cover;
        }
      }
    }
    // Desktop's final fallback: YouTube Music song thumbnails. Only a
    // matching title/artist may supply the image, never a random first hit.
    if (!album && searchSongs != null) {
      try {
        final results = await searchSongs!(
          '${request.artist} ${request.title}',
        );
        for (final song in results) {
          final image = allowed(song.artwork);
          if (matchingTitle(song.title) &&
              matchingArtist(song.artist) &&
              image.isNotEmpty)
            return image;
        }
      } catch (_) {
        /* Keep the placeholder if every artwork source fails. */
      }
    }
    // Exact matches remain preferred. When local tags have a small wording
    // mismatch, search a broader phrase and accept only a high-confidence
    // match from the *same artist*. Never silently pick the first search hit.
    if (!album) {
      const stopWords = {
        'a',
        'an',
        'and',
        'at',
        'by',
        'for',
        'in',
        'of',
        'on',
        'the',
        'to',
        'with',
      };
      final keywords = titleKey(request.title)
          .split(' ')
          .where((word) => word.length >= 3 && !stopWords.contains(word))
          .toList();
      // A one-word title (e.g. "Dangerous") is safe to retry for Discord:
      // the confidence scorer still requires an exact canonical title and
      // an accepted primary artist, so random search hits cannot pass.
      if (keywords.length >= (allowCollaborations ? 1 : 2)) {
        final candidates = <({double score, String title, String url})>[];
        void consider(String title, String artist, String url) {
          final image = allowed(url);
          if (image.isEmpty) return;
          final score = artworkMatchConfidence(
            title: request.title,
            artist: request.artist,
            candidateTitle: title,
            candidateArtist: artist,
            allowCollaborations: allowCollaborations,
          );
          if (score >= artworkConfidenceThreshold) {
            candidates.add((score: score, title: title, url: image));
          }
        }

        final broadTitle = keywords.join(' ');
        final deezerResults = await _rows(
          Uri.https('api.deezer.com', '/search', {
            'q': 'artist:"${request.artist}" $broadTitle',
            'limit': '30',
          }),
          'data',
        );
        for (final row in deezerResults) {
          final albumArt = row['album'] is Map ? row['album'] as Map : const {};
          final artist = row['artist'] is Map ? row['artist'] as Map : const {};
          consider(
            row['title']?.toString() ?? '',
            nameOf(artist),
            first([albumArt['cover_xl'], albumArt['cover_big']]),
          );
        }

        for (final country in ['us', 'gb', if (album) 'in']) {
          final itunesResults = await _rows(
            Uri.https('itunes.apple.com', '/search', {
              'term': '${request.artist} $broadTitle',
              'country': country,
              'entity': 'song',
              'limit': '30',
            }),
            'results',
          );
          for (final row in itunesResults) {
            final small = row['artworkUrl100'];
            consider(
              row['trackName']?.toString() ?? '',
              row['artistName']?.toString() ?? '',
              small is String
                  ? small.replaceFirst(
                      '100x100bb',
                      album ? '1500x1500bb' : '600x600bb',
                    )
                  : '',
            );
          }
        }

        if (searchSongs != null) {
          try {
            for (final result in await searchSongs!(
              '${request.artist} $broadTitle',
            )) {
              consider(result.title, result.artist, result.artwork ?? '');
            }
          } catch (_) {
            // Keep candidates already verified from other sources.
          }
        }

        candidates.sort((a, b) => b.score.compareTo(a.score));
        if (candidates.isNotEmpty) {
          final best = candidates.first;
          // Two competing, differently titled candidates with nearly equal
          // confidence are ambiguous. Avoid showing an unrelated cover.
          final competing = candidates.where(
            (candidate) =>
                titleKey(candidate.title) != titleKey(best.title) &&
                best.score - candidate.score < 0.025,
          );
          if (competing.isEmpty) return best.url;
        }
      }
    }
    return '';
  }
}

/// Your library's covers by normalised title and artist (or album and album
/// artist), so a recommendation you already own shows its own artwork.
class DiscoveryLocalArtwork {
  DiscoveryLocalArtwork(Iterable<Song> songs) : _covers = {} {
    for (final song in songs) {
      final art = song.albumArt?.trim() ?? '';
      if (art.isEmpty) continue;
      final artists = {
        recommendationKey(song.artist),
        if (song.albumArtist != null) recommendationKey(song.albumArtist),
      }..remove('');
      final title = recommendationKey(song.title);
      final album = recommendationKey(song.album);
      for (final artist in artists) {
        if (title.isNotEmpty) {
          _covers.putIfAbsent(
            _id(DiscoveryArtworkKind.track, artist, title),
            () => art,
          );
        }
        if (album.isNotEmpty) {
          _covers.putIfAbsent(
            _id(DiscoveryArtworkKind.album, artist, album),
            () => art,
          );
        }
      }
    }
  }

  static const empty = DiscoveryLocalArtwork._empty();
  const DiscoveryLocalArtwork._empty() : _covers = const {};

  final Map<String, String> _covers;

  static String _id(DiscoveryArtworkKind kind, String artist, String title) =>
      '${kind.name}\u0000$artist\u0000$title';

  /// The library cover for [request], or null. Artists have no library
  /// picture in this track-cover index; their cached portraits are read separately.
  String? lookup(DiscoveryArtworkRequest request) {
    if (!request.isComplete || request.kind == DiscoveryArtworkKind.artist) {
      return null;
    }
    final art =
        _covers[_id(
          request.kind,
          recommendationKey(request.artist),
          recommendationKey(request.title),
        )];
    return art == null || art == request.exclude ? null : art;
  }
}

/// Shared remote artwork pipeline for Last.fm/Discovery and Discord presence.
/// Exact track/artist matching plus Deezer, US/GB Apple Music storefronts,
/// and verified YouTube Music fallbacks stay identical across both features.
DiscoveryArtworkResolver createDiscoveryArtworkResolver(
  DiscoveryHttp web, {
  void Function(String source, String reason)? onSourceFailure,
  bool allowCollaborations = false,
}) {
  final youtube = YoutubeMusicCatalog(web, refreshClientContext: true);
  return DiscoveryArtworkResolver(
    web,
    searchSongs: youtube.search,
    onSourceFailure: onSourceFailure,
    allowCollaborations: allowCollaborations,
    artistPortrait: (name) async {
      final api = AppleMusicMetadataService.instance;
      final artist = await api.resolveArtist(name);
      if (artist == null) return null;
      return (await api.getArtistInfo(artist.artistId))?.imageUrl;
    },
  );
}

/// One resolver for the app's lifetime, so its cache survives Home rebuilds.
final discoveryArtworkResolverProvider = Provider<DiscoveryArtworkResolver>((
  ref,
) {
  final client = GracefulHttpClient();
  ref.onDispose(client.close);
  return createDiscoveryArtworkResolver(
    DiscoveryHttp(client, timeout: const Duration(seconds: 4)),
  );
});

final discoveryLocalArtworkProvider =
    Provider.autoDispose<DiscoveryLocalArtwork>((ref) {
      final songs = ref.watch(konnektedLibraryProvider).value;
      return songs == null || songs.isEmpty
          ? DiscoveryLocalArtwork.empty
          : DiscoveryLocalArtwork(songs);
    });

/// Desktop's `DiscoveryImage`: shows [url], and when it is missing or fails to
/// load, looks a cover up and shows that, else [placeholder].
class DiscoveryArtwork extends StatelessWidget {
  const DiscoveryArtwork({
    super.key,
    required this.kind,
    required this.artist,
    this.title = '',
    this.url = '',
    required this.placeholder,
    this.width,
    this.height,
  });

  final DiscoveryArtworkKind kind;
  final String title;
  final String artist;
  final String url;
  final Widget placeholder;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final image = discoveryImageUrl(url);
    final fallback = _DiscoveryArtworkFallback(
      request: DiscoveryArtworkRequest(
        kind: kind,
        title: title,
        artist: artist,
        exclude: image,
      ),
      placeholder: placeholder,
      width: width,
      height: height,
    );
    if (image.isEmpty) return fallback;
    return CachedImageWidget(
      imagePath: image,
      width: width,
      height: height,
      placeholder: placeholder,
      errorWidget: fallback,
    );
  }
}

class _DiscoveryArtworkFallback extends ConsumerStatefulWidget {
  const _DiscoveryArtworkFallback({
    required this.request,
    required this.placeholder,
    this.width,
    this.height,
    this.skipLocal = false,
  });

  final DiscoveryArtworkRequest request;
  final Widget placeholder;
  final double? width;
  final double? height;
  final bool skipLocal;

  @override
  ConsumerState<_DiscoveryArtworkFallback> createState() =>
      _DiscoveryArtworkFallbackState();
}

class _DiscoveryArtworkFallbackState
    extends ConsumerState<_DiscoveryArtworkFallback> {
  Future<String>? _remote;

  @override
  void didUpdateWidget(covariant _DiscoveryArtworkFallback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request != widget.request) _remote = null;
  }

  Widget _image(String path, Widget onError) => CachedImageWidget(
    imagePath: path,
    width: widget.width,
    height: widget.height,
    placeholder: widget.placeholder,
    errorWidget: onError,
  );

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    if (!request.isComplete) return widget.placeholder;
    if (!widget.skipLocal) {
      final portrait = request.kind == DiscoveryArtworkKind.artist
          ? ref.watch(
              artistMetadataProvider.select(
                (images) => images[ArtistMetadata.key(request.artist)],
              ),
            )
          : null;
      if (portrait != null && portrait != request.exclude) {
        return _image(
          portrait,
          _DiscoveryArtworkFallback(
            request: request,
            placeholder: widget.placeholder,
            width: widget.width,
            height: widget.height,
            skipLocal: true,
          ),
        );
      }
      final local = ref.watch(
        discoveryLocalArtworkProvider.select((index) => index.lookup(request)),
      );
      if (local != null) {
        return _image(
          local,
          _DiscoveryArtworkFallback(
            request: request,
            placeholder: widget.placeholder,
            width: widget.width,
            height: widget.height,
            skipLocal: true,
          ),
        );
      }
    }
    _remote ??= ref.read(discoveryArtworkResolverProvider).resolve(request);
    return FutureBuilder<String>(
      future: _remote,
      builder: (context, snapshot) {
        final image = snapshot.data ?? '';
        return image.isEmpty
            ? widget.placeholder
            : _image(image, widget.placeholder);
      },
    );
  }
}
