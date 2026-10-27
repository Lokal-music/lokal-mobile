import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/l10n/l10n.dart';

/// Convert a linear volume (0.0–1.0) to decibels using the same
/// exponential curve as the Rust audio engine (≈ -60 dB to 0 dB).
String _volumeToDb(double volume) {
  if (volume <= 0.0) return '-∞';
  if (volume >= 1.0) return '0.0';
  final db = 60.0 * (volume - 1.0);
  return db.toStringAsFixed(1);
}

class Uac2VolumeControl extends ConsumerStatefulWidget {
  final bool useGradientBackground;
  final List<Color>? gradientColors;

  const Uac2VolumeControl({
    super.key,
    this.useGradientBackground = false,
    this.gradientColors,
  });

  @override
  ConsumerState<Uac2VolumeControl> createState() => _Uac2VolumeControlState();
}

class _Uac2VolumeControlState extends ConsumerState<Uac2VolumeControl> {
  bool _muteUpdateInFlight = false;

  /// Volume level to restore when unmuting via button.
  double _preMuteVolume = 1.0;

  /// Optimistic volume while the user is dragging the slider.
  double? _draggingVolume;

  /// Called on every slider tick during drag — optimistic UI only, no platform call.
  void _onSliderChanged(double volume) {
    setState(() => _draggingVolume = volume);
  }

  /// Called when the user lifts the finger — commits the value to the
  /// platform. PlayerService.setVolume is the single entry point; it routes
  /// to the DAC Feature Unit (hardware), the engine (software/DSP) or drops
  /// the write when volume is unavailable (bit-perfect passthrough).
  Future<void> _onSliderChangeEnd(double volume) async {
    final player = ref.read(playerServiceProvider);
    final hardware = player.isHardwareVolumeAuthority;
    final device = ref.read(uac2DeviceStatusProvider);
    if (mounted) setState(() => _draggingVolume = null);
    if (hardware && device?.muted == true && volume > 0.0) {
      await ref.read(uac2DeviceStatusProvider.notifier).setMute(false);
    } else if (hardware && device?.muted != true && volume == 0.0) {
      _preMuteVolume = player.currentVolume > 0 ? player.currentVolume : 1.0;
      await ref.read(uac2DeviceStatusProvider.notifier).setMute(true);
    }
    await player.setVolume(volume);
    if (mounted) setState(() {});
  }

