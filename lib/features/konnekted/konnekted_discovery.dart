import 'package:flick/core/utils/artist_credits.dart';
import 'package:flick/core/utils/app_log.dart';
import 'package:flutter/material.dart';
import 'package:flick/features/morneye/morneye_auth_sheet.dart';

import 'dart:async';
import 'dart:convert';

import 'discovery_snapshot_cache.dart';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:flick/features/discovery/discovery_artwork.dart'
    show discoveryImageUrl;
import 'package:flick/features/discovery/discovery_http.dart';
import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flick/features/discovery/discovery_playback.dart';
import 'package:flick/features/discovery/discovery_progressive_streams.dart';
import 'package:flick/features/discovery/discovery_registry.dart';
import 'package:flick/features/discovery/discovery_settings.dart';
import 'package:flick/features/discovery/discovery_sources.dart';
import 'package:flick/features/discovery/monochrome_source.dart';
import 'package:flick/features/discovery/soundcloud_source.dart';
import 'package:flick/features/discovery/lastfm_discovery.dart';
import 'package:flick/features/discovery/recommendation_match.dart';
import 'package:flick/features/discovery/spotify_discovery.dart';
import 'package:flick/features/discovery/youtube_audio.dart';
import 'package:flick/features/discovery/youtube_music_account.dart';
import 'package:flick/features/discovery/youtube_music_store.dart';
import 'package:flick/features/morneye/morneye_live_playback.dart';
import 'package:flick/features/morneye/morneye_packages.dart';
import 'package:flick/features/morneye/morneye_playback_quality.dart';
import 'package:flick/features/morneye/morneye_runtime.dart';
import 'package:flick/features/morneye/morneye_service.dart';
import 'package:flick/features/spotify/spotify_api.dart';
import 'package:flick/features/spotify/spotify_web_api.dart';
import 'package:flick/features/spotify/spotify_oauth.dart';
import 'package:flick/features/spotify/spotify_storage.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/atmos_playback_support.dart';
import 'package:flick/services/atmos_diagnostics.dart';
import 'package:flick/providers/lastfm_provider.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/queue_pre_resolver.dart';
import 'package:flick/services/playback_source_priority.dart';
import 'package:flick/services/catalogue_quality.dart';
import 'package:flick/services/graceful_http_client.dart';
import 'package:flick/features/search/online_song_save.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Home's Discovery tab, with opt-in provider-native YouTube Music shelves.

enum KonnektedDiscoverySource { lastfm, youtube, spotify }

final konnektedLastfmAccountProvider = FutureProvider.autoDispose<String?>((
  ref,
) async {
  final session = await ref.watch(lastFmSessionProvider.future);
  final name = session?.username.trim() ?? '';
  return name.isEmpty ? null : name;
});

final konnektedLastfmCallProvider = Provider<LastfmCall>((ref) {
  final client = ref.watch(lastFmApiClientProvider);
  return (method, params) => client.get({'method': method, ...params});
});

/// Disk metadata is restored only for the selected, authenticated provider.
final konnektedDiscoverySnapshotCacheProvider =
    Provider<DiscoverySnapshotCache>((ref) => const DiscoverySnapshotCache());

/// Spotify retains previous shelves during network failures and refreshes
/// expired snapshots without blocking first paint.
final konnektedSpotifyDiscoveryProvider =
    AsyncNotifierProvider<KonnektedSpotifyDiscoveryNotifier,
        SpotifyDiscoverySnapshot>(KonnektedSpotifyDiscoveryNotifier.new);

class KonnektedSpotifyDiscoveryNotifier
    extends AsyncNotifier<SpotifyDiscoverySnapshot> {
  String? _accountKey;
  int _generation = 0;

  @override
  Future<SpotifyDiscoverySnapshot> build() async {
    _accountKey = null;
    void onSessionChanged() {
      final previous = _accountKey;
      if (previous != null) {
        unawaited(ref.read(konnektedDiscoverySnapshotCacheProvider)
            .invalidate('spotify', previous));
      }
      ref.invalidateSelf();
    }
    SecureSpotifyTokenStore.sessionRevision.addListener(onSessionChanged);
    ref.onDispose(() =>
        SecureSpotifyTokenStore.sessionRevision.removeListener(onSessionChanged));
    final settings = SpotifySettingsStore();
    if (!await settings.loadDiscoveryEnabled()) {
      return const SpotifyDiscoverySnapshot(enabled: false, connected: false);
    }
    final tokens = await settings.tokenStore.readTokens();
    final cookie = tokens?.sessionCookie;
    if (cookie == null || cookie.isEmpty) {
      return const SpotifyDiscoverySnapshot(enabled: true, connected: false);
    }
    // Authentication material is never persisted in filenames or cache JSON.
    final key = sha256.convert(utf8.encode(cookie)).toString();
    _accountKey = key;
    final cache = ref.read(konnektedDiscoverySnapshotCacheProvider);
    final saved = await cache.readSpotify(key);
    if (saved != null) {
      if (!saved.isFresh(DiscoverySnapshotCache.spotifyTtl)) {
        // The first frame uses the disk copy; only expired data triggers I/O.
        Future<void>.delayed(Duration.zero, () => refresh());
      }
      return SpotifyDiscoverySnapshot(
        enabled: true, connected: true, data: saved.data);
    }
    final SpotifyDiscoverySnapshot result;
    try {
      result = await _fetch(settings);
    } catch (_) {
      return const SpotifyDiscoverySnapshot(
        enabled: true, connected: true,
        error: 'Spotify Discovery could not be loaded. Try again later.');
    }
    if (result.data case final data? when !data.isEmpty) {
      await cache.writeSpotify(key, data);
    }
    return result;
  }

  Future<SpotifyDiscoverySnapshot> _fetch(SpotifySettingsStore settings) {
    final oauth = SpotifyOAuthService(tokenStore: settings.tokenStore);
    return loadSpotifyDiscoverySnapshot(
      settings: settings,
      oauth: oauth,
      api: SpotifyApi(tokenStore: settings.tokenStore, oauth: oauth),
    );
  }

  Future<void> refresh() async {
    final key = _accountKey;
    if (key == null) {
      ref.invalidateSelf();
      return;
    }
    final generation = ++_generation;
    final previous = state.value;
    SpotifyDiscoverySnapshot result;
    try {
      result = await _fetch(SpotifySettingsStore());
    } catch (_) {
      result = const SpotifyDiscoverySnapshot(
        enabled: true, connected: true,
        error: 'Spotify Discovery could not be loaded. Try again later.');
    }
    if (!ref.mounted || generation != _generation ||
        key != _accountKey) return;
    if (result.data case final data? when !data.isEmpty) {
      state = AsyncData(result);
      await ref.read(konnektedDiscoverySnapshotCacheProvider)
          .writeSpotify(key, data);
    } else if (!result.enabled || !result.connected) {
      state = AsyncData(result);
      await ref.read(konnektedDiscoverySnapshotCacheProvider)
          .invalidate('spotify', key);
    } else {
      state = AsyncData(SpotifyDiscoverySnapshot(
        enabled: true,
        connected: true,
        data: previous?.data,
        error: result.error,
      ));
    }
  }
}

/// A tap opens the native Spotify playlist with the same saved-cookie session.
/// Keep the client scoped to the action, including expiry refresh and cleanup.
final konnektedSpotifyMixLoaderProvider =
    Provider<Future<List<LokalDiscoveryTrack>> Function(String)>((ref) {
      return (id) async {
        final settings = SpotifySettingsStore();
        final api = SpotifyWebApi(
          store: settings.tokenStore,
          oauth: SpotifyOAuthService(tokenStore: settings.tokenStore),
        );
        try {
          return await loadSpotifyWebMix(api, id);
        } finally {
          api.close();
        }
      };
    });

final konnektedYoutubeMusicStoreProvider = Provider<YoutubeMusicSessionStore>(
  (ref) => YoutubeMusicSessionStore(),
);

final konnektedYoutubeMusicSessionProvider =
    AsyncNotifierProvider<KonnektedYoutubeMusicNotifier, YoutubeMusicSession?>(
      KonnektedYoutubeMusicNotifier.new,
    );

class KonnektedYoutubeMusicNotifier
    extends AsyncNotifier<YoutubeMusicSession?> {
  @override
  Future<YoutubeMusicSession?> build() =>
      ref.read(konnektedYoutubeMusicStoreProvider).read();

  Future<void> save(YoutubeMusicSession session) async {
    await ref.read(konnektedYoutubeMusicStoreProvider).write(session);
    forgetYoutubeMusicAccount();
    state = AsyncData(session);
  }

  Future<void> rotated(YoutubeMusicSession session) async {
    // Keep the account provider stable while its own client is in flight.
    // The account object has already accepted these rotated cookies; persist
    // them without publishing a new AsyncData value that would dispose it.
    if (state.value == null) return;
    await ref.read(konnektedYoutubeMusicStoreProvider).write(session);
  }

  Future<void> signOut() async {
    await ref.read(konnektedYoutubeMusicStoreProvider).clear();
    forgetYoutubeMusicAccount();
    state = const AsyncData(null);
    ref.read(konnektedDiscoveryProvider.notifier).clearYoutubeMusicAccount();
  }
}

