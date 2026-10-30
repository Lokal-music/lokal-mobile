import 'package:flutter/material.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flick/services/online_lyrics_service.dart';

/// Same manual flow as desktop: title + artist, search, select a result.
/// A bounded in-memory session retains edits/results when reopening a song.
class LyricsSearchSession {
  LyricsSearchSession(Song song) : title = song.title, artist = song.artist;
  String title, artist;
  List<OnlineLyricsResult> results = [];
  bool searched = false;
}

class OnlineLyricsSearchSheet extends StatefulWidget {
  const OnlineLyricsSearchSheet({
    super.key,
    required this.song,
    required this.lyricsService,
    this.onlineService,
    this.session,
  });
  final Song song;
  final LyricsService lyricsService;
  final OnlineLyricsService? onlineService;
  final LyricsSearchSession? session;
  static final _sessions = <String, LyricsSearchSession>{};
  static Future<bool?> show({
    required BuildContext context,
    required Song song,
    required LyricsService lyricsService,
  }) {
    final key = '${song.id}|${song.filePath}';
    final session = _sessions.putIfAbsent(key, () => LyricsSearchSession(song));
    while (_sessions.length > 20) {
      _sessions.remove(_sessions.keys.first);
    }
    final t = context.lokal;
    return showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: t.surface,
      barrierColor: Colors.black.withValues(alpha: .5),
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: FractionallySizedBox(
          heightFactor: .88,
          child: OnlineLyricsSearchSheet(
            song: song,
            lyricsService: lyricsService,
            session: session,
          ),
        ),
      ),
    );
  }

  @override
  State<OnlineLyricsSearchSheet> createState() =>
      _OnlineLyricsSearchSheetState();
}

class _OnlineLyricsSearchSheetState extends State<OnlineLyricsSearchSheet> {
  late final _session = widget.session ?? LyricsSearchSession(widget.song);
  late final _title = TextEditingController(text: _session.title);
  late final _artist = TextEditingController(text: _session.artist);
  late final _online = widget.onlineService ?? OnlineLyricsService();
  bool _searching = false, _saving = false;
  int _generation = 0;
  String? _error;
  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    super.dispose();
  }

  void _edit(String _) {
    _generation++;
    setState(() {
      _session.title = _title.text;
      _session.artist = _artist.text;
      _session.results = [];
      _session.searched = false;
      _searching = false;
      _error = null;
    });
  }

  Future<void> _search() async {
    final title = _title.text.trim(), artist = _artist.text.trim();
    if (title.isEmpty || artist.isEmpty || _searching || _saving) return;
    FocusScope.of(context).unfocus();
    final generation = ++_generation;
    setState(() {
      _searching = true;
      _error = null;
      _session.results = [];
    });
    try {
      final results = await _online.search(
        title: title,
        artist: artist,
        refresh: true,
        reportErrors: true,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _session.results = results;
        _session.searched = true;
        _searching = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _searching = false;
        if (error is OnlineLyricsHttpException) {
          final retryAfter = error.retryAfter;
          final retryHint = retryAfter != null && retryAfter.inSeconds > 0
              ? ' Retry in ${retryAfter.inSeconds} seconds.'
              : ' Try again shortly.';
          _error = switch (error.statusCode) {
            429 => 'Lyrics service rate limit reached.$retryHint',
            503 => 'Lyrics service is temporarily busy.$retryHint',
            _ => 'Lyrics service returned HTTP ${error.statusCode}. Please retry.',
          };
        } else if (error is FormatException || error is TypeError) {
          _error = 'Lyrics service returned an invalid response. Please retry.';
        } else {
          _error = 'Could not reach the lyrics service. Check your connection and retry.';
        }
      });
    }
  }

  Future<void> _select(OnlineLyricsResult result) async {
    if (_saving || result.bestLyrics.trim().isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    var content = result.bestLyrics;
    if (result.hasSyncedLyrics && widget.song.duration > Duration.zero) {
      content =
          '${widget.lyricsService.formatLengthTag(widget.song.duration)}\n${content.replaceAll(RegExp(r'^\[length:[^\]]*\]\s*', multiLine: true), '')}';
    }
    try {
      await widget.lyricsService.importLyricsForSong(
        song: widget.song,
        fileName: result.hasSyncedLyrics ? 'online.lrc' : 'online.txt',
        content: content,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted)
        setState(() {
          _saving = false;
          _error = 'Could not save these lyrics. Tap the result to retry.';
        });
    }
  }

  String _duration(double? seconds) {
    if (seconds == null || seconds <= 0) return '--:--';
    return '${seconds ~/ 60}:${(seconds.toInt() % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    InputDecoration field(String label) => InputDecoration(
      labelText: label,
      filled: true,
      fillColor: t.surface2,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    );
    return SafeArea(
      top: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Search lyrics',
                    style: TextStyle(
                      color: t.text,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Expanded(
            child: CustomScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          key: const ValueKey('lyrics-search-title'),
                          controller: _title,
                          decoration: field('Title'),
                          onChanged: _edit,
                          enabled: !_saving,
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const ValueKey('lyrics-search-artist'),
                          controller: _artist,
                          decoration: field('Artist'),
                          onChanged: _edit,
                          enabled: !_saving,
                          textInputAction: TextInputAction.search,
                          onSubmitted: (_) => _search(),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed:
                              _searching ||
                                  _saving ||
                                  _title.text.trim().isEmpty ||
                                  _artist.text.trim().isEmpty
                              ? null
                              : _search,
                          icon: _searching || _saving
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.search_rounded, size: 18),
                          label: Text(
                            _saving
                                ? 'Saving…'
                                : _searching
                                ? 'Searching…'
                                : 'Search',
                          ),
                        ),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        const SizedBox(height: 16),
                        if (_session.results.isEmpty &&
                            !_searching &&
                            _error == null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: Text(
                              _session.searched
                                  ? 'Nothing found. Try a shorter title.'
                                  : 'Enter title and artist to search.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: t.muted),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                  sliver: SliverList.builder(
                    itemCount: _session.results.length,
                    itemBuilder: (context, index) {
                      final result = _session.results[index],
                          usable = result.bestLyrics.trim().isNotEmpty;
                      return ListTile(
                        enabled: usable && !_saving,
                        onTap: () => _select(result),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        title: Text(
                          result.trackName ?? widget.song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          [
                            result.artistName ?? widget.song.artist,
                            if (result.albumName?.isNotEmpty == true)
                              result.albumName!,
                          ].join('\n'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              _duration(result.duration),
                              style: TextStyle(fontSize: 12, color: t.muted),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              result.instrumental
                                  ? 'Instrumental'
                                  : result.hasSyncedLyrics
                                  ? 'Synced'
                                  : 'Plain',
                              style: TextStyle(
                                fontSize: 11,
                                color: result.hasSyncedLyrics
                                    ? t.accent
                                    : t.muted,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
