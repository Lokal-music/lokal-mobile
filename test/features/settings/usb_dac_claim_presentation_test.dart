import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/settings/screens/uac2_settings_screen.dart';

void main() {
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
