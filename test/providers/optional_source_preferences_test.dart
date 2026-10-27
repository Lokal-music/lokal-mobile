import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/providers/opt_in_source_provider.dart';

void main() {
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
