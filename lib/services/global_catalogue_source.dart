import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// This setting chooses the metadata catalogue only. Resolving audio still
/// uses PlaybackSourcePriority, completely independently.
abstract final class GlobalCatalogueSource {
  static const key = 'lokal.global_catalogue_source';
  static const apple = 'apple';
  static const spotify = 'spotify';

  static final ValueNotifier<String> selected = ValueNotifier(apple);
  static Future<void>? _loading;

  static Future<String> load() => (_loading ??= _read()).then((_) => selected.value);

  static Future<void> _read() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(key);
    if (saved == spotify || saved == apple) selected.value = saved!;
  }

  static Future<void> set(String value) async {
    if (value != spotify && value != apple) return;
    await load();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
    selected.value = value;
  }
}