final konnektedYoutubeMusicAccountProvider = Provider<YoutubeMusicAccount?>((
  ref,
) {
  final session = ref.watch(konnektedYoutubeMusicSessionProvider).value;
  if (session == null || !session.signedIn) return null;
  final client = http.Client();
  ref.onDispose(client.close);
  return YoutubeMusicAccount(
    client,
    session,
    onSessionChanged: (updated) {
      unawaited(
        ref
            .read(konnektedYoutubeMusicSessionProvider.notifier)
            .rotated(updated),
      );
    },
  );
});

class KonnektedDiscoveryState {
  const KonnektedDiscoveryState({
    this.data,
    this.loading = false,
    this.error,
    this.connected = true,
    this.source = KonnektedDiscoverySource.lastfm,
  });

  /// Shelves remain visible when a refresh fails.
  final LokalDiscovery? data;
  final bool loading;
  final String? error;
  final bool connected;
  final KonnektedDiscoverySource source;
}

class KonnektedDiscoveryNotifier extends Notifier<KonnektedDiscoveryState> {
  var _page = 0;
  var _generation = 0;
  var _sourceLoaded = false;
  bool _loadAttempted = false;
  Future<void>? _sourceRestore;
  String? _account;

  static const _sourceKey = 'lokal_discovery_source';

  @override
  KonnektedDiscoveryState build() => const KonnektedDiscoveryState();

  Future<void> setSource(KonnektedDiscoverySource source) async {
    if (state.source == source && _sourceLoaded) return;
    if (source == KonnektedDiscoverySource.spotify)
      ref.invalidate(konnektedSpotifyDiscoveryProvider);
    ++_generation;
    _page = 0;
    _account = null;
    _loadAttempted = false;
    _sourceLoaded = true;
    state = KonnektedDiscoveryState(source: source, connected: true);
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_sourceKey, source.name);
    } catch (_) {
      // The in-memory selection remains usable if persistence fails.
    }
    await load();
  }

  Future<void> _restoreSource() {
    if (_sourceLoaded) return Future<void>.value();
    return _sourceRestore ??= _restoreSavedSource();
  }

  Future<void> _restoreSavedSource() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final value = preferences.getString(_sourceKey);
      final saved = KonnektedDiscoverySource.values
          .where((source) => source.name == value)
          .firstOrNull;
      // A manual source change may have happened while preferences loaded.
      if (!_sourceLoaded && saved != null) {
        state = KonnektedDiscoveryState(source: saved);
      }
    } catch (_) {
      // Last.fm remains the default.
    } finally {
      _sourceLoaded = true;
    }
  }

  /// Clears displayed account data immediately when the user signs out.
  void clearYoutubeMusicAccount() {
    if (state.source != KonnektedDiscoverySource.youtube) return;
    final previousAccount = _account;
    if (previousAccount != null) {
      unawaited(ref.read(konnektedDiscoverySnapshotCacheProvider)
          .invalidate('youtube', previousAccount));
    }
    ++_generation;
    _page = 0;
    _account = null;
    state = const KonnektedDiscoveryState(
      connected: false,
      source: KonnektedDiscoverySource.youtube,
    );
  }

  /// Loads the selected provider. A refresh rotates between provider picks.
  Future<void> load({bool refresh = false}) async {
    if (!refresh && (_loadAttempted || state.data != null || state.loading))
      return;
    await _restoreSource();
    final source = state.source;
    if (!refresh && (_loadAttempted || state.data != null || state.loading))
      return;
    _loadAttempted = true;
    final generation = ++_generation;
    state = KonnektedDiscoveryState(
      data: state.data,
      loading: true,
      connected: state.connected,
      source: source,
    );

    if (source == KonnektedDiscoverySource.youtube) {
      YoutubeMusicSession? session;
      try {
        session = await ref.read(konnektedYoutubeMusicSessionProvider.future);
      } catch (_) {
        session = null;
      }
      if (generation != _generation) return;
      if (session == null || !session.signedIn) {
        _account = null;
        _page = 0;
        state = const KonnektedDiscoveryState(
          connected: false,
          source: KonnektedDiscoverySource.youtube,
        );
        return;
      }
      final account = ref.read(konnektedYoutubeMusicAccountProvider);
      if (account == null) {
        state = const KonnektedDiscoveryState(
          connected: false,
          source: KonnektedDiscoverySource.youtube,
        );
        return;
      }
      final accountKey = 'youtube:' + session.accountKey;
      final cache = ref.read(konnektedDiscoverySnapshotCacheProvider);
      final existing = accountKey == _account ? state.data : null;
      final saved = existing == null
          ? await cache.readLokal('youtube', accountKey) : null;
      if (generation != _generation) return;
      final previous = existing ?? saved?.data;
      if (accountKey != _account) _page = previous?.page ?? 0;
      _account = accountKey;
      if (previous != null) {
        state = KonnektedDiscoveryState(
          data: previous, source: source, loading: false);
      }
      if (!refresh && previous != null &&
          (existing != null ||
           saved?.isFresh(DiscoverySnapshotCache.youtubeTtl) == true)) return;
      if (refresh && previous != null) _page++;
      if (previous != null) {
        state = KonnektedDiscoveryState(
          data: previous, source: source, loading: true);
      }
      try {
        final result = await loadYoutubeMusicDiscovery(
          account,
          page: _page,
          force: refresh,
        );
        if (generation != _generation) return;
        final merged = result.keeping(previous);
        state = KonnektedDiscoveryState(data: merged, source: source);
        unawaited(cache.writeLokal('youtube', accountKey, merged));
      } on YoutubeMusicSignedOut catch (error) {
        if (generation != _generation) return;
        await ref.read(konnektedYoutubeMusicSessionProvider.notifier).signOut();
        unawaited(cache.invalidate('youtube', accountKey));
        state = KonnektedDiscoveryState(
          error: error.message,
          connected: false,
          source: source,
        );
      } catch (error) {
        if (generation != _generation) return;
        state = KonnektedDiscoveryState(
          data: previous,
          error: error is LokalDiscoveryFailure ? error.message : 'YouTube Music couldn’t be reached. Check your connection and try again.',
          source: source,
        );
      }
      return;
    }

    if (source == KonnektedDiscoverySource.spotify) {
      // Spotify shelves are owned by konnektedSpotifyDiscoveryProvider.
      // Keep the selection stable; never fall through into Last.fm loading.
      _account = null;
      _page = 0;
      state = const KonnektedDiscoveryState(
        source: KonnektedDiscoverySource.spotify,
      );
      return;
    }

    String? account;
    try {
      account = await ref.read(konnektedLastfmAccountProvider.future);
    } catch (_) {
      account = null;
    }
    if (generation != _generation) return;
    if (account == null) {
      _account = null;
      _page = 0;
      state = const KonnektedDiscoveryState(
        connected: false,
        source: KonnektedDiscoverySource.lastfm,
      );
      return;
    }
    final accountKey = 'lastfm:' + account.toLowerCase();
    final cache = ref.read(konnektedDiscoverySnapshotCacheProvider);
    final existing = accountKey == _account ? state.data : null;
    final saved = existing == null
        ? await cache.readLokal('lastfm', accountKey) : null;
    if (generation != _generation) return;
    final previous = existing ?? saved?.data;
    if (accountKey != _account) _page = previous?.page ?? 0;
    _account = accountKey;
    if (previous != null) {
      state = KonnektedDiscoveryState(
        data: previous, source: source, loading: false);
    }
    if (!refresh && previous != null &&
        (existing != null ||
         saved?.isFresh(DiscoverySnapshotCache.lastfmTtl) == true)) return;
    if (refresh && previous != null) _page++;
    if (previous != null) {
      state = KonnektedDiscoveryState(
        data: previous, source: source, loading: true);
    }
    try {
      final result = await loadLastfmDiscovery(
        username: account,
        call: ref.read(konnektedLastfmCallProvider),
        page: _page,
      );
      if (generation != _generation) return;
      final merged = result.keeping(previous);
      state = KonnektedDiscoveryState(
        data: merged, source: KonnektedDiscoverySource.lastfm);
      unawaited(cache.writeLokal('lastfm', accountKey, merged));
    } catch (error) {
      if (generation != _generation) return;
      state = KonnektedDiscoveryState(
        data: previous,
        error: error is LokalDiscoveryFailure ? error.message : 'Last.fm couldn’t be reached. Check your connection and try again.',
        source: KonnektedDiscoverySource.lastfm,
      );
    }
  }
}

final konnektedDiscoveryProvider =
    NotifierProvider<KonnektedDiscoveryNotifier, KonnektedDiscoveryState>(
      KonnektedDiscoveryNotifier.new,
    );

