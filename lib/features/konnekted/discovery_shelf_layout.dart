import 'package:shared_preferences/shared_preferences.dart';

/// Stable shelf identifiers, kept independent of translated display names.
const discoveryShelfTitles = <String, String>{
  'mixes': 'Mixed for you',
  'community': 'From the community',
  'newReleases': 'New releases',
  'trending': 'Trending songs for you',
  'featuredPlaylists': 'Featured playlists for you',
  'dailyDiscover': 'Your daily discover',
  'fresh': 'Fresh Finds',
  'quick': 'Quick Picks',
  'history': 'Recently Played',
  'albums': 'Albums For You',
  'artists': 'Artists For You',
};

const discoveryShelfDefaults = <String, List<String>>{
  'youtube': [
    'mixes', 'community', 'newReleases', 'trending', 'featuredPlaylists',
    'dailyDiscover', 'fresh', 'quick', 'artists',
  ],
  'lastfm': ['albums', 'fresh', 'artists'],
  'spotify': ['mixes', 'fresh', 'quick', 'history', 'albums', 'artists'],
};

class DiscoveryShelfLayout {
  DiscoveryShelfLayout({
    required this.order,
    required this.hidden,
  });

  final List<String> order;
  final Set<String> hidden;

  factory DiscoveryShelfLayout.defaults(String provider) =>
      DiscoveryShelfLayout(
        order: List.of(discoveryShelfDefaults[provider] ?? const []),
        hidden: <String>{},
      );

  /// Merges newly introduced shelves into an older preference record.
  factory DiscoveryShelfLayout.restore(
    String provider, List<String>? savedOrder, List<String>? savedHidden,
  ) {
    final defaults = discoveryShelfDefaults[provider] ?? const <String>[];
    final order = <String>{
      for (final id in savedOrder ?? const <String>[])
        if (defaults.contains(id)) id,
      ...defaults,
    }.toList();
    return DiscoveryShelfLayout(
      order: order,
      hidden: {
        for (final id in savedHidden ?? const <String>[])
          if (defaults.contains(id)) id,
      },
    );
  }

  Iterable<String> get visible => order.where((id) => !hidden.contains(id));

  DiscoveryShelfLayout moved(int oldIndex, int newIndex) {
    final updated = List<String>.of(order);
    if (newIndex > oldIndex) newIndex--;
    final id = updated.removeAt(oldIndex);
    updated.insert(newIndex, id);
    return DiscoveryShelfLayout(order: updated, hidden: Set.of(hidden));
  }

  DiscoveryShelfLayout showing(String id, bool show) {
    final updated = Set<String>.of(hidden);
    if (show) {
      updated.remove(id);
    } else {
      updated.add(id);
    }
    return DiscoveryShelfLayout(order: List.of(order), hidden: updated);
  }
}

class DiscoveryShelfLayoutStore {
  const DiscoveryShelfLayoutStore();

  static const _prefix = 'lokal.discovery.shelves.v1.';

  Future<DiscoveryShelfLayout> read(String provider) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return DiscoveryShelfLayout.restore(
        provider,
        prefs.getStringList('$_prefix$provider.order'),
        prefs.getStringList('$_prefix$provider.hidden'),
      );
    } catch (_) {
      return DiscoveryShelfLayout.defaults(provider);
    }
  }

  Future<void> write(String provider, DiscoveryShelfLayout layout) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('$_prefix$provider.order', layout.order);
    await prefs.setStringList('$_prefix$provider.hidden', layout.hidden.toList());
  }
}
