import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/konnekted/konnekted_data.dart';
import 'package:flick/features/konnekted/library/lokal_genres.dart';
import 'package:flick/models/song.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Song track(String id, String? genre, {String? path, DateTime? added,
    String? sourcePackage}) => Song(
  id: id,
  title: 'Track $id',
  artist: 'Artist',
  genre: genre,
  dateAdded: added,
  filePath: path,
  sourcePackage: sourcePackage,
  duration: const Duration(minutes: 3),
  fileType: 'FLAC',
);

void main() {
  test('desktop aliases and subgenres become one broad genre', () {
    expect(lokalNormalizeGenreName('VGM'), 'Video Game Music');
    expect(lokalNormalizeGenreName('Video Game Soundtrack'), 'Video Game Music');
    expect(lokalNormalizeGenreName('video game'), 'Video Game Music');
    expect(lokalNormalizeGenreName('Original Soundtrack'), 'Soundtrack');
    expect(lokalNormalizeGenreName('EDM'), 'Electronic');
    expect(lokalNormalizeGenreName('Techno'), 'Electronic');
    expect(lokalNormalizeGenreName('Indie Rock'), 'Rock');
    expect(lokalNormalizeGenreName('Hip-Hop'), 'Hip-Hop');
    expect(lokalNormalizeGenreName('R&B'), 'R&B / Soul');
    expect(lokalNormalizeGenreName('norteño'), 'Latin');
    expect(lokalNormalizeGenreName('NORTENO'), 'Latin');
    expect(lokalNormalizeGenreName('рэп'), 'Hip-Hop');
    expect(lokalNormalizeGenreName('City Pop'), 'Pop');
    expect(lokalNormalizeGenreName('Afro House'), 'Electronic');
    expect(lokalNormalizeGenreName('UK Garage'), 'Electronic');
    expect(lokalNormalizeGenreName('Amapiano'), 'Electronic');
    expect(lokalNormalizeGenreName('Shoegaze'), 'Rock');
    expect(lokalNormalizeGenreName('Raï'), 'World');
    expect(lokalNormalizeGenreName('invented microgenre'), 'invented microgenre');
  });

  test('ignored tags are not genres; do not modify stored raw metadata', () {
    for (final raw in ['Karaoke_Plain', 'Instrumental', 'Unknown',
        '255', 'No genre', 'Podcast', '']) {
      expect(lokalNormalizeGenreName(raw), isNull, reason: raw);
    }
    final song = track('raw', 'VGM; Video Game Soundtrack / Rock');
    expect(lokalSplitGenres(song.genre),
        ['VGM', 'Video Game Soundtrack', 'Rock']);
    expect(lokalTrackGenres(song), ['Video Game Music', 'Rock']);
    expect(song.genre, 'VGM; Video Game Soundtrack / Rock');
  });

  test('desktop genre summary keeps single recognized and repeated custom genres', () {
    final items = [
      track('1', 'VGM'),
      track('2', 'video game'),
      track('3', 'Rock, EDM'),
      track('4', 'Classic Rock'),
      track('5', 'Indie Rock; Techno'),
      track('6', 'House'),
      track('7', 'Random Tag One'),
      track('8', 'Random Tag Two'),
      track('9', 'Baroque'),
      track('10', 'Karaoke_Plain, Unknown, 128'),
      track('11', 'Unknown'),
      track('12', 'Future Jazz'),
      track('13', 'future-jazz'),
    ];
    final summary = lokalGenreSummary(items);
    final byName = {for (final g in summary.genres) g.name: g};
    expect(byName['Video Game Music']!.songs.length, 2);
    expect(byName['Rock']!.songs.length, 3);
    expect(byName['Electronic']!.songs.length, 3);
    expect(byName['Other']!.songs.length, 2);
    expect(byName['Classical']!.songs.length, 1);
    expect(byName['Future Jazz']!.songs.length, 2);
    expect(summary.noGenre.map((s) => s.id), ['10', '11']);
    expect(summary.genres.where((g) => g.songs.length == 1).map((g) => g.name),
        ['Classical']);
    expect(summary.genres.map((g) => g.name).toList(),
        ['Electronic', 'Rock', 'Future Jazz', 'Other',
         'Video Game Music', 'Classical']);
    // Each category is populated from the same recordings as the cards.
    expect(byName['Rock']!.songs.map((s) => s.id), ['3', '4', '5']);
    expect(items[0].genre, 'VGM');
  });

  test('rare unknown tag becomes No genre when Other cannot reach two tracks', () {
    final summary = lokalGenreSummary([
      track('1', 'Baroque'),
      track('2', 'Hip-Hop'),
      track('3', 'Hip Hop'),
      track('4', 'Unknown'),
    ]);
    expect(summary.genres.map((x) => x.name), ['Hip-Hop']);
    expect(summary.noGenre.map((x) => x.id), ['1', '4']);
  });

  test('multi-tag tracks prefer common genre rather than being put in Other', () {
    final summary = lokalGenreSummary([
      track('1', 'Random Tag, Hip Hop'),
      track('2', 'Hip-Hop'),
      track('3', 'House'),
      track('4', 'Electronic'),
    ]);
    expect(summary.genres.map((g) => g.name), ['Electronic', 'Hip-Hop']);
    expect(summary.genres.firstWhere((g) => g.name == 'Hip-Hop')
        .songs.map((s) => s.id), ['1', '2']);
    expect(summary.noGenre, isEmpty);
  });


  test('unknown labels used on several recordings become a custom category', () {
    final summary = lokalGenreSummary([
      track('1', 'Highlife'),
      track('2', 'Future Soul'),
      track('3', 'future-soul'),
      track('4', 'Other'),
      track('5', 'Other'),
    ]);
    final genres = {for (final genre in summary.genres) genre.name: genre};
    expect(genres['World']!.songs.map((s) => s.id), ['1']);
    expect(genres['Future Soul']!.songs.map((s) => s.id), ['2', '3']);
    expect(genres['Other']!.songs.map((s) => s.id), ['4', '5']);
  });

  test('recognized one-track categories stay visible and do not pollute Other', () {
    final summary = lokalGenreSummary([
      track('1', 'Classical'),
      track('2', 'Unknown style a'),
      track('3', 'Unknown style b'),
      track('4', 'Rock, Unknown style c'),
    ]);
    final byName = {for (final g in summary.genres) g.name: g};
    expect(byName['Classical']!.songs.map((s) => s.id), ['1']);
    expect(byName['Rock']!.songs.map((s) => s.id), ['4']);
    expect(byName['Other']!.songs.map((s) => s.id), ['2', '3']);
    expect(summary.noGenre, isEmpty);
  });

  test('pending placeholders are excluded and art order follows added date', () {
    final summary = lokalGenreSummary([
      track('old', 'Rock', added: DateTime(2024)),
      track('ghost', 'Rock', path: 'ghost://catalogue/1'),
      track('pending', 'Rock', sourcePackage: Song.pendingSourcePackage),
      track('new', 'Rock', added: DateTime(2026)),
    ]);
    expect(summary.genres.single.songs.map((s) => s.id), ['new', 'old']);
  });

  testWidgets('Genres page searches canonical groups and keeps No genre', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(393, 852)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final library = [
      track('r1', 'Rock'), track('r2', 'Indie Rock'),
      track('x1', 'Unknown'),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          konnektedLibraryProvider.overrideWithValue(AsyncData(library)),
        ],
        child: MaterialApp(
          theme: LokalTheme.build(LokalTokens.themes[LokalThemeId.dark]!),
          home: const LokalGenresPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Rock'), findsOneWidget);
    expect(find.text('Indie Rock'), findsNothing);
    expect(find.text('No genre'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'rock');
    await tester.pumpAndSettle();
    expect(find.text('Rock'), findsOneWidget);
    expect(find.text('No genre'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'no genre');
    await tester.pumpAndSettle();
    expect(find.text('Rock'), findsNothing);
    expect(find.text('No genre'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
