import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flick/services/playback_source_priority.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _RejectOnce extends InMemorySharedPreferencesStore {
  _RejectOnce() : super.empty();
  bool reject = false;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (reject) {
      reject = false;
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      PlaybackSourcePriority.key: ['mono', 'w-lossless', 'sc', 'yt'],
    });
  });

  test('Eco Data Mode is off by default and can be persisted', () async {
    expect(await EcoDataMode.enabled(), isFalse);
    await EcoDataMode.setEnabled(true);
    expect(await EcoDataMode.enabled(), isTrue);
    await EcoDataMode.setEnabled(false);
    expect(await EcoDataMode.enabled(), isFalse);
  });

  test('Eco Data Mode requires mobile connectivity, not Wi-Fi', () {
    expect(EcoDataMode.isCellularOnly([ConnectivityResult.mobile]), true);
    expect(
      EcoDataMode.isCellularOnly([
        ConnectivityResult.mobile,
        ConnectivityResult.wifi,
      ]),
      false,
    );
    expect(EcoDataMode.isCellularOnly([ConnectivityResult.wifi]), false);
    expect(EcoDataMode.isCellularOnly([ConnectivityResult.none]), false);
  });

  test('cellular source policy prefers compressed native sources without saving changes', () async {
    const sources = ['mono', 'w-lossless', 'sc', 'yt'];
    final normal = await PlaybackSourcePriority.order(sources, (x) => x);
    expect(normal, sources);

    final automaticCellular = await PlaybackSourcePriority.order(
      sources,
      (x) => x,
      ecoOnCellular: true,
      ecoActive: () async => true,
    );
    expect(automaticCellular, ['yt', 'sc', 'mono', 'w-lossless']);
    expect(
      await PlaybackSourcePriority.load(),
      sources,
      reason: 'Eco mode must not rewrite the preferred source order',
    );

    final onWifi = await PlaybackSourcePriority.order(
      sources,
      (x) => x,
      ecoOnCellular: true,
      ecoActive: () async => false,
    );
    expect(onWifi, sources);
    final selected = await PlaybackSourcePriority.order(
      sources,
      (x) => x,
      ecoActive: () async => true,
    );
    expect(
      selected,
      sources,
      reason: 'Explicitly selected sources never run the eco override',
    );
  });

  test(
    'rejected reorder restores cached priority and allows a later retry',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = _RejectOnce();
      SharedPreferencesStorePlatform.instance = store;
      final preferences = await SharedPreferences.getInstance();
      await preferences.setStringList(PlaybackSourcePriority.key, [
        'first',
        'second',
      ]);
      store.reject = true;
      await expectLater(
        PlaybackSourcePriority.reorder(['first', 'second'], 0, 2),
        throwsStateError,
      );
      expect(await PlaybackSourcePriority.load(), ['first', 'second']);
      await PlaybackSourcePriority.reorder(['first', 'second'], 0, 2);
      expect(await PlaybackSourcePriority.load(), ['second', 'first']);
    },
  );

  test(
    'new addons are promoted without disturbing established priorities',
    () async {
      await PlaybackSourcePriority.promoteNewAddon('w-new-http');
      expect(await PlaybackSourcePriority.load(), [
        'w-new-http',
        'mono',
        'w-lossless',
        'sc',
        'yt',
      ]);

      await PlaybackSourcePriority.promoteNewAddon('a-new-package');
      expect(await PlaybackSourcePriority.load(), [
        'a-new-package',
        'w-new-http',
        'mono',
        'w-lossless',
        'sc',
        'yt',
      ]);
      await PlaybackSourcePriority.promoteNewAddon('a-new-package');
      expect(
        (await PlaybackSourcePriority.load()).where(
          (id) => id == 'a-new-package',
        ),
        hasLength(1),
      );
    },
  );

  test('dragging a row relocates it instead of swapping endpoints', () async {
    await PlaybackSourcePriority.reorder(
      ['mono', 'w-lossless', 'sc', 'yt'],
      0,
      3,
    );
    expect(await PlaybackSourcePriority.load(), [
      'w-lossless',
      'sc',
      'mono',
      'yt',
    ]);
    await PlaybackSourcePriority.reorder(
      ['w-lossless', 'sc', 'mono', 'yt'],
      3,
      0,
    );
    expect(await PlaybackSourcePriority.load(), [
      'yt',
      'w-lossless',
      'sc',
      'mono',
    ]);
  });

  test(
    'drag preserves disabled source positions and future visibility',
    () async {
      SharedPreferences.setMockInitialValues({
        PlaybackSourcePriority.key: ['yt', 'hidden', 'a-one', 'mono'],
      });
      await PlaybackSourcePriority.reorder(['yt', 'a-one', 'mono'], 0, 3);
      expect(await PlaybackSourcePriority.load(), [
        'a-one',
        'hidden',
        'mono',
        'yt',
      ]);
      expect(
        await PlaybackSourcePriority.order([
          'yt',
          'hidden',
          'a-one',
          'mono',
        ], (id) => id),
        ['a-one', 'hidden', 'mono', 'yt'],
      );
    },
  );

  test('no-op drag does not change saved priority', () async {
    await PlaybackSourcePriority.reorder(
      ['mono', 'w-lossless', 'sc', 'yt'],
      1,
      2,
    );
    expect(await PlaybackSourcePriority.load(), [
      'mono',
      'w-lossless',
      'sc',
      'yt',
    ]);
  });

  test(
    'HTTP-only configuration never introduces a disabled YouTube source',
    () async {
      final actual = await PlaybackSourcePriority.order(
        ['w-lossless'],
        (x) => x,
        ecoOnCellular: true,
        ecoActive: () async => true,
      );
      expect(actual, ['w-lossless']);
    },
  );
}
