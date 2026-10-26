import 'dart:async';
import 'dart:io';

import 'package:flick/models/song.dart';
import 'package:flick/features/discovery/discovery_progressive_streams.dart';
import 'package:flick/features/morneye/morneye_live_playback.dart';
import 'package:flick/services/player_service.dart';
import 'package:flutter/foundation.dart';

// Predictive pre-resolving, as desktop's src/queuePrefetch.js: songs you
// don't own sit in the queue as placeholders ([Song.isPending]) and the next
// [QueuePreResolver.lookahead] of them in play order (the shuffle order when
// shuffled, round again on repeat-all) are found and downloaded ahead of
// time, the first at once and the rest [QueuePreResolver.stagger] apart, so
// each starts at once when its turn comes. Songs looked up lately aren't
// asked for again; a lookup for a song no longer coming up (an add-on's
// download included) is cancelled. Run when the song changes (a crossfade
// included) and, once it settles, when the queue does.

/// Finds and downloads a placeholder's song; null when no source has it.
/// [cancel] completes when the song is no longer wanted.
typedef PendingResolve = Future<Song?> Function({
  void Function(String status)? onStatus,
  Future<void>? cancel,
});

/// What the pre-resolver needs from the player.
abstract class PreResolveHost {
  /// The songs in play order (already shuffled when shuffle is on).
  List<Song> get playlist;
  int get currentIndex;
  bool get repeatAll;

  /// Fires when the song playing changes.
  Listenable get songChanges;

  /// Fires when the queue, shuffle or repeat changes.
  Listenable get queueChanges;

  /// Puts [resolved] in place of the placeholder [pendingId], wherever it is
  /// queued, without interrupting playback.
  void replacePending(String pendingId, Song resolved);
}

/// The next [count] songs in play order after the one at [currentIndex],
/// round again from the start when [repeatAll]. The current song itself is
/// never among them.
List<Song> upcomingSongs(
  List<Song> playlist,
  int currentIndex, {
  required bool repeatAll,
  int count = QueuePreResolver.defaultLookahead,
}) {
  if (playlist.isEmpty || currentIndex < 0 || currentIndex >= playlist.length) {
    return const [];
  }
  final current = playlist[currentIndex].id;
  final out = <Song>[];
  for (var step = 1; out.length < count && step < playlist.length; step++) {
    final index = currentIndex + step;
    if (index >= playlist.length && !repeatAll) break;
    final song = playlist[index % playlist.length];
    if (song.id != current) out.add(song);
  }
  return out;
}

class _Lookup {
  _Lookup({required this.onDemand});

  bool onDemand;
  bool cancelled = false;
  bool timedOut = false;
  String? lastStatus;
  Timer? watchdog;
  Object? error;
  final cancel = Completer<void>();
  final result = Completer<Song?>();

  void stop() {
    if (cancelled) return;
    cancelled = true;
    watchdog?.cancel();
    cancel.complete();
    if (!result.isCompleted) result.complete(null);
  }
}

class QueuePreResolver {
  QueuePreResolver({
    this.lookahead = defaultLookahead,
    this.stagger = const Duration(seconds: 2),
    this.ttl = const Duration(minutes: 20),
    this.lookupIdleTimeout = const Duration(seconds: 90),
    this.queueSettle = const Duration(milliseconds: 600),
    DateTime Function()? now,
    bool Function(Song song)? stillUsable,
  }) : _now = now ?? DateTime.now,
       _stillUsable = stillUsable ?? isPlayableResolvedSource;

  static const defaultLookahead = 4;
  static const _maxRecent = 100;
  static const _maxRegistered = 500;

  final int lookahead;
  final Duration stagger;

  /// How long a song looked up stays good (desktop: 20 minutes).
  final Duration ttl;
  final Duration lookupIdleTimeout;

  /// Queue edits come in bursts: look ahead once they settle.
  final Duration queueSettle;
  final DateTime Function() _now;
  final bool Function(Song song) _stillUsable;

  static QueuePreResolver? _shared;

  /// The app's pre-resolver, attached to the [PlayerService] on first use.
  static QueuePreResolver get shared =>
      _shared ??= QueuePreResolver()
        ..attach(PlayerServiceHost(PlayerService()));

  /// What an on-demand lookup is doing ("Getting X from Y…"), else null.
  final status = ValueNotifier<String?>(null);

