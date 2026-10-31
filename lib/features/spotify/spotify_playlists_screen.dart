import 'dart:async';

import 'package:flick/features/discovery/lastfm_discovery.dart';
import 'package:flick/features/discovery/spotify_discovery.dart';
import 'package:flick/features/konnekted/konnekted_data.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flick/features/spotify/spotify_api.dart';
import 'package:flick/features/spotify/spotify_models.dart';
import 'package:flick/features/spotify/spotify_oauth.dart';
import 'package:flick/features/spotify/spotify_playlist_cache.dart';
import 'package:flick/features/spotify/provider_playlist_visibility.dart';
import 'package:flick/features/songs/widgets/song_actions_bottom_sheet.dart';
import 'package:flick/features/spotify/provider_playlist_track_tile.dart';
import 'package:flick/features/spotify/spotify_storage.dart';
import 'package:flick/features/spotify/spotify_web_api.dart';
import 'package:flick/models/song.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Read-only library browser using the already-configured Spotify cookie.
/// No Spotify token or cookie is retained in widget state or logged.
class SpotifyPlaylistsScreen extends ConsumerStatefulWidget {
  const SpotifyPlaylistsScreen({super.key, required this.onPlay});

  final void Function(Song song, List<Song> queue) onPlay;

  @override
  ConsumerState<SpotifyPlaylistsScreen> createState() =>
      _SpotifyPlaylistsScreenState();
}

