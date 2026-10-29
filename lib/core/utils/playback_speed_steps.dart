/// The playback-speed picker operates on hundredths to avoid floating-point
/// drift when nudging the rate repeatedly.
const double minPlaybackSpeed = 0.5;
const double maxPlaybackSpeed = 2.0;

const int _hundredthsPerUnit = 100;
const int _minSpeedHundredths = 50;
const int _maxSpeedHundredths = 200;

/// Snaps a slider value to the nearest 0.01x increment within the supported
/// playback-speed range.
double snapPlaybackSpeed(double speed) {
  final hundredths = (speed * _hundredthsPerUnit).round();
  return hundredths.clamp(_minSpeedHundredths, _maxSpeedHundredths) /
      _hundredthsPerUnit;
}

/// Adjusts the current rate by an exact number of 0.01x increments.
double stepPlaybackSpeed(double currentSpeed, int steps) {
  final hundredths = (currentSpeed * _hundredthsPerUnit).round() + steps;
  return hundredths.clamp(_minSpeedHundredths, _maxSpeedHundredths) /
      _hundredthsPerUnit;
}
