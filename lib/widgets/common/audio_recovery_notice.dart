import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/services/local_audio_lifecycle.dart';

/// Takes layout space beneath the player, including the official video controls.
/// It does not own transport: Play belongs to the selected song, station or video.
class AudioRecoveryNotice extends StatelessWidget {
  const AudioRecoveryNotice({
    super.key,
    required this.phase,
    this.remoteOutputActive = false,
  });

  final ValueListenable<LocalAudioPhase> phase;
  final bool remoteOutputActive;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: phase,
    builder: (context, value, _) {
      if (remoteOutputActive || value == LocalAudioPhase.ready) {
        return const SizedBox.shrink();
      }
      final message = switch (value) {
        LocalAudioPhase.lost => 'Audio is temporarily unavailable.',
        LocalAudioPhase.recovering => 'Restoring audio…',
        LocalAudioPhase.paused => 'Audio is ready. Use Play to continue.',
        LocalAudioPhase.blocked => 'Close and reopen the app to restore audio.',
        LocalAudioPhase.ready => '',
      };
      return Semantics(
        key: const ValueKey('audio-recovery-notice'),
        liveRegion: true,
        child: Material(
          color: AppColors.surface,
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.all(16),
            child: Row(
              children: [
                if (value == LocalAudioPhase.recovering)
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.accent,
                    ),
                  )
                else
                  Icon(
                    value == LocalAudioPhase.blocked
                        ? Icons.info_outline_rounded
                        : Icons.pause_circle_outline_rounded,
                    color: AppColors.textSecondary,
                    size: 22,
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    lokalText(message),
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: AppColors.textPrimary),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
