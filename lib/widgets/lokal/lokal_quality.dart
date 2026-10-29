import 'package:flick/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_appearance.dart';
import 'package:flick/features/player/widgets/full_player_visuals.dart';
import 'package:flick/services/catalogue_quality.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/models/song.dart';

/// Desktop Lokal's audio quality tiers (`src/quality.js`), with its exact
/// colours. They stay the same on every theme, as on desktop.
enum LokalQualityTier {
  unknown(
    'Not read',
    'Audio details have not been read yet',
    Color(0xFF777777),
    Color(0xFFBBBBBB),
    Color(0xFF999999),
  ),
  hiRes(
    'Hi-res',
    'Lossless, more than 16-bit or 48 kHz',
    // violet-500/15, violet-300, violet-400/25 (Tailwind v4)
    Color(0xFF8E51FF),
    Color(0xFFC4B4FF),
    Color(0xFFA684FF),
  ),
  lossless(
    'Lossless',
    'Lossless, 16-bit up to 48 kHz',
    // green-500/15, green-300, green-400/25
    Color(0xFF00C950),
    Color(0xFF7BF1A8),
    Color(0xFF05DF72),
  ),
  high(
    'High',
    'MP3/AAC at 256 kbps or more, Opus/Vorbis at 160 kbps or more',
    // sky-500/15, sky-300, sky-400/25
    Color(0xFF00A6F4),
    Color(0xFF74D4FF),
    Color(0xFF00BCFF),
  ),
  low(
    'Low',
    'MP3/AAC under 256 kbps, Opus/Vorbis under 160 kbps',
    // yellow-500/15, yellow-200, yellow-400/25
    Color(0xFFF0B100),
    Color(0xFFFFF085),
    Color(0xFFFDC700),
  );

  const LokalQualityTier(
    this.label,
    this.hint,
    this.fill,
    this.text,
    this.border,
  );

  final String label;
  final String hint;
  final Color fill;
  final Color text;
  final Color border;

  static const _lossless = {
    'FLAC',
    'WAV',
    'WAVE',
    'ALAC',
    'AIFF',
    'AIF',
    'APE',
    'WV',
    'WAVPACK',
  };
  static final _kbps = RegExp(
    r'(\d+(?:\.\d+)?)\s*(?:kbps|kb/s|kbit/s)',
    caseSensitive: false,
  );
  static final _opusLike = RegExp(
    r'^(?:opus|ogg|vorbis)',
    caseSensitive: false,
  );

  /// The tier desktop would show for [song], or null when there is nothing to
  /// tell (a lossy file whose bitrate was never read).
  static LokalQualityTier? of(Song song) {
    if (song.isPending) return null;
    final type = song.fileType.toUpperCase();
    if (song.isDsd || _lossless.contains(type)) {
      final aboveCd =
          song.isDsd ||
          (song.bitDepth ?? 0) > 16 ||
          (song.sampleRate ?? 0) > 48000;
      if (aboveCd) return hiRes;
      if ((song.bitDepth ?? 0) <= 0 || (song.sampleRate ?? 0) <= 0)
        return unknown;
      return lossless;
    }
    final match = _kbps.firstMatch(song.resolution ?? '');
    final kbps = match == null
        ? 0
        : (double.tryParse(match.group(1)!) ?? 0).round();
    if (kbps == 0) return unknown;
    final threshold = _opusLike.hasMatch(song.fileType) ? 160 : 256;
    return kbps >= threshold ? high : low;
  }
}

