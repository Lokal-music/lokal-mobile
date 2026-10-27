import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/song.dart';
import '../../models/playlist.dart';
import '../../services/online_playlist_reference.dart';
import '../../providers/player_provider.dart';
import '../../providers/playlist_provider.dart';
import '../../services/online_radio_recommendations.dart';
import '../../services/automix_analysis_cache.dart';
import 'domain/flow_models.dart';
import 'flow_library.dart';
import 'flow_playback.dart';
import 'flow_store.dart';

/// Injectable online recommendation boundary. Production fetches BitChord-style
/// radio; tests can verify queue behavior without live provider requests.
typedef FlowRadioLookup = Future<List<Song>> Function(
  Song seed,
  Iterable<Song> existing,
  int count,
);

final flowRadioProvider = Provider<FlowRadioLookup>(
  (ref) =>
      (seed, existing, count) => const OnlineRadioRecommendations().recommend(
        seed,
        existing: existing,
        count: count,
      ),
);

final flowStoreProvider = FutureProvider<FlowStore>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  return FlowStore(
    read: () async => prefs.getString(FlowStore.preferenceKey),
    write: (text) => prefs.setString(FlowStore.preferenceKey, text),
  );
});

final flowMessageProvider = NotifierProvider<FlowMessage, String?>(
  FlowMessage.new,
);

class FlowMessage extends Notifier<String?> {
  @override
  String? build() => null;
  void show(String? message) => state = message;
}

// Intentionally kept alive after the screen is first opened: queue growth and
// real player observations continue when the user visits another screen.
final flowControllerProvider = AsyncNotifierProvider<FlowController, FlowData>(
  FlowController.new,
);

class FlowController extends AsyncNotifier<FlowData> {
  late FlowStore _store;
  Future<void> _pending = Future.value();
  String? _lastStartedId;
  bool _growthScheduled = false;
  String? _lastGrowthAttempt;

  @override
  Future<FlowData> build() async {
    _store = await ref.watch(flowStoreProvider.future);
    final data = await _store.load();
    if (!ref.mounted) return data;
    ref.listen(playerProvider, (_, next) => _observe(next));
    return data;
  }

