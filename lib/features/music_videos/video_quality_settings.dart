import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Maximum native video resolution. The resolver picks an available format at
/// or below this ceiling; quality is never fabricated or upscaled.
const videoQualityHeights = <int>[0, 360, 480, 720, 1080, 1440, 2160];
const defaultVideoQualityHeight = 1080;
const _videoQualityPreferenceKey = 'lokal.music_video.max_height';

int effectiveVideoHeight(int selection) =>
    selection == 0 ? 2160 : selection;

String videoQualityLabel(int height) =>
    height == 0 ? 'Auto (best available)' : '${height}p';

class VideoQualityNotifier extends Notifier<int> {
  // Restoring preferences must never overwrite a newer user selection.
  // It also prevents an older asynchronous save from winning a rapid change.
  int _selectionGeneration = 0;

  @override
  int build() {
    unawaited(_restore());
    return defaultVideoQualityHeight;
  }

  Future<void> _restore() async {
    final generation = _selectionGeneration;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_videoQualityPreferenceKey);
    if (ref.mounted && generation == _selectionGeneration &&
        videoQualityHeights.contains(saved)) {
      state = saved!;
    }
  }

  Future<void> select(int height) async {
    if (!videoQualityHeights.contains(height)) return;
    final generation = ++_selectionGeneration;
    state = height;
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted || generation != _selectionGeneration) return;
    await prefs.setInt(_videoQualityPreferenceKey, height);
  }
}

final videoQualityProvider =
    NotifierProvider<VideoQualityNotifier, int>(VideoQualityNotifier.new);
