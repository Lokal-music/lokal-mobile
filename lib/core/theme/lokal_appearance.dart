import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lokal_tokens.dart';

enum LokalPerformanceLevel { full, performance, ultra }

/// The listener's look: theme, accent, text size and glass.
///
/// Mirrors desktop Lokal's Appearance settings. As on desktop, picking a
/// theme drops a custom accent, while text size and performance mode
/// survive the switch.
@immutable
class LokalAppearance {
  const LokalAppearance({
    this.theme = LokalThemeId.dark,
    this.accent,
    this.textScale = 1.0,
    this.performanceMode = true,
    this.ultraPerformanceMode = false,
    this.fullscreenCover = false,
    this.unboxedPlayerControls = false,
    this.resolutionTagsInLists = false,
    this.resolutionTagsInFullPlayer = false,
  });

  final LokalThemeId theme;

  /// A preset chosen on top of the theme; null uses the theme's own accent.
  final LokalAccent? accent;

  /// Multiplies the system text scale, 0.7–1.5 like desktop's Text Size.
  final double textScale;

  /// Replaces every glass surface with its solid tint (desktop's
  /// Performance Mode removes every backdrop-filter the same way).
  final bool performanceMode;

  /// Additional rendering reductions for entry-level phones; opt-in.
  final bool ultraPerformanceMode;
  LokalPerformanceLevel get performanceLevel => ultraPerformanceMode
      ? LokalPerformanceLevel.ultra
      : performanceMode
      ? LokalPerformanceLevel.performance
      : LokalPerformanceLevel.full;

  /// Edge-to-edge artwork behind full-player controls, with no live blur.
  final bool fullscreenCover;
  final bool unboxedPlayerControls;

  /// Show measured/explicit audio resolution instead of quality tiers in lists.
  final bool resolutionTagsInLists;

  /// Separate choice for the player quality badge (keeps its white styling).
  final bool resolutionTagsInFullPlayer;

  static const minTextScale = 0.7;
  static const maxTextScale = 1.5;

  LokalTokens get tokens => LokalTokens.resolve(theme, accent: accent);

  LokalAppearance copyWith({
    LokalThemeId? theme,
    LokalAccent? accent,
    bool clearAccent = false,
    double? textScale,
    bool? performanceMode,
    bool? ultraPerformanceMode,
    bool? fullscreenCover,
    bool? unboxedPlayerControls,
    bool? resolutionTagsInLists,
    bool? resolutionTagsInFullPlayer,
  }) => LokalAppearance(
    theme: theme ?? this.theme,
    accent: clearAccent ? null : (accent ?? this.accent),
    textScale: (textScale ?? this.textScale).clamp(minTextScale, maxTextScale),
    performanceMode: performanceMode ?? this.performanceMode,
    ultraPerformanceMode: ultraPerformanceMode ?? this.ultraPerformanceMode,
    fullscreenCover: fullscreenCover ?? this.fullscreenCover,
    unboxedPlayerControls: unboxedPlayerControls ?? this.unboxedPlayerControls,
    resolutionTagsInLists: resolutionTagsInLists ?? this.resolutionTagsInLists,
    resolutionTagsInFullPlayer:
        resolutionTagsInFullPlayer ?? this.resolutionTagsInFullPlayer,
  );

  Map<String, Object?> toJson() => {
    'theme': theme.name,
    'accent': accent?.name,
    'textScale': textScale,
    'performanceMode': performanceMode,
    'ultraPerformanceMode': ultraPerformanceMode,
    'fullscreenCover': fullscreenCover,
    'unboxedPlayerControls': unboxedPlayerControls,
    'resolutionTagsInLists': resolutionTagsInLists,
    'resolutionTagsInFullPlayer': resolutionTagsInFullPlayer,
  };