/// Explicit source resolution for labels, not a claim about the current
/// output path. Absent measurements stay absent: a codec, catalogue tier or
/// lossy decoder PCM width does not establish bit depth/sample rate.
String? lokalSongResolutionLabel(Song song) {
  if (song.isPending) return null;
  if (song.isDsd) return song.dsdRateLabel;

  final codec = song.fileType.trim().toUpperCase();
  const lossless = {
    'FLAC',
    'WAV',
    'WAVE',
    'ALAC',
    'AIFF',
    'AIF',
    'APE',
    'WV',
    'WAVPACK',
  };
  final raw = song.resolution ?? '';
  final pair = compactAudioResolution(raw);
  final bitMatch = RegExp(
    r'(?<!\d)(\d{1,2})\s*-?\s*bits?\b',
    caseSensitive: false,
  ).firstMatch(raw);
  final rateMatch = RegExp(
    r'(?<![\d.])(\d{2,3}(?:\.\d+)?)\s*k(?:hz)?\b',
    caseSensitive: false,
  ).firstMatch(raw);
  final bitrateMatch = RegExp(
    r'(?<!\d)(\d{2,4}(?:\.\d+)?)\s*(?:kbps|kb/s|kbit/s)\b',
    caseSensitive: false,
  ).firstMatch(raw);

  final depth = lossless.contains(codec)
      ? (song.bitDepth ??
            pair?.bitDepth ??
            int.tryParse(bitMatch?.group(1) ?? ''))
      : null;
  final rate =
      song.sampleRate ??
      pair?.sampleRate ??
      ((double.tryParse(rateMatch?.group(1) ?? '') ?? 0) * 1000).round();
  final parts = <String>[];
  // Lossy decoded PCM precision is not the source's encoded bit depth.
  if (depth != null &&
      depth >= 8 &&
      depth <= 64 &&
      (lossless.contains(codec) || bitMatch != null || pair != null)) {
    parts.add('$depth-bit');
  }
  if (rate >= 8000 && rate <= 768000) {
    final khz = rate / 1000;
    parts.add(
      '${khz == khz.roundToDouble() ? khz.toStringAsFixed(0) : khz.toStringAsFixed(1)} kHz',
    );
  }
  if (!lossless.contains(codec) && bitrateMatch != null) {
    parts.insert(0, '${bitrateMatch.group(1)} kbps');
  }
  if (parts.isEmpty) return null;
  const unknown = {'', 'UNKNOWN', 'ONLINE', 'N/A', 'OTHER'};
  final format = unknown.contains(codec) ? '' : codec;
  return [if (format.isNotEmpty) format, parts.join(' / ')].join(' · ');
}

/// Desktop's quality pill: Hi-res, Lossless, High or Low.
class LokalQualityPill extends ConsumerWidget {
  const LokalQualityPill({
    super.key,
    required this.tier,
    this.icon,
    this.song,
    this.fullPlayer = false,
  });

  final LokalQualityTier tier;
  final Song? song;
  final bool fullPlayer;

  /// An extra mark before the label, e.g. verified bit-perfect output.
  final IconData? icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showResolution = ref.watch(
      lokalAppearanceProvider.select(
        (look) => fullPlayer
            ? look.resolutionTagsInFullPlayer
            : look.resolutionTagsInLists,
      ),
    );
    final resolution = showResolution && song != null
        ? lokalSongResolutionLabel(song!)
        : null;
    final display = resolution ?? tier.label;
    final textColor = fullPlayer ? FullPlayerVisuals.primaryText : tier.text;
    return Semantics(
      label: resolution == null
          ? lokalText(
              "{arg0} quality. {arg1}",
              args: {'arg0': tier.label, 'arg1': tier.hint},
            )
          : display,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: tier.fill.withValues(alpha: .15),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: tier.border.withValues(alpha: .25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 10, color: textColor),
              const SizedBox(width: 3),
            ],
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: (MediaQuery.sizeOf(context).width * .48)
                    .clamp(100.0, 240.0)
                    .toDouble(),
              ),
              child: Text(
                display,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: LokalTheme.label(
                  context.lokal,
                  size: 10,
                  color: textColor,
                ).copyWith(letterSpacing: .4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dolby Atmos is a Tidal catalogue mode, NOT a PCM quality tier.
/// In particular, this never asserts that the current output is Atmos.
class LokalAtmosPill extends StatelessWidget {
  const LokalAtmosPill({super.key});

  static const String description =
      "Tidal offers an Atmos version. Lokal requests the original E-AC-3 JOC stream when Android's native decoder or passthrough route supports it.";

  @override
  Widget build(BuildContext context) => Tooltip(
    message: description,
    child: Semantics(
      label: description,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFF8E51FF).withValues(alpha: .15),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: const Color(0xFFA684FF).withValues(alpha: .25),
          ),
        ),
        child: Text(
          'ATMOS',
          style: LokalTheme.label(
            context.lokal,
            size: 10,
            color: const Color(0xFFC4B4FF),
          ).copyWith(letterSpacing: .4),
        ),
      ),
    ),
  );
}

/// Shown only when Android MediaExtractor verified the downloaded source as
/// E-AC-3 JOC and it was routed to the native Android audio engine.
class LokalAtmosStreamPill extends StatelessWidget {
  const LokalAtmosStreamPill({super.key});

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'E-AC-3 JOC Dolby Atmos stream. Final spatial rendering depends on the connected device.',
    child: Semantics(
      label: 'Dolby Atmos E-AC-3 JOC encoded stream',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFA684FF)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          'DOLBY ATMOS',
          style: LokalTheme.label(
            context.lokal,
            size: 10,
            color: const Color(0xFFC4B4FF),
          ),
        ),
      ),
    ),
  );
}
