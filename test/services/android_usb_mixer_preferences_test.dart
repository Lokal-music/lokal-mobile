import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/services/uac2_preferences_service.dart';
import 'package:flick/services/uac2_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Android mixer capability requires SDK 34 and fails closed', () async {
    const channel = MethodChannel('com.mossapps.flick/uac2');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    for (final sdk in [33, 34, 35]) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getAndroidSdkInt');
        return sdk;
      });
      expect(await Uac2Service.instance.supportsAndroidUsbMixer(), sdk >= 34);
    }
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    expect(await Uac2Service.instance.supportsAndroidUsbMixer(), isFalse);
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'unavailable');
    });
    expect(await Uac2Service.instance.supportsAndroidUsbMixer(), isFalse);
  });

  test('Android USB mixer is an opt-in persisted engine choice', () async {
    final prefs = Uac2PreferencesService();
    await prefs.setAudioEnginePreference(AudioEnginePreference.androidMixerUsb);
    expect(Uac2PreferencesService.isAndroidMixerUsbSelectedSync, isTrue);
    expect(
      await Uac2PreferencesService().getAudioEnginePreference(),
      AudioEnginePreference.androidMixerUsb,
    );
    final raw = await SharedPreferences.getInstance();
    expect(raw.getString('audio_engine_preference'), 'androidMixerUsb');

    await prefs.setAudioEnginePreference(AudioEnginePreference.isochronousUsb);
    expect(Uac2PreferencesService.isAndroidMixerUsbSelectedSync, isFalse);
    expect(
      await prefs.getAudioEnginePreference(),
      AudioEnginePreference.isochronousUsb,
    );
  });

  test('source precision gate refuses unknown and 32-bit PCM', () async {
    final prefs = Uac2PreferencesService();
    final raw = await SharedPreferences.getInstance();
    for (final depth in [null, 0, -1, 32]) {
      await prefs.setAndroidMixerSourceBitDepth(depth);
      expect(raw.getInt('android_mixer_source_bits'), 0);
    }
    for (final depth in [16, 24]) {
      await prefs.setAndroidMixerSourceBitDepth(depth);
      expect(raw.getInt('android_mixer_source_bits'), depth);
    }
  });

  test('clearing preferences also clears framework mixer selection and source gate', () async {
    final prefs = Uac2PreferencesService();
    await prefs.setAudioEnginePreference(AudioEnginePreference.androidMixerUsb);
    await prefs.setAndroidMixerSourceBitDepth(24);
    await prefs.clearAllPreferences();
    expect(
      await prefs.getAudioEnginePreference(),
      AudioEnginePreference.exoPlayer,
    );
    expect(Uac2PreferencesService.isAndroidMixerUsbSelectedSync, isFalse);
    final raw = await SharedPreferences.getInstance();
    expect(raw.containsKey('android_mixer_source_bits'), isFalse);
  });

  test('unrecognized engine selection stays on standard Android', () async {
    SharedPreferences.setMockInitialValues({
      'audio_engine_preference': 'nonexistent',
    });
    expect(
      await Uac2PreferencesService().getAudioEnginePreference(),
      AudioEnginePreference.exoPlayer,
    );
  });
}