RecommendationCandidate discoveryCandidate(LokalDiscoveryTrack track) =>
    RecommendationCandidate(
      title: track.title,
      artist: track.artist,
      album: track.album,
      duration: track.duration,
    );

RecommendationCandidate _songCandidate(Song song) => RecommendationCandidate(
  title: song.title,
  artist: song.artist,
  album: song.album,
  duration: song.duration > Duration.zero ? song.duration : null,
);

/// Your library, looked up by title, so matching a shelf of picks doesn't
/// compare each one against every song you own.
class KonnektedLibraryIndex {
  KonnektedLibraryIndex(this.songs) {
    for (final song in songs) {
      final keys = <String>{
        for (final title in recommendationTitles(song.title)) titleKey(title),
      };
      // "Artist - Title" names: the title after the artist, too.
      final parts = song.title.split(RegExp(r'\s+[-–—|]\s+'));
      if (parts.length > 1) {
        keys
          ..add(titleKey(parts.skip(1).join(' - ')))
          ..add(titleKey(parts.last));
      }
      for (final key in keys) {
        if (key.isNotEmpty) _byTitle.putIfAbsent(key, () => []).add(song);
      }
    }
  }

  final List<Song> songs;
  final _byTitle = <String, List<Song>>{};

  static KonnektedLibraryIndex? _last;

  /// The index for [songs], reused while the library is the same list.
  static KonnektedLibraryIndex of(List<Song> songs) {
    final last = _last;
    if (last != null && identical(last.songs, songs)) return last;
    return _last = KonnektedLibraryIndex(songs);
  }

  /// Your copy of [track], if you have it.
  Song? match(LokalDiscoveryTrack track) {
    final candidate = discoveryCandidate(track);
    final nearby = <Song>{
      for (final title in recommendationTitles(track.title))
        ...?_byTitle[titleKey(title)],
    };
    if (nearby.isEmpty) return null;
    return recommendationMatch(candidate, nearby, _songCandidate);
  }

  /// Your copies of [tracks], in order, each once.
  List<Song> matchAll(Iterable<LokalDiscoveryTrack> tracks) {
    final seen = <String>{};
    return [
      for (final track in tracks)
        if (match(track) case final song? when seen.add(song.id)) song,
    ];
  }

  /// Your songs from [album] by [artist], in disc and track order.
  List<Song> album(String album, String artist) {
    final title = recommendationKey(album);
    final by = recommendationKey(mainArtist(artist));
    if (title.isEmpty) return const [];
    final found = songs.where((song) {
      if (recommendationKey(song.album) != title) return false;
      return recommendationKey(mainArtist(song.albumArtist ?? song.artist)) ==
              by ||
          recommendationKey(mainArtist(song.artist)) == by ||
          recommendationKey(leadArtist(song.artist)) == by;
    }).toList();
    found.sort((a, b) {
      final disc = (a.discNumber ?? 1).compareTo(b.discNumber ?? 1);
      return disc != 0
          ? disc
          : (a.trackNumber ?? 0).compareTo(b.trackNumber ?? 0);
    });
    return found;
  }

  /// Your songs by [artist].
  List<Song> artist(String artist) {
    final by = recommendationKey(mainArtist(artist));
    if (by.isEmpty) return const [];
    return songs
        .where(
          (song) =>
              songArtistNames(song)
                  .any((name) => recommendationKey(name) == by),
        )
        .toList();
  }
}

/// A place a song you don't own can be played from.
/// A song a source found, with its cover when the source has one.
class OnlineResult {
  const OnlineResult(this.track, {String? artwork}) : _artwork = artwork;

  final DiscoveryTrack track;
  final String? _artwork;

  String? get artwork => _artwork ?? track.artwork;
}

/// A place to find songs you don't have: YouTube Music or one of your
/// add-ons, as desktop's Search page offers them.
class OnlineSource {
  const OnlineSource({
    required this.id,
    required this.name,
    required this.results,
    required this.play,
    this.addon = false,
    this.needsVerification,
    this.verify,
  });

  final String id;
  final String name;
  final bool addon;
  final bool Function()? needsVerification;
  final Future<bool> Function(BuildContext)? verify;

  /// Songs matching a query, with covers.
  final Future<List<OnlineResult>> Function(String query) results;

  /// Gets a track ready to play (downloaded and checked).
  final Future<Song> Function(DiscoveryTrack track) play;

  Future<List<DiscoveryTrack>> search(String query) async => [
    for (final result in await results(query)) result.track,
  ];
}

typedef _PlaybackSource = OnlineSource;

/// App-shell supplied verification UI. Discovery and autoplay resolvers run
/// without BuildContext; only a foreground request may open the auth sheet.
Future<bool> Function(OnlineSource source)? playbackSourceVerification;

// Desktop has a reusable audio-cache for already downloaded Morneye tracks.
// Keep a small in-session index of verified, existing cache files so Replay,
// repeat, and revisiting the same Search result do not repeat provider
// verification and a full transfer. Never key only by track ID: changing
// addon binary, requested tier, or account/settings must not reuse old audio.
final _morneyeReadyPlayback = <String, Song>{};

/// Keep *provider identity*, not a signed audio link or cached file path.
/// Any add-on can change its rendition quality while a song is playing.
final _onlineAddonOrigin = <String, ({String addonId, DiscoveryTrack track})>{};

void _rememberOnlineAddon(Song song, String addonId, DiscoveryTrack track) {
  _onlineAddonOrigin.remove(song.id);
  _onlineAddonOrigin[song.id] = (addonId: addonId, track: track);
  while (_onlineAddonOrigin.length > 256) {
    _onlineAddonOrigin.remove(_onlineAddonOrigin.keys.first);
  }
}

/// A fresh quality selection must resolve a fresh stream for **every** addon.
/// This never infers audio quality from the selected option: playback's native
/// codec probe establishes the actual delivered rendition.
Future<void> onOnlineAddonSettingsChanged(String addonKey) async {
  _morneyeReadyPlayback.clear();
  final player = PlayerService();
  final previous = player.currentSongNotifier.value;
  if (previous == null) return;
  final origin = _onlineAddonOrigin[previous.id];
  if (origin == null || origin.addonId != addonKey) return;
  final savedPosition = player.positionNotifier.value;
  final wasPlaying = player.isPlayingNotifier.value;
  try {
    final replacement = await playOnlineTrack(
      'a-$addonKey',
      origin.track,
    );
    // Avoid resurrecting a superseded track while another selection plays.
    if (player.currentSongNotifier.value?.id != previous.id) return;
    await player.play(replacement);
    if (savedPosition > Duration.zero) await player.seek(savedPosition);
    if (!wasPlaying) await player.pause();
  } catch (_) {
    // Keep the old edition playable if the newly requested tier fails.
    rethrow;
  }
}
const _maxMorneyeReadyPlayback = 32;

String morneyePlaybackCacheKey({
  required String addonKey,
  required String addonDigest,
  required String trackId,
  required String settingsFingerprint,
  required String requestedTier,
}) => sha256.convert(utf8.encode(jsonEncode([
  addonKey, addonDigest, trackId, settingsFingerprint, requestedTier,
]))).toString();

void _rememberMorneyePlayback(String key, Song song) {
  _morneyeReadyPlayback.remove(key);
  _morneyeReadyPlayback[key] = song;
  while (_morneyeReadyPlayback.length > _maxMorneyeReadyPlayback) {
    _morneyeReadyPlayback.remove(_morneyeReadyPlayback.keys.first);
  }
}

/// A configured download preference is *not* per-track audio quality.
/// Amazon's "FLAC Best Available" option must not become a Search badge on
/// every song. Only provider-advertised per-track metadata is shown.
String? morneyeAdvertisedQuality(String? advertised) {
  final quality = advertised?.trim() ?? '';
  return quality.isEmpty ? null : quality;
}

/// Reuse actual audio probe results from a previously prepared song.
/// A catalogue search can omit Amazon's codec/depth/rate even though the
/// downloaded file exposes them in Now Playing. Prefer metadata explicitly
/// reported by the source and never reinterpret the user's quality setting
/// as a claim about an unplayed song.
({String? codec, int? bitDepth, int? sampleRate}) morneyeSearchAudioDetails({
  String? codec,
  int? bitDepth,
  int? sampleRate,
  Song? verifiedPlayback,
}) {
  final fileType = verifiedPlayback?.fileType.toUpperCase();
  const known = {
    'FLAC', 'ALAC', 'AAC', 'MP3', 'OPUS', 'VORBIS', 'WAV', 'AIFF',
    'OGG', 'APE', 'WAVPACK', 'WV',
  };
  final cachedCodec = known.contains(fileType) ? fileType : null;
  final advertisedCodec = codec?.trim().toUpperCase();
  // Do not combine a previously cached FLAC's 24-bit PCM metadata with a
  // newly advertised AAC/Opus edition of the same catalogue recording.
  final sameCodec = advertisedCodec == null ||
      advertisedCodec.isEmpty ||
      advertisedCodec == cachedCodec;
  return (
    codec: codec ?? cachedCodec,
    bitDepth: bitDepth ?? (sameCodec ? verifiedPlayback?.bitDepth : null),
    sampleRate: sampleRate ??
        (sameCodec ? verifiedPlayback?.sampleRate : null),
  );
}

