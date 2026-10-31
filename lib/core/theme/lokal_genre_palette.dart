import 'package:flutter/material.dart';

/// Semantic colour families for the editorial genre tiles. Dark chromatic
/// surfaces keep white type legible independently of the active accent preset.
/// The palette is deterministic: inserting a new genre never recolours the
/// existing ones.
@immutable
class LokalGenreTone {
  const LokalGenreTone(this.base, this.highlight, this.icon, this.italic);
  final Color base;
  final Color highlight;
  final IconData icon;
  final bool italic;
}

abstract final class LokalGenrePalette {
  static const foreground = Color(0xFFF9F7FF);

  static const _tones = <LokalGenreTone>[
    LokalGenreTone(Color(0xFF503787), Color(0xFF8260D1), Icons.graphic_eq_rounded, false),
    LokalGenreTone(Color(0xFF866011), Color(0xFFB88723), Icons.music_note_rounded, false),
    LokalGenreTone(Color(0xFF23503D), Color(0xFF3C8861), Icons.album_rounded, true),
    LokalGenreTone(Color(0xFF075B79), Color(0xFF1583AA), Icons.audiotrack_rounded, false),
    LokalGenreTone(Color(0xFF713B55), Color(0xFFA45D7F), Icons.music_video_rounded, true),
    LokalGenreTone(Color(0xFF514F80), Color(0xFF757CB9), Icons.piano_rounded, false),
    LokalGenreTone(Color(0xFF854D28), Color(0xFFB97443), Icons.headphones_rounded, false),
    LokalGenreTone(Color(0xFF22586B), Color(0xFF33859A), Icons.equalizer_rounded, true),
    LokalGenreTone(Color(0xFF4C6224), Color(0xFF77913D), Icons.library_music_rounded, false),
    LokalGenreTone(Color(0xFF76404A), Color(0xFFA9616D), Icons.radio_rounded, true),
    LokalGenreTone(Color(0xFF36517A), Color(0xFF527AAB), Icons.music_note_rounded, false),
    LokalGenreTone(Color(0xFF604784), Color(0xFF9171C0), Icons.queue_music_rounded, true),
  ];

  static LokalGenreTone of(String name) {
    final normalized = name.trim().toLowerCase();
    // Genre names remain portable between local-only and linked desktop
    // libraries. Explicit families match the inspiration's clear colour cues.
    if (normalized.contains('jazz')) return _tones[0];
    if (normalized.contains('afro')) return _tones[1];
    if (normalized.contains('indie') || normalized.contains('alternative')) return _tones[2];
    if (normalized.contains('r&b') || normalized.contains('soul')) return _tones[3];
    if (normalized.contains('hip') || normalized.contains('rap')) return _tones[7];
    if (normalized.contains('rock')) return _tones[4];
    if (normalized.contains('electronic') || normalized.contains('dance')) return _tones[5];
    if (normalized.contains('pop')) return _tones[9];
    if (normalized.contains('classical')) return _tones[10];
    if (normalized.contains('soundtrack')) return _tones[11];
    var hash = 0;
    for (final unit in normalized.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return _tones[hash % _tones.length];
  }
}
