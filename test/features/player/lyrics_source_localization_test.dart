import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/player/widgets/lyrics_source_button.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _lyrics = LyricsData(
  lines: [
    LyricsLine(
      timestamp: Duration(seconds: 2),
      text: 'Fixture',
      words: [
        LyricsWord(
          start: Duration(seconds: 2),
          end: Duration(seconds: 3),
          text: 'Fixture',
        ),
      ],
    ),
  ],
  isSynchronized: true,
  rawContent: '',
  source: 'LyricsPlus',
);

class _Providers extends LyricsService {
  @override
  Future<LyricsData?> loadLyricsForSong(
    Song song, {
    bool forceRefresh = false,
    bool fetchOnline = false,
    bool refreshOnline = false,
    String source = 'auto',
    bool Function()? stillCurrent,
  }) async => null;

  @override
  Future<LyricsData?> fetchOnlineLyrics(
    Song song, {
    String source = 'auto',
    bool Function()? stillCurrent,
  }) async => source == 'lyricsplus' ? _lyrics : null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader(LokalTheme.sans)
      ..addFont(rootBundle.load('assets/fonts/DMSans-Regular.ttf'));
    await font.load();
  });

  for (final width in [320.0, 393.0]) {
    testWidgets(
      'lyrics picker keeps provider identity at 200% on ${width.toInt()}px',
      (tester) async {
        final previous = l10n;
        addTearDown(() => LocaleController.instance.bind(previous));
        LocaleController.instance.bindLocale(const Locale('tr'));
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 852);
        addTearDown(tester.view.reset);
        final song = Song(
          id: 'picker-$width',
          title: 'Fixture',
          artist: 'Artist',
          duration: const Duration(minutes: 3),
          fileType: 'FLAC',
        );
        final service = _Providers();
        await service.probeSourceHits(song);
        final selected = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.dark)),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: Center(
                child: LyricsSourceButton(
                  selected: 'lyricsplus',
                  lyrics: _lyrics,
                  song: song,
                  lyricsService: service,
                  busy: false,
                  onSelected: selected.add,
                  onRefresh: () {},
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Hece'));
        await tester.pumpAndSettle();
        expect(find.text('Şarkı sözü kaynağı'), findsOneWidget);
        await tester.scrollUntilVisible(find.text('LyricsPlus'), 120);
        await tester.pumpAndSettle();
        expect(find.text('Bulundu · Hece'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('LyricsPlus'));
        await tester.pumpAndSettle();
        expect(selected, ['lyricsplus']);
        expect(lyricsSourceLabel(_lyrics, 'lyricsplus'), 'LyricsPlus');
        LocaleController.instance.bindLocale(const Locale('en'));
        expect(lyricsSourceHitLabel(song, 'lyricsplus'), 'Found · Syllable');
      },
    );
  }
}