/// Your Morneye add-ons that can play songs right now, as playback sources.
Future<List<_PlaybackSource>> _morneyeSources(
  MorneyeService service,
  DiscoveryPlaybackCache Function() cache,
  void Function(String status)? onStatus, {
  Future<void>? cancel,
  bool forDownload = false,
  String? selectedSourceId,
}) async {
  final List<MorneyeAddon> addons;
  final MorneyePackages packages;
  try {
    packages = await service.packages;
    addons = await service.playable();
  } catch (_) {
    return const []; // Add-ons unavailable: the other sources still play.
  }
  return [
    for (final addon in addons)
      if (selectedSourceId == null || selectedSourceId == 'a-${addon.key}')
      OnlineSource(
        id: 'a-${addon.key}',
        name: addon.displayName,
        addon: true,
        needsVerification: () => !packages.access(addon).ready,
        verify: (context) async {
          if (packages.access(addon).ready) return true;
          final url = await packages.verify(addon.key);
          if (url == null) return packages.access(addon).ready;
          if (!context.mounted) return false;
          final verified = await MorneyeAuthSheet.show(
            context,
            packages: packages,
            addon: addon,
            url: url,
          );
          if (verified) service.changed();
          return verified;
        },
        results: (query) async {
          final found = await packages.search(addon.key, query);
          final settings = packages.settings(addon);
          // A chosen lower tier must override catalogue MAX-quality claims in
          // Search, but must be labelled as requested until the audio was
          // actually probed. Deezer's current add-on has one FLAC-only tier.
          final configured = settings['downloadQuality'] as String?;
          final tidal = addon.name.toLowerCase().contains('tidal') ||
              addon.key.toLowerCase().contains('tidal');
          final requestedQuality = tidal
              ? tidalRequestedQualityLabel(
                  configured: configured, options: addon.qualityOptions)
              : null;
          // A configured tier is not proof of the rendered stream's quality.
          // Retain Tidal's *per-track catalogue availability* regardless of
          // the selected quality; Search labels it as catalogue data, not
          // verified playback. Suppressing these fields broke first-search
          // Tidal tags until a song had been played.
          // This fingerprint is the same one used for the verified playback
          // cache. Another account, requested tier or add-on version cannot
          // borrow a different recording's quality badge.
          final fingerprint = sha256
              .convert(utf8.encode(jsonEncode(settings)))
              .toString();
          final results = <OnlineResult>[];
          for (final song in found) {
            final key = morneyePlaybackCacheKey(
              addonKey: addon.key,
              addonDigest: addon.digest,
              trackId: song.id,
              settingsFingerprint: fingerprint,
              requestedTier: '',
            );
            final cached = _morneyeReadyPlayback[key];
            final verified = cached != null &&
                cached.filePath != null &&
                File(cached.filePath!).existsSync()
                ? cached : null;
            final details = morneyeSearchAudioDetails(
              // Previously probed audio takes precedence over catalogue
              // maximums. Otherwise preserve provider-advertised measurements
              // even when the requested rendition may be lower.
              codec: verified != null ? null : song.codec,
              bitDepth: verified != null ? null : song.bitDepth,
              sampleRate: verified != null ? null : song.sampleRate,
              verifiedPlayback: verified,
            );
            results.add(OnlineResult(DiscoveryTrack(
              id: song.id,
              title: song.title,
              artist: song.artist,
              album: song.album,
              duration: song.duration,
              source: DiscoverySource.morneye,
              addonId: addon.key,
              sourceName: addon.displayName,
              artwork: song.thumbnail,
              atmosAvailable: song.atmosAvailable,
              // Tidal's search metadata describes catalogue availability,
              // while requestedQuality describes the user's download option.
              // Both must survive to the badge formatter so it can distinguish
              // them without pretending to have probed the audio file.
              catalogueQuality: verified != null
                  ? verified.resolution
                  : morneyeAdvertisedQuality(song.quality),
              requestedQuality: verified == null ? requestedQuality : null,
              catalogueCodec: details.codec,
              catalogueBitDepth: details.bitDepth,
              catalogueSampleRate: details.sampleRate,
            )));
          }
          return results;
        },
        play: (found) async {
          final progress = MorneyeProgressText(found.title, addon.displayName);
          final qobuz = addon.name.toLowerCase().contains('qobuz');
          final tidal = addon.name.toLowerCase().contains('tidal');
          final deezer = addon.name.toLowerCase().startsWith('deezer');
          final byteProgressSource = qobuz || tidal || deezer;
          double? actualTransferPercent;
          var segmentedProgress = false;
          var finished = false;
          MorneyeDownload download;
          // Normal Play stays on the provider's configured stereo/lossless
          // tier. Only an explicit user request opts in to E-AC-3 JOC.
          if (found.atmosAvailable || found.atmosRequested) {
            AtmosDiagnostics.record('request', {
              'source': 'morneye',
              'requested': found.atmosRequested,
              'downloadOnly': found.atmosDownload,
              'available': found.atmosAvailable,
              'mode': found.atmosRequested ? 'atmos' : 'normal',
            });
          }
          if (found.atmosRequested && !found.atmosAvailable) {
            AtmosDiagnostics.record('request_rejected', {'reason': 'catalogue_not_atmos'});
            throw const DiscoveryException('This track has no advertised Atmos version.');
          }
          final tryAtmos = found.atmosRequested;
          final explicitTier = explicitMorneyePlaybackTier(atmosRequested: tryAtmos);
          final requestedTier = explicitTier ?? '';
          final cacheKey = morneyePlaybackCacheKey(
            addonKey: addon.key,
            addonDigest: addon.digest,
            trackId: found.id,
            settingsFingerprint:
                sha256.convert(utf8.encode(jsonEncode(packages.settings(addon)))).toString(),
            requestedTier: requestedTier,
          );
          if (!forDownload && !found.atmosDownload) {
            final cached = _morneyeReadyPlayback[cacheKey];
            if (cached != null) {
              final path = cached.filePath;
              if (path != null &&
                  File(path).existsSync() &&
                  File(path).lengthSync() > 0) {
                return cached;
              }
            }
            _morneyeReadyPlayback.remove(cacheKey);
          }
          // Direct, verified FLAC (including Tidal and Amazon), or a
          // complete-header, unencrypted fast-start M4A may start from the
          // host's growing media file. DASH segments, encrypted Amazon
          // containers and conversions are not exposed as live sources.
          // Explicit Save/Atmos still require full-file validation.
          final live = !forDownload && !tryAtmos &&
                  !found.atmosDownload &&
                  morneyeCanPlayWhileDownloading(addon.name)
              ? MorneyeLiveSession()
              : null;
          if (tryAtmos && !found.atmosDownload && !await AtmosPlaybackSupport.available) {
            AtmosDiagnostics.record('request_rejected', {'reason': 'decoder_unavailable'});
            throw const DiscoveryException(
              'This Android device does not report an E-AC-3 JOC decoder or direct Atmos output. No stereo track was substituted.',
            );
          }
          try {
            Future<MorneyeDownload> fetch({String? quality}) =>
                packages.download(
                  addon.key,
                  found.id,
                  quality: quality,
                  forPlayback: !forDownload && !found.atmosDownload,
                  trackHint: morneyeSelectedTrackHint(
                    id: found.id,
                    title: found.title,
                    artist: found.artist,
                    durationMs: found.duration?.inMilliseconds,
                  ),
                  onResolutionStage: (stage) {
                    if (finished) return;
                    final detail = switch (stage) {
                      'initializing' => 'Starting',
                      'metadata' => 'Checking metadata on',
                      'availability' => 'Verifying recording on',
                      'cross_provider_enrichment' => 'Matching recording on',
                      'availability_retry' => 'Checking matched recording on',
                      'preparing_media' => 'Fetching audio from',
                      _ => 'Preparing',
                    };
                    onStatus?.call('${detail} ${addon.displayName}…');
                  },
                  // Even an explicit Qobuz Save (live == null) needs the
                  // host's measured byte progress. The guest's initial 5%
                  // only means its download ticket is being resolved.
                  onTransfer: live == null && !byteProgressSource ? null : (transfer) {
                    live?.observe(transfer);
                    // Qobuz's extension emits 5% during URL/ticket
                    // resolution. Only host-observed bytes are transfer
                    // progress; they must supersede guest progress numbers.
                    if (byteProgressSource && !finished && !segmentedProgress &&
                        transfer.total > 0 &&
                        transfer.written > 0) {
                      actualTransferPercent =
                          (transfer.written * 100 / transfer.total)
                              .clamp(0.0, 100.0).toDouble();
                      final text = progress.update(
                        percent: actualTransferPercent,
                        message: forDownload ? 'Downloading audio…' : 'Receiving audio…',
                      );
                      if (text != null) onStatus?.call(text);
                    }
                  },
                  onProgress: ({percent, message}) {
                    if (finished) return;
                    if (byteProgressSource) {
                      if (message == 'Downloading audio segments…') {
                        segmentedProgress = true;
                        // Host-observed completed segments, not a guess.
                        final text = progress.update(
                          percent: percent, message: message,
                        );
                        if (text != null) onStatus?.call(text);
                      } else if (actualTransferPercent == null &&
                                 !segmentedProgress) {
                        // The extension's initial 5% is a resolver stage.
                        // Once real segments start, ignore guest status/%
                        // callbacks so there is only one stable toast.
                        final text = progress.update(
                          message: qobuz
                              ? 'Connecting to Qobuz audio…'
                              : tidal
                                  ? 'Downloading Tidal audio…'
                                  : 'Downloading Deezer audio…',
                        );
                        if (text != null) onStatus?.call(text);
                      }
                      return;
                    }
                    final text = progress.update(
                      percent: percent, message: message,
                    );
                    if (text != null) onStatus?.call(text);
                  },
              cancel: cancel,
            );
            try {
              if (tryAtmos) AtmosDiagnostics.record('download_start', {
                'quality': 'DOLBY_ATMOS',
                'downloadOnly': found.atmosDownload,
              });
              final transfer = fetch(
                quality: explicitTier,
              );
              // Race verified progressive readability against completed
              // playback preparation; preserve early playback for direct
              // Tidal/Amazon sources without risking the MPD/decrypt paths.
              final canStream = live != null && await Future.any<bool>([
                live.playable.then((_) => true),
                transfer.then((_) => false),
              ]);
              if (canStream) {
                final session = live!;
                final handle = MorneyeLiveRegistry.instance.register(session);
                // Retain the transfer after Now Playing starts. Adoption,
                // validation and staging cleanup stay asynchronous, while
                // late failures propagate to the ranged audio reader.
                unawaited(
                  transfer.then((completed) async {
                    try {
                      // A CDN can report a misleading HEAD length for
                      // segments. Never promote a decoder that was given a
                      // different sourceLength than the actual assembled file.
                      final actualLength = await completed.file.length();
                      final lengthMatches = actualLength == session.total;
                      // Always validate and adopt the *complete* rendition.
                      // A misleading CDN total must not lose a playable,
                      // correctly probed download when the early reader fails.
                      final cached = await cache().adopt(
                        found, completed.file, sourceInfo: completed.info,
                      );
                      final path = cached.filePath;
                      if (path == null) {
                        throw StateError('Completed audio has no cache path');
                      }
                      _rememberMorneyePlayback(cacheKey, cached);
                      QueuePreResolver.shared.schedule();
                      if (lengthMatches) {
                        session.promote(path);
                      } else {
                        // Media3 already knows the original length, so the
                        // growing reader cannot safely change its response
                        // size. Stop using it, then hand the verified complete
                        // cache to the same logical queue entry. Keep both the
                        // position and the current playback/pause preference.
                        session.fail(StateError('Live media size changed during transfer'));
                        final player = PlayerService();
                        final liveSongId =
                            'discovery:${found.key.hashCode}:morneye-live';
                        if (player.currentSongNotifier.value?.id == liveSongId) {
                          final position = player.positionNotifier.value;
                          final wasPlaying = player.isPlayingNotifier.value;
                          final replacement = cached.copyWith(
                            id: liveSongId,
                            sourceDisplayName: addon.displayName,
                            fileSizeBytes: actualLength,
                          );
                          // Same song id => play() replaces its audio source
                          // in the existing playlist, without dropping Up Next.
                          await player.play(replacement);
                          if (player.currentSongNotifier.value?.id == liveSongId) {
                            if (position > Duration.zero) {
                              await player.seek(position);
                            }
                            if (!wasPlaying) await player.pause();
                          }
                        }
                        onStatus?.call('Stream metadata changed; switched to complete audio');
                      }
                    } catch (error) {
                      session.fail(error);
                      QueuePreResolver.shared.schedule();
                    } finally {
                      await completed.cleanup();
                    }
                  }).catchError((Object error, StackTrace stack) {
                    session.fail(error);
                    QueuePreResolver.shared.schedule();
                  }),
                );
                onStatus?.call('Streaming ${found.title} from ${addon.displayName}…');
                return Song(
                  id: 'discovery:${found.key.hashCode}:morneye-live',
                  title: found.title,
                  artist: found.artist,
                  album: found.album,
                  albumArt: found.artwork,
                  duration: found.duration ?? Duration.zero,
                  fileType: session.fileType ?? 'ONLINE',
                  // Verified FLAC or fast-start MP4; show bit depth/rate only
                  // when they were measured from the actual FLAC header. Use
                  // STREAMINFO measurements; the provider's catalogue maximum
                  // can be 24-bit even when LOW/LOSSLESS was selected.
                  bitDepth: session.bitDepth,
                  sampleRate: session.sampleRate,
                  filePath: handle,
                  sourcePackage: 'konnekted.morneye-live',
                  sourceDisplayName: addon.displayName,
                  fileSizeBytes: session.total > 0 ? session.total : null,
                  remoteId: found.id,
                  isExternal: true,
                );
              }
              download = await transfer;
              if (tryAtmos) {
                AtmosDiagnostics.record('download_complete', {
                  'quality': 'DOLBY_ATMOS',
                  'encoded': download.atmosEncoded,
                  'outcome': download.atmosEncoded ? 'joc_confirmed' : 'not_joc',
                });
              }
              if (tryAtmos && !download.atmosEncoded) {
                // The provider returned an ordinary recording. Discard the
                // staged copy before rejecting the explicitly requested tier.
                await download.cleanup();
                throw const DiscoveryException(
                  'Lokal could not verify the downloaded source as E-AC-3 JOC Dolby Atmos. No stereo track was substituted. Check Atmos diagnostics.',
                );
              }
            } catch (error) {
              final reason = error.toString();
              if (tryAtmos || found.atmosAvailable) {
                AtmosDiagnostics.record('download_error', {
                  'errorClass': error.runtimeType.toString(),
                  'reason': tidalAtmosTransportFailure(reason)
                      ? 'network_failure'
                      : tidalAtmosTierUnavailable(reason)
                          ? 'tier_unavailable'
                          : 'download_or_probe_failure',
                });
              }
              // An addon can request Atmos from its own settings even when
              // this device did not enable the native JOC path. Do not rely
              // on tryAtmos alone to classify a failed Atmos API request.
              if (tidalAtmosTransportFailure(reason) &&
                  (tryAtmos || tidalAtmosErrorMentionsMode(reason))) {
                throw DiscoveryException(tidalAtmosTransportMessage(reason));
              }
              if (tryAtmos) {
                if (error is DiscoveryException) rethrow;
                final rejectedProbe = error is MorneyePackageError &&
                    error.message.startsWith('The requested Atmos source');
                throw DiscoveryException(
                  rejectedProbe
                      ? 'The requested Dolby Atmos stream was not verified as E-AC-3 JOC. Check Atmos diagnostics for the actual codec and probe result. No stereo track was substituted.'
                      : tidalAtmosTierUnavailable(reason)
                          ? 'This source has no downloadable Atmos stream for this track. No stereo track was substituted.'
                          : 'Atmos download failed. No stereo track was substituted.',
                );
              }
              rethrow;
            }
          } on MorneyePackageError catch (error) {
            final detail = error.message;
            throw DiscoveryException(
              tidalAtmosTransportFailure(detail) &&
                      tidalAtmosErrorMentionsMode(detail)
                  ? tidalAtmosTransportMessage(detail)
                  : detail,
            );
          } on MorneyeRuntimeError catch (error) {
            final detail = error.toString();
            throw DiscoveryException(
              tidalAtmosTransportFailure(detail) &&
                      tidalAtmosErrorMentionsMode(detail)
                  ? tidalAtmosTransportMessage(detail)
                  : detail,
            );
          } on DiscoveryException {
            rethrow;
          } catch (_) {
            // Network drops, stalls and file errors: this source failed, so
            // the next one can be tried.
            throw DiscoveryException(
              '${addon.displayName} couldn’t download ${found.title}. '
              'Check your connection and try again.',
            );
          } finally {
            finished = true;
          }
          try {
            if (tryAtmos) AtmosDiagnostics.record('cache_adopt_start', {
              'encoded': download.atmosEncoded,
              'mode': found.atmosDownload ? 'download' : 'playback',
            });
            final adopted = await cache().adopt(
              found,
              download.file,
              atmosEncoded: download.atmosEncoded,
              sourceInfo: download.info,
            );
            if (tryAtmos) AtmosDiagnostics.record('cache_adopt_done', {
              'encoded': adopted.atmosEncoded,
              'outcome': 'ready',
            });
            if (!forDownload && !found.atmosDownload) {
              _rememberMorneyePlayback(cacheKey, adopted);
            }
            return adopted;
          } catch (error) {
            if (tryAtmos) AtmosDiagnostics.record('cache_adopt_error', {
              'errorClass': error.runtimeType.toString(),
              'reason': 'cache_failure',
            });
            rethrow;
          } finally {
            await download.cleanup();
          }
        },
      ),
  ];
}

