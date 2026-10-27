import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/widgets/common/flick_artwork_placeholder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/song.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/songs_provider.dart';
import 'domain/flow_models.dart';
import 'flow_controller.dart';
import 'flow_library.dart';
import 'flow_playback.dart';
import 'flow_tuner_sheet.dart';
import 'flow_hero.dart';

/// Drop-in shell entry point. Requires the app's existing ProviderScope.
class FlowScreen extends ConsumerStatefulWidget {
  const FlowScreen({super.key, this.embedded = false});

  /// Hide the standalone AppBar when Flow is shown inside Home.
  final bool embedded;

  @override
  ConsumerState<FlowScreen> createState() => _FlowScreenState();
}

class _FlowScreenState extends ConsumerState<FlowScreen> {
  bool _busy = false;
  FlowController get _controller => ref.read(flowControllerProvider.notifier);

  Future<void> _run(Future<void> Function() action, {String? success}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted && success != null) _message(success);
    } catch (error) {
      if (mounted) _message('Flow could not complete that action: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  void _retry() {
    ref.invalidate(songsProvider);
    ref.invalidate(favoritesProvider);
    ref.invalidate(flowHistoryProvider);
    if (ref.read(flowControllerProvider).hasError) {
      ref.invalidate(flowControllerProvider);
    }
  }

  Future<void> _tune(FlowData data, FlowLibrary library, {FlowMood? mood}) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (context) => FlowTunerSheet(
          config: data.config,
          initialMood: mood,
          genres: library.tracks.expand((track) => track.genres).toSet(),
          onApply: _controller.apply,
        ),
      );

  Future<void> _save(FlowData data) => showDialog<void>(
    context: context,
    builder: (context) => _SaveFlowDialog(
      initialName: data.config.mood == FlowMood.flow
          ? 'My Flow'
          : '${data.config.mood.label} Flow',
      onSave: (name) async {
        await _controller.savePlaylist(name);
        if (mounted) _message('Saved “${name.trim()}” to Playlists.');
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final flowAsync = ref.watch(flowControllerProvider);
    final libraryAsync = ref.watch(flowLibraryProvider);
    // Playback position updates roughly every 250 ms. The Flow mix and song
    // list only need track identity and play/pause, not progress ticks.
    final playback = ref.watch(
      playerProvider.select(
        (state) => (song: state.currentSong, isPlaying: state.isPlaying),
      ),
    );
    final backgroundError = ref.watch(flowMessageProvider);
    final data = flowAsync.value;
    final library = libraryAsync.value;
    final error = flowAsync.error ?? libraryAsync.error;
    final body = SafeArea(
      top: false,
      child: error != null
          ? _StateCard(
              icon: Icons.error_outline,
              title: 'Could not load Flow',
              message: '$error',
              action: 'Try again',
              onAction: _retry,
            )
          : data == null || library == null
          ? const Center(
              child: CircularProgressIndicator(semanticsLabel: 'Loading Flow'),
            )
          : _content(
              data,
              library,
              playback.song,
              playback.isPlaying,
              backgroundError,
            ),
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flow'),
        actions: [
          IconButton(
            tooltip: 'Refresh library',
            onPressed: _busy ? null : _retry,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _content(
    FlowData data,
    FlowLibrary library,
    Song? currentSong,
    bool isPlaying,
    String? error,
  ) {
    final songs = library.mix(data, DateTime.now());
    final ownsQueue = ref
        .read(flowPlaybackProvider)
        .ownsSession(data.session.seed);
    final currentInMix = songs.any((s) => s.id == currentSong?.id);
    final active = ownsQueue && currentInMix;
    final playing = active && isPlaying;
    final enabled = !_busy && library.unlocked && songs.isNotEmpty;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FlowHero(
              mood: data.config.mood,
              count: songs.length,
              playing: playing,
              busy: _busy,
              enabled: enabled,
              onPlay: () => _run(
                () => active
                    ? ref.read(playerProvider.notifier).togglePlayPause()
                    : _controller.play(),
              ),
              onShuffle: () => _run(() => _controller.play(shuffle: true)),
              onSave: () => _save(data),
              onTune: _busy ? null : () => _tune(data, library),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                for (final mood in FlowMood.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(mood.label),
                      selected: data.config.mood == mood,
                      onSelected: _busy
                          ? null
                          : (_) => _tune(data, library, mood: mood),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (data.notice != null || library.warning != null || error != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                [
                  data.notice,
                  library.warning,
                  error,
                ].whereType<String>().join('\n'),
              ),
            ),
          ),
        if (library.songs.isEmpty)
          const SliverToBoxAdapter(
            child: _StateCard(
              icon: Icons.library_music_outlined,
              title: 'Your local library is empty',
              message: 'Scan music in your Library, then like at least 16 tracks to build your Flow.',
            ),
          )
        else if (!library.unlocked)
          SliverToBoxAdapter(
            child: _StateCard(
              icon: Icons.lock_outline,
              title: 'Your Flow is taking shape',
              message:
                  '${library.favoriteCount} / 16 local favorites · '
                  'Like ${FlowRules.needed(library.favoriteCount)} more tracks to unlock '
                  'your personal soundtrack. Artist names on liked tracks do not count as follows.',
            ),
          )
        else if (songs.isEmpty)
          SliverToBoxAdapter(
            child: _StateCard(
              icon: Icons.filter_alt_off_outlined,
              title: 'No tracks match this Flow',
              message:
                  'Try a wider discovery range, enable more genres, or remove a ban. '
                  'Online recommendations require a connection; try another mood or allow more genres. Offline fallback uses your library.',
              action: 'Tune Flow',
              onAction: () => _tune(data, library),
            ),
          )
        else ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Your mix · ${songs.length} tracks',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : () => _run(_controller.newMix),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('New mix'),
                  ),
                ],
              ),
            ),
          ),
          if (active)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${isPlaying ? 'Playing' : 'Paused'} · '
                        '${currentSong!.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _busy ? null : () => _run(_controller.skip),
                      icon: const Icon(Icons.skip_next),
                      label: const Text('Skip'),
                    ),
                  ],
                ),
              ),
            ),
          SliverList.builder(
            itemCount: songs.length,
            itemBuilder: (context, index) =>
                _songTile(songs[index], index, library, currentSong?.id),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  const Text(
                    'Continuous online-first mix · refills with three tracks remaining, up to 200 tracks. '
                    'Save keeps both downloaded and online recommendations in Playlists.',
                    textAlign: TextAlign.center,
                  ),
                  if (!ownsQueue)
                    TextButton.icon(
                      onPressed: _busy ? null : () => _run(_controller.grow),
                      icon: const Icon(Icons.add),
                      label: const Text('Add more tracks'),
                    ),
                ],
              ),
            ),
          ),
        ],
        if (data.bannedIds.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(
                child: ExpansionTile(
                  title: Text('Banned from Flow · ${data.bannedIds.length}'),
                  leading: const Icon(Icons.block),
                  children: [
                    for (final id in data.bannedIds)
                      ListTile(
                        dense: true,
                        title: Text(
                          library.byId[id]?.title ?? 'Unavailable track ($id)',
                        ),
                        subtitle: library.byId[id] == null
                            ? null
                            : Text(library.byId[id]!.artist),
                        trailing: TextButton(
                          onPressed: _busy
                              ? null
                              : () => _run(() => _controller.unban(id)),
                          child: const Text('Unban'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        // Room for the host shell's persistent mini-player, if present.
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ],
    );
  }

  Widget _songTile(
    Song song,
    int index,
    FlowLibrary library,
    String? currentSongId,
  ) {
    final current = currentSongId == song.id;
    final liked = library.favoriteIds.contains(song.id);
    return ListTile(
      selected: current,
      leading: SizedBox.square(
        dimension: 44,
        child: ClipOval(
          child: CachedImageWidget(
            imagePath: song.albumArt,
            audioSourcePath: song.filePath,
            fit: BoxFit.cover,
            placeholder: const FlickArtworkPlaceholder(),
            errorWidget: const FlickArtworkPlaceholder(),
          ),
        ),
      ),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${song.artist} · ${song.formattedDuration}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: _busy ? null : () => _run(() => _controller.play(songId: song.id)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: liked ? 'Unlike ${song.title}' : 'Like ${song.title}',
            icon: Icon(liked ? Icons.favorite : Icons.favorite_border),
            onPressed: _busy
                ? null
                : () => _run(() async {
                    await ref
                        .read(favoritesProvider.notifier)
                        .toggleFavorite(song.id, song: song);
                  }),
          ),
          IconButton(
            tooltip: 'Ban ${song.title} from Flow',
            icon: const Icon(Icons.block),
            onPressed: _busy ? null : () => _run(() => _controller.ban(song)),
          ),
        ],
      ),
    );
  }
}

class _StateCard extends StatelessWidget {
  const _StateCard({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.onAction,
  });
  final IconData icon;
  final String title;
  final String message;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36),
            const SizedBox(height: 12),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            if (action != null)
              TextButton(onPressed: onAction, child: Text(action!)),
          ],
        ),
      ),
    ),
  );
}

class _SaveFlowDialog extends StatefulWidget {
  const _SaveFlowDialog({required this.initialName, required this.onSave});
  final String initialName;
  final Future<void> Function(String) onSave;
  @override
  State<_SaveFlowDialog> createState() => _SaveFlowDialogState();
}

class _SaveFlowDialogState extends State<_SaveFlowDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName,
  );
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(_name.text.trim());
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: const Text('Save your Flow'),
      content: TextField(
        controller: _name,
        autofocus: true,
        enabled: !_saving,
        maxLength: 100,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: 'Playlist name',
          errorText: _error,
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving || _name.text.trim().isEmpty ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    ),
  );
}