  Future<void> _toggleMute() async {
    final player = ref.read(playerServiceProvider);
    final hardware = player.isHardwareVolumeAuthority;
    final notifier = ref.read(uac2DeviceStatusProvider.notifier);
    final muted = hardware
        ? (ref.read(uac2DeviceStatusProvider)?.muted ?? false)
        : player.currentVolume == 0.0;
    if (mounted) setState(() => _muteUpdateInFlight = true);
    try {
      if (!muted) {
        _preMuteVolume = player.currentVolume.clamp(0.01, 1.0);
        if (hardware) await notifier.setMute(true);
        await player.setVolume(0.0);
      } else {
        await player.setVolume(_preMuteVolume);
        if (hardware) await notifier.setMute(false);
      }
    } finally {
      if (mounted) setState(() => _muteUpdateInFlight = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final deviceStatus = ref.watch(uac2DeviceStatusProvider);

    if (deviceStatus == null ||
        deviceStatus.state == Uac2State.idle ||
        (!deviceStatus.hasVolumeControl &&
            !ref.read(playerServiceProvider).isVolumeAvailable)) {
      return const SizedBox.shrink();
    }

    final isSoftwareVolume = deviceStatus.volumeMode == Uac2VolumeMode.software;
    final playerService = ref.read(playerServiceProvider);
    final isAvailable = playerService.isVolumeAvailable;
    final playerVolume = playerService.currentVolume;
    final hardwareAuthority = playerService.isHardwareVolumeAuthority;
    final effectiveVolume =
        _draggingVolume ??
        (hardwareAuthority
            ? (deviceStatus.volume ?? playerVolume)
            : playerVolume);
    final effectiveMuted = hardwareAuthority
        ? (deviceStatus.muted ?? false)
        : playerVolume == 0.0;
    final volumeControlWritable =
        isAvailable &&
        (!hardwareAuthority || deviceStatus.volumeControlWritable) &&
        !_muteUpdateInFlight;
    final showDb =
        isSoftwareVolume || deviceStatus.volumeMode == Uac2VolumeMode.hardware;

    final t = context.lokal;
    final useGradient = widget.useGradientBackground;
    final gradientColors =
        widget.gradientColors ??
        const [Color(0xFF194B68), Color(0xFF0C1624), Color(0xFF1D2A19)];
    final labelColor = useGradient ? Colors.white : t.text;
    final subLabelColor = useGradient
        ? Colors.white.withValues(alpha: 0.7)
        : t.muted;
    final tertiaryColor = useGradient
        ? Colors.white.withValues(alpha: 0.5)
        : t.muted2;

    return Container(
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      decoration: BoxDecoration(
        gradient: useGradient
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: gradientColors,
                stops: const [0.0, 0.56, 1.0],
              )
            : null,
        // Plain, it sits inside a settings section's card.
        borderRadius: BorderRadius.circular(
          useGradient ? AppConstants.radiusLg : 20,
        ),
        border: useGradient
            ? Border.all(color: Colors.white.withValues(alpha: 0.08))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.volume2, color: subLabelColor, size: 20),
              const SizedBox(width: AppConstants.spacingSm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hardwareAuthority
                          ? (deviceStatus.isExternalRoute
                                ? l10n.usbRouteVolume
                                : l10n.deviceDacVolume)
                          : l10n.volume,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: labelColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if ((deviceStatus.routeLabel?.isNotEmpty ?? false))
                      Text(
                        deviceStatus.routeLabel!,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: tertiaryColor),
                      ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  effectiveMuted ? LucideIcons.volumeX : LucideIcons.volume2,
                  size: 20,
                ),
                onPressed: volumeControlWritable ? _toggleMute : null,
                color: effectiveMuted
                    ? (useGradient ? Colors.red.shade400 : t.red)
                    : subLabelColor,
                tooltip: effectiveMuted ? l10n.unmute : l10n.mute,
              ),
            ],
          ),
          const SizedBox(height: AppConstants.spacingSm),
          Row(
            children: [
              Icon(LucideIcons.volume1, color: tertiaryColor, size: 16),
              Expanded(
                child: Slider(
                  value: effectiveVolume,
                  min: 0.0,
                  max: 1.0,
                  divisions: 100,
                  label: showDb
                      ? l10n.db15(
                          (effectiveVolume * 100).round(),
                          _volumeToDb(effectiveVolume),
                        )
                      : '${(effectiveVolume * 100).round()}%',
                  onChanged: volumeControlWritable ? _onSliderChanged : null,
                  onChangeEnd: volumeControlWritable
                      ? _onSliderChangeEnd
                      : null,
                  activeColor: useGradient ? AppColors.accent : t.accent,
                  inactiveColor: useGradient
                      ? Colors.white.withValues(alpha: 0.22)
                      : t.surface3,
                ),
              ),
              Icon(LucideIcons.volume2, color: tertiaryColor, size: 16),
              const SizedBox(width: AppConstants.spacingSm),
              SizedBox(
                width: showDb ? 82 : 40,
                child: Text(
                  showDb
                      ? l10n.db15(
                          (effectiveVolume * 100).round(),
                          _volumeToDb(effectiveVolume),
                        )
                      : '${(effectiveVolume * 100).round()}%',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: subLabelColor,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          if (!isAvailable) ...[
            const SizedBox(height: AppConstants.spacingXs),
            Text(
              l10n.volumeIsFixedWhileBitPerfect2,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: tertiaryColor),
            ),
          ] else if (!deviceStatus.volumeControlWritable) ...[
            const SizedBox(height: AppConstants.spacingXs),
            Text(
              l10n.hardwareVolumeIsDetectedButWrites,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: tertiaryColor),
            ),
          ],
        ],
      ),
    );
  }
}
