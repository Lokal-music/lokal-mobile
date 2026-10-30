import 'package:flick/features/discovery/discovery_settings.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemorySettings extends DiscoverySettingsStore {
  _MemorySettings(this.settings);

  final DiscoverySettings settings;

  @override
  Future<DiscoverySettings> load() async => settings;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

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

    expect(sources.singleWhere((source) => source.id == 'mono').name, 'Monochrome');
    expect(sources.singleWhere((source) => source.id == 'sc').name, 'SoundCloud');
    expect(sources.singleWhere((source) => source.id == 'sc').addon, isFalse);
    expect(sources.singleWhere((source) => source.id == 'mono').addon, isFalse);
    expect(sources.singleWhere((source) => source.id == 'yt').addon, isFalse);

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
