import 'package:flick/features/konnekted/discovery_shelf_layout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('all three provider modes have independently named shelves', () {
    expect(discoveryShelfDefaults['youtube'], containsAll([
      'community', 'newReleases', 'trending', 'featuredPlaylists',
      'dailyDiscover',
    ]));
    expect(discoveryShelfDefaults['lastfm'], contains('albums'));
    expect(discoveryShelfDefaults['spotify'], contains('history'));
  });

  test('new shelves are merged into older preferences without duplicates', () {
    final layout = DiscoveryShelfLayout.restore('youtube', [
      'trending', 'mixes', 'trending', 'removed',
    ], ['mixes', 'obsolete']);
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
}
