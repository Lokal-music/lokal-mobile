import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/audio_output_diagnostics.dart';
import 'package:flick/providers/uac2_provider.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/features/settings/screens/uac2_settings_screen.dart'
    show UsbDacClaimPresentation, classifyUsbDacClaim, sameUsbDacDevice;
import 'package:flick/widgets/uac2/uac2_hotplug_monitor.dart';

/// Snapshot shown in the full-player menu. Attachment alone cannot prove
/// exclusive USB ownership, bypassing Android's mixer, or held audio focus.
@immutable
class UsbDacQuickStatus {
  const UsbDacQuickStatus({
    required this.deviceName,
    required this.connected,
    required this.isLiveUsbRoute,
    required this.mixerManaged,
    required this.claim,
    required this.audioFocusHeld,
    required this.playbackMode,
    this.fallbackReason,
  });

  final String deviceName;
  final bool connected;
  final bool isLiveUsbRoute;
  final bool? mixerManaged;
  final UsbDacClaimPresentation claim;
  final bool? audioFocusHeld;
  final String playbackMode;
  final String? fallbackReason;
}

String _friendlyDacName(Uac2DeviceInfo device) {
  final product = device.productName.trim();
  final manufacturer = device.manufacturer.trim();
  if (product.isEmpty) return manufacturer.isEmpty ? 'USB audio device' : manufacturer;
  if (manufacturer.isEmpty ||
      product.toLowerCase().contains(manufacturer.toLowerCase())) {
    return product;
  }
  return manufacturer + ' ' + product;
}

String _engineName(AudioEngineType mode) => switch (mode) {
  AudioEngineType.normalAndroid => 'Android / system output',
  AudioEngineType.rustOboe => 'Rust Oboe / Android output',
  AudioEngineType.usbDacExperimental => 'Direct USB / isochronous',
  AudioEngineType.dapInternalHighRes => 'Internal DAP / high resolution',
};

/// The selected device and native route must match the *current physical
/// inventory*. Otherwise an old USB session would display stale "claimed".
/// Still report the genuinely active playback engine if it fell back to
/// Android output with a DAC plugged in.
@visibleForTesting
UsbDacQuickStatus usbDacQuickStatus({
  required List<Uac2DeviceInfo> physicalDevices,
  required Uac2DeviceInfo? selectedDevice,
  required Uac2DeviceStatus? liveStatus,
  required AudioOutputDiagnostics? diagnostics,
  required AudioEngineType? initializedMode,
  required bool songLoaded,
}) {
  final attachedLiveDevice = liveStatus == null ? null :
      physicalDevices.where((device) =>
        sameUsbDacDevice(device, liveStatus.device)).firstOrNull;
  final selected = selectedDevice == null ? null :
      physicalDevices.where((device) =>
        sameUsbDacDevice(device, selectedDevice)).firstOrNull;
  final device = attachedLiveDevice ?? selected ??
      (physicalDevices.isEmpty ? null : physicalDevices.first);
  final liveUsbRoute = attachedLiveDevice != null &&
      liveStatus != null &&
      (liveStatus.routeType == Uac2RouteType.externalUsb ||
          liveStatus.isExternalRoute);
  final activeDiagnostics = liveUsbRoute ? diagnostics : null;
  final attemptedDirectPlayback = liveUsbRoute && liveStatus != null &&
      (liveStatus.state == Uac2State.error ||
          (diagnostics?.selectedMode == AudioEngineType.usbDacExperimental &&
           liveStatus.state == Uac2State.streaming) ||
          RegExp(r'direct usb|usb dac|usb path|uac2|libusb|isochronous',
            caseSensitive: false).hasMatch(diagnostics?.fallbackReason ?? ''));
  final claim = activeDiagnostics == null
      ? (device == null
          ? UsbDacClaimPresentation.inactive
          : UsbDacClaimPresentation.connectedIdle)
      : classifyUsbDacClaim(
          registered: activeDiagnostics.directUsbRegistered,
          claimed: activeDiagnostics.usbInterfaceClaimed,
          connected: true,
          directUsbPlaybackAttempt: attemptedDirectPlayback,
        );
  final actualMode = diagnostics?.initializedMode ?? initializedMode;
  final mode = songLoaded && actualMode != null
      ? _engineName(actualMode) +
          (diagnostics?.outputStrategyLabel.trim().isNotEmpty == true
              ? ' · ' + diagnostics!.outputStrategyLabel : '')
      : 'Idle / no active playback';
  return UsbDacQuickStatus(
    deviceName: device == null ? 'Disconnected' : _friendlyDacName(device),
    connected: device != null,
    isLiveUsbRoute: liveUsbRoute,
    mixerManaged: activeDiagnostics?.isMixerManaged,
    claim: claim,
    audioFocusHeld: activeDiagnostics?.audioFocusHeld,
    playbackMode: mode,
    fallbackReason: songLoaded ? diagnostics?.fallbackReason : null,
  );
}

