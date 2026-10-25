import 'dart:io';
import 'dart:ui' as ui;

import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/core/utils/navigation_helper.dart';
import 'package:flick/features/queue/screens/queue_screen.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Song song(String id) => Song(
  id: id,
  title: 'Track $id',
  artist: 'Artist $id',
  duration: const Duration(minutes: 3),
  fileType: 'FLAC',
);

class _Player extends PlayerNotifier {
  PlayerState? initial;
  final played = <String>[];
  @override
  PlayerState build() =>
      initial ??
      PlayerState(
        currentSong: song('Now'),
        upNext: [for (var i = 0; i < 30; i++) song('$i')],
        queue: [song('Manual')],
      );
  @override
  Future<void> playFromUpNextIndex(int index) async {
    played.add('next:$index');
  }

  @override
  Future<void> playFromAutoplayIndex(int index) async {
    played.add('autoplay:$index');
  }

  @override
  Future<void> playFromQueueIndex(int index) async {
    played.add('manual:$index');
  }
}

void main() {
  late _Player player;
  var opens = 0;
  final boundary = GlobalKey();
  Future<void> pump(
    WidgetTester tester, {
    bool manualOnly = false,
    bool autoplayOnly = false,
    LokalThemeId theme = LokalThemeId.dark,
  }) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    player = _Player();
    if (manualOnly) player.initial = PlayerState(queue: [song('Manual')]);
    if (autoplayOnly) {
      player.initial = PlayerState(
        currentSong: song('Now'),
        autoplayUpNext: [song('Suggested'), song('Following')],
      );
    }
    opens = 0;
    if (Platform.environment.containsKey('LOKAL_QUEUE_PREVIEW')) {
      await tester.runAsync(() async {
        for (final entry in {
          'DMSans': 'assets/fonts/DMSans-Regular.ttf',
          'DMMono': 'assets/fonts/DMMono-Regular.ttf',
          'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
          'packages/lucide_icons_flutter/Lucide':
              'packages/lucide_icons_flutter/assets/lucide.ttf',
        }.entries) {
          await (FontLoader(
            entry.key,
          )..addFont(rootBundle.load(entry.value))).load();
        }
      });
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [playerProvider.overrideWith(() => player)],
        child: RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: LokalTheme.build(LokalTokens.themes[theme]!),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => NavigationHelper.navigateToQueue<void>(
                      context,
                      onOpenPlayer: () async {
                        opens++;
                      },
                    ),
                    child: const Text('Open queue'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open queue'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'starts near half-height, shares app surface, expands and scrolls',
    (tester) async {
      await pump(tester);
      final list = find.byType(QueueList);
      expect(tester.getSize(list).height, inInclusiveRange(380, 450));
      expect(find.text('Track Now'), findsOneWidget);
      final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
      expect(
        sheet.backgroundColor,
        LokalTokens.themes[LokalThemeId.dark]!.surface,
      );
      if (Platform.environment['LOKAL_QUEUE_PREVIEW'] case final String path) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(path).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.drag(find.text('Track 1'), const Offset(0, -450));
      await tester.pumpAndSettle();
      expect(tester.getSize(list).height, greaterThan(500));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(find.text('Track 0').hitTestable(), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('pulling down from top dismisses sheet', (tester) async {
    await pump(tester);
    final top = tester.getTopLeft(find.byType(BottomSheet));
    await tester.flingFrom(
      top + const Offset(200, 12),
      const Offset(0, 400),
      1400,
    );
    await tester.pumpAndSettle();
    expect(find.byType(QueueList), findsNothing);
    expect(opens, 0);
  });
  testWidgets('current song opens player after sheet closes', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('queue-now-playing')));
    await tester.pumpAndSettle();
    expect(find.byType(QueueList), findsNothing);
    expect(opens, 1);
  });
  testWidgets(
    'playing a queued song opens the player and retains its queue index',
    (tester) async {
      await pump(tester);
      await tester.tap(find.text('Track 0'));
      await tester.pumpAndSettle();
      expect(player.played, ['next:0']);
      expect(opens, 1);
      expect(find.byType(QueueList), findsNothing);
    },
  );
  testWidgets('a single shows upcoming autoplay and tapping uses its index', (
    tester,
  ) async {
    await pump(tester, autoplayOnly: true);
    expect(find.text('Autoplay'), findsOneWidget);
    expect(find.text('Track Suggested'), findsOneWidget);
    expect(find.text('Track Following'), findsOneWidget);
    expect(find.text('Track Suggested (catalogue)'), findsNothing);
    expect(find.text('Track Manual'), findsNothing);
    await tester.tap(find.text('Track Suggested'));
    await tester.pumpAndSettle();
    expect(player.played, ['autoplay:0']);
    expect(opens, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual-only queue remains accessible and opens its song', (
    tester,
  ) async {
    await pump(tester, manualOnly: true);
    await tester.tap(find.text('Track Manual'));
    await tester.pumpAndSettle();
    expect(player.played, ['manual:0']);
    expect(opens, 1);
  });
  testWidgets('sheet adopts the active light palette', (tester) async {
    await pump(tester, theme: LokalThemeId.light);
    final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(
      sheet.backgroundColor,
      LokalTokens.themes[LokalThemeId.light]!.surface,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('repeated current-song taps cannot pop the page underneath', (
    tester,
  ) async {
    await pump(tester);
    final current = find.byKey(const ValueKey('queue-now-playing'));
    await tester.tap(current);
    await tester.tap(current, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(opens, 1);
    expect(find.text('Open queue'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
