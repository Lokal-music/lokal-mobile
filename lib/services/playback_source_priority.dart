import 'package:shared_preferences/shared_preferences.dart';

/// One order for automatic playback lookups across artist/album pages,
/// recommendations and pending queues. Explicit Search source picks stay exact.
abstract final class PlaybackSourcePriority {
  static const key = 'lokal.playback.source_order';

  static Future<List<String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(key);
    if (saved != null) return saved.toSet().toList();
    // Preserve the user's earlier pinned source as their first preference.
    final previous = prefs.getString('lokal.catalogue.playback_source');
    final order = previous == null ? <String>[] : [previous];
    await prefs.setStringList(key, order);
    await prefs.remove('lokal.catalogue.playback_source');
    return order;
  }

  static Future<List<T>> order<T>(
    List<T> available,
    String Function(T) id, {
    // Stable provider ids supersede the old HTTP ids derived from display
    // labels. A rename must not silently restore YouTube as first choice.
    Map<String, String> aliases = const {},
  }) async {
    final saved = await load();
    final sources = {for (final source in available) id(source): source};
    final migrated = <String>[for (final key in saved) aliases[key] ?? key]
        .toSet()
        .toList();
    if (migrated.join('\u0000') != saved.join('\u0000')) {
      await (await SharedPreferences.getInstance()).setStringList(
        key,
        migrated,
      );
    }
    return [
      for (final sourceId in {...migrated, ...sources.keys})
        if (sources[sourceId] case final source?) source,
    ];
  }

  static Future<void> move(List<String> visible, int from, int to) async {
    final saved = <String>{...await load(), ...visible}.toList();
    final a = saved.indexOf(visible[from]), b = saved.indexOf(visible[to]);
    final old = saved[a];
    saved[a] = saved[b];
    saved[b] = old;
    await (await SharedPreferences.getInstance()).setStringList(key, saved);
  }
}
