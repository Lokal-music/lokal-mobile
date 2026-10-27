import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/providers/opt_in_source_provider.dart';

class _RejectedPreferences implements SharedPreferences {
  bool? cached;
  @override
  bool? getBool(String key) => cached;
  @override
  Future<bool> setBool(String key, bool value) async {
    cached = value;
    return false;
  }

  @override
  Future<bool> remove(String key) async {
    cached = null;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('SoundCloud requires a persisted explicit opt-in', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(await isSoundCloudEnabled(), false);
    expect(container.read(soundCloudEnabledProvider), false);
    await container.read(soundCloudEnabledProvider.notifier).set(true);
    expect(await isSoundCloudEnabled(), true);
    await container.read(soundCloudEnabledProvider.notifier).set(false);
    expect(await isSoundCloudEnabled(), false);
  });

  test(
    'rejected source save restores the attempted preference cache',
    () async {
      final prefs = _RejectedPreferences();
      final provider = NotifierProvider<OptInSourceNotifier, bool>(
        () => OptInSourceNotifier(
          soundCloudEnabledPreferenceKey,
          preferences: () async => prefs,
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(provider), false);
      await expectLater(
        container.read(provider.notifier).set(true),
        throwsStateError,
      );
      expect(container.read(provider), false);
      expect(prefs.cached, isNull);
    },
  );

  test(
    'new Monochrome service is off until the persisted explicit choice',
    () async {
      SharedPreferences.setMockInitialValues({});
      expect(await isMonochromeEnabled(), isFalse);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(monochromeEnabledProvider), isFalse);
      await container.read(monochromeEnabledProvider.notifier).set(true);
      expect(container.read(monochromeEnabledProvider), isTrue);
      expect(await isMonochromeEnabled(), isTrue);
      await container.read(monochromeEnabledProvider.notifier).set(false);
      expect(await isMonochromeEnabled(), isFalse);
    },
  );

  test(
    'late initial preference load cannot undo a new explicit choice',
    () async {
      SharedPreferences.setMockInitialValues({});
      final gate = Completer<SharedPreferences>();
      final provider = NotifierProvider<OptInSourceNotifier, bool>(
        () => OptInSourceNotifier(
          'source-fixture',
          preferences: () => gate.future,
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(provider), isFalse);
      final save = container.read(provider.notifier).set(true);
      gate.complete(await SharedPreferences.getInstance());
      await save;
      expect(container.read(provider), isTrue);
      expect(
        (await SharedPreferences.getInstance()).getBool('source-fixture'),
        isTrue,
      );
    },
  );
}
