import 'package:flutter_test/flutter_test.dart';
import 'package:flick/widgets/uac2/uac2_hotplug_monitor.dart';

void main() {
  group('physical USB hotplug inventory', () {
    test('first physical scan establishes the inventory', () {
      expect(usbInventoryChanged(null, {'/dev/bus/usb/001/002'}), isTrue);
    });

    test('the same attached device does not cause repeated refreshes', () {
      expect(usbInventoryChanged(
        {'/dev/bus/usb/001/002'},
        {'/dev/bus/usb/001/002'},
      ), isFalse);
    });

    test('USB attach and detach both refresh the device list', () {
      expect(usbInventoryChanged(
        <String>{},
        {'/dev/bus/usb/001/002'},
      ), isTrue);
      expect(usbInventoryChanged(
        {'/dev/bus/usb/001/002'},
        <String>{},
      ), isTrue);
    });

    test('a different DAC on the same port count triggers refresh', () {
      expect(usbInventoryChanged(
        {'/dev/bus/usb/001/002'},
        {'/dev/bus/usb/001/003'},
      ), isTrue);
    });

    test('reordering the inventory is not treated as hotplug', () {
      expect(usbInventoryChanged(
        {'dac-a', 'dac-b'},
        {'dac-b', 'dac-a'},
      ), isFalse);
    });
  });
}
