import 'dart:convert';

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
    'mixes',
    'community',
    'newReleases',
    'trending',
    'featuredPlaylists',
    'dailyDiscover',
    'fresh',
    'quick',
    'artists',
  ],
  'lastfm': ['albums', 'fresh', 'artists'],
  'spotify': ['mixes', 'fresh', 'quick', 'history', 'albums', 'artists'],
};

class DiscoveryShelfLayout {
  DiscoveryShelfLayout({
    required List<String> order,
    required Set<String> hidden,
  }) : order = List.unmodifiable(order),
       hidden = Set.unmodifiable(hidden);

  final List<String> order;
  final Set<String> hidden;

  factory DiscoveryShelfLayout.defaults(String provider) =>
      DiscoveryShelfLayout(
        order: List.of(discoveryShelfDefaults[provider] ?? const []),
        hidden: <String>{},
      );

  /// Merges newly introduced shelves into an older preference record.
  factory DiscoveryShelfLayout.restore(
    String provider,
    List<String>? savedOrder,
    List<String>? savedHidden,
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
  const DiscoveryShelfLayoutStore({this.preferences});

  final Future<SharedPreferences> Function()? preferences;

  Future<SharedPreferences> _prefs() =>
      (preferences ?? SharedPreferences.getInstance)();

  static const _prefix = 'lokal.discovery.shelves.v1.';

  Future<DiscoveryShelfLayout> read(String provider) async {
    try {
      final prefs = await _prefs();
      final document = prefs.getString('$_prefix$provider.record');
      if (document != null) {
        final decoded = jsonDecode(document);
        if (decoded is! Map || decoded['version'] != 1) {
          return DiscoveryShelfLayout.defaults(provider);
        }
        return DiscoveryShelfLayout.restore(
          provider,
          (decoded['order'] as List).cast<String>(),
          (decoded['hidden'] as List).cast<String>(),
        );
      }
      // Read the earlier two-key shape, but all new saves commit one record.
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
    final prefs = await _prefs();
    final key = '$_prefix$provider.record';
    final previous = prefs.getString(key);
    final normalized = DiscoveryShelfLayout.restore(
      provider,
      layout.order,
      layout.hidden.toList(),
    );
    try {
      final saved = await prefs.setString(
        key,
        jsonEncode({
          'version': 1,
          'order': normalized.order,
          'hidden': normalized.hidden.toList(),
        }),
      );
      if (!saved) throw StateError('Discovery layout save rejected');
    } catch (_) {
      // Legacy SharedPreferences mutates its cache before disk acknowledges.
      try {
        if (previous == null) {
          await prefs.remove(key);
        } else {
          await prefs.setString(key, previous);
        }
      } catch (_) {}
      rethrow;
    }
  }
}
