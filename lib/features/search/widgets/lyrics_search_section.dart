import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/services/link/library_song_identity.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flick/services/online_lyrics_service.dart';
import 'package:flick/services/online_playlist_reference.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';

typedef _LyricHit = ({Song song, String line});
typedef _LyricProgress = ({List<_LyricHit> hits, int checked, int total});

/// Lyrics on local files are indexed incrementally and without online
/// lookups. Do not parse all 5,000+ songs on the UI thread in one frame.
/// Online mode queries LRCLIB lyric records by track/artist/album keywords;
/// LRCLIB does not provide a full-text lyric-line search API.
class LyricsSearchSection extends ConsumerStatefulWidget {
  const LyricsSearchSection({
    super.key, required this.query, required this.online,
    required this.onPlayLocal,
  });
  final String query;
  final bool online;
  final Future<void> Function(Song song, List<Song> playlist) onPlayLocal;

  @override
  ConsumerState<LyricsSearchSection> createState() => _LyricsSearchSectionState();
}

class _LyricsSearchSectionState extends ConsumerState<LyricsSearchSection> {
  final _lyrics = LyricsService();
  final _online = OnlineLyricsService();
  // Shared between query revisions: do not re-read thousands of files on
  // each keystroke or each scope/category switch.
  static final _textCache = <String, List<String>>{};
  Stream<_LyricProgress>? _localResults;
  Future<List<OnlineLyricsResult>>? _onlineResults;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    LyricsService.contentRevision.addListener(_onContentChanged);
    _reload();
  }

  void _onContentChanged() {
    _textCache.clear();
    if (mounted && !widget.online) {
      setState(_reload);
    }
  }

  @override
  void dispose() {
    LyricsService.contentRevision.removeListener(_onContentChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant LyricsSearchSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query || oldWidget.online != widget.online) {
      _reload();
    }
  }

  void _reload() {
    if (widget.online) {
      _onlineResults = _online.search(query: widget.query, reportErrors: true);
      _localResults = null;
    } else {
      _localResults = _searchLocal(widget.query);
      _onlineResults = null;
    }
  }

  Stream<_LyricProgress> _searchLocal(String query) async* {
    final loaded = ref.read(songsProvider).value?.songs ??
        await ref.read(songRepositoryProvider).getAllSongs();
    final songs = preferLocalLibrarySongs(loaded)
        .where((s) => s.filePath != null && s.filePath!.isNotEmpty)
        .toList(growable: false);
    final needle = query.trim().toLowerCase();
    final sourceRevision = LyricsService.contentRevision.value;
    final hits = <_LyricHit>[];
    var scanned = 0;
    for (final song in songs) {
      if (!mounted || sourceRevision != LyricsService.contentRevision.value) {
        return;
      }
      final key = '${song.id}|${song.filePath}|${song.fileSizeBytes ?? 0}|$sourceRevision';
      var lines = _textCache[key];
      if (lines == null) {
        var readSucceeded = false;
        try {
          final own = await _lyrics.loadLyricsForSong(
            song, fetchOnline: false, source: 'local',
          );
          lines = own?.lines.map((line) => line.text).toList() ?? <String>[];
          readSucceeded = true;
        } catch (_) {
          // Transient file/storage exceptions must be retried next time.
          lines = <String>[];
        }
        if (sourceRevision != LyricsService.contentRevision.value) return;
        if (readSucceeded) {
          if (_textCache.length >= 6000) _textCache.remove(_textCache.keys.first);
          _textCache[key] = lines;
        }
      }
      final matching = lines.where((line) =>
          line.toLowerCase().contains(needle)).firstOrNull;
      if (matching != null) hits.add((song: song, line: matching));
      scanned++;
      if (scanned % 24 == 0 || scanned == songs.length) {
        yield (hits: List<_LyricHit>.of(hits), checked: scanned, total: songs.length);
        // Yield to the UI and transport controls during large library scans.
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    if (songs.isEmpty) yield (hits: const [], checked: 0, total: 0);
  }

  Song _pending(OnlineLyricsResult row) => stableOnlinePlaylistSong(Song(
    id: 'lyrics:${row.id}',
    title: row.trackName ?? '',
    artist: row.artistName ?? '',
    album: row.albumName,
    duration: Duration(milliseconds: ((row.duration ?? 0) * 1000).round()),
    fileType: 'ONLINE',
    sourcePackage: Song.pendingSourcePackage,
  ));

  Future<void> _playOnline(OnlineLyricsResult selected, List<OnlineLyricsResult> rows) async {
    if (_playing) return;
    setState(() => _playing = true);
    try {
      final queue = [for (final row in rows) _pending(row)];
      LokalToast.show(context,
          'Finding ${selected.trackName} through your playback sources…');
      await ref.read(playerProvider.notifier).play(_pending(selected), playlist: queue);
    } catch (_) {
      if (mounted) LokalToast.show(context, 'Could not start this song.');
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    if (widget.online) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Online lyrics', style: TextStyle(color: t.text, fontSize: 17,
              fontWeight: FontWeight.w600)),
          Text('LRCLIB catalogue · searchable by song, artist and album name (not lyric-line text)',
              style: TextStyle(color: t.muted, fontSize: 11)),
          const SizedBox(height: 8),
          FutureBuilder<List<OnlineLyricsResult>>(
            future: _onlineResults,
            builder: (context, snapshot) {
              if (snapshot.hasError) return Text('Online lyrics unavailable.',
                  style: TextStyle(color: t.muted));
              if (!snapshot.hasData) return const CircularProgressIndicator();
              final rows = snapshot.data!.where((r) =>
                  !r.instrumental && (r.hasPlainLyrics || r.hasSyncedLyrics) &&
                  (r.trackName?.isNotEmpty ?? false) &&
                  (r.artistName?.isNotEmpty ?? false)).toList();
              if (rows.isEmpty) return Text('No online lyrics records found.',
                  style: TextStyle(color: t.muted));
              return Column(children: [
                for (final row in rows)
                  ListTile(
                    dense: true, contentPadding: EdgeInsets.zero,
                    enabled: !_playing,
                    leading: const Icon(Icons.lyrics_outlined),
                    title: Text(row.trackName!, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${row.artistName} · ${row.snippet ?? ''}',
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: const Icon(Icons.play_arrow_rounded),
                    onTap: () => unawaited(_playOnline(row, rows)),
                  ),
              ]);
            },
          ),
        ]),
      );
    }
    // Owns its scroll view: SliverList.builder creates only visible rows
    // instead of rebuilding thousands of ListTiles on every scan update.
    return StreamBuilder<_LyricProgress>(
      stream: _localResults,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Could not search saved lyrics.',
                style: TextStyle(color: t.muted)),
          );
        }
        final data = snapshot.data;
        final hits = data?.hits ?? const <_LyricHit>[];
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Lyrics matches', style: TextStyle(
                        color: t.text, fontSize: 17,
                        fontWeight: FontWeight.w600)),
                    Text('Searches lyrics saved with your local library',
                        style: TextStyle(color: t.muted, fontSize: 11)),
                    const SizedBox(height: 8),
                    if (data == null) const CircularProgressIndicator(),
                    if (data != null && data.checked < data.total)
                      Text('Scanning saved lyrics · ${data.checked}/${data.total}',
                          style: TextStyle(color: t.muted, fontSize: 11)),
                    if (data != null && data.checked == data.total && hits.isEmpty)
                      Text('No lyrics matches in your library.',
                          style: TextStyle(color: t.muted)),
                  ],
                ),
              ),
            ),
            if (hits.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList.builder(
                  itemCount: hits.length,
                  itemBuilder: (context, index) {
                    final hit = hits[index];
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(hit.song.title),
                      subtitle: Text('${hit.song.artist} · ${hit.line}',
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: const Icon(Icons.play_arrow_rounded),
                      onTap: () => unawaited(widget.onPlayLocal(
                        hit.song, hits.map((entry) => entry.song).toList(),
                      )),
                    );
                  },
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 120)),
          ],
        );
      },
    );
  }
}