class _SpotifyPlaylistsScreenState
    extends ConsumerState<SpotifyPlaylistsScreen> {
  late final SpotifyWebApi _api;
  final SpotifyPlaylistCache _cache = SpotifyPlaylistCache.instance;
  final SpotifySettingsStore _settings = SpotifySettingsStore();
  final ProviderPlaylistVisibility _visibility = const ProviderPlaylistVisibility();
  String _account = '';
  Set<String> _hidden = {};
  bool _showHidden = false;
  bool _autoUpdate = false;
  bool _autoReady = false;
  bool _savingAutoUpdate = false;
  List<SpotifyPlaylist> _playlists = const [];
  bool _loading = true;
  bool _refreshing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final settings = SpotifySettingsStore();
    _api = SpotifyWebApi(
      store: settings.tokenStore,
      oauth: SpotifyOAuthService(tokenStore: settings.tokenStore),
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final account = await _cache.accountId();
      final hidden = await _visibility.hidden('spotify', account);
      final cached = await _cache.playlists();
      final autoUpdate = await _settings.loadPlaylistAutoUpdate();
      if (mounted) setState(() {
        _account = account;
        _hidden = hidden;
        _autoUpdate = autoUpdate;
        _autoReady = true;
      });
      if (!mounted) return;
      if (cached == null) {
        await _refresh();
        return;
      }
      setState(() { _playlists = cached; _loading = false; _error = null; });
      // Local data is visible before an optional scheduled refresh starts.
      if (await _cache.shouldAutoUpdateList() && mounted) {
        unawaited(_refresh(silent: true));
      }
    } catch (_) {
      if (mounted) setState(() {
        _loading = false;
        _error = 'Could not open the saved Spotify playlists.';
      });
    }
  }

  Future<void> _refresh({bool silent = false}) async {
    if (_refreshing) return;
    _refreshing = true;
    if (!silent) setState(() { _loading = true; _error = null; });
    try {
      final result = await _cache.refreshList(_api);
      if (mounted) setState(() { _playlists = result; _error = null; });
    } catch (error) {
      if (mounted) {
        final message = error is SpotifyApiException
            ? error.message
            : 'Could not update Spotify playlists. Retry or reconnect.';
        if (_playlists.isEmpty) {
          setState(() => _error = message);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(message)),
          );
        }
      }
    } finally {
      _refreshing = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _changeHidden(String id, bool hidden) async {
    final next = await _visibility.setHidden('spotify', _account, id, hidden);
    if (mounted) setState(() => _hidden = next);
  }

  Future<void> _setAutoUpdate(bool enabled) async {
    if (_savingAutoUpdate) return;
    setState(() {
      _autoUpdate = enabled;
      _savingAutoUpdate = true;
    });
    try {
      await _settings.savePlaylistAutoUpdate(enabled);
    } catch (_) {
      // The previous value remains authoritative if writing preferences fails.
      try {
        final saved = await _settings.loadPlaylistAutoUpdate();
        if (mounted) setState(() => _autoUpdate = saved);
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not save Spotify playlist auto-update setting.'),
        ));
      }
    } finally {
      if (mounted) setState(() => _savingAutoUpdate = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = _playlists.where((p) =>
        _showHidden || !_hidden.contains(p.id)).toList();
    return Scaffold(
    appBar: AppBar(
      title: const Text('Spotify playlists'),
      actions: [
        IconButton(
          tooltip: 'Refresh Spotify playlists',
          onPressed: _loading ? null : () => unawaited(_refresh()),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    ),
    body: Column(children: [
      SwitchListTile(
        dense: true,
        title: const Text('Auto-update playlists'),
        subtitle: const Text('Check at most once every 24 hours when opened'),
        value: _autoUpdate,
        onChanged: !_autoReady || _savingAutoUpdate
            ? null : (value) => unawaited(_setAutoUpdate(value)),
      ),
      if (_hidden.isNotEmpty)
        SwitchListTile(
          dense: true,
          title: Text('Show hidden playlists (${_hidden.length})'),
          value: _showHidden,
          onChanged: (value) => setState(() => _showHidden = value),
        ),
      Expanded(child: _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
            ? Center(child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  TextButton(onPressed: () => unawaited(_refresh()),
                      child: const Text('Retry')),
                ]),
              ))
            : visible.isEmpty
                ? Center(child: Text(_hidden.isNotEmpty
                    ? 'All playlists hidden. Show hidden playlists to restore them.'
                    : 'No saved Spotify playlists.'))
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final playlist = visible[index];
                        return ListTile(
                          leading: _SpotifyCover(url: playlist.imageUrl),
                          title: Text(playlist.name, maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          subtitle: playlist.owner?.isNotEmpty == true
                              ? Text(playlist.owner!, maxLines: 1,
                                  overflow: TextOverflow.ellipsis)
                              : null,
                          trailing: IconButton(
                            tooltip: _hidden.contains(playlist.id)
                                ? 'Show playlist' : 'Hide playlist',
                            icon: Icon(_hidden.contains(playlist.id)
                                ? Icons.visibility_rounded
                                : Icons.visibility_off_outlined),
                            onPressed: () => unawaited(_changeHidden(playlist.id,
                                !_hidden.contains(playlist.id))),
                          ),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => _SpotifyPlaylistDetail(
                                playlist: playlist, onPlay: widget.onPlay,
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

class _SpotifyCover extends StatelessWidget {
  const _SpotifyCover({this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final url = this.url;
    if (url == null || !url.startsWith('https://')) {
      return const SizedBox(
        width: 48, height: 48,
        child: Icon(Icons.library_music_rounded),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: Image.network(
        url, width: 48, height: 48, fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const SizedBox(
          width: 48, height: 48,
          child: Icon(Icons.library_music_rounded),
        ),
      ),
    );
  }
}

class _SpotifyPlaylistDetail extends ConsumerStatefulWidget {
  const _SpotifyPlaylistDetail({
    required this.playlist,
    required this.onPlay,
  });

  final SpotifyPlaylist playlist;
  final void Function(Song song, List<Song> queue) onPlay;

  @override
  ConsumerState<_SpotifyPlaylistDetail> createState() =>
      _SpotifyPlaylistDetailState();
}

class _SpotifyPlaylistDetailState
    extends ConsumerState<_SpotifyPlaylistDetail> {
  late final SpotifyWebApi _api;
  final SpotifyPlaylistCache _cache = SpotifyPlaylistCache.instance;
  List<LokalDiscoveryTrack> _tracks = const [];
  bool _loading = true;
  bool _refreshing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final settings = SpotifySettingsStore();
    _api = SpotifyWebApi(
      store: settings.tokenStore,
      oauth: SpotifyOAuthService(tokenStore: settings.tokenStore),
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final cached = await _cache.tracks(widget.playlist.id);
      if (!mounted) return;
      if (cached == null) {
        await _refresh();
        return;
      }
      setState(() {
        _tracks = cached.map(spotifyDiscoveryTrack).toList(growable: false);
        _loading = false;
        _error = null;
      });
      if (await _cache.shouldAutoUpdateTracks(widget.playlist.id) && mounted) {
        unawaited(_refresh(silent: true));
      }
    } catch (_) {
      if (mounted) setState(() {
        _loading = false;
        _error = 'Could not open the saved Spotify playlist.';
      });
    }
  }

  Future<void> _refresh({bool silent = false}) async {
    if (_refreshing) return;
    _refreshing = true;
    if (!silent) setState(() { _loading = true; _error = null; });
    try {
      final tracks = await _cache.refreshTracks(_api, widget.playlist.id);
      if (mounted) setState(() {
        _tracks = tracks.map(spotifyDiscoveryTrack).toList(growable: false);
        _error = null;
      });
    } catch (error) {
      if (mounted) {
        final message = error is SpotifyApiException
            ? error.message
            : 'Could not update this playlist.';
        if (_tracks.isEmpty) {
          setState(() => _error = message);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(message)),
          );
        }
      }
    } finally {
      _refreshing = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Song> _queue() {
    final index = KonnektedLibraryIndex.of(
      ref.read(konnektedLibraryProvider).value ?? const <Song>[],
    );
    // Each remote item remains metadata until Lokal's on-demand resolver
    // finds a playable source; Spotify cookie auth does not stream audio.
    return [
      for (final track in _tracks)
        index.match(track) ?? discoveryPendingSong(track),
    ];
  }

  void _play(int index) {
    if (index < 0 || index >= _tracks.length) return;
    final queue = _queue();
    if (queue.isNotEmpty) widget.onPlay(queue[index], queue);
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
      title: Text(widget.playlist.name),
      actions: [
        IconButton(
          tooltip: 'Refresh playlist',
          icon: const Icon(Icons.refresh_rounded),
          onPressed: _loading ? null : () => unawaited(_refresh()),
        ),
        IconButton(
          tooltip: 'Play all',
          icon: const Icon(Icons.play_arrow_rounded),
          onPressed: _loading || _tracks.isEmpty ? null : () => _play(0),
        ),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
            ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_error!, textAlign: TextAlign.center),
                ),
                TextButton(onPressed: () => unawaited(_refresh()),
                    child: const Text('Retry')),
              ]))
            : _tracks.isEmpty
                ? const Center(child: Text('No playable tracks in this playlist.'))
                : ListView.builder(
                    itemCount: _tracks.length,
                    itemBuilder: (context, index) {
                      final track = _tracks[index];
                      return ProviderPlaylistTrackTile(
                        track: track,
                        leading: _SpotifyCover(url: track.artworkUrl),
                        onPlay: () => _play(index),
                        onSongActions: () => _songActions(index),
                      );
                    },
                  ),
  );
}
