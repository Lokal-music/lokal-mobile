import 'dart:async';

import 'package:flick/features/discovery/lastfm_discovery.dart';
import 'package:flick/features/discovery/youtube_music_playlist_cache.dart';
import 'package:flick/features/konnekted/konnekted_data.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flick/features/spotify/provider_playlist_visibility.dart';
import 'package:flick/features/songs/widgets/song_actions_bottom_sheet.dart';
import 'package:flick/features/spotify/provider_playlist_track_browser.dart';
import 'package:flick/features/playlist_links/playlist_link_models.dart';
import 'package:flick/models/song.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Saved YouTube Music playlists, independent of Discovery recommendations.
class YoutubeMusicPlaylistsScreen extends ConsumerStatefulWidget {
  const YoutubeMusicPlaylistsScreen({super.key, required this.onPlay});
  final void Function(Song song, List<Song> queue) onPlay;
  @override
  ConsumerState<YoutubeMusicPlaylistsScreen> createState() =>
      _YoutubeMusicPlaylistsScreenState();
}

class _YoutubeMusicPlaylistsScreenState
    extends ConsumerState<YoutubeMusicPlaylistsScreen> {
  final _cache = YoutubeMusicPlaylistCache.instance;
  final _visibility = const ProviderPlaylistVisibility();
  List<LokalDiscoveryMix> _items = [];
  Set<String> _hidden = {};
  String _account = '';
  String? _error;
  bool _loading = true, _updating = false, _showHidden = false, _auto = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    await ref.read(konnektedYoutubeMusicSessionProvider.future);
    if (!mounted) return;
    final account = ref.read(konnektedYoutubeMusicAccountProvider);
    if (account == null) {
      if (mounted) setState(() {
        _loading = false;
        _items = [];
        _error = 'Sign in to YouTube Music in Data → Accounts first.';
      });
      return;
    }
    final id = account.session.accountKey;
    final cached = await _cache.playlists(id);
    final hidden = await _visibility.hidden('youtube', id);
    final auto = await _cache.autoUpdate;
    if (!mounted) return;
    setState(() {
      _account = id;
      _hidden = hidden;
      _auto = auto;
      if (cached != null) _items = cached;
      _loading = cached == null;
      _error = null;
    });
    if (cached == null || await _cache.due(id, 'library')) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    if (_updating) return;
    final account = ref.read(konnektedYoutubeMusicAccountProvider);
    if (account == null) return;
    _updating = true;
    try {
      final list = await _cache.refreshLibrary(account);
      if (mounted && account.session.accountKey == _account) {
        setState(() { _items = list; _error = null; });
      }
    } catch (error) {
      if (mounted) setState(() {
        _error = _items.isEmpty ? error.toString() : null;
      });
      if (mounted && _items.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('YouTube Music update failed. Saved playlists are still available.')),
        );
      }
    } finally {
      _updating = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setHidden(String id, bool hidden) async {
    final result = await _visibility.setHidden('youtube', _account, id, hidden);
    if (mounted) setState(() => _hidden = result);
  }

  Future<void> _setAuto(bool auto) async {
    await _cache.setAutoUpdate(auto);
    if (mounted) setState(() => _auto = auto);
  }

  @override
  Widget build(BuildContext context) {
    final shown = _items.where((p) => _showHidden || !_hidden.contains(p.id)).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('YouTube Music playlists'),
        actions: [
          IconButton(
            tooltip: 'Update playlists', onPressed: _updating ? null : () => unawaited(_refresh()),
            icon: _updating
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(children: [
        SwitchListTile(
          dense: true,
          title: const Text('Auto-update playlists'),
          subtitle: const Text('Check at most once every 24 hours when opened'),
          value: _auto, onChanged: (value) => unawaited(_setAuto(value)),
        ),
        if (_hidden.isNotEmpty)
          ListTile(
            dense: true, title: Text('Show hidden playlists (${_hidden.length})'),
            trailing: Switch(value: _showHidden, onChanged: (v) => setState(() => _showHidden = v)),
            onTap: () => setState(() => _showHidden = !_showHidden),
          ),
        Expanded(
          child: _loading && _items.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!, textAlign: TextAlign.center),
                    ))
                  : shown.isEmpty
                      ? Center(child: Text(_hidden.isNotEmpty
                          ? 'All playlists are hidden. Enable Show hidden playlists to restore them.'
                          : 'No saved YouTube Music playlists.'))
                      : RefreshIndicator(
                          onRefresh: _refresh,
                          child: ListView.builder(
                            itemCount: shown.length,
                            itemBuilder: (context, index) {
                              final playlist = shown[index];
                              final hidden = _hidden.contains(playlist.id);
                              return ListTile(
                                leading: _YoutubePlaylistArtwork(url: playlist.artworkUrl),
                                title: Text(playlist.title, maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                subtitle: Text(playlist.author.isEmpty
                                    ? 'YouTube Music' : playlist.author,
                                    maxLines: 1, overflow: TextOverflow.ellipsis),
                                trailing: IconButton(
                                  tooltip: hidden ? 'Show playlist' : 'Hide playlist',
                                  icon: Icon(hidden ? Icons.visibility_rounded
                                      : Icons.visibility_off_outlined),
                                  onPressed: () => unawaited(_setHidden(playlist.id, !hidden)),
                                ),
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => _YoutubePlaylistDetail(
                                      playlist: playlist, onPlay: widget.onPlay,
                                      accountId: _account,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
        ),
      ]),
    );
  }
}

class _YoutubePlaylistArtwork extends StatelessWidget {
  const _YoutubePlaylistArtwork({required this.url});
  final String url;
  @override
  Widget build(BuildContext context) => url.startsWith('https://')
      ? ClipRRect(borderRadius: BorderRadius.circular(5),
          child: Image.network(url, width: 48, height: 48, fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox(width: 48, height: 48,
              child: Icon(Icons.library_music_rounded))))
      : const SizedBox(width: 48, height: 48,
          child: Icon(Icons.library_music_rounded));
}

class _YoutubePlaylistDetail extends ConsumerStatefulWidget {
  const _YoutubePlaylistDetail({
    required this.playlist, required this.onPlay, required this.accountId,
  });
  final LokalDiscoveryMix playlist;
  final String accountId;
  final void Function(Song song, List<Song> queue) onPlay;
  @override
  ConsumerState<_YoutubePlaylistDetail> createState() =>
      _YoutubePlaylistDetailState();
}

class _YoutubePlaylistDetailState
    extends ConsumerState<_YoutubePlaylistDetail> {
  final _cache = YoutubeMusicPlaylistCache.instance;
  List<LokalDiscoveryTrack> _tracks = [];
  bool _loading = true, _updating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final cached = await _cache.tracks(widget.accountId, widget.playlist.id);
    if (!mounted) return;
    if (cached != null) {
      setState(() { _tracks = cached; _loading = false; });
    }
    if (cached == null ||
        await _cache.due(widget.accountId, 'tracks.${widget.playlist.id}')) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    if (_updating) return;
    final account = ref.read(konnektedYoutubeMusicAccountProvider);
    if (account == null || account.session.accountKey != widget.accountId) {
      if (mounted) setState(() {
        _loading = false;
        _error = 'YouTube Music session changed. Reopen this playlist.';
      });
      return;
    }
    _updating = true;
    try {
      final tracks = await _cache.refreshTracks(account, widget.playlist.id);
      if (mounted) setState(() { _tracks = tracks; _error = null; });
    } catch (error) {
      if (mounted && _tracks.isEmpty) setState(() => _error = error.toString());
      if (mounted && _tracks.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update playlist; saved songs remain available.')),
        );
      }
    } finally {
      _updating = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  // Use the same local-first / pending-online resolution as playback.
  // Long-press actions must operate on the actual Lokal Song, not on the
  // YouTube Music metadata card.
  void _playOrdered(List<int> sourceIndices, int startIndex) {
    if (sourceIndices.isEmpty || startIndex < 0 ||
        startIndex >= sourceIndices.length ||
        sourceIndices.any((index) => index < 0 || index >= _tracks.length)) {
      return;
    }
    final library = KonnektedLibraryIndex.of(
      ref.read(konnektedLibraryProvider).value ?? const <Song>[],
    );
    // Keep the source playlist order (including duplicate songs) when playing
    // normally. Shuffle supplies an independently randomized ordering.
    final queue = [
      for (final index in sourceIndices)
        library.match(_tracks[index]) ?? discoveryPendingSong(_tracks[index]),
    ];
    widget.onPlay(queue[startIndex], queue);
  }

  void _songActions(int index) {
    if (index < 0 || index >= _tracks.length) return;
    // A context menu only needs the selected track, not a 1,000-song queue.
    final library = KonnektedLibraryIndex.of(
      ref.read(konnektedLibraryProvider).value ?? const <Song>[],
    );
    final track = _tracks[index];
    final song = library.match(track) ?? discoveryPendingSong(track);
    unawaited(SongActionsBottomSheet.show(context, song));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.playlist.title),
      actions: [
        IconButton(
          tooltip: 'Update playlist', onPressed: _updating ? null : () => unawaited(_refresh()),
          icon: const Icon(Icons.refresh_rounded),
        ),

      ],
    ),
    body: _loading && _tracks.isEmpty
        ? const Center(child: CircularProgressIndicator())
        : _error != null && _tracks.isEmpty
            ? Center(child: Text(_error!))
            : _tracks.isEmpty
                ? const Center(child: Text('No accessible tracks in this playlist.'))
                : ProviderPlaylistTrackBrowser(
                    tracks: _tracks,
                    source: PlaylistLinkSource.youtube,
                    playlistId: widget.playlist.id,
                    accountId: widget.accountId,
                    artworkBuilder: (track) => _YoutubePlaylistArtwork(url: track.artworkUrl),
                    onPlay: _playOrdered,
                    onSongActions: _songActions,
                  ),
  );
}