/// Detects explicit Atmos requests even if no local native JOC decoder
/// was selected (e.g. user-configured download quality in an addon).
bool tidalAtmosErrorMentionsMode(String message) =>
    RegExp(r'DOLBY[_ -]?ATMOS|EAC3[_ -]?JOC|Tidal Atmos',
      caseSensitive: false).hasMatch(message);

/// A remote network fault is not proof that the catalogue's Atmos edition is
/// missing. All error paths must use the same concise, non-sensitive message.
bool tidalAtmosTransportFailure(String message) =>
    RegExp(r'HTTP\s*5\d\d|TimeoutException|timed?\s*out|SocketException|without confirmation',
      caseSensitive: false).hasMatch(message);

/// Only a deterministic response permits a stereo fallback. Unknown errors,
/// repeated 502s, expired tickets and verification failures remain errors.
bool tidalAtmosTierUnavailable(String message) =>
    RegExp(r'QUALITY_UNAVAILABLE|QUALITY_NOT_AVAILABLE|CODEC_UNAVAILABLE|TIDAL API did not report EAC3_JOC|returned lower tier than requested',
      caseSensitive: false).hasMatch(message);

String tidalAtmosTransportMessage(String message) {
  final status = RegExp(r'HTTP\s*(5\d\d)', caseSensitive: false)
      .firstMatch(message)?.group(1);
  if (status != null) {
    return 'Tidal Atmos unavailable: download service HTTP $status. '
        'No Atmos stream was received. Retry later.';
  }
  if (RegExp(r'TimeoutException|timed?\s*out',
          caseSensitive: false).hasMatch(message)) {
    return 'Tidal Atmos unavailable: download service timed out. '
        'No Atmos stream was received. Retry later.';
  }
  return 'Tidal Atmos unavailable: download service failed. '
      'No Atmos stream was received. Retry later.';
}

