import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/services/uac2_preferences_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('PCM output precision defaults to Auto', () async {
    final prefs = Uac2PreferencesService();
    expect(await prefs.getOutputPrecision(), OutputPrecisionPreference.auto);
  });

  test('16-bit PCM and 32-bit float selections persist as native-readable indices', () async {
    final service = Uac2PreferencesService();
    await service.setOutputPrecision(OutputPrecisionPreference.pcm16);
    expect(await service.getOutputPrecision(), OutputPrecisionPreference.pcm16);
    expect(
      (await SharedPreferences.getInstance()).getInt('output_precision'),
      1,
    );

    await service.setOutputPrecision(OutputPrecisionPreference.float32);
    expect(await Uac2PreferencesService().getOutputPrecision(),
        OutputPrecisionPreference.float32);
    expect(
      (await SharedPreferences.getInstance()).getInt('output_precision'),
      2,
    );
  });

  test('unknown persisted formats safely fall back to Auto', () async {
    SharedPreferences.setMockInitialValues({'output_precision': 99});
    expect(await Uac2PreferencesService().getOutputPrecision(),
        OutputPrecisionPreference.auto);
  });

  test('clearing USB preferences resets the output precision', () async {
    final service = Uac2PreferencesService();
    await service.setOutputPrecision(OutputPrecisionPreference.pcm16);
    await service.clearAllPreferences();
    expect(await service.getOutputPrecision(), OutputPrecisionPreference.auto);
  });
}