/// Launch from the full player's three-dot menu only after it has dismissed.
/// The diagnostic sheet never requests USB permission or claims the device.
Future<void> showUsbDacQuickStatusSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const UsbDacQuickStatusSheet(),
    );

class UsbDacQuickStatusSheet extends ConsumerWidget {
  const UsbDacQuickStatusSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(uac2DevicesProvider);
    final live = ref.watch(uac2DeviceStatusProvider);
    final selected = ref.watch(selectedUac2DeviceProvider);
    final diagnostics = ref.watch(audioOutputDiagnosticsProvider);
    final player = ref.watch(playerServiceProvider);
    final snapshot = devices.asData == null
        ? null
        : usbDacQuickStatus(
            physicalDevices: devices.asData!.value,
            selectedDevice: selected,
            liveStatus: live,
            diagnostics: diagnostics,
            initializedMode: player.initializedPlaybackModeNotifier.value,
            songLoaded: player.currentSongNotifier.value != null,
          );
    final textTheme = Theme.of(context).textTheme;

    Widget fact(String label, String value, {Key? key}) => Padding(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Text(label, style: textTheme.bodyMedium),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 5,
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    String claimLabel(UsbDacClaimPresentation claim) => switch (claim) {
      UsbDacClaimPresentation.claimed => 'Claimed by Lokal',
      UsbDacClaimPresentation.registeredUnclaimed => 'Registered, not claimed',
      UsbDacClaimPresentation.connectedIdle => 'Connected · idle',
      UsbDacClaimPresentation.inactive => 'Disconnected',
      UsbDacClaimPresentation.failed => 'Not registered / fallback',
    };

    return SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 650),
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Rechecks the physical inventory every few seconds and on
              // attach/detach. Does not initialize an audio engine.
              const Uac2HotplugMonitor(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                child: Text('USB DAC status',
                    style: textTheme.titleLarge),
              ),
              if (devices.isLoading && snapshot == null)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (devices.hasError && snapshot == null)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('Could not read the connected USB audio devices.'),
                )
              else if (snapshot != null) ...[
                fact('USB audio device', snapshot.deviceName,
                    key: const ValueKey('usb-status-device')),
                fact('Mixer management',
                    snapshot.mixerManaged == null
                        ? 'Inactive / not verified'
                        : snapshot.mixerManaged!
                            ? 'Android-managed'
                            : 'Direct USB device-managed',
                    key: const ValueKey('usb-status-mixer')),
                fact('DAC claim', claimLabel(snapshot.claim),
                    key: const ValueKey('usb-status-claim')),
                fact('Audio focus',
                    snapshot.audioFocusHeld == null
                        ? 'Inactive / not verified'
                        : snapshot.audioFocusHeld! ? 'Held' : 'Not held',
                    key: const ValueKey('usb-status-focus')),
                fact('Current playback mode', snapshot.playbackMode,
                    key: const ValueKey('usb-status-mode')),
                if (snapshot.fallbackReason?.isNotEmpty == true)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                    child: Text(
                      'Playback fallback: ' + snapshot.fallbackReason!,
                      style: textTheme.bodySmall,
                    ),
                  ),
                if (snapshot.connected && !snapshot.isLiveUsbRoute)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                    child: Text(
                      'The DAC is physically attached. Exclusive ownership '
                      'and USB mixer bypass are only verified during an '
                      'active direct-USB session.',
                      style: textTheme.bodySmall,
                    ),
                  ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => ref.invalidate(uac2DevicesProvider),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Refresh'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
