import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flick/services/playback_source_priority.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
