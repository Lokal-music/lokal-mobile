import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('verified USB inventory requests bypass Android device cache', () {
    final dartService = File('lib/services/uac2_service.dart').readAsStringSync();
    final mainActivity = File(
      'android/app/src/main/kotlin/com/mossapps/flick/MainActivity.kt',
    ).readAsStringSync();

    // Explicit physical inventory verification must refresh the Android
    // UsbManager list even after a missed ATTACHED/DETACHED broadcast.
    expect(
      dartService,
      contains('return _listDevicesAndroid(refresh: true);'),
    );
    expect(
      dartService,
      contains("'listDevices',\n        {'refresh': refresh}"),
    );
    expect(
      mainActivity,
      contains('val refresh = call.argument<Boolean>("refresh") ?: false'),
    );
    expect(mainActivity, contains('val devices = listUac2Devices(refresh)'));
    expect(mainActivity, contains('if (!refresh && uac2DeviceCache != null)'));
  });
}