  factory LokalAppearance.fromJson(Map<String, Object?> json) {
    final scale = json['textScale'];
    return LokalAppearance(
      theme: LokalThemeId.fromKey(json['theme'] as String?),
      accent: LokalAccent.byName(json['accent'] as String?),
      textScale: (scale is num ? scale.toDouble() : 1.0).clamp(
        minTextScale,
        maxTextScale,
      ),
      performanceMode:
          json['ultraPerformanceMode'] == true ||
          (json['performanceMode'] as bool? ?? true),
      ultraPerformanceMode: json['ultraPerformanceMode'] as bool? ?? false,
      fullscreenCover: json['fullscreenCover'] as bool? ?? false,
      unboxedPlayerControls: json['unboxedPlayerControls'] as bool? ?? false,
      resolutionTagsInLists: json['resolutionTagsInLists'] == true,
      resolutionTagsInFullPlayer: json['resolutionTagsInFullPlayer'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LokalAppearance &&
      other.theme == theme &&
      other.accent == accent &&
      other.textScale == textScale &&
      other.performanceMode == performanceMode &&
      other.ultraPerformanceMode == ultraPerformanceMode &&
      other.fullscreenCover == fullscreenCover &&
      other.unboxedPlayerControls == unboxedPlayerControls &&
      other.resolutionTagsInLists == resolutionTagsInLists &&
      other.resolutionTagsInFullPlayer == resolutionTagsInFullPlayer;

  @override
  int get hashCode => Object.hash(
    theme,
    accent,
    textScale,
    performanceMode,
    ultraPerformanceMode,
    fullscreenCover,
    unboxedPlayerControls,
    resolutionTagsInLists,
    resolutionTagsInFullPlayer,
  );
}

class LokalAppearanceNotifier extends Notifier<LokalAppearance> {
  static const prefKey = 'lokal.appearance.v1';

  /// Set once the listener changes anything, so a slow first read of the
  /// saved look can't undo that change on screen.
  bool _touched = false;

  @override
  LokalAppearance build() {
    Future<void>.microtask(_load);
    return ref.read(lokalInitialAppearanceProvider);
  }

  static Future<LokalAppearance> readSaved() async {
    final raw = (await SharedPreferences.getInstance()).get(prefKey);
    if (raw is! String) return const LokalAppearance();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>)
        return LokalAppearance.fromJson(decoded);
    } on Object {
      /* Invalid preferences use the yellow-accented Dark theme. */
    }
    return const LokalAppearance();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefKey);
    if (raw == null || _touched || !ref.mounted) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        state = LokalAppearance.fromJson(decoded);
      }
    } on Object {
      // A damaged value falls back to the defaults rather than failing start-up.
    }
  }

  Future<void> _commit(LokalAppearance next) async {
    _touched = true;
    if (jsonEncode(next.toJson()) == jsonEncode(state.toJson())) return;
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefKey, jsonEncode(next.toJson()));
  }

  Future<void> adoptDesktopTheme(Map<String, dynamic> value) async {
    final name = value['theme']?.toString();
    final themes = LokalThemeId.values.where((item) => item.name == name);
    var next = themes.isEmpty
        ? state
        : state.copyWith(theme: themes.first, clearAccent: true);
    final accentName = value['accent']?.toString();
    final accents = LokalAccent.presets.where(
      (item) => item.name == accentName,
    );
    if (accents.isNotEmpty) {
      next = next.copyWith(accent: accents.first);
    } else {
      final raw = value['accentColor']?.toString().replaceFirst('#', '');
      if (raw != null && RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(raw))
        next = next.copyWith(
          accent: LokalAccent.nearest(Color(int.parse('ff$raw', radix: 16))),
        );
    }
    await _commit(next);
  }

  Future<void> selectTheme(LokalThemeId theme) =>
      _commit(state.copyWith(theme: theme, clearAccent: true));

  /// Null goes back to the theme's own accent.
  Future<void> setAccent(LokalAccent? accent) => _commit(
    accent == null
        ? state.copyWith(clearAccent: true)
        : state.copyWith(accent: accent),
  );

  Future<void> setTextScale(double value) =>
      _commit(state.copyWith(textScale: value));

  Future<void> setUnboxedPlayerControls(bool value) =>
      _commit(state.copyWith(unboxedPlayerControls: value));

  Future<void> setFullscreenCover(bool value) =>
      _commit(state.copyWith(fullscreenCover: value));

  Future<void> setResolutionTagsInLists(bool value) =>
      _commit(state.copyWith(resolutionTagsInLists: value));

  Future<void> setResolutionTagsInFullPlayer(bool value) =>
      _commit(state.copyWith(resolutionTagsInFullPlayer: value));

  Future<void> setPerformanceMode(bool value) => _commit(
    state.copyWith(
      performanceMode: value,
      ultraPerformanceMode: value && state.ultraPerformanceMode,
    ),
  );

  Future<void> setPerformanceLevel(LokalPerformanceLevel level) => _commit(
    state.copyWith(
      performanceMode: level != LokalPerformanceLevel.full,
      ultraPerformanceMode: level == LokalPerformanceLevel.ultra,
    ),
  );
}

final lokalInitialAppearanceProvider = Provider<LokalAppearance>(
  (ref) => const LokalAppearance(),
);

final lokalAppearanceProvider =
    NotifierProvider<LokalAppearanceNotifier, LokalAppearance>(
      LokalAppearanceNotifier.new,
    );
