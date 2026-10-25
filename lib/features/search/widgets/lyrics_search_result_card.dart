import 'package:flutter/material.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/l10n/l10n.dart';

/// Library lyrics-search styling shared by local matches and online records.
class LyricsSearchResultCard extends StatelessWidget {
  const LyricsSearchResultCard({
    super.key,
    required this.title,
    required this.artist,
    this.album,
    required this.snippet,
    required this.onPlay,
  });
  final String title;
  final String artist;
  final String? album;
  final String snippet;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: t.surface2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: t.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPlay,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: t.text,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            [
                              artist,
                              if (album?.isNotEmpty ?? false) album!,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: t.muted, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      lokalText('Play').toUpperCase(),
                      style: TextStyle(
                        color: t.accent,
                        fontSize: 10,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.play_arrow_rounded, color: t.accent, size: 17),
                  ],
                ),
                if (snippet.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    snippet,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.muted, fontSize: 12, height: 1.4),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String lyricsResultSnippet(String text, String query) {
  final lines = text
      .split(RegExp(r'\r?\n'))
      .map(
        (line) => line
            .replaceAll(
              RegExp(
                r'\[(?:\d{1,3}:\d{2}(?:[.:]\d{1,3})?|(?:ar|ti|al|by|offset|length|re|ve):[^\]]*)\]',
                caseSensitive: false,
              ),
              '',
            )
            .trim(),
      )
      .where((line) => line.isNotEmpty)
      .toList();
  final needle = query.trim().toLowerCase();
  final matching = needle.isEmpty
      ? null
      : lines.where((line) => line.toLowerCase().contains(needle)).firstOrNull;
  final result = matching ?? lines.take(2).join(' · ');
  return result.length > 240 ? result.substring(0, 240) : result;
}