  final _registered = <String, PendingResolve>{};
  // Durable liked-song IDs may exceed the 500-entry discovery prefetch LRU.
  // Keep their resolvers separate so a large Likes queue cannot invalidate
  // the first song simply by registering its later entries.
  final _savedSongResolvers = <String, PendingResolve>{};
  final _recent = <String, ({Song song, DateTime at})>{};
  final _running = <String, _Lookup>{};
  // Each stagger timer belongs to a specific upcoming song. Repeated queue
  // or track notifications must not restart its two-second countdown.
  final _timers = <String, Timer>{};
  Timer? _settle;
  _Lookup? _statusOwner;
  PreResolveHost? _host;

  /// Unlike staged songs, HTTP and live Morneye tracks have intentionally
  /// opaque in-memory handles. They are usable while their registered
  /// descriptors exist, even though File(handle).existsSync() is false.
  @visibleForTesting
  static bool isPlayableResolvedSource(Song song) {
    if (song.sourcePackage == 'konnekted.progressive') {
      return DiscoveryProgressiveStreams.instance.contains(song.filePath);
    }
    if (song.sourcePackage == 'konnekted.morneye-live') {
      return MorneyeLiveRegistry.instance.resolve(song.filePath)?.isPlayable ==
          true;
    }
    return _fileExists(song);
  }

  static bool _fileExists(Song song) {
    final path = song.filePath;
    return path != null && File(path).existsSync();
  }

  /// Placeholder ids being looked up right now (tests, diagnostics).
  Set<String> get running => Set.unmodifiable(_running.keys);

  /// Files of songs looked up lately: kept by the playback cache.
  Set<String> get resolvedPaths => {
    for (final entry in _recent.values)
      if (_now().difference(entry.at) < ttl &&
          _stillUsable(entry.song) &&
          _fileExists(entry.song))
        if (entry.song.filePath case final String path) path,
  };

  void attach(PreResolveHost host) {
    _host = host;
    host.songChanges.addListener(_onSongChanged);
    host.queueChanges.addListener(_onQueueChanged);
    if (host is PlayerServiceHost) {
      host.player.pendingSongResolver = resolveNow;
      host.player.cancelPendingSongResolution = cancelOnDemand;
    }
  }

  void detach() {
    final host = _host;
    if (host == null) return;
    host.songChanges.removeListener(_onSongChanged);
    host.queueChanges.removeListener(_onQueueChanged);
    if (host is PlayerServiceHost &&
        host.player.pendingSongResolver == resolveNow) {
      host.player.pendingSongResolver = null;
      host.player.cancelPendingSongResolution = null;
    }
    _host = null;
  }

  void _onSongChanged() {
    _settle?.cancel();
    schedule();
  }

  void _onQueueChanged() {
    _settle?.cancel();
    _settle = Timer(queueSettle, schedule);
  }

  /// A placeholder for a song still to be found; [resolve] finds it.
  Song pending({
    required String key,
    /// Preserve the durable song ID for saved Likes, so the heart status
    /// remains attached to the same track after the source is re-resolved.
    String? stableId,
    required String title,
    required String artist,
    String? album,
    Duration? duration,
    String? artwork,
    required PendingResolve resolve,
  }) {
    final id = stableId ?? 'pending:$key';
    if (stableId != null) {
      _savedSongResolvers[id] = resolve;
    } else {
      _registered.remove(id);
      _registered[id] = resolve;
      while (_registered.length > _maxRegistered) {
        _registered.remove(_registered.keys.first);
      }
    }
    return Song(
      id: id,
      title: title,
      artist: artist,
      album: album == null || album.isEmpty ? null : album,
      // The cover's address, shown while it's looked up; the song found
      // brings its own copy on disk.
      albumArt: artwork == null || artwork.isEmpty ? null : artwork,
      duration: duration ?? Duration.zero,
      fileType: 'ONLINE',
      sourcePackage: Song.pendingSourcePackage,
      isExternal: true,
    );
  }

  Song? _recentSong(String id) {
    final entry = _recent[id];
    if (entry == null) return null;
    if (_now().difference(entry.at) >= ttl || !_stillUsable(entry.song)) {
      _recent.remove(id);
      return null;
    }
    return entry.song;
  }

  void _remember(String id, Song song) {
    _recent.remove(id);
    _recent[id] = (song: song, at: _now());
    while (_recent.length > _maxRecent) {
      _recent.remove(_recent.keys.first);
    }
  }