/// One line of an add-on's download progress, "Getting Song from Qobuz…
/// 42%", said only when it changes: percentages come several times a
/// second, and the add-on's own status words ("Qobuz loading…") replace
/// the percentage instead of being repeated after it.
class MorneyeProgressText {
  MorneyeProgressText(this.title, this.source);

  final String title;
  final String source;
  String? _said;
  int? _percent;

  /// The line to show now, or null when it says what was said already.
  String? update({double? percent, String? message}) {
    if (percent != null && percent.isFinite && percent >= 0) {
      final measured = percent.clamp(0, 100).round();
      _percent = _percent == null || measured > _percent! ? measured : _percent;
    }
    final words = message?.trim() ?? '';
    final prefix = 'Getting $title from $source…';
    final percentText = _percent == null ? '' : ' $_percent%';
    final RegExp numbered = RegExp(r'\d+(\.\d+)?\s*%');
    // An add-on may keep emitting its initial 5% even after host transfer
    // bytes/segments advance. Prefer the highest measured progress instead
    // of letting a stale guest message jump the toast backwards.
    final normalizedWords = _percent == null ? words
        : words.replaceAllMapped(numbered, (_) => '${_percent!}%');
    final text = words.isEmpty
        ? (_percent == null ? prefix : '$prefix$percentText')
        : numbered.hasMatch(normalizedWords)
        ? '$prefix ${normalizedWords.replaceAll(RegExp(r'\s+'), ' ')}'
        : '$prefix ${normalizedWords.replaceAll(RegExp(r'\s+'), ' ')}$percentText';
    if (text == _said) return null;
    _said = text;
    return text;
  }
}

/// Where found songs are kept while they play; never deletes what's queued.
DiscoveryPlaybackCache _playbackCache(
  DiscoveryHttp web,
  Set<String> Function()? additionalProtectedPaths,
) => DiscoveryPlaybackCache(
  http: web,
  protectedPaths: () {
    final player = PlayerService();
    return {
      if (player.currentSongNotifier.value?.filePath case final String path)
        path,
      ...player.queue.map((s) => s.filePath).whereType<String>(),
      ...player.upNext.map((s) => s.filePath).whereType<String>(),
      ...(additionalProtectedPaths?.call() ?? const <String>{}),
    };
  },
);

/// YouTube Music, then your web add-ons, then your Morneye add-ons:
/// desktop's order.
/// HTTP add-ons provide an independently authorized progressive HTTPS URL.
/// Pass it directly to Android Media3. Unlike download-only Morneye sources,
/// no full-file staging or format probe is needed before the first audio
/// frame. Never store signed URLs in a queue or persistence layer.
Song progressiveAddonSong(DiscoveryTrack track, ResolvedDiscoveryAudio audio) {
  final handle = DiscoveryProgressiveStreams.instance.register(audio.url);
  final artwork = track.artwork;
  final ext = audio.url.pathSegments.isEmpty
      ? '' : audio.url.pathSegments.last.split('.').last.toLowerCase();
  final extension = const {
    'flac': 'FLAC', 'mp3': 'MP3', 'm4a': 'ALAC',
    'aac': 'AAC', 'ogg': 'OGG', 'opus': 'OPUS',
    'wav': 'WAV', 'webm': 'OPUS',
  }[ext];
  // Never combine a selected low-quality stream's few metadata fields with
  // a 24/96 catalogue maximum from a different rendition. When the resolver
  // reports any rendition detail, its missing fields must remain unknown.
  final hasRenditionDetails = audio.codec != null ||
      audio.quality != null ||
      audio.bitDepth != null ||
      audio.sampleRate != null;
  final audioInfo = advertisedOnlineAudio(
    codec: hasRenditionDetails ? audio.codec : track.catalogueCodec,
    quality: hasRenditionDetails ? audio.quality : track.catalogueQuality,
    bitDepth: hasRenditionDetails ? audio.bitDepth : track.catalogueBitDepth,
    sampleRate: hasRenditionDetails ? audio.sampleRate : track.catalogueSampleRate,
    // A filename suffix is only a container hint; M4A and WebM may hold
    // different codecs, so do not invent ALAC/OPUS from those extensions.
    fallbackFileType: (ext == 'm4a' || ext == 'webm')
        ? 'ONLINE' : (extension ?? 'ONLINE'),
  );
  return Song(
    id: 'discovery:${track.key.hashCode}:progressive',
    title: track.title,
    artist: track.artist,
    album: track.album,
    albumArt: artwork,
    duration: track.duration ?? Duration.zero,
    fileType: audioInfo.fileType,
    resolution: audioInfo.resolution,
    bitDepth: audioInfo.bitDepth,
    sampleRate: audioInfo.sampleRate,
    filePath: handle,
    sourcePackage: 'konnekted.progressive',
    sourceDisplayName: track.sourceName,
    fileSizeBytes: audio.length,
    remoteId: track.id,
    isExternal: true,
  );
}

