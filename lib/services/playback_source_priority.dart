import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

/// One order for automatic playback lookups across artist/album pages,
/// recommendations and pending queues. Explicit Search source picks stay exact.
/// Opt-in low-bandwidth lookup policy. Active only when the device uses mobile
/// data, not Wi-Fi or wired connectivity. Never changes the saved source order.
abstract final class EcoDataMode {
  static const key = 'lokal.playback.eco_data_mode';

  static Future<bool> enabled() async =>
      (await SharedPreferences.getInstance()).getBool(key) ?? false;

  static Future<void> setEnabled(bool value) async {
    await (await SharedPreferences.getInstance()).setBool(key, value);
  }

  static bool isCellularOnly(List<ConnectivityResult> transports) =>
      transports.contains(ConnectivityResult.mobile) &&
      !transports.contains(ConnectivityResult.wifi) &&
      !transports.contains(ConnectivityResult.ethernet);

  static Future<bool> activeOnCellular() async {
    if (!await enabled()) return false;
    try {
      return isCellularOnly(await Connectivity().checkConnectivity());
    } catch (_) {
      // Do not change playback order if the platform cannot identify the link.
      return false;
    }
  }
}

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
    // Applied to automatic source discovery only, never an explicit Search
    // selection or a pinned queue entry. No persistent reordering.
    bool ecoOnCellular = false,
    Future<bool> Function()? ecoActive,
  }) async {
    final saved = await load();
    final sources = {for (final source in available) id(source): source};
    final migrated = <String>[
      for (final key in saved) aliases[key] ?? key,
    ].toSet().toList();
    if (migrated.join('\u0000') != saved.join('\u0000')) {
      await (await SharedPreferences.getInstance())
          .setStringList(key, migrated);
    }
    final ordered = [
      for (final sourceId in {...migrated, ...sources.keys})
        if (sources[sourceId] case final source?) source,
    ];
    if (!ecoOnCellular ||
        !await (ecoActive ?? EcoDataMode.activeOnCellular)()) {
      return ordered;
    }
    // Prefer compressed native streams over lossless Monochrome/addons on
    // metered mobile data. Keep the saved order for all remaining sources.
    const economical = ['yt', 'sc'];
    return [
      for (final sourceId in economical)
        if (sources[sourceId] case final source?) source,
      for (final source in ordered)
        if (!economical.contains(id(source))) source,
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
