import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flick/models/song.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flick/services/lyrics_sources.dart';

String lyricsTimingLabel(LyricsData? lyrics) => lyrics == null
    ? 'Not found'
    : lyrics.lines.any((l) => l.words?.isNotEmpty == true)
    ? 'Syllable'
    : lyrics.isSynchronized
    ? 'Line'
    : 'Plain';
String lyricsSourceLabel(LyricsData? lyrics, String selected) =>
    lyricsSources[lyrics?.source] ??
    (lyrics?.source != null && lyrics!.source!.contains('/')
        ? 'Local file'
        : lyrics?.source) ??
    (selected == 'auto'
        ? 'Automatic'
        : selected == 'local'
        ? 'Local file'
        : lyricsSources[selected] ?? selected);

class LyricsSourceButton extends StatelessWidget {
  const LyricsSourceButton({
    super.key,
    required this.selected,
    required this.lyrics,
    required this.song,
    required this.lyricsService,
    required this.onSelected,
    required this.onRefresh,
    this.busy = false,
  });
  final String selected;
  final LyricsData? lyrics;
  final Song song;
  final LyricsService lyricsService;
  final bool busy;
  final ValueChanged<String> onSelected;
  final VoidCallback onRefresh;
  Future<void> _show(BuildContext context) async {
    // Availability checks are on-demand: opening the chooser starts bounded
    // searches and reuses recent results; playback itself does not fan out.
    unawaited(lyricsService.probeSourceHits(song));
    final t = context.lokal;
    final choice = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: t.surface,
      barrierColor: Colors.black.withValues(alpha: .45),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => ValueListenableBuilder<int>(
        valueListenable: LyricsService.sourceHitsRevision,
        builder: (context, _, __) => SafeArea(
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: .65,
          minChildSize: .35,
          maxChildSize: .9,
          builder: (context, scroll) => ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 18),
                  decoration: BoxDecoration(
                    color: t.muted.withValues(alpha: .35),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              Text(
                'Lyrics source',
                style: TextStyle(
                  color: t.text,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${lyricsSourceLabel(lyrics, selected)} · ${lyricsTimingLabel(lyrics)}',
                style: TextStyle(color: t.accent),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.refresh_rounded),
                title: const Text('Refresh search'),
                subtitle: const Text(
                  'Search this source again; keep existing lyrics on a miss.',
                ),
                enabled: !busy,
                onTap: () => Navigator.pop(context, '__refresh'),
              ),
              const Divider(),
              for (final source in {
                'auto': 'Automatic',
                'local': 'Local file',
                ...lyricsSources,
              }.entries)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  selected: selected == source.key,
                  selectedTileColor: t.accent.withValues(alpha: .1),
                  title: Text(source.value),
                  subtitle: Text(
                    source.key != 'auto' &&
                            LyricsService.sourceHitFor(song, source.key) case final hit?
                        ? '${hit.status == 'hit' ? 'Found · ${hit.timing}' : hit.status == 'checking' ? 'Checking…' : 'No result'}'
                        : source.key == 'auto'
                        ? 'Use your priority order and keep the best timing'
                        : source.key == 'local'
                        ? 'Copied, sidecar or embedded lyrics'
                        : source.key == 'lrclib'
                        ? 'Line-synced and plain lyrics'
                        : source.key == 'lyricsovh'
                        ? 'Plain lyrics'
                        : 'Supports syllable / word timing',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (LyricsService.sourceHitFor(song, source.key)?.status == 'hit')
                        const Icon(Icons.check_circle_rounded,
                            color: Colors.greenAccent, size: 18),
                      if (LyricsService.sourceHitFor(song, source.key)?.status == 'checking')
                        const SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      if (selected == source.key)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Icon(Icons.check_rounded, color: t.accent),
                        ),
                    ],
                  ),
                  onTap: () => Navigator.pop(context, source.key),
                ),
            ],
          ),
        ),
        ),
      ),
    );
    if (!context.mounted) return;
    if (choice == '__refresh') {
      onRefresh();
    } else if (choice != null) {
      onSelected(choice);
    }
  }

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: () => _show(context),
    style: TextButton.styleFrom(
      foregroundColor: context.lokal.text,
      visualDensity: VisualDensity.compact,
    ),
    icon: busy
        ? const SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.tune_rounded, size: 19),
    label: Text(
      lyricsTimingLabel(lyrics),
      style: const TextStyle(fontSize: 12),
    ),
  );
}