  Future<void> _serialize(Future<void> Function() action) {
    final result = _pending.then((_) async {
      if (!ref.mounted) return;
      await action();
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _commit(FlowData data) async {
    await _store.save(data);
    if (ref.mounted) state = AsyncData(data);
  }

  void _background(Future<void> operation) {
    unawaited(
      operation.catchError((Object error) {
        if (ref.mounted) {
          ref
              .read(flowMessageProvider.notifier)
              .show('Flow could not update: $error');
        }
      }),
    );
  }

  void _observe(PlayerState player) {
    final song = player.currentSong;
    if (state.value == null || !player.isPlaying || song == null) return;
    if (_lastStartedId != song.id) {
      _lastStartedId = song.id;
      _background(
        _serialize(() async {
          final data = state.requireValue;
          final session = data.session;
          final library = await ref.read(flowLibraryProvider.future);
          final playback = ref.read(flowPlaybackProvider);
          // A pending YouTube/Last.fm recommendation is replaced with a real
          // Song ID after stream resolution. Keep its Flow position, feedback
          // signals and saved-session mapping pointing at the actual song.
          final oldId = playback.ownsSession(session.seed)
              ? session.trackIds.where((id) {
                  final pending = library.byId[id];
                  return pending != null &&
                      pending.isPending &&
                      radioRecordingKey(pending.artist, pending.title) ==
                          radioRecordingKey(song.artist, song.title);
                }).firstOrNull
              : null;
          if (oldId != null) library.rememberOnline([song]);
          await _commit(
            data.copyWith(
              recentIds: [song.id, ...data.recentIds],
              session: FlowSession(
                trackIds: [
                  for (final id in session.trackIds)
                    if (id == oldId) song.id else id,
                ],
                seed: session.seed,
                builtAtMs: session.builtAtMs,
                currentId:
                    ref.read(flowPlaybackProvider).ownsSession(session.seed) &&
                        (session.trackIds.contains(song.id) || oldId != null)
                    ? song.id
                    : session.currentId,
              ),
            ),
          );
        }),
      );
    }
    final playback = ref.read(flowPlaybackProvider);
    final session = state.requireValue.session;
    final growthKey = '${session.seed}:${song.id}:${session.trackIds.length}';
    if (!_growthScheduled &&
        player.upNext.length <= 4 &&
        _lastGrowthAttempt != growthKey &&
        playback.ownsSession(session.seed)) {
      _growthScheduled = true;
      _lastGrowthAttempt = growthKey;
      _background(
        grow(onlyWhenLast: true).whenComplete(() {
          _growthScheduled = false;
        }),
      );
    }
  }

  FlowData _newSession(
    FlowLibrary library,
    FlowData data, {
    FlowConfig? config,
  }) {
    final next = data.copyWith(
      config: config,
      session: FlowSession(seed: (data.session.seed + 1) & 0x7fffffff),
    );
    final now = DateTime.now();
    final songs = library.mix(next, now);
    return next.copyWith(
      session: FlowSession(
        trackIds: songs.map((song) => song.id),
        seed: next.session.seed,
        builtAtMs: now.millisecondsSinceEpoch,
      ),
    );
  }

  /// Apply persists a fresh preview, but never restarts audio under a slider.
  Future<void> apply(FlowConfig config) => _serialize(() async {
    final library = await ref.read(flowLibraryProvider.future);
    await _commit(_newSession(library, state.requireValue, config: config));
  });

  Future<void> newMix() => _serialize(() async {
    final library = await ref.read(flowLibraryProvider.future);
    await _commit(_newSession(library, state.requireValue));
  });

  Future<void> play({
    String? songId,
    bool shuffle = false,
  }) => _serialize(() async {
    final library = await ref.read(flowLibraryProvider.future);
    var data = state.requireValue;
    if (shuffle) data = _newSession(library, data);
    final available = library.mix(data, DateTime.now());
    if (available.isEmpty) {
      throw StateError('No playable tracks in this Flow.');
    }
    final target = songId ?? data.session.currentId;
    final first =
        available.where((s) => s.id == target).firstOrNull ?? available.first;
    // Playback begins immediately with a short local anchor. The online
    // radio lookup then fills the queue while the first song is playing.
    // This avoids blocking Play on network/auth and prevents a 24-track
    // downloaded queue from hiding online discoveries for an hour.
    final songs = [
      first,
      ...available.where((song) => song.id != first.id),
    ].take(3).toList();
    data = data.copyWith(
      session: FlowSession(
        trackIds: songs.map((s) => s.id),
        seed: data.session.seed,
        builtAtMs: DateTime.now().millisecondsSinceEpoch,
        currentId: first.id,
      ),
    );
    await _commit(data);
    await ref.read(flowPlaybackProvider).play(songs, first, data.session.seed);
    // Warm only the near queue, from already-computed waveforms. Never hold
    // initial audio start while reading persistent transition profiles.
    unawaited(
      AutoMixAnalysisCache.instance.warm(songs).catchError((Object _) {}),
    );
    // The player-state observation asynchronously tops up at four or fewer
    // upcoming songs. Never block the initial playback on online lookups;
    // injected headless adapters may explicitly request grow().
  });

  /// Grow when at most four tracks remain; appending to the context tail
  /// preserves user-selected songs and gives network streams time to preload.
  Future<void> grow({bool onlyWhenLast = false}) => _serialize(() async {
    final playback = ref.read(flowPlaybackProvider);
    var data = state.requireValue;
    final active = playback.ownsSession(data.session.seed);
    if (onlyWhenLast &&
        (!active ||
            !playback.state.isPlaying ||
            playback.state.upNext.length > 4)) {
      return;
    }
    if (active && playback.state.upNext.length > 4) return;
    final library = await ref.read(flowLibraryProvider.future);
    if (data.session.trackIds.isEmpty ||
        (!active && !data.session.isFresh(DateTime.now()))) {
      data = _newSession(library, data);
    }
    final remaining = FlowRules.maxSessionTracks - data.session.trackIds.length;
    if (remaining <= 0) return;
    final seed =
        (active ? playback.state.currentSong : null) ??
        library.mix(data, DateTime.now()).firstOrNull;
    final existing = [
      for (final id in data.session.trackIds)
        if (library.byId[id] case final track?) track,
    ];
    List<Song> online = const [];
    if (seed != null) {
      try {
        online = await ref
            .read(flowRadioProvider)(
              seed,
              existing,
              remaining.clamp(0, FlowRules.topUpTracks),
            )
            .timeout(
              const Duration(seconds: 8),
              onTimeout: () => const <Song>[],
            );
      } catch (_) {
        // Provider failures should never block Flow controls or leave no
        // next track when the local fallback remains available.
        online = const [];
      }
    }
    if (!ref.mounted || (active && !playback.ownsSession(data.session.seed)))
      return;
    // The online provider is a discovery boundary, not a policy bypass:
    // apply the same bans, genre exclusions and recording deduplication.
    online = library.eligibleOnline(
      data,
      online,
      limit: remaining.clamp(0, FlowRules.topUpTracks),
    );
    library.rememberOnline(online);
    final onlineRecordings = online
        .map((song) => radioRecordingKey(song.artist, song.title))
        .toSet();
    final local = library
        .topUp(data, trailingArtists: online.map((song) => song.artist))
        .where(
          (song) => !onlineRecordings.contains(
            radioRecordingKey(song.artist, song.title),
          ),
        )
        .take(
          (remaining.clamp(0, FlowRules.topUpTracks) - online.length).clamp(
            0,
            FlowRules.topUpTracks,
          ),
        );
    final extra = [...online, ...local];
    if (extra.isEmpty) return;
    // Persist the plan before touching the player. If a platform append fails,
    // a retry cannot accidentally enqueue the successfully appended prefix twice.
    await _commit(
      data.copyWith(
        session: FlowSession(
          trackIds: [...data.session.trackIds, ...extra.map((song) => song.id)],
          seed: data.session.seed,
          builtAtMs: data.session.builtAtMs,
          currentId: data.session.currentId,
        ),
      ),
    );
    unawaited(
      AutoMixAnalysisCache.instance.warm(extra).catchError((Object _) {}),
    );
    for (final song in extra) {
      if (active) {
        if (!playback.ownsSession(data.session.seed)) break;
        await playback.append(song);
      }
    }
  });

  Future<void> ban(Song song) => _serialize(() async {
    final data = state.requireValue;
    final library = await ref.read(flowLibraryProvider.future);
    final recording = library.tracks.where((s) => s.id == song.id).firstOrNull;
    final ids = {
      song.id,
      if (recording != null)
        ...library.tracks
            .where((s) => s.recordingKey == recording.recordingKey)
            .map((s) => s.id),
    };
    final bans = {...data.bannedIds, ...ids};
    if (bans.length > FlowRules.maxBans) {
      throw StateError('Remove a Flow ban before adding another.');
    }
    await _commit(data.copyWith(bannedIds: bans));
    final playback = ref.read(flowPlaybackProvider);
    if (playback.ownsSession(data.session.seed)) {
      await playback.removeUpcoming(ids);
      if (ids.contains(playback.state.currentSong?.id)) await playback.next();
    }
  });

  Future<void> unban(String id) => _serialize(() async {
    final data = state.requireValue;
    await _commit(data.copyWith(bannedIds: {...data.bannedIds}..remove(id)));
  });

  /// Count only an explicit Flow Skip tap, never a natural track transition.
  Future<void> skip() => _serialize(() async {
    final playback = ref.read(flowPlaybackProvider);
    final data = state.requireValue;
    final id = playback.state.currentSong?.id;
    if (id == null || !playback.ownsSession(data.session.seed)) return;
    final skips = {...data.skipCounts}..remove(id);
    skips[id] = ((data.skipCounts[id] ?? 0) + 1).clamp(1, 1000);
    while (skips.length > FlowRules.maxSignals) {
      skips.remove(skips.keys.first);
    }
    await _commit(data.copyWith(skipCounts: skips));
    await playback.next();
  });

  Future<void> savePlaylist(String name) => _serialize(() async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError('Enter a playlist name.');
    final library = await ref.read(flowLibraryProvider.future);
    // Library-backed tracks keep their native IDs. An online entry is
    // converted to a stable catalogue reference with a replayable resolver.
    // Do not persist temporary files or provider-signed stream handles.
    final songs = library.mix(state.requireValue, DateTime.now()).map((song) {
      if (song.isPending ||
          song.isExternal ||
          song.isNetworkSource ||
          song.filePath?.isNotEmpty != true) {
        return stableOnlinePlaylistSong(song);
      }
      return song;
    }).toList();
    if (songs.isEmpty) throw StateError('There are no tracks to save.');
    final service = ref.read(playlistServiceProvider);
    final playlist = await service.createPlaylist(trimmed);
    if (playlist == null) {
      throw StateError('That playlist name is already in use.');
    }
    try {
      final saved = await service.updatePlaylist(
        playlist.copyWith(
          songIds: songs.map((s) => s.id).toList(),
          songAddedAt: {for (final song in songs) song.id: DateTime.now()},
          songSnapshots: {
            for (final song in songs)
              if (song.id.startsWith(onlinePlaylistPrefix))
                song.id: PlaylistSongSnapshot.fromSong(song),
          },
        ),
      );
      if (saved == null) throw StateError('Could not save the Flow tracks.');
    } catch (_) {
      await service.deletePlaylist(playlist.id);
      rethrow;
    } finally {
      if (ref.mounted) ref.invalidate(playlistsProvider);
    }
  });
}
