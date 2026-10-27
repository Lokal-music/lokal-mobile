import 'package:flick/features/discovery/discovery_http.dart';
import 'package:flick/features/discovery/discovery_models.dart';
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

  test('SoundCloud is optional and disabling it removes queued access', () async {
    final client = MockClient((_) async => fail('Disabled sources cannot contact a service'));
    addTearDown(client.close);
    final store = _MemorySettings(const DiscoverySettings());
    expect((await onlineSources(client, store: store)).where((s) => s.id == 'sc'), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(soundCloudEnabledPreferenceKey, true);
    final source = (await onlineSources(client, store: store)).singleWhere((s) => s.id == 'sc');
    expect(source.name, 'SoundCloud');
    expect(source.addon, false);
    await prefs.setBool(soundCloudEnabledPreferenceKey, false);
    expect((await onlineSources(client, store: store)).where((s) => s.id == 'sc'), isEmpty);
    await expectLater(playOnlineTrack('sc', const DiscoveryTrack(
      id: '123', title: 'Chosen source', artist: 'Artist',
      source: DiscoverySource.soundCloud, sourceName: 'SoundCloud',
    ), store: store, client: client), throwsA(isA<DiscoveryException>()));
  });

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
