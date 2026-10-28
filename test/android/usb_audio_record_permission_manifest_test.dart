import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('USB capture-capable DAC warning permission is declared explicitly', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    // The manifest used to remove RECORD_AUDIO from transitive dependencies.
    // Declaring it is required for permission_handler to request a grant
    // and for Android SystemUI to check an actually granted permission.
    expect(
      manifest,
      contains('<uses-permission android:name="android.permission.RECORD_AUDIO" />'),
    );
    expect(
      manifest,
      isNot(contains(
        'android.permission.RECORD_AUDIO" tools:node="remove"',
      )),
    );

    // A connected USB DAC need not include a microphone at all. Declaring
    // RECORD_AUDIO must not filter output-only devices from app listings.
    expect(
      manifest,
      contains(
        '<uses-feature android:name="android.hardware.microphone" '
        'android:required="false" />',
      ),
    );

    // This feature does not capture microphone audio or run a mic service.
    expect(
      manifest,
      contains(
        'android.permission.FOREGROUND_SERVICE_MICROPHONE" '
        'tools:node="remove"',
      ),
    );
  });
}
