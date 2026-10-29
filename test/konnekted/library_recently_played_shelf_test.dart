import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/konnekted/konnekted_data.dart';
import 'package:flick/features/konnekted/konnekted_destination.dart';
import 'package:flick/features/konnekted/konnekted_home.dart';
import 'package:flick/features/konnekted/konnekted_library.dart';
import 'package:flick/features/konnekted/library/lokal_library_kit.dart';
import 'package:flick/models/song.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Song _song(String id) => Song(
  id: id,
  title: 'Track $id',
  artist: 'Artist $id',
  duration: const Duration(minutes: 3),
  fileType: 'FLAC',
);

void main() {
  testWidgets('Library shows recently played as a horizontal shelf below More', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(393, 852)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final opened = <KonnektedDestination>[];
    final history = [_song('r1'), _song('r2')];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          konnektedLibraryProvider.overrideWithValue(
            AsyncData([_song('library')]),
          ),
          konnektedRecentSongsProvider.overrideWith(
            (ref) => Stream.value(history),
          ),
        ],
        child: MaterialApp(
          theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.dark)),
          home: Scaffold(body: KonnektedLibrary(onNavigate: opened.add)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The More group no longer includes a history row.
    await tester.scrollUntilVisible(
      find.text('More'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byType(LokalNavRow), findsNWidgets(4));
    expect(find.byIcon(Icons.history_rounded), findsNothing);

    final recentShelf = find.byWidgetPredicate(
      (widget) =>
          widget is KonnektedSongShelf && widget.title == 'Recently played',
    );
    await tester.scrollUntilVisible(
      recentShelf,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('Recently played'), findsOneWidget);
    expect(find.text('Track r1'), findsOneWidget);
    expect(find.text('Track r2'), findsOneWidget);
    final horizontalList = tester.widget<ListView>(
      find.descendant(of: recentShelf, matching: find.byType(ListView)),
    );
    expect(horizontalList.scrollDirection, Axis.horizontal);

    await tester.tap(
      find.descendant(of: recentShelf, matching: find.text('See all')),
    );
    expect(opened, [KonnektedDestination.recentlyPlayed]);
    expect(tester.takeException(), isNull);
  });
}
