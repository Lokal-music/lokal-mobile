import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/song.dart';
import '../../providers/player_provider.dart';
import '../../services/player_service.dart' show PlayerService;

/// Injectable command boundary; production delegates every action to Flick.
abstract class FlowPlayback {
  PlayerState get state;
  bool ownsSession(int seed);
  Future<void> play(List<Song> songs, Song first, int seed);
  Future<void> append(Song song);
  Future<void> next();
  Future<void> removeUpcoming(Set<String> ids);
}

final flowPlaybackProvider = Provider<FlowPlayback>(_HostFlowPlayback.new);

class _HostFlowPlayback implements FlowPlayback {
  _HostFlowPlayback(this.ref) : _service = ref.read(playerServiceProvider) {
    ref.listen(playerProvider, (_, next) {
      if (_seed != null && !_starting && !_matches(next)) _release();
    });
    ref.onDispose(_release);
  }
  final Ref ref;
  final PlayerService _service;
  int? _seed;
  final Set<String> _ownedIds = {};
  bool _starting = false;
  bool? _previousAutoplay;
  @override
  PlayerState get state => ref.read(playerProvider);
  @override
  bool ownsSession(int seed) => _seed == seed && _matches(state);

  bool _matches(PlayerState state) =>
      _service.playbackContext.sourceId == 'konnekted:flow:$_seed' &&
      _ownedIds.contains(state.currentSong?.id) &&
      state.upNext.every((song) => _ownedIds.contains(song.id));

  void _release() {
    // Restore the host's preference when another queue takes over. Changing
    // this runtime flag does not write the user's saved playback preferences.
    final previous = _previousAutoplay;
    if (previous != null) {
      _service.setAutoplayOnQueueEnd(previous);
    }
    _previousAutoplay = null;
    _seed = null;
    _ownedIds.clear();
  }

  @override
  Future<void> play(List<Song> songs, Song first, int seed) async {
    final player = ref.read(playerProvider.notifier);
    final service = _service;
    _starting = true;
    _seed = seed;
    _ownedIds
      ..clear()
      ..addAll(songs.map((song) => song.id));
    _previousAutoplay ??= service.autoplayOnQueueEndNotifier.value;
    service.setAutoplayOnQueueEnd(false);
    // The weighted order is already shuffled. Keep the engine from reordering
    // it or repeating it automatically while Flow supplies unused candidates.
    try {
      await player.setShuffleMode(ShuffleMode.off);
      await player.setLoopMode(LoopMode.off);
      await player.play(
        first,
        playlist: songs,
        context: PlaybackContext(
          source: PlaybackSource.unknown,
          sourceId: 'konnekted:flow:$seed',
          sourceName: 'Flow',
        ),
      );
      // First-time audio initialization can reload the host preferences.
      service.setAutoplayOnQueueEnd(false);
      if (state.currentSong?.id != first.id) {
        throw StateError('The player could not load this local track.');
      }
    } catch (_) {
      _release();
      rethrow;
    } finally {
      _starting = false;
    }
  }

  @override
  Future<void> append(Song song) async {
    _ownedIds.add(song.id);
    await _service.appendToPlaylistTail(song);
  }

  @override
  Future<void> next() => ref.read(playerProvider.notifier).next();

  @override
  Future<void> removeUpcoming(Set<String> ids) async {
    // Re-read after each asynchronous removal, as playback can advance.
    while (true) {
      final index = state.upNext.indexWhere((song) => ids.contains(song.id));
      if (index < 0) return;
      await ref.read(playerProvider.notifier).removeFromUpNext(index);
    }
  }
}
