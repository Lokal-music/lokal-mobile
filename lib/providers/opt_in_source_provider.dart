import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preference-backed switches for optional online sources. Radio and videos
/// pass [alwaysEnabled] because their user-facing opt-in controls were removed.
class OptInSourceNotifier extends Notifier<bool> {
  OptInSourceNotifier(
    this.key, {
    this.alwaysEnabled = false,
    Future<SharedPreferences> Function()? preferences,
  }) : _preferences = preferences ?? SharedPreferences.getInstance;

  final String key;
  final bool alwaysEnabled;
  final Future<SharedPreferences> Function() _preferences;
  int _revision = 0;

  @override
  bool build() {
    unawaited(_load(_revision).catchError((Object _) {}));
    return alwaysEnabled;
  }

  Future<void> _load(int revision) async {
    final prefs = await _preferences();
    final value = alwaysEnabled ? true : (prefs.getBool(key) ?? false);
    if (alwaysEnabled) await prefs.setBool(key, true);
    if (ref.mounted && revision == _revision && value != state) state = value;
  }

  Future<void> set(bool value) async {
    final revision = ++_revision;
    final next = alwaysEnabled ? true : value;
    final prefs = await _preferences();
    final previous = prefs.getBool(key);
    try {
      if (!await prefs.setBool(key, next)) {
        throw StateError('Source preference could not be saved.');
      }
    } catch (_) {
      // Legacy preferences update their cache before disk acknowledgement.
      // A rejected save must not enable a source through that attempted value.
      if (revision == _revision) {
        try {
          if (previous == null) {
            await prefs.remove(key);
          } else {
            await prefs.setBool(key, previous);
          }
        } catch (_) {}
      }
      rethrow;
    }
    if (ref.mounted && revision == _revision) state = next;
  }
}

const monochromeEnabledPreferenceKey = 'lokal_monochrome_enabled';

final monochromeEnabledProvider = NotifierProvider<OptInSourceNotifier, bool>(
  () => OptInSourceNotifier(monochromeEnabledPreferenceKey),
);

/// Search/fallback never contacts the new service until explicitly enabled.
Future<bool> isMonochromeEnabled() async {
  try {
    return (await SharedPreferences.getInstance()).getBool(
          monochromeEnabledPreferenceKey,
        ) ??
        false;
  } catch (_) {
    return false;
  }
}

const soundCloudEnabledPreferenceKey = 'lokal_soundcloud_enabled';

final soundCloudEnabledProvider = NotifierProvider<OptInSourceNotifier, bool>(
  () => OptInSourceNotifier(soundCloudEnabledPreferenceKey),
);

/// Optional catalogue access is disabled until the listener enables it.
Future<bool> isSoundCloudEnabled() async {
  try {
    return (await SharedPreferences.getInstance()).getBool(
          soundCloudEnabledPreferenceKey,
        ) ??
        false;
  } catch (_) {
    return false;
  }
}

/// Internet radio stations; the station list is fetched when used.
final internetRadioEnabledProvider =
    NotifierProvider<OptInSourceNotifier, bool>(
      () => OptInSourceNotifier(
        'lokal_internet_radio_enabled',
        alwaysEnabled: true,
      ),
    );

/// Music videos: YouTube Music search for a song's official video, watched
/// in YouTube's own embedded player.
final musicVideosEnabledProvider = NotifierProvider<OptInSourceNotifier, bool>(
  () => OptInSourceNotifier('lokal_music_videos_enabled', alwaysEnabled: true),
);