  void _pruneRecent() {
    final now = _now();
    _recent.removeWhere((_, entry) => now.difference(entry.at) >= ttl);
  }

  List<Song> _upcomingPending() {
    final host = _host;
    if (host == null) return const [];
    final seen = <String>{};
    return [
      for (final song in upcomingSongs(
        host.playlist,
        host.currentIndex,
        repeatAll: host.repeatAll,
        count: lookahead,
      ))
        if (song.isPending && seen.add(song.id)) song,
    ];
  }

  String? _currentId() {
    final host = _host;
    if (host == null) return null;
    final playlist = host.playlist;
    final index = host.currentIndex;
    return index >= 0 && index < playlist.length ? playlist[index].id : null;
  }

  /// Looks up the placeholders coming up. Returns the ids asked for, in
  /// order (for the tests).
  List<String> schedule() {
    final host = _host;
    if (host == null) return const [];
    // Never disable the entire next-four preload window while a live FLAC
    // is downloading: a long Qobuz transfer can otherwise leave the whole
    // Search queue unresolved. Give the playing stream a brief head start,
    // then stagger background requests rather than waiting for completion.
    final current = host is PlayerServiceHost
        ? host.player.currentSongNotifier.value : null;
    final liveTransfer = current?.sourcePackage == 'konnekted.morneye-live' &&
        MorneyeLiveRegistry.instance.resolve(current?.filePath)
                ?.isTransferring == true;
    // The foreground request gets the add-on runtime and bandwidth first.
    // Queue notifications during its download must not start competing work.
    if (_running.values.any((lookup) => lookup.onDemand && !lookup.cancelled)) {
      return const [];
    }
    _pruneRecent();
    final upcoming = _upcomingPending();
    final keep = {for (final song in upcoming) song.id, ?_currentId()};
    for (final entry in _timers.entries.toList()) {
      if (!keep.contains(entry.key)) {
        entry.value.cancel();
        _timers.remove(entry.key);
      }
    }
    // No longer coming up: its lookup (an add-on's download, say) stops.
    for (final id in _running.keys.toList()) {
      if (!keep.contains(id)) _running.remove(id)?.stop();
    }
    final asked = <String>[];
    var delay = liveTransfer
        ? const Duration(seconds: 3) : Duration.zero;
    for (final song in upcoming) {
      final id = song.id;
      if (_recentSong(id) case final ready?) {
        // Looked up lately (queued again, say): no need to ask again.
        host.replacePending(id, ready);
        continue;
      }
      if (!_registered.containsKey(id) &&
          !_savedSongResolvers.containsKey(id)) continue;
      if (_running.containsKey(id) || _timers.containsKey(id)) {
        // Respect its existing slot in the two-second stagger instead of
        // starting a newly revealed fourth track immediately alongside it.
        delay += stagger;
        continue;
      }
      asked.add(id);
      void start() {
        if (_running.containsKey(id)) return;
        // A delayed timer may fire after a foreground resolution started.
        // Foreground completion schedules the window again, so don't launch
        // competing provider requests while the selected track prepares.
        if (_running.values.any((lookup) => lookup.onDemand && !lookup.cancelled)) {
          return;
        }
        // Started later: still coming up in the queue as it is now?
        if (!_upcomingPending().any((other) => other.id == id)) return;
        _start(id, onDemand: false);
      }

      if (delay == Duration.zero) {
        start();
      } else {
        _timers[id] = Timer(delay, () {
          _timers.remove(id);
          start();
        });
      }
      delay += stagger;
    }
    return asked;
  }

  /// Gets [pending] ready now: playback has reached it. Reuses a lookup
  /// already under way or done lately. Null when it can't be found.
  Future<Song?> resolveNow(Song pending) {
    final id = pending.id;
    _settle?.cancel();
    // Keep the other next-four background lookups alive. A foreground skip
    // takes priority but must not discard all previously prepared successors
    // or continually reset their stagger timers.
    final wanted = {id, for (final song in _upcomingPending()) song.id};
    for (final entry in _timers.entries.toList()) {
      if (!wanted.contains(entry.key)) {
        entry.value.cancel();
        _timers.remove(entry.key);
      }
    }
    for (final other in _running.keys.toList()) {
      if (other != id &&
          (_running[other]!.onDemand || !wanted.contains(other))) {
        _running.remove(other)?.stop();
      }
    }
    if (_recentSong(id) case final ready?) {
      _host?.replacePending(id, ready);
      return Future.value(ready);
    }
    final running = _running[id];
    if (running != null) {
      running.onDemand = true;
      _statusOwner = running;
      status.value = running.lastStatus ?? 'Preparing ${pending.title}…';
      return _foregroundResult(running);
    }
    // Show the loading toast immediately on Next—even before the add-on's
    // first progress callback. It will update in place once it has details.
    status.value = 'Preparing ${pending.title}…';
    final lookup = _start(id, onDemand: true);
    if (lookup == null) {
      status.value = null;
      return Future.value(null);
    }
    return _foregroundResult(lookup);
  }

