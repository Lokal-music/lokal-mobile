import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/models/audio_output_diagnostics.dart';
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/uac2_preferences_service.dart'
    show AudioEnginePreference;
import 'package:flick/services/uac2_service.dart';
import 'package:flick/features/settings/screens/uac2_preferences_screen.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';
import 'package:flick/widgets/uac2/uac2_volume_control.dart';
import 'package:flick/widgets/uac2/uac2_hotplug_monitor.dart';
import 'package:flick/l10n/l10n.dart';

/// Native USB registration is a playback-session state, not USB discovery.
/// A connected idle DAC must not appear to have failed registration.
enum UsbDacClaimPresentation {
  claimed,
  registeredUnclaimed,
  connectedIdle,
  inactive,
  failed,
}

@visibleForTesting
UsbDacClaimPresentation classifyUsbDacClaim({
  required bool registered,
  required bool claimed,
  required bool connected,
  required bool directUsbPlaybackAttempt,
}) {
  if (registered) {
    return claimed
        ? UsbDacClaimPresentation.claimed
        : UsbDacClaimPresentation.registeredUnclaimed;
  }
  if (directUsbPlaybackAttempt) return UsbDacClaimPresentation.failed;
  return connected
      ? UsbDacClaimPresentation.connectedIdle
      : UsbDacClaimPresentation.inactive;
}

/// The USB DAC page: connected devices, what the DAC can do and is doing,
/// then the engine, bit-perfect, format and DSD preferences, all on one page.
class Uac2SettingsScreen extends ConsumerStatefulWidget {
  const Uac2SettingsScreen({super.key});

  @override
  ConsumerState<Uac2SettingsScreen> createState() => _Uac2SettingsScreenState();
}

