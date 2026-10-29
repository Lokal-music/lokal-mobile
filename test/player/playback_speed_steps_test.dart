import 'package:flutter_test/flutter_test.dart';
import 'package:flick/core/utils/playback_speed_steps.dart';

void main() {
  test('slider speeds snap to hundredths', () {
    expect(snapPlaybackSpeed(1.01), 1.01);
    expect(snapPlaybackSpeed(1.019999999), 1.02);
    expect(snapPlaybackSpeed(1.014), 1.01);
    expect(snapPlaybackSpeed(1.016), 1.02);
  });

  test('nudging changes speed in exact 0.01x increments', () {
    expect(stepPlaybackSpeed(1.0, 1), 1.01);
    expect(stepPlaybackSpeed(1.01, 1), 1.02);
    expect(stepPlaybackSpeed(1.02, -1), 1.01);
    expect(stepPlaybackSpeed(1.01, -1), 1.0);
    expect(stepPlaybackSpeed(1.0, 25), 1.25);
  });

  test('slider and stepper respect the original range', () {
    expect(snapPlaybackSpeed(0.1), minPlaybackSpeed);
    expect(snapPlaybackSpeed(4.0), maxPlaybackSpeed);
    expect(stepPlaybackSpeed(minPlaybackSpeed, -1), minPlaybackSpeed);
    expect(stepPlaybackSpeed(maxPlaybackSpeed, 1), maxPlaybackSpeed);
    expect(stepPlaybackSpeed(0.5, 150), 2.0);
  });

  test('every hundredth in the supported range is selectable', () {
    for (var hundredths = 50; hundredths <= 200; hundredths++) {
      final speed = hundredths / 100.0;
      expect(snapPlaybackSpeed(speed), speed);
    }
  });
}