  Future<Song?> _foregroundResult(_Lookup lookup) async {
    final song = await lookup.result.future;
    final error = lookup.error;
    if (error != null && (!lookup.cancelled || lookup.timedOut)) throw error;
    return song;
  }

  /// A new playback request preempts the old foreground download immediately,
  /// even if that song still happens to be within the prefetch lookahead.
  void cancelOnDemand() {
    for (final entry in _running.entries.toList()) {
      if (entry.value.onDemand) _running.remove(entry.key)?.stop();
    }
    _statusOwner = null;
    status.value = null;
  }

  _Lookup? _start(String id, {required bool onDemand}) {
    final resolve = _savedSongResolvers[id] ?? _registered[id];
    if (resolve == null) return null;
    final lookup = _Lookup(onDemand: onDemand);
    _running[id] = lookup;
    if (onDemand) _statusOwner = lookup;
    void armWatchdog() {
      lookup.watchdog?.cancel();
      lookup.watchdog = Timer(lookupIdleTimeout, () {
        lookup.timedOut = true;
        lookup.error = TimeoutException(
          'Online source stopped responding. Try another source or retry.',
          lookupIdleTimeout,
        );
        lookup.stop();
        if (identical(_running[id], lookup)) _running.remove(id);
        if (identical(_statusOwner, lookup)) {
          _statusOwner = null;
          status.value = null;
        }
      });
    }

    armWatchdog();
    unawaited(_run(id, resolve, lookup, armWatchdog));
    return lookup;
  }

  Future<void> _run(
    String id,
    PendingResolve resolve,
    _Lookup lookup,
    VoidCallback activity,
  ) async {
    Song? song;
    try {
      song = await resolve(
        cancel: lookup.cancel.future,
        onStatus: (message) {
          if (lookup.cancelled) return;
          if (message != lookup.lastStatus) {
            lookup.lastStatus = message;
            activity();
          }
          if (lookup.onDemand &&
              !lookup.cancelled &&
              identical(_statusOwner, lookup)) {
            status.value = message;
          }
        },
      );
    } catch (error) {
      if (!lookup.cancelled) lookup.error = error;
      song = null;
    }
    lookup.watchdog?.cancel();
    if (identical(_running[id], lookup)) _running.remove(id);
    if (lookup.cancelled) song = null;
    if (song != null) {
      _remember(id, song);
      _host?.replacePending(id, song);
    }
    if (lookup.onDemand && identical(_statusOwner, lookup)) {
      _statusOwner = null;
      status.value = null;
    }
    if (!lookup.result.isCompleted) lookup.result.complete(song);
    if (lookup.onDemand && !lookup.cancelled && _host != null) {
      // Refill the four-ahead window once the foreground download finishes,
      // even if the engine has not emitted its next track state yet.
      _onQueueChanged();
    }
  }

  /// Forgets everything (tests; another account).
  void reset() {
    _settle?.cancel();
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    for (final lookup in _running.values) {
      lookup.stop();
    }
    _running.clear();
    _recent.clear();
    _statusOwner = null;
    status.value = null;
  }
}

/// The [PlayerService] as a [PreResolveHost].
class PlayerServiceHost implements PreResolveHost {
  PlayerServiceHost(this.player);

  final PlayerService player;

  @override
  List<Song> get playlist => player.playlist;

  @override
  int get currentIndex => player.currentIndex;

  @override
  bool get repeatAll => player.loopModeNotifier.value == LoopMode.all;

  @override
  Listenable get songChanges => player.currentSongNotifier;

  @override
  late final Listenable queueChanges = Listenable.merge([
    player.upNextNotifier,
    player.queueNotifier,
    player.loopModeNotifier,
    player.shuffleModeNotifier,
  ]);

  @override
  void replacePending(String pendingId, Song resolved) =>
      player.replacePendingSong(pendingId, resolved);
}