Future<List<OnlineSource>> _playbackSources(
  DiscoveryHttp web,
  DiscoverySettings settings,
  DiscoveryPlaybackCache Function() cache,
  void Function(String status)? onStatus,
  MorneyeService morneye, {
  Future<void>? cancel,
  bool forDownload = false,
  bool includeMorneye = true,
  String? selectedSourceId,
  bool respectEnabledDiscoverySources = false,
}) async {
  final registry = DiscoverySourceRegistry(web, settings);
  final youtube = YoutubeAudio(web);
  // Automatic Discovery should not resurrect native sources behind the
  // listener's back when their only enabled source is an HTTP add-on.
  // Explicit online Search selections still have access to native sources.
  final httpOnly = respectEnabledDiscoverySources &&
      settings.activeAddons.isNotEmpty && !settings.youtubeEnabled;
  final legacyLabels = <String, String>{};
  for (final addon in registry.addons) {
    if (registry.addons.where((other) =>
        other.displayName == addon.displayName).length == 1) {
      legacyLabels['w-${addon.displayName}'] = 'w-${addon.configId}';
    }
  }
  return PlaybackSourcePriority.order([
    if (!httpOnly && (selectedSourceId == null || selectedSourceId == 'yt'))
    OnlineSource(
      id: 'yt',
      name: 'YouTube Music',
      results: (query) async => [
        for (final track in await YoutubeMusicCatalog(web).search(query))
          OnlineResult(track, artwork: track.artwork),
      ],
      play: (found) => youtube.prepare(found, cache(), cancel: cancel),
    ),
    // Independent native source, without any add-on installation or credentials.
    if (!httpOnly && (selectedSourceId == null || selectedSourceId == 'mono'))
    OnlineSource(
      id: 'mono',
      name: 'Monochrome',
      results: (query) async => [
        for (final track in await MonochromeSource.search(web, query))
          OnlineResult(track, artwork: track.artwork),
      ],
      play: (found) async {
        onStatus?.call('Connecting to Monochrome…');
        final audio = MonochromeSource.resolve(found);
        if (forDownload) {
          return cache().prepare(found, audio, cancel: cancel,
            onProgress: (received) {
              if (audio.length case final total? when total > 0) {
                onStatus?.call('Downloading from Monochrome… ${(received * 100 / total).clamp(0, 100).round()}%');
              } else {
                onStatus?.call('Downloading from Monochrome…');
              }
            },
          );
        }
        onStatus?.call('Buffering from Monochrome…');
        return progressiveAddonSong(found, audio);
      },
    ),
    // Built-in SoundCloud source: no HTTP addon or Morneye installation.
    if (!httpOnly && (selectedSourceId == null || selectedSourceId == 'sc'))
    OnlineSource(
      id: 'sc',
      name: 'SoundCloud',
      results: (query) async => [
        for (final track in await SoundCloudSource(web).search(query))
          OnlineResult(track, artwork: track.artwork),
      ],
      play: (found) async {
        onStatus?.call('Connecting to SoundCloud…');
        final audio = await SoundCloudSource(web).resolve(
          found, forDownload: forDownload,
        );
        if (forDownload) {
          onStatus?.call('Downloading from SoundCloud…');
          return cache().prepare(found, audio, cancel: cancel);
        }
        onStatus?.call('Buffering from SoundCloud…');
        return progressiveAddonSong(found, audio);
      },
    ),
    for (final addon in registry.addons)
      if (selectedSourceId == null || selectedSourceId == 'w-${addon.configId}')
      OnlineSource(
        id: 'w-${addon.configId}',
        name: addon.displayName,
        addon: true,
        results: (query) async => [
          for (final track in await addon.search(query))
            OnlineResult(track, artwork: track.artwork),
        ],
        play: (found) async {
          onStatus?.call('Connecting to ${addon.displayName}…');
          final audio = await registry.resolve(
            found, cancel: cancel, forDownload: forDownload,
          );
          if (forDownload) {
            return cache().prepare(
              found, audio, cancel: cancel,
              onProgress: (received) {
                if (audio.length case final total? when total > 0) {
                  onStatus?.call('Downloading from ${addon.displayName}… '
                      '${(received * 100 / total).clamp(0, 100).round()}%');
                } else {
                  onStatus?.call('Downloading from ${addon.displayName}…');
                }
              },
            );
          }
          final song = progressiveAddonSong(found, audio);
          onStatus?.call('Buffering from ${addon.displayName}…');
          return song;
        },
      ),
    if (includeMorneye)
      ...await _morneyeSources(morneye, cache, onStatus,
        cancel: cancel, forDownload: forDownload,
        selectedSourceId: selectedSourceId),
  ], (source) => source.id, aliases: legacyLabels,
    ecoOnCellular: respectEnabledDiscoverySources && selectedSourceId == null);
}

/// The sources Search offers for songs you don't have. [onStatus] hears
/// download progress; [client] stays open until the caller closes it.
Future<List<OnlineSource>> onlineSources(
  http.Client client, {
  void Function(String status)? onStatus,
  DiscoverySettingsStore? store,
  MorneyeService? morneye,
}) async {
  var settings = const DiscoverySettings();
  try {
    settings = await (store ?? DiscoverySettingsStore()).load();
  } catch (_) {
    // Unreadable add-on settings still leave YouTube Music.
  }
  final web = DiscoveryHttp(client);
  return _playbackSources(
    web,
    settings,
    () => _playbackCache(web, null),
    onStatus,
    morneye ?? MorneyeService.instance,
  );
}

/// Preserve source pinning when a legacy queued HTTP ID used a mutable name.
String _canonicalOnlineSourceId(String sourceId, DiscoveryTrack track) {
  if (!sourceId.startsWith('w-') ||
      track.source != DiscoverySource.addon ||
      track.addonId == null) {
    return sourceId;
  }
  final stable = 'w-' + track.addonId!;
  final legacy = track.sourceName == null ? null : 'w-' + track.sourceName!;
  return sourceId == stable || sourceId == legacy ? stable : sourceId;
}

/// Classify without logging signed audio URLs or provider credentials.
String _onlineFailureKind(Object error) {
  final message = error.toString().toLowerCase();
  final status = RegExp(r'http\s+(401|403|404|408|429|500|502|503|504)')
      .firstMatch(message);
  if (status != null) return 'http_${status.group(1)}';
  if (message.contains('timeout') || message.contains('timed out')) {
    return 'timeout';
  }
  if (message.contains('cancelled') || message.contains('canceled')) {
    return 'cancelled';
  }
  if (message.contains('auth') || message.contains('token')) {
    return 'authorization';
  }
  if (message.contains('verify')) return 'verification';
  if (message.contains('network') || message.contains('connection')) {
    return 'network';
  }
  return error.runtimeType.toString();
}

/// Gets [track], found earlier on the source [sourceId] (an [OnlineSource.id]),
/// ready to play, with its own connection so it outlives the Search page:
/// for a song queued from Search or saved to the library. [onStatus] hears
/// an add-on's progress; once [cancel] completes an add-on's download stops.
Future<Song> playOnlineTrack(
  String sourceId,
  DiscoveryTrack track, {
  void Function(String status)? onStatus,
  Future<void>? cancel,
  Set<String> Function()? additionalProtectedPaths,
  DiscoverySettingsStore? store,
  MorneyeService? morneye,
  http.Client? client,
  bool forDownload = false,
}) async {
  var settings = const DiscoverySettings();
  // The chosen native YouTube or Morneye source has no dependency on HTTP
  // addon settings. Avoid storage I/O on the time-critical playback path.
  if (sourceId.startsWith('w-')) {
    try {
      settings = await (store ?? DiscoverySettingsStore()).load();
    } catch (_) {
      // Missing/disabled sources are reported by source resolution.
    }
  }
  final owned = client == null;
  final transport = client ?? GracefulHttpClient();
  try {
    final web = DiscoveryHttp(transport);
    final canonicalId = _canonicalOnlineSourceId(sourceId, track);
    final sources = await _playbackSources(
      web,
      settings,
      () => _playbackCache(web, additionalProtectedPaths),
      onStatus,
      morneye ?? MorneyeService.instance,
      cancel: cancel,
      forDownload: forDownload,
      // HTTP playback never waits for unrelated Morneye initialization.
      includeMorneye: canonicalId.startsWith('a-'),
      selectedSourceId: canonicalId,
    );
    final source = sources.where((s) => s.id == canonicalId).firstOrNull;
    if (source == null) {
      throw DiscoveryException(
        '${track.sourceName ?? 'That source'} isn’t available any more.',
      );
    }
    final resolved = await source.play(track);
    final song = resolved.copyWith(sourceDisplayName: source.name);
    if (!forDownload && sourceId.startsWith('a-')) {
      _rememberOnlineAddon(song, sourceId.substring(2), track);
    }
    if (!forDownload) {
      OnlineSongSaveRegistry.instance.register(
        song,
        () => playOnlineTrack(sourceId, track, forDownload: true),
      );
    }
    return song;
  } catch (error) {
    AppLog.instance.add(
      '[OnlineSource] playback failed source=$sourceId '
      'stage=prepare reason=${_onlineFailureKind(error)}',
    );
    rethrow;
  } finally {
    if (owned) transport.close();
  }
}

/// A queue placeholder for [track], a Search result from [sourceId]: got
/// ready ahead of its turn by the [QueuePreResolver], like Discovery's picks.
Song onlinePendingSong(
  String sourceId,
  DiscoveryTrack track, {
  QueuePreResolver? resolver,
}) {
  final queue = resolver ?? QueuePreResolver.shared;
  final pending = queue.pending(
    key: 'online:$sourceId:${track.key}',
    title: track.title,
    artist: track.artist,
    album: track.album,
    duration: track.duration,
    resolve: ({onStatus, cancel}) => playOnlineTrack(
      sourceId,
      track,
      onStatus: onStatus,
      cancel: cancel,
      additionalProtectedPaths: () => queue.resolvedPaths,
    ),
  );
  OnlineSongSaveRegistry.instance.register(
    pending,
    () => playOnlineTrack(sourceId, track, forDownload: true),
  );
  return pending;
}