class _Uac2SettingsScreenState extends ConsumerState<Uac2SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final isAvailable = ref.watch(uac2AvailableProvider);
    final devicesAsync = ref.watch(uac2DevicesProvider);
    final selectedDevice = ref.watch(selectedUac2DeviceProvider);
    final deviceStatus = ref.watch(uac2DeviceStatusProvider);
    final appPreferences = ref.watch(appPreferencesProvider);
    final isochronous =
        ref.watch(audioEnginePreferenceProvider).asData?.value ==
        AudioEnginePreference.isochronousUsb;
    final showVolume =
        isochronous ||
        (deviceStatus != null &&
            deviceStatus.state != Uac2State.idle &&
            deviceStatus.hasVolumeControl &&
            appPreferences.showUsbVolumeOnSettings);

    return LokalSettingsScaffold(
      title: 'USB DAC',
      subtitle:
          'Play straight to a USB DAC: devices, bit-perfect output, '
          'format and DSD.',
      children: [
        if (!isAvailable)
          LokalSettingsBlock(
            top: 16,
            child: LokalSettingsNotice(text: l10n.uac2IsNotAvailableOnThis),
          )
        else ...[
          const Uac2HotplugMonitor(),
          LokalSettingsSection(
            title: l10n.usbAudioDevices,
            children: devicesAsync.when(
              data: (devices) =>
                  _deviceRows(devices, selectedDevice, deviceStatus),
              loading: () => [_loadingRow()],
              error: (error, _) => [_errorRow(error), _refreshRow()],
            ),
          ),
          if (deviceStatus != null)
            LokalSettingsSection(
              title: l10n.status,
              children: _statusRows(
                deviceStatus,
                usbDetected: devicesAsync.asData?.value.isNotEmpty == true ||
                    deviceStatus.routeType == Uac2RouteType.externalUsb,
              ),
            ),
          if (showVolume)
            LokalSettingsSection(
              title: l10n.volumeControl,
              children: const [Uac2VolumeControl()],
            ),
          if (selectedDevice != null) ...[
            LokalSettingsSection(
              title: l10n.deviceInformation,
              children: _deviceInfoRows(selectedDevice),
            ),
            LokalSettingsSection(
              title: l10n.capabilities,
              children: _capabilityRows(selectedDevice),
            ),
          ],
        ],
        const Uac2PreferencesSections(),
      ],
    );
  }

  Widget _loadingRow() => Padding(
    padding: const EdgeInsets.all(20),
    child: Center(
      child: SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: context.lokal.accent,
        ),
      ),
    ),
  );

  Widget _errorRow(Object error) => Padding(
    padding: const EdgeInsets.all(12),
    child: LokalSettingsNotice(text: l10n.error(error), warning: true),
  );

  Widget _refreshRow() => LokalSettingRow(
    label: l10n.refreshDevices,
    icon: Icons.refresh_rounded,
    onTap: () => ref.invalidate(uac2DevicesProvider),
  );

  List<Widget> _deviceRows(
    List<Uac2DeviceInfo> devices,
    Uac2DeviceInfo? selectedDevice,
    Uac2DeviceStatus? deviceStatus,
  ) {
    if (devices.isEmpty) {
      return [
        LokalSettingRow(
          label: l10n.noUsbAudioDevicesFound,
          description: l10n.connectAUsbDacOrAudio,
          icon: Icons.usb_off_rounded,
        ),
        _refreshRow(),
      ];
    }
    return [
      for (final device in devices)
        _deviceRow(device, selectedDevice, deviceStatus),
      _refreshRow(),
    ];
  }

  Widget _deviceRow(
    Uac2DeviceInfo device,
    Uac2DeviceInfo? selectedDevice,
    Uac2DeviceStatus? deviceStatus,
  ) {
    final isSelected =
        selectedDevice?.vendorId == device.vendorId &&
        selectedDevice?.productId == device.productId &&
        selectedDevice?.serial == device.serial;
    final isConnected =
        isSelected &&
        (deviceStatus?.state == Uac2State.connected ||
            deviceStatus?.state == Uac2State.prewarming ||
            deviceStatus?.state == Uac2State.streaming);
    return LokalSettingRow(
      label: '${device.manufacturer} ${device.productName}'.trim(),
      description:
          'VID 0x${device.vendorId.toRadixString(16).padLeft(4, '0')} · '
          'PID 0x${device.productId.toRadixString(16).padLeft(4, '0')}',
      icon: Icons.usb_rounded,
      selected: isSelected,
      trailing: isConnected
          ? _statusPill(deviceStatus!.state)
          : isSelected
          ? Icon(Icons.check_circle_rounded, color: context.lokal.accent)
          : null,
      onTap: () => _handleDeviceSelection(device, isSelected, isConnected),
    );
  }

  Widget _statusPill(Uac2State state) => LokalStatusPill(
    label: _getStatusLabel(state),
    active: state == Uac2State.connected || state == Uac2State.streaming,
    warning:
        state == Uac2State.connecting ||
        state == Uac2State.prewarming ||
        state == Uac2State.error,
  );

  String _hex(int value) =>
      '0x${value.toRadixString(16).toUpperCase().padLeft(4, '0')}';

  List<Widget> _deviceInfoRows(Uac2DeviceInfo device) => [
    _InfoRow(
      label: l10n.manufacturer,
      value: device.manufacturer.isNotEmpty
          ? device.manufacturer
          : l10n.unknown,
    ),
    _InfoRow(label: l10n.product, value: device.productName),
    _InfoRow(label: l10n.serialNumber, value: device.serial ?? 'N/A'),
    _InfoRow(label: l10n.vendorId, value: _hex(device.vendorId)),
    _InfoRow(label: l10n.productId, value: _hex(device.productId)),
  ];

  List<Widget> _capabilityRows(Uac2DeviceInfo device) {
    final capabilitiesAsync = ref.watch(uac2DeviceCapabilitiesProvider(device));
    return capabilitiesAsync.when(
      data: (capabilities) {
        if (capabilities == null) {
          return [
            LokalSettingRow(
              label: l10n.capabilitiesNotAvailable,
              enabled: false,
            ),
          ];
        }
        return [
          _InfoRow(label: l10n.deviceType, value: capabilities.deviceType),
          _InfoRow(
            label: l10n.sampleRates,
            value: capabilities.supportedSampleRates
                .map((r) => '${r ~/ 1000}kHz')
                .join(', '),
          ),
          _InfoRow(
            label: l10n.bitDepths,
            value: capabilities.supportedBitDepths
                .map((d) => '${d}bit')
                .join(', '),
          ),
          _InfoRow(
            label: l10n.channels,
            value: capabilities.supportedChannels
                .map(
                  (c) => c == 1
                      ? l10n.mono
                      : c == 2
                      ? l10n.stereo
                      : '$c ch',
                )
                .join(', '),
          ),
        ];
      },
      loading: () => [_loadingRow()],
      error: (error, _) => [_errorRow(error)],
    );
  }

  List<Widget> _statusRows(
    Uac2DeviceStatus status, {
    required bool usbDetected,
  }) {
    final diagnostics = ref.watch(audioOutputDiagnosticsProvider);
    final t = context.lokal;
    Color good(bool ok) => ok ? t.accent : t.orange;
    final format = status.currentFormat;
    final claimPresentation = diagnostics == null
        ? UsbDacClaimPresentation.inactive
        : classifyUsbDacClaim(
            registered: diagnostics.directUsbRegistered,
            claimed: diagnostics.usbInterfaceClaimed,
            connected: usbDetected,
            // A direct USB start can fail before reaching the streaming
            // state, and its fallback can already select normal Android.
            directUsbPlaybackAttempt:
                status.state == Uac2State.error ||
                (RegExp(r'direct usb|usb dac|usb path|uac2|libusb|isochronous',
                    caseSensitive: false)
                    .hasMatch(diagnostics.fallbackReason ?? '')) ||
                (diagnostics.selectedMode == AudioEngineType.usbDacExperimental &&
                    status.state == Uac2State.streaming),
          );
    Widget notice(String text, {bool warning = true, IconData? icon}) =>
        Padding(
          padding: const EdgeInsets.all(12),
          child: LokalSettingsNotice(text: text, warning: warning, icon: icon),
        );
    return [
      LokalSettingRow(
        label: l10n.connectionStatus,
        trailing: _statusPill(status.state),
      ),
      if (status.routeType != Uac2RouteType.unknown)
        _InfoRow(
          label: l10n.playbackPath,
          value: _getPlaybackPathLabel(status, diagnostics: diagnostics),
        ),
      if (diagnostics != null) ...[
        _InfoRow(
          label: l10n.capabilityState,
          value: diagnostics.capabilityStateLabel,
        ),
        _InfoRow(label: l10n.backend, value: diagnostics.backendDescription),
      ],
      if (format != null) ...[
        _InfoRow(
          label: format.isDsdStream ? l10n.trackDsdRate : l10n.trackSampleRate,
          value: format.displayRateLabel,
        ),
        _InfoRow(label: l10n.trackBitDepth, value: format.bitDepthLabel),
        _InfoRow(
          label: l10n.trackChannels,
          value: format.channels == 1
              ? l10n.mono
              : format.channels == 2
              ? l10n.stereo
              : l10n.channels2(format.channels),
        ),
        if (diagnostics != null) ...[
          _InfoRow(
            label: l10n.requestedOutputRate,
            value: diagnostics.requestedOutputSampleRate == null
                ? l10n.unknown
                : l10n.khz(diagnostics.requestedOutputSampleRate! ~/ 1000),
          ),
          _InfoRow(
            label: l10n.reportedOutputRate,
            value: diagnostics.reportedOutputSampleRate == null
                ? l10n.unreported
                : l10n.khz(diagnostics.reportedOutputSampleRate! ~/ 1000),
          ),
        ],
      ],
      if (diagnostics != null) ...[
        _InfoRow(
          label: l10n.mixerManagement,
          value: diagnostics.isMixerManaged
              ? 'Android-managed'
              : l10n.directUsbDeviceManaged,
          valueColor: good(!diagnostics.isMixerManaged),
        ),
        _InfoRow(
          label: l10n.dacClaim,
          value: switch (claimPresentation) {
            UsbDacClaimPresentation.claimed => l10n.claimedByFlick,
            UsbDacClaimPresentation.registeredUnclaimed =>
              l10n.registeredNotClaimed,
            UsbDacClaimPresentation.connectedIdle =>
              '${l10n.connected} · ${l10n.idle}',
            UsbDacClaimPresentation.inactive => l10n.idle,
            UsbDacClaimPresentation.failed => l10n.notRegistered,
          },
          valueColor: claimPresentation == UsbDacClaimPresentation.failed
              ? t.orange
              : (claimPresentation == UsbDacClaimPresentation.claimed
                  ? t.accent
                  : null),
        ),
        _InfoRow(
          label: l10n.audioFocus,
          value: diagnostics.audioFocusHeld ? l10n.held : l10n.notHeld,
          valueColor: good(diagnostics.audioFocusHeld),
        ),
      ],
      if (claimPresentation == UsbDacClaimPresentation.connectedIdle)
        notice(
          'USB registration starts with direct playback and is released '
          'when playback stops.',
          warning: false,
          icon: Icons.info_outline_rounded,
        ),
      if (diagnostics != null &&
          diagnostics.verificationReason != null &&
          diagnostics.verificationReason != diagnostics.fallbackReason)
        notice(diagnostics.verificationReason!),
      if (diagnostics?.fallbackReason != null)
        notice(diagnostics!.fallbackReason!),
      if (status.warningMessage != null) notice(status.warningMessage!),
      if (status.compatibilityNotice != null)
        notice(
          status.compatibilityNotice!,
          warning: false,
          icon: Icons.help_outline_rounded,
        ),
      if (status.errorMessage != null)
        notice(status.errorMessage!, icon: Icons.error_outline_rounded),
    ];
  }

  void _handleDeviceSelection(
    Uac2DeviceInfo device,
    bool isSelected,
    bool isConnected,
  ) async {
    final deviceStatusNotifier = ref.read(uac2DeviceStatusProvider.notifier);

    if (isConnected) {
      await deviceStatusNotifier.disconnect();
    } else {
      ref.read(selectedUac2DeviceProvider.notifier).select(device);
      await deviceStatusNotifier.selectDevice(device);
    }
  }

  String _getStatusLabel(Uac2State state) {
    switch (state) {
      case Uac2State.idle:
        return l10n.idle;
      case Uac2State.connecting:
        return l10n.connecting;
      case Uac2State.connected:
        return l10n.connected;
      case Uac2State.prewarming:
        return l10n.prewarming;
      case Uac2State.streaming:
        return l10n.streaming;
      case Uac2State.error:
        return l10n.error3;
    }
  }

  String _getPlaybackPathLabel(
    Uac2DeviceStatus status, {
    AudioOutputDiagnostics? diagnostics,
  }) {
    if (diagnostics != null) {
      return diagnostics.capabilityStateLabel;
    }

    switch (status.routeType) {
      case Uac2RouteType.internalDac:
        return l10n.deviceDac;
      case Uac2RouteType.externalUsb:
        return l10n.androidUsbRoute;
      case Uac2RouteType.wired:
        return l10n.wiredOutput;
      case Uac2RouteType.bluetooth:
        return l10n.bluetoothOutput;
      case Uac2RouteType.dock:
        return l10n.androidDockRoute;
      case Uac2RouteType.unknown:
        return status.routeLabel ?? l10n.unknown;
    }
  }
}

/// A read-only fact: its label on the left, the value in DM Mono on the right.
class _InfoRow extends StatelessWidget implements LokalSearchable {
  const _InfoRow({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  String get searchText => '$label $value';

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontFamily: LokalTheme.sans,
                fontSize: 14,
                color: t.muted,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Flexible(
            flex: 2,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: LokalTheme.mono,
                fontSize: 12.5,
                height: 1.4,
                fontWeight: FontWeight.w500,
                color: valueColor ?? t.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
