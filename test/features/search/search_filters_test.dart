import 'package:flick/features/search/providers/search_filter_provider.dart';
import 'package:flick/features/search/models/search_category.dart';
import 'package:flick/features/search/widgets/search_filter_chips.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'a category isolates immediately, and retired All maps to Songs',
    () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final f = c.read(searchFilterProvider.notifier);
      expect(c.read(searchFilterProvider), {SearchCategory.songs});
      f.toggle(SearchCategory.albums);
      expect(c.read(searchFilterProvider), {SearchCategory.albums});
      f.toggle(SearchCategory.albums);
      expect(c.read(searchFilterProvider), {SearchCategory.albums});
      await Future<void>.delayed(Duration.zero);
      expect(c.read(searchFilterProvider), {
        SearchCategory.albums,
      }); // Hydration cannot undo a tap.
      f.toggle(SearchCategory.artists);
      expect(c.read(searchFilterProvider), {SearchCategory.artists});
      f.select(SearchCategory.songs);
      expect(c.read(searchFilterProvider), {SearchCategory.songs});
    },
  );
  test('old exclusion mask does not restore a disabled-all dead end', () async {
    SharedPreferences.setMockInitialValues({
      'search_enabled_categories': <String>[],
    });
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(searchFilterProvider);
    await Future<void>.delayed(Duration.zero);
    expect(c.read(searchFilterProvider), {SearchCategory.songs});
  });
  test('online/local-only categories have consistent scope', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final f = c.read(searchFilterProvider.notifier);
    final scope = c.read(searchScopeProvider.notifier);
    scope.select(SearchScope.online);
    f.select(SearchCategory.folders);
    expect(c.read(searchScopeProvider), SearchScope.library);
    scope.select(SearchScope.online);
    expect(c.read(searchFilterProvider), {SearchCategory.songs});
    f.select(SearchCategory.albums);
    expect(c.read(searchScopeProvider), SearchScope.online);
  });
  testWidgets(
    'category and scope controls respond directly on a narrow phone',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: LokalTheme.build(LokalTokens.themes[LokalThemeId.dark]!),
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  final enabled = ref.watch(searchFilterProvider);
                  return SearchFilterChips(
                    enabled: enabled,
                    scope: ref.watch(searchScopeProvider),
                    onScopeChanged: ref
                        .read(searchScopeProvider.notifier)
                        .select,
                    onToggle: ref.read(searchFilterProvider.notifier).select,
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Albums'));
      await tester.pumpAndSettle();
      expect(c.read(searchFilterProvider), {SearchCategory.albums});
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Albums'))
            .selected,
        true,
      );
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Songs'))
            .selected,
        false,
      );
      await tester.tap(find.text('Online'));
      await tester.pumpAndSettle();
      expect(c.read(searchScopeProvider), SearchScope.online);
      expect(find.text('All'), findsNothing);
      expect(c.read(searchFilterProvider), {SearchCategory.albums});
      expect(tester.takeException(), isNull);
    },
  );
}
