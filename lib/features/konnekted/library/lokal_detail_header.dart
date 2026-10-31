import 'package:flutter/material.dart';

import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/widgets/lokal/lokal_glass.dart';

/// The artist and album headers share chrome, but not artwork treatment:
/// artists get a photographic canvas; albums get an actual framed cover.
/// This avoids stretching square covers across an entire phone display.
class LokalDetailHeader extends StatelessWidget {
  const LokalDetailHeader({
    super.key,
    required this.title,
    required this.artwork,
    required this.isArtist,
    required this.background,
    required this.onBack,
    required this.onShare,
    required this.onMore,
    this.artistCredit,
  });

  final String title;
  final Widget artwork;
  final Widget? artistCredit;
  final bool isArtist;
  final Color background;
  final VoidCallback onBack, onShare, onMore;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final size = MediaQuery.sizeOf(context);
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.8);
    final topInset = MediaQuery.paddingOf(context).top;
    final artSize = (size.width * (size.width > 620 ? .36 : .63))
        .clamp(184.0, 314.0);
    final heroHeight = isArtist
        ? (size.height * .52 + (scale - 1) * 90).clamp(350.0, 580.0)
        : artSize + 180 + topInset + (scale - 1) * 92;

    return SizedBox(
      height: heroHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: isArtist
                    ? const Alignment(0, -.5)
                    : const Alignment(0, -.2),
                radius: 1.15,
                colors: [Color.lerp(background, t.accent, .10)!, background],
              ),
            ),
          ),
          if (isArtist) ...[
            RepaintBoundary(child: artwork),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0, .3, .63, 1],
                  colors: [
                    Colors.black.withValues(alpha: .50),
                    Colors.transparent,
                    background.withValues(alpha: .53),
                    background,
                  ],
                ),
              ),
            ),
          ] else
            Positioned(
              top: topInset + 76,
              left: 24,
              right: 24,
              child: Center(
                child: Container(
                  width: artSize,
                  height: artSize,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(23),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .25),
                        blurRadius: 32,
                        offset: const Offset(0, 14),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(23),
                    child: RepaintBoundary(child: artwork),
                  ),
                ),
              ),
            ),
          Positioned(
            left: 20,
            right: 20,
            top: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  children: [
                    _headerButton(
                      context,
                      Icons.arrow_back_rounded,
                      l10n.back,
                      onBack,
                    ),
                    const Spacer(),
                    _headerButton(
                      context,
                      Icons.ios_share_rounded,
                      l10n.share,
                      onShare,
                    ),
                    const SizedBox(width: 10),
                    _headerButton(
                      context,
                      Icons.more_horiz_rounded,
                      lokalText('More'),
                      onMore,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isArtist ? 'ARTIST' : 'ALBUM',
                  style: LokalTheme.label(
                    t,
                    size: 11,
                    color: isArtist
                        ? Colors.white.withValues(alpha: .78)
                        : t.muted,
                  ),
                ),
                const SizedBox(height: 8),
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: LokalTheme.sans,
                      fontSize: isArtist ? 43 : 32,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1.35,
                      height: 1.06,
                      color: isArtist ? Colors.white : t.text,
                      shadows: isArtist
                          ? const [Shadow(color: Colors.black54, blurRadius: 18)]
                          : null,
                    ),
                  ),
                ),
                if (artistCredit != null) ...[
                  const SizedBox(height: 9),
                  artistCredit!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerButton(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) => LokalGlassButton(
    semanticLabel: label,
    onPressed: onTap,
    tint: Colors.black.withValues(alpha: .16),
    child: Icon(icon, color: isArtist ? Colors.white : context.lokal.text, size: 23),
  );
}
