import 'package:flick/features/discovery/discovery_settings.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/providers/opt_in_source_provider.dart';

class _MemorySettings extends DiscoverySettingsStore {
  _MemorySettings(this.settings);

  final DiscoverySettings settings;

  @override
  Future<DiscoverySettings> load() async => settings;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'Monochrome is opt-in and remains a native source when enabled',
    () async {
      final client = MockClient(
        (_) async => fail('Listing sources must not contact a service'),
      );
      addTearDown(client.close);
      final store = _MemorySettings(const DiscoverySettings());
      final disabled = await onlineSources(client, store: store);
      expect(disabled.where((source) => source.id == 'mono'), isEmpty);
      await (await SharedPreferences.getInstance()).setBool(
        monochromeEnabledPreferenceKey,
        true,
      );
      final enabled = await onlineSources(client, store: store);
      expect(
        enabled.singleWhere((source) => source.id == 'mono').name,
        'Monochrome',
      );
      expect(
        enabled.singleWhere((source) => source.id == 'mono').addon,
        isFalse,
      );
      expect(enabled.singleWhere((source) => source.id == 'yt').addon, isFalse);
    },
  );

  test('new online Search includes saved HTTP add-ons', () async {
    final client = MockClient((_) async => fail('Search was not started'));
    addTearDown(client.close);
    final sources = await onlineSources(
      client,
      store: _MemorySettings(
        const DiscoverySettings(
          addons: [
            DiscoveryAddonConfig(
              id: 'home',
              label: 'Home music',
              endpoint: 'https://music.example/library',
              token: 'fixture-token',
              enabled: true,
            ),
          ],
        ),
      ),
    );

    expect(
      sources.where((source) => source.name == 'Home music'),
      hasLength(1),
    );
    expect(
      sources.singleWhere((source) => source.name == 'Home music').addon,
      isTrue,
    );
  });
}