/// Query the current provider first, then hedge alternate artist/title forms
/// when its primary HTTP/native search is slow. A verified match can be used
/// without waiting for an unrelated slow search to return. Provider priority,
/// recording/artist matching and explicit source selection are unchanged.
/// Morneye add-ons execute guest calls serially, so do not queue competing
/// search calls behind their in-flight native runtime.
Future<DiscoveryTrack?> findDiscoverySourceMatch({
  required OnlineSource source,
  required RecommendationCandidate candidate,
  required List<String> queries,
  void Function()? checkCancelled,
  Duration hedgeDelay = const Duration(milliseconds: 600),
}) async {
  Future<DiscoveryTrack?> search(String query) async {
    checkCancelled?.call();
    try {
      final results = await source.search(query);
      checkCancelled?.call();
      return recommendationMatch(
        candidate,
        results,
        (result) => RecommendationCandidate(
          title: result.title,
          artist: result.artist,
          album: result.album,
          duration: result.duration,
        ),
      );
    } catch (error) {
      // A failed alternate query is not a source failure. Propagate a
      // cancellation even if a search completed at the same instant.
      checkCancelled?.call();
      AppLog.instance.add(
        '[OnlineSource] search failed source=${source.id} '
        'reason=${_onlineFailureKind(error)}',
      );
      return null;
    }
  }

  if (queries.isEmpty) return null;
  if (queries.length == 1 || source.id.startsWith('a-')) {
    // Keep serial Morneye calls on one worker and prioritize the original
    // query, without a new timeout or a flood of concurrent guest requests.
    final first = await search(queries.first);
    if (first != null || queries.length == 1) return first;
    final fallbacks = await Future.wait(queries.skip(1).take(2).map(search));
    checkCancelled?.call();
    for (final matched in fallbacks) {
      if (matched != null) return matched;
    }
    return null;
  }

  final completion = Completer<DiscoveryTrack?>();
  var inFlight = 0;
  var alternatesStarted = false;
  late void Function() startAlternates;

  void completeMatch(DiscoveryTrack? matched) {
    inFlight--;
    if (completion.isCompleted) return;
    if (matched != null) {
      completion.complete(matched);
    } else if (!alternatesStarted) {
      // A fast authoritative miss should immediately start alternatives.
      startAlternates();
    } else if (inFlight == 0) {
      completion.complete(null);
    }
  }

  void launch(String query) {
    inFlight++;
    unawaited(search(query).then(
      completeMatch,
      onError: (Object error, StackTrace stack) {
        inFlight--;
        if (!completion.isCompleted) {
          completion.completeError(error, stack);
        }
      },
    ));
  }

  startAlternates = () {
    if (alternatesStarted || completion.isCompleted) return;
    alternatesStarted = true;
    for (final query in queries.skip(1).take(2)) {
      launch(query);
    }
    if (inFlight == 0 && !completion.isCompleted) completion.complete(null);
  };
  launch(queries.first);
  // Hedging is not a deadline: the primary keeps working and may still win.
  // Launch at most two alternate *metadata* searches, never extra audio
  // downloads or fallback to another selected playback provider.
  unawaited(Future<void>.delayed(hedgeDelay).then((_) => startAlternates()));
  return completion.future;
}

/// Finds [track] somewhere to play it and downloads it, as desktop does for
/// songs you don't own: YouTube Music first (desktop's default order), then
/// your add-ons. Null when none has it. [onStatus] hears what's happening;
/// once [cancel] completes the search stops and an add-on's download with it.
Future<Song?> findDiscoverySong(
  LokalDiscoveryTrack track, {
  void Function(String status)? onStatus,
  DiscoverySettingsStore? store,
  http.Client? client,
  Set<String> Function()? additionalProtectedPaths,
  MorneyeService? morneye,
  Future<void>? cancel,
  bool Function()? mayRequestVerification,
}) async {
  var cancelled = false;
  if (cancel != null) unawaited(cancel.then((_) => cancelled = true));
  void check() {
    if (cancelled) throw const DiscoveryException('Request cancelled.');
  }

  var settings = const DiscoverySettings();
  try {
    settings = await (store ?? DiscoverySettingsStore()).load();
  } catch (_) {
    // Unreadable add-on settings still leave YouTube Music.
  }
  final owned = client == null;
  final transport = client ?? GracefulHttpClient();
  try {
    final web = DiscoveryHttp(transport);
    final youtube = YoutubeAudio(web);
    DiscoveryException? failure;
    DiscoveryPlaybackCache cache() =>
        _playbackCache(web, additionalProtectedPaths);
    final sources = await _playbackSources(
      web,
      settings,
      cache,
      onStatus,
      morneye ?? MorneyeService.instance,
      cancel: cancel,
      respectEnabledDiscoverySources: true,
    );
    final candidate = discoveryCandidate(track);
    final queries = recommendationQueries(candidate).take(3).toList();
    for (final source in sources) {
      check();
      if (source.needsVerification?.call() == true) {
        // Preloads must not open an auth popup over an unrelated screen.
        // Once current, await user verification instead of skipping the Mix.
        if (mayRequestVerification?.call() == false) {
          throw DiscoveryVerificationRequired(source.name);
        }
        onStatus?.call('Verify ${source.name} to continue ${track.title}…');
        final verified = await playbackSourceVerification?.call(source) ?? false;
        check();
        if (!verified || source.needsVerification?.call() == true) {
          throw DiscoveryVerificationRequired(source.name);
        }
      }
      if (source.id == 'yt' && track.videoId != null) {
        final videoId = track.videoId!;
        onStatus?.call('Getting ${track.title} directly from YouTube Music…');
        try {
          final direct = DiscoveryTrack(
            id: videoId,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            source: DiscoverySource.youtubeMusic,
            sourceUrl: Uri.tryParse(track.url),
            artwork: _artworkOf(track),
          );
          final resolved = await youtube.prepare(
            direct,
            _playbackCache(web, additionalProtectedPaths),
            cancel: cancel,
          );
          final song = resolved.copyWith(sourceDisplayName: 'YouTube Music');
          OnlineSongSaveRegistry.instance.register(
            song,
            () => playOnlineTrack('yt', direct, forDownload: true),
          );
          return song;
        } on DiscoveryException catch (error) {
          check();
          if (error.message == 'Request cancelled.') rethrow;
          AppLog.instance.add(
            '[OnlineSource] direct YouTube failed '
            'reason=${_onlineFailureKind(error)}',
          );
          // Public videos can be refused by one YouTube client as it rotates.
          // Try the other configured sources rather than treating the first
          // player response as proof the recording is unavailable in this region.
          failure = error;
          onStatus?.call(
            'YouTube Music could not start ${track.title}. Trying another source…',
          );
        } catch (error) {
          check();
          AppLog.instance.add(
            '[OnlineSource] direct YouTube failed '
            'reason=${_onlineFailureKind(error)}',
          );
          failure = const DiscoveryException(
            'YouTube Music could not resolve this recording. Trying another source.',
          );
          onStatus?.call(
            'YouTube Music could not start ${track.title}. Trying another source…',
          );
        }
      }
      check();
      final found = await findDiscoverySourceMatch(
        source: source,
        candidate: candidate,
        queries: queries,
        checkCancelled: check,
      );
      if (found == null) continue;
      check();
      onStatus?.call('Getting ${track.title} from ${source.name}…');
      try {
        final selected = found.withArtwork(_artworkOf(track));
        final resolved = await source.play(selected);
        final song = resolved.copyWith(sourceDisplayName: source.name);
        if (source.id.startsWith('a-')) {
          _rememberOnlineAddon(song, source.id.substring(2), selected);
        }
        OnlineSongSaveRegistry.instance.register(
          song,
          () => playOnlineTrack(source.id, selected, forDownload: true),
        );
        return song;
      } catch (error) {
        check();
        AppLog.instance.add(
          '[OnlineSource] source playback failed source=${source.id} '
          'reason=${_onlineFailureKind(error)}',
        );
        // An Atmos server timeout must not silently switch to stereo.
        if (found.atmosAvailable &&
            error is DiscoveryException &&
            error.message.startsWith('Tidal Atmos server')) {
          onStatus?.call(error.message);
          rethrow;
        }
        failure = error is DiscoveryException
            ? error
            : DiscoveryException(
                '${source.name} couldn’t get ${track.title} ready.',
              );
        onStatus?.call(
          'Couldn’t get ${track.title} from ${source.name}. '
          'Trying elsewhere…',
        );
      }
    }
    if (failure != null) throw failure;
    return null;
  } finally {
    if (owned) transport.close();
  }
}

/// [track]'s cover address, or null when it has none worth fetching.
String? _artworkOf(LokalDiscoveryTrack track) {
  final url = discoveryImageUrl(track.artworkUrl);
  return url.isEmpty ? null : url;
}

/// A queue placeholder for [track], a song you don't own: found on YouTube
/// Music or your add-ons and downloaded once it's coming up (QueuePreResolver).
Song discoveryPendingSong(LokalDiscoveryTrack track) {
  final resolver = QueuePreResolver.shared;
  late final Song pending;
  pending = resolver.pending(
    key: track.key,
    title: track.title,
    artist: track.artist,
    album: track.album,
    duration: track.duration,
    artwork: _artworkOf(track),
    resolve: ({onStatus, cancel}) => findDiscoverySong(
      track,
      onStatus: onStatus,
      cancel: cancel,
      additionalProtectedPaths: () => resolver.resolvedPaths,
      mayRequestVerification: () =>
          PlayerService().currentSongNotifier.value?.id == pending.id,
    ),
  );
  OnlineSongSaveRegistry.instance.register(
    pending,
    () async {
      final found = await findDiscoverySong(track);
      if (found == null) throw const DiscoveryException(
        'This recommendation has no downloadable audio source.',
      );
      return found;
    },
  );
  return pending;
}
