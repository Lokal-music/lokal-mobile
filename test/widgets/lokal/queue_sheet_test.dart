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
  final upNextMoves = <(int, int)>[];
  final manualMoves = <(int, int)>[];
  List<String> get upNextIds => state.upNext.map((s) => s.id).toList();
  List<String> get manualIds => state.queue.map((s) => s.id).toList();

  @override
  Future<void> moveUpNextItem(int from, int to) async {
    upNextMoves.add((from, to));
    final items = [...state.upNext];
    items.insert(to, items.removeAt(from));
    state = state.copyWith(upNext: items);
  }

  @override
  Future<void> moveQueueItem(int from, int to) async {
    manualMoves.add((from, to));
    final items = [...state.queue];
    items.insert(to, items.removeAt(from));
    state = state.copyWith(queue: items);
  }

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
    bool reorderDemo = false,
    bool autoplayOnly = false,
    bool discoveryPendingOnly = false,
    LokalThemeId theme = LokalThemeId.dark,
  }) async {
    // Give the sheet enough height for both sliver sections to be mounted.
    // Existing sheet sizing tests keep their regular phone dimensions.
    tester.view.physicalSize = reorderDemo
        ? const Size(400, 1300)
        : const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    player = _Player();
    if (manualOnly) player.initial = PlayerState(queue: [song('Manual')]);
    if (reorderDemo) {
      player.initial = PlayerState(
        currentSong: song('Now'),
        upNext: [song('Next0'), song('Next1'), song('Next2')],
        queue: [song('Manual0'), song('Manual1'), song('Manual2')],
      );
    }
    if (discoveryPendingOnly) {
      player.initial = PlayerState(
        currentSong: song('Now'),
        upNext: [
          Song(
            id: 'pending:discovery-1',
            title: 'Unresolved Discovery',
            artist: 'Artist',
            duration: Duration.zero,
            fileType: 'ONLINE',
            sourcePackage: Song.pendingSourcePackage,
          ),
        ],
      );
    }
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
  testWidgets('unresolved Discovery queue shows unknown duration, not 00:00', (tester) async {
    await pump(tester, discoveryPendingOnly: true);
    expect(find.text('Unresolved Discovery'), findsOneWidget);
    expect(find.text('…'), findsWidgets);
    expect(find.text('00:00'), findsNothing);
    expect(tester.takeException(), isNull);
  });

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
  testWidgets('popup queue grip drags Up Next down and Manual Queue up',
      (tester) async {
    await pump(tester, reorderDemo: true);

    Future<void> drag(WidgetTester tester, Finder grip, Offset delta) async {
      final handle = grip;
      expect(handle, findsOneWidget);
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 40));
      await gesture.moveBy(delta);
      await tester.pump(const Duration(milliseconds: 120));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    await drag(tester, find.byKey(const ValueKey('upnext-drag-0')),
        const Offset(0, 165));
    expect(player.upNextMoves, isNotEmpty,
        reason: 'Drag handle in the mini-player sheet must invoke the callback');
    expect(player.upNextMoves.last.$1, 0);
    expect(player.upNextMoves.last.$2, greaterThan(0));
    expect(player.upNextIds.first, isNot('Next0'));

    // Make sure the second list is independently reorderable, not just Up Next.
    await drag(tester, find.byKey(const ValueKey('manual-queue-drag-1')),
        const Offset(0, -90));
    expect(player.manualMoves, isNotEmpty);
    expect(player.manualMoves.last.$1, 1);
    expect(player.manualMoves.last.$2, 0);
    expect(player.manualIds.first, 'Manual1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('sheet queue heading uses the same inset as upcoming tracks',
      (tester) async {
    await pump(tester, reorderDemo: true);
    final titleX = tester.getTopLeft(find.text('QUEUE')).dx;
    final upcomingX = tester.getTopLeft(find.text('Up next')).dx;
    expect(titleX, closeTo(upcomingX, 1),
        reason: 'Popup Queue title was too far left of the content');
    expect(tester.takeException(), isNull);
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
