import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/utils/playback_speed_steps.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/widgets/common/glass_bottom_sheet.dart';
import 'package:flick/l10n/l10n.dart';

class SpeedBottomSheet extends StatelessWidget {
  final PlayerService playerService;
  const SpeedBottomSheet({super.key, required this.playerService});

  static Future<void> show(BuildContext context, PlayerService playerService) {
    return showModalBottomSheet(
      useRootNavigator: true,
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => SpeedBottomSheet(playerService: playerService),
    );
  }

  @override
  Widget build(BuildContext context) {
    const min = minPlaybackSpeed;
    const max = maxPlaybackSpeed;
    return Container(
      decoration: AppBottomSheetSurface.decoration,
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        24 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.gauge,
                color: AppColors.accent,
                size: 24,
              ),
              const SizedBox(width: 12),
              Text(
                l10n.playbackSpeed,
                style: TextStyle(
                  fontFamily: 'GoogleSansFlex',
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          ValueListenableBuilder<double>(
            valueListenable: playerService.playbackSpeedNotifier,
            builder: (context, currentSpeed, _) {
              return Column(
                children: [
                  Row(
                    children: [
                      const SizedBox(width: 4),
                      Text(
                        l10n.x(min),
                        style: TextStyle(
                          fontFamily: 'GoogleSansFlex',
                          fontSize: 14,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: snapPlaybackSpeed(currentSpeed),
                          min: min,
                          max: max,
                          activeColor: AppColors.accent,
                          inactiveColor: AppColors.glassBorder,
                          onChanged: (value) {
                            final next = snapPlaybackSpeed(value);
                            if (next != snapPlaybackSpeed(currentSpeed)) {
                              playerService.setPlaybackSpeed(next);
                            }
                          },
                        ),
                      ),
                      Text(
                        l10n.x2(max),
                        style: TextStyle(
                          fontFamily: 'GoogleSansFlex',
                          fontSize: 14,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: '${l10n.playbackSpeed} −0.01x',
                        onPressed: snapPlaybackSpeed(currentSpeed) <= min
                            ? null
                            : () => playerService.setPlaybackSpeed(
                                stepPlaybackSpeed(currentSpeed, -1),
                              ),
                        icon: const Icon(LucideIcons.minus),
                        color: AppColors.textPrimary,
                      ),
                      SizedBox(
                        width: 90,
                        child: Text(
                          l10n.x3(
                            snapPlaybackSpeed(currentSpeed).toStringAsFixed(2),
                          ),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: 'GoogleSansFlex',
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppColors.accent,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '${l10n.playbackSpeed} +0.01x',
                        onPressed: snapPlaybackSpeed(currentSpeed) >= max
                            ? null
                            : () => playerService.setPlaybackSpeed(
                                stepPlaybackSpeed(currentSpeed, 1),
                              ),
                        icon: const Icon(LucideIcons.plus),
                        color: AppColors.textPrimary,
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
