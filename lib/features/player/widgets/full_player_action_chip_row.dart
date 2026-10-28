import 'package:flutter/material.dart';

import '../../link/lokal_devices_card.dart';

import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/features/player/widgets/sleep_timer_bottom_sheet.dart';
import 'package:flick/features/player/widgets/speed_bottom_sheet.dart';
import 'package:flick/features/player/widgets/pitch_bottom_sheet.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/l10n/l10n.dart';

/// The labeled action strip used by the artwork-card player.
///
/// Keep this separate from [PlayerActionButtonRow]: the latter is deliberately
/// configurable and icon-first, while the full player reference design has a
/// stable, discoverable set of labeled actions that can scroll on narrow phones.
class FullPlayerActionChipRow extends StatelessWidget {
  const FullPlayerActionChipRow({
    super.key,
    required this.playerService,
    required this.lyricsActive,
    required this.onOpenQueue,
    required this.onToggleLyrics,
    required this.onOpenEqualizer,
    this.compactTransformsOnly = false,
  });

  final PlayerService playerService;
  final bool lyricsActive;
  final VoidCallback onOpenQueue;
  final VoidCallback onToggleLyrics;
  final VoidCallback onOpenEqualizer;

  /// In immersive layout, only show Speed, Pitch, and EQ in the footer.
  /// Artwork-card layout keeps its existing broader action strip.
  final bool compactTransformsOnly;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height:
          context.responsive(48, 52, 56) +
          (MediaQuery.textScalerOf(context).scale(14) / 14 - 1).clamp(0, 2) *
              20,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(
          horizontal: context.responsive(16, 20, 24),
        ),
        children: [
          if (!compactTransformsOnly) ...[
            const Center(child: LokalOutputPill()),
            _ActionChip(
              icon: LucideIcons.listMusic,
              label: l10n.queue,
              onTap: onOpenQueue,
            ),
            _ActionChip(
              icon: LucideIcons.messageSquareQuote,
              label: l10n.lyrics,
              active: lyricsActive,
              onTap: onToggleLyrics,
            ),
            _ActionChip(
              icon: LucideIcons.moonStar,
              label: l10n.sleepTimer,
              onTap: () => SleepTimerBottomSheet.show(context, playerService),
            ),
          ],
          _ActionChip(
            icon: LucideIcons.gauge,
            label: l10n.speedUp,
            onTap: () => SpeedBottomSheet.show(context, playerService),
          ),
          ValueListenableBuilder<double>(
            valueListenable: playerService.pitchSemitonesNotifier,
            builder: (_, pitch, __) => _ActionChip(
              key: const ValueKey('full-player-pitch'),
              icon: Icons.graphic_eq_rounded,
              semanticLabel:
                  '${l10n.pitch}: ${l10n.pitchSemitones(pitch.round())}',
              label: pitch.abs() < 0.01
                  ? l10n.pitch
                  : '${pitch > 0 ? '+' : ''}${pitch.toStringAsFixed(0)} st',
              active: pitch.abs() >= 0.01,
              onTap: () => PitchBottomSheet.show(context, playerService),
            ),
          ),
          _ActionChip(
            icon: LucideIcons.slidersHorizontal,
            label: l10n.equalizer,
            onTap: onOpenEqualizer,
          ),
        ],
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.semanticLabel,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = context.lokal;
    final accent = tokens.accent;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Semantics(
        button: true,
        label: semanticLabel ?? label,
        selected: active,
        onTap: onTap,
        excludeSemantics: true,
        child: Material(
          color: active
              ? accent.withValues(alpha: 0.24)
              : tokens.text.withValues(alpha: 0.045),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: active ? accent.withValues(alpha: 0.65) : tokens.border,
            ),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: context.responsive(17, 19, 21),
                    color: active ? accent : tokens.text,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: TextStyle(
                      fontFamily: 'GoogleSansFlex',
                      fontSize: context.responsive(13, 14, 15),
                      fontWeight: FontWeight.w500,
                      color: tokens.text,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
