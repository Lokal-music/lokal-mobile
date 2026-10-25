import 'package:flutter_test/flutter_test.dart';
import 'package:flick/providers/equalizer_provider.dart';
import 'package:flick/services/equalizer_service.dart';

void main() {
  test('flat iPhone playback stays on the system backend', () {
    expect(requiresIosRustDsp(EqualizerState.initial()), false);
  });
  test('ordinary EQ uses real DSP and master bypass releases it', () {
    final state = EqualizerState.initial().copyWith(
      enabled: true,
      graphicGainsDb: [3, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    );
    expect(requiresIosRustDsp(state), true);
    expect(requiresIosRustDsp(state.copyWith(enabled: false)), false);
  });
}
