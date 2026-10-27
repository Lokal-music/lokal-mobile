import 'package:flick/features/konnekted/discovery_shelf_layout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RejectedPreferences implements SharedPreferences {
  String? cached;
  bool reject = false;
  @override
  String? getString(String key) => cached;
  @override
  Future<bool> setString(String key, String value) async {
    cached = value;
    return !reject;
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
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('all three provider modes have independently named shelves', () {
    expect(
      discoveryShelfDefaults['youtube'],
      containsAll([
        'community',
        'newReleases',
        'trending',
        'featuredPlaylists',
        'dailyDiscover',
      ]),
    );
    expect(discoveryShelfDefaults['lastfm'], contains('albums'));
    expect(discoveryShelfDefaults['spotify'], contains('history'));
  });

  test('new shelves are merged into older preferences without duplicates', () {
    final layout = DiscoveryShelfLayout.restore(
      'youtube',
      ['trending', 'mixes', 'trending', 'removed'],
      ['mixes', 'obsolete'],
    );
    expect(layout.order.first, 'trending');
    expect(layout.order.where((id) => id == 'trending'), hasLength(1));
    expect(layout.order, containsAll(discoveryShelfDefaults['youtube']!));
    expect(layout.hidden, {'mixes'});
    expect(layout.visible, isNot(contains('mixes')));
  });

  test('reorder and visibility persist per provider', () async {
    const store = DiscoveryShelfLayoutStore();
    var youtube = DiscoveryShelfLayout.defaults('youtube');
    youtube = youtube.moved(0, 4).showing('trending', false);
    await store.write('youtube', youtube);
    expect((await store.read('youtube')).order, youtube.order);
    expect((await store.read('youtube')).hidden, {'trending'});
    expect((await store.read('spotify')).hidden, isEmpty);
    expect((await store.read('lastfm')).order.first, 'albums');
  });

  test(
    'rejected save restores the prior complete order and visibility',
    () async {
      final prefs = _RejectedPreferences();
      final store = DiscoveryShelfLayoutStore(preferences: () async => prefs);
      final original = DiscoveryShelfLayout.defaults('youtube');
      await store.write('youtube', original);
      final committed = prefs.cached;
      prefs.reject = true;
      await expectLater(
        store.write('youtube', original.moved(0, 4).showing('mixes', false)),
        throwsStateError,
      );
      expect(prefs.cached, committed);
      expect((await store.read('youtube')).order, original.order);
      expect((await store.read('youtube')).hidden, isEmpty);
    },
  );

  test('legacy preferences migrate to one normalized record', () async {
    SharedPreferences.setMockInitialValues({
      'lokal.discovery.shelves.v1.youtube.order': ['trending', 'mixes'],
      'lokal.discovery.shelves.v1.youtube.hidden': ['mixes'],
    });
    const store = DiscoveryShelfLayoutStore();
    final restored = await store.read('youtube');
    expect(restored.order.first, 'trending');
    expect(restored.hidden, {'mixes'});
    await store.write('youtube', restored.showing('community', false));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('lokal.discovery.shelves.v1.youtube.order', [
      'mixes',
    ]);
    final current = await store.read('youtube');
    expect(current.order.first, 'trending');
    expect(current.hidden, {'mixes', 'community'});
  });

  test(
    'invalid or future records use defaults without mixing partial fields',
    () async {
      for (final record in [
        '{"version":2,"order":[]}',
        '{bad',
        '{"version":1,"order":[7],"hidden":[]}',
      ]) {
        SharedPreferences.setMockInitialValues({
          'lokal.discovery.shelves.v1.youtube.record': record,
        });
        final layout = await const DiscoveryShelfLayoutStore().read('youtube');
        expect(layout.order, discoveryShelfDefaults['youtube']);
        expect(layout.hidden, isEmpty);
      }
    },
  );
}
