import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flick/core/theme/lokal_appearance.dart';
import 'package:flick/core/theme/lokal_tokens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('JSON round-trips and clamps text size', () {
    const look = LokalAppearance(
      theme: LokalThemeId.cyberpunk,
      accent: LokalAccent.teal,
      textScale: 1.2,
      performanceMode: true,
      fullscreenCover: true,
      resolutionTagsInLists: true,
      resolutionTagsInFullPlayer: true,
    );
    expect(LokalAppearance.fromJson(look.toJson()), look);
    expect(
      LokalAppearance.fromJson(const {'textScale': 9}).textScale,
      LokalAppearance.maxTextScale,
    );
    expect(LokalAppearance.fromJson(const {}), const LokalAppearance());
    expect(
      LokalAppearance.fromJson(const {'resolutionTagsInLists': 'yes'})
          .resolutionTagsInLists,
      isFalse,
    );
    expect(
      const LokalAppearance().copyWith(resolutionTagsInLists: true),
      isNot(const LokalAppearance()),
    );
    expect(
      const LokalAppearance().copyWith(resolutionTagsInFullPlayer: true),
      isNot(const LokalAppearance()),
    );
  });

  test('picking a theme drops a custom accent but keeps the rest', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(lokalAppearanceProvider);
    await pumpEventQueue();
    final notifier = container.read(lokalAppearanceProvider.notifier);
    await notifier.setAccent(LokalAccent.orange);
    await notifier.setTextScale(1.3);
    await notifier.setFullscreenCover(true);
    await notifier.setResolutionTagsInLists(true);
    await notifier.setResolutionTagsInFullPlayer(false);
    await notifier.selectTheme(LokalThemeId.forest);
    final look = container.read(lokalAppearanceProvider);
    expect(look.theme, LokalThemeId.forest);
    expect(look.accent, isNull);
    expect(look.textScale, 1.3);
    expect(look.fullscreenCover, isTrue);
    expect(look.resolutionTagsInLists, isTrue);
    expect(look.resolutionTagsInFullPlayer, isFalse);
  });

  test('the look is saved and restored', () async {
    final first = ProviderContainer();
    first.read(lokalAppearanceProvider);
    await pumpEventQueue();
    await first
        .read(lokalAppearanceProvider.notifier)
        .selectTheme(LokalThemeId.rosegold);
    await first
        .read(lokalAppearanceProvider.notifier)
        .setAccent(LokalAccent.cyan);
    await first.read(lokalAppearanceProvider.notifier).setFullscreenCover(true);
    await first
        .read(lokalAppearanceProvider.notifier)
        .setResolutionTagsInLists(true);
    await first
        .read(lokalAppearanceProvider.notifier)
        .setResolutionTagsInFullPlayer(true);
    first.dispose();

    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString(LokalAppearanceNotifier.prefKey)!);
    expect(saved['theme'], 'rosegold');

    final second = ProviderContainer();
    addTearDown(second.dispose);
    second.read(lokalAppearanceProvider);
    await pumpEventQueue();
    final look = second.read(lokalAppearanceProvider);
    expect(look.theme, LokalThemeId.rosegold);
    expect(look.accent, LokalAccent.cyan);
    expect(look.fullscreenCover, isTrue);
    expect(look.resolutionTagsInLists, isTrue);
    expect(look.resolutionTagsInFullPlayer, isTrue);
  });

  test('a damaged saved value falls back to the defaults', () async {
    SharedPreferences.setMockInitialValues({
      LokalAppearanceNotifier.prefKey: '{not json',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(lokalAppearanceProvider);
    await pumpEventQueue();
    expect(container.read(lokalAppearanceProvider), const LokalAppearance());
  });
}
