import 'package:flutter_test/flutter_test.dart';

import 'package:flick/features/player/widgets/usb_dac_quick_status_sheet.dart';
import 'package:flick/features/settings/screens/uac2_settings_screen.dart'
    show UsbDacClaimPresentation;
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/audio_output_diagnostics.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/src/rust/api/uac2_api.dart';

const _dac = Uac2DeviceInfo(
  vendorId: 0x1234,
  productId: 0x5678,
  manufacturer: 'Example Audio',
  productName: 'Reference DAC',
  deviceName: '/dev/bus/usb/001/002',
);
const _otherDac = Uac2DeviceInfo(
  vendorId: 0x1234,
  productId: 0x5678,
  manufacturer: 'Example Audio',
  productName: 'Reference DAC',
  deviceName: '/dev/bus/usb/001/003',
);
const _capabilities = AudioCapabilityFlags(
  supportsExclusiveUsbOwnership: true,
  supportsDirectSampleRateSwitching: true,
  supportsVerifiedBitPerfect: true,
  supportsAndroidManagedHighResOnly: false,
  supportsInternalDapPathOnly: false,
);

AudioOutputDiagnostics _diagnostics({
  bool registered = true,
  bool claimed = true,
  bool mixerManaged = false,
  bool focusHeld = true,
  AudioEngineType selected = AudioEngineType.usbDacExperimental,
  AudioEngineType initialized = AudioEngineType.usbDacExperimental,
  String? fallback,
}) => AudioOutputDiagnostics(
  selectedMode: selected,
  initializedMode: initialized,
  detectedDap: false,
  detectedDapBrand: null,
  pathManagement: AudioPathManagement.directUsbExperimental,
  outputStrategyLabel: 'Bit-perfect',
  capabilityStateLabel: 'Verified direct USB',
  backendDescription: 'Rust USB',
  routeType: 'usb',
  routeLabel: 'External USB DAC',
  outputDeviceLabel: 'Reference DAC',
  isMixerManaged: mixerManaged,
  audioFocusHeld: focusHeld,
  directUsbRegistered: registered,
  usbInterfaceClaimed: claimed,
  usbStreamStable: registered && claimed,
  trackSampleRate: 44100,
  requestedOutputSampleRate: 44100,
  reportedOutputSampleRate: 44100,
  resamplerActive: false,
  passthroughAllowed: true,
  activeOutputSignature: 'android-uac2:1234:5678',
  verificationReason: null,
  fallbackReason: fallback,
  capabilityFlags: _capabilities,
);

void main() {
  test('no physical DAC never exposes stale registration, claim or focus', () {
    final state = usbDacQuickStatus(
      physicalDevices: const [],
      selectedDevice: _dac,
      liveStatus: const Uac2DeviceStatus(
        device: _dac,
        state: Uac2State.streaming,
        routeType: Uac2RouteType.externalUsb,
      ),
      diagnostics: _diagnostics(),
      initializedMode: AudioEngineType.usbDacExperimental,
      songLoaded: true,
    );
    expect(state.connected, isFalse);
    expect(state.deviceName, 'Disconnected');
    expect(state.claim, UsbDacClaimPresentation.inactive);
    expect(state.isLiveUsbRoute, isFalse);
    expect(state.mixerManaged, isNull);
    expect(state.audioFocusHeld, isNull);
  });

  test('attached DAC without a session is connected but not claimed', () {
    final state = usbDacQuickStatus(
      physicalDevices: const [_dac],
      selectedDevice: _dac,
      liveStatus: null,
      diagnostics: _diagnostics(),
      initializedMode: null,
      songLoaded: false,
    );
    expect(state.deviceName, 'Example Audio Reference DAC');
    expect(state.connected, isTrue);
    expect(state.claim, UsbDacClaimPresentation.connectedIdle);
    expect(state.mixerManaged, isNull);
    expect(state.audioFocusHeld, isNull);
    expect(state.playbackMode, 'Idle / no active playback');
  });

  test('a live matched direct-USB session exposes real engine state', () {
    final state = usbDacQuickStatus(
      physicalDevices: const [_dac],
      selectedDevice: _dac,
      liveStatus: const Uac2DeviceStatus(
        device: _dac,
        state: Uac2State.streaming,
        routeType: Uac2RouteType.externalUsb,
      ),
      diagnostics: _diagnostics(),
      initializedMode: AudioEngineType.normalAndroid,
      songLoaded: true,
    );
    expect(state.claim, UsbDacClaimPresentation.claimed);
    expect(state.isLiveUsbRoute, isTrue);
    expect(state.mixerManaged, isFalse);
    expect(state.audioFocusHeld, isTrue);
    expect(state.playbackMode, contains('Direct USB / isochronous'));
    expect(state.playbackMode, contains('Bit-perfect'));
  });

  test('DAC identity mismatch does not borrow another device claim', () {
    final state = usbDacQuickStatus(
      physicalDevices: const [_dac],
      selectedDevice: _dac,
      liveStatus: const Uac2DeviceStatus(
        device: _otherDac,
        state: Uac2State.streaming,
        routeType: Uac2RouteType.externalUsb,
      ),
      diagnostics: _diagnostics(),
      initializedMode: AudioEngineType.normalAndroid,
      songLoaded: true,
    );
    expect(state.connected, isTrue);
    expect(state.isLiveUsbRoute, isFalse);
    expect(state.claim, UsbDacClaimPresentation.connectedIdle);
    expect(state.mixerManaged, isNull);
    expect(state.audioFocusHeld, isNull);
  });

  test('failed direct registration reports fallback, never claimed', () {
    final state = usbDacQuickStatus(
      physicalDevices: const [_dac],
      selectedDevice: _dac,
      liveStatus: const Uac2DeviceStatus(
        device: _dac,
        state: Uac2State.streaming,
        routeType: Uac2RouteType.externalUsb,
      ),
      diagnostics: _diagnostics(
        registered: false,
        claimed: false,
        mixerManaged: true,
        focusHeld: false,
        selected: AudioEngineType.usbDacExperimental,
        initialized: AudioEngineType.normalAndroid,
        fallback: 'Direct USB unavailable; Android playback resumed',
      ),
      initializedMode: AudioEngineType.usbDacExperimental,
      songLoaded: true,
    );
    expect(state.claim, UsbDacClaimPresentation.failed);
    expect(state.mixerManaged, isTrue);
    expect(state.audioFocusHeld, isFalse);
    expect(state.playbackMode, contains('Android / system output'));
    expect(state.fallbackReason, contains('Direct USB unavailable'));
  });

  test('a different route does not masquerade as exclusive USB ownership', () {
    final state = usbDacQuickStatus(
      physicalDevices: const [_dac],
      selectedDevice: _dac,
      liveStatus: const Uac2DeviceStatus(
        device: _dac,
        state: Uac2State.connected,
        routeType: Uac2RouteType.bluetooth,
      ),
      diagnostics: _diagnostics(),
      initializedMode: AudioEngineType.rustOboe,
      songLoaded: true,
    );
    expect(state.isLiveUsbRoute, isFalse);
    expect(state.claim, UsbDacClaimPresentation.connectedIdle);
    expect(state.audioFocusHeld, isNull);
  });
}
