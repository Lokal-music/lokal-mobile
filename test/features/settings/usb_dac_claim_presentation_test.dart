import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/settings/screens/uac2_settings_screen.dart';
import 'package:flick/services/uac2_service.dart';

void main() {
  const dacA = Uac2DeviceInfo(
    vendorId: 0x1234,
    productId: 0x5678,
    productName: 'DAC A',
    manufacturer: 'Test',
    serial: '1',
    deviceName: '/dev/bus/usb/001/002',
  );
  const dacB = Uac2DeviceInfo(
    vendorId: 0x1234,
    productId: 0x5678,
    productName: 'DAC B',
    manufacturer: 'Test',
    serial: '2',
    deviceName: '/dev/bus/usb/001/003',
  );

  group('USB DAC visibility before playback', () {
    test('connected idle DAC always produces a status', () {
      final status = usbDacStatusForDisplay(
        physicalDevices: [dacA],
        liveStatus: null,
        selectedDevice: null,
      );
      expect(status, isNotNull);
      expect(status!.device, dacA);
      expect(status.state, Uac2State.connected);
      expect(status.routeType, Uac2RouteType.externalUsb);
      expect(status.currentFormat, isNull);
      expect(status.state, isNot(Uac2State.streaming));
    });

    test('a live status is preserved for the physically matching DAC', () {
      const live = Uac2DeviceStatus(
        device: dacA,
        state: Uac2State.streaming,
        routeType: Uac2RouteType.externalUsb,
        isExternalRoute: true,
        currentFormat: Uac2AudioFormat(
          sampleRate: 44100,
          bitDepth: 16,
          channels: 2,
        ),
      );
      final status = usbDacStatusForDisplay(
        physicalDevices: [dacA], liveStatus: live, selectedDevice: null,
      );
      expect(identical(status, live), isTrue);
    });

    test('stale streaming status cannot mark another DAC as streaming', () {
      const stale = Uac2DeviceStatus(
        device: dacA,
        state: Uac2State.streaming,
        routeType: Uac2RouteType.externalUsb,
      );
      final status = usbDacStatusForDisplay(
        physicalDevices: [dacB], liveStatus: stale, selectedDevice: null,
      );
      expect(status!.device, dacB);
      expect(status.state, Uac2State.connected);
      expect(identical(status, stale), isFalse);
    });

    test('a selected physical DAC is preferred over the first device', () {
      final status = usbDacStatusForDisplay(
        physicalDevices: [dacA, dacB],
        liveStatus: null,
        selectedDevice: dacB,
      );
      expect(status!.device, dacB);
    });

    test('a fully detached DAC removes the status panel', () {
      const live = Uac2DeviceStatus(
        device: dacA,
        state: Uac2State.streaming,
        routeType: Uac2RouteType.externalUsb,
      );
      expect(usbDacStatusForDisplay(
        physicalDevices: const [],
        liveStatus: live,
        selectedDevice: dacA,
      ), isNull);
    });

    test('a known active USB route remains visible during initial discovery', () {
      const live = Uac2DeviceStatus(
        device: dacA,
        state: Uac2State.streaming,
        routeType: Uac2RouteType.externalUsb,
      );
      expect(usbDacStatusForDisplay(
        physicalDevices: null,
        liveStatus: live,
        selectedDevice: null,
      ), same(live));
    });
  });
  group('USB DAC status presentation', () {
    test('connected idle device is not shown as registration failure', () {
      expect(
        classifyUsbDacClaim(
          registered: false,
          claimed: false,
          connected: true,
          directUsbPlaybackAttempt: false,
        ),
        UsbDacClaimPresentation.connectedIdle,
      );
    });

    test('no device and no USB playback is simply inactive', () {
      expect(
        classifyUsbDacClaim(
          registered: false,
          claimed: false,
          connected: false,
          directUsbPlaybackAttempt: false,
        ),
        UsbDacClaimPresentation.inactive,
      );
    });

    test('USB playback without registration remains a real failure', () {
      expect(
        classifyUsbDacClaim(
          registered: false,
          claimed: false,
          connected: true,
          directUsbPlaybackAttempt: true,
        ),
        UsbDacClaimPresentation.failed,
      );
    });

    test('registered and claimed states remain distinct and accurate', () {
      expect(
        classifyUsbDacClaim(
          registered: true,
          claimed: false,
          connected: true,
          directUsbPlaybackAttempt: false,
        ),
        UsbDacClaimPresentation.registeredUnclaimed,
      );
      expect(
        classifyUsbDacClaim(
          registered: true,
          claimed: true,
          connected: true,
          directUsbPlaybackAttempt: true,
        ),
        UsbDacClaimPresentation.claimed,
      );
    });
  });
}
