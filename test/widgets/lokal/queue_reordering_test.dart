import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/queue/screens/queue_screen.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Song _track(String id) => Song(
  id: id,
  title: 'Track $id',
  artist: 'Artist $id',
  duration: const Duration(minutes: 3),
  fileType: 'FLAC',
);

class _QueuePlayer extends PlayerNotifier {
  final upcomingMoves = <(int, int)>[];
  bool rejectNextMove = false;
  final manualMoves = <(int, int)>[];

  @override
  PlayerState build() => PlayerState(
    currentSong: _track('playing'),
    upNext: [
      _track('a'),
      _track('b'),
      _track('c'),
      _track('d'),
      _track('e'),
      _track('f'),
    ],
    queue: [_track('d'), _track('e'), _track('f')],
  );

  @override
  Future<void> moveUpNextItem(int from, int to) async {
    upcomingMoves.add((from, to));
    if (rejectNextMove) {
      rejectNextMove = false;
      throw StateError('Rejected fixture move');
    }
    final songs = [...state.upNext];
    songs.insert(to, songs.removeAt(from));
    state = state.copyWith(upNext: songs);
  }

  @override
  Future<void> moveQueueItem(int from, int to) async {
    manualMoves.add((from, to));
    final songs = [...state.queue];
    songs.insert(to, songs.removeAt(from));
    state = state.copyWith(queue: songs);
  }

  List<String> get upcomingIds => state.upNext.map((s) => s.id).toList();
  List<String> get manualIds => state.queue.map((s) => s.id).toList();
}

Future<void> _drag(WidgetTester tester, String key, double dy) async {
  final grip = find.byKey(ValueKey(key));
  await tester.ensureVisible(grip);
  await tester.pump();
  final gesture = await tester.startGesture(tester.getCenter(grip));
  await tester.pump(const Duration(milliseconds: 40));
  await gesture.moveBy(Offset(0, dy));
  await tester.pump(const Duration(milliseconds: 250));
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    for (final (family, asset) in [
      (LokalTheme.sans, 'assets/fonts/DMSans-Regular.ttf'),
      ('NotoSansSC', 'assets/fonts/NotoSansSC-Regular.ttf'),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
  });
  test('queue drop positions use one pre-removal normalization', () {
    expect(queueDropIndex(0, 2, 3), 1);
    expect(queueDropIndex(0, 3, 3), 2);
    expect(queueDropIndex(2, 0, 3), 0);
    expect(queueDropIndex(1, 1, 3), 1);
  });

  test('row keys remain unique across moves and repeated songs', () {
    final songs = [_track('a'), _track('b'), _track('a'), _track('c')];
    final first = queueRowIdentities(songs, 'next');
    final moved = queueRowIdentities([
      songs[1],
      songs[0],
      songs[2],
      songs[3],
    ], 'next');
    expect(first.toSet(), hasLength(4));
    expect(moved.toSet(), hasLength(4));
    expect(first[0], moved[1]);
    expect(first[1], moved[0]);
    expect(first[2], moved[2]);
  });

  for (final embedded in [false, true]) {
    testWidgets(
      '${embedded ? 'full-player' : 'standalone'} queue drags playback order in both directions',
      (tester) async {
        tester.view.physicalSize = const Size(440, 1024);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final player = _QueuePlayer();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [playerProvider.overrideWith(() => player)],
            child: MaterialApp(
              theme: LokalTheme.build(LokalTokens.themes[LokalThemeId.dark]!),
              home: Scaffold(body: QueueList(embedded: embedded)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Queue'), findsOneWidget);
        expect(
          find.text('Track d'),
          findsOneWidget,
          reason: 'Manual tracks are in the single real playback list',
        );
        expect(
          find.text('Manual queue'),
          findsNothing,
          reason: 'Manual songs must not appear a second time below Up Next',
        );
        expect(find.byType(SliverReorderableList), findsOneWidget);
        await _drag(tester, 'queue-grip-0', 180);
        expect(player.upcomingMoves, isNotEmpty);
        expect(player.upcomingMoves.last.$1, 0);
        expect(player.upcomingMoves.last.$2, greaterThan(0));
        expect(player.upcomingIds.first, isNot('a'));

        await _drag(tester, 'queue-grip-2', -180);
        expect(player.upcomingMoves.length, 2);
        expect(player.upcomingMoves.last.$1, 2);
        expect(player.upcomingMoves.last.$2, lessThan(2));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('manual queue with no active playback is reorderable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(440, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final player = _ManualOnlyPlayer();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [playerProvider.overrideWith(() => player)],
        child: MaterialApp(
          theme: LokalTheme.build(LokalTokens.themes[LokalThemeId.dark]!),
          home: const Scaffold(body: QueueList()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _drag(tester, 'queue-grip-0', 180);
    expect(player.manualMoves, hasLength(1));
    expect(player.manualMoves.single.$1, 0);
    expect(player.manualMoves.single.$2, greaterThan(0));
    expect(player.manualIds.first, isNot('d'));
    expect(player.manualIds.toSet(), {'d', 'e', 'f'});
  });
  testWidgets('all queue modes fit every locale at 200% on 320px', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final previous = l10n;
    addTearDown(() => LocaleController.instance.bind(previous));
    for (final locale in kSupportedLocales) {
      LocaleController.instance.bindLocale(locale);
      for (final embedded in [false, true]) {
        await tester.pumpWidget(
          ProviderScope(
            key: ValueKey('$locale-$embedded'),
            overrides: [playerProvider.overrideWith(_QueuePlayer.new)],
            child: MaterialApp(
              theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.light)),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(2),
                  disableAnimations: true,
                ),
                child: child!,
              ),
              home: Scaffold(body: QueueList(embedded: embedded)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(lokalText('Queue')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('queue-clear-upcoming')),
          findsOneWidget,
        );
        expect(
          tester
              .getSize(find.byKey(const ValueKey('queue-clear-upcoming')))
              .height,
          greaterThanOrEqualTo(44),
        );
        expect(
          tester.takeException(),
          isNull,
          reason: '$locale embedded=$embedded',
        );
        await tester.tap(find.byTooltip(l10n.selectAll));
        await tester.pumpAndSettle();
        expect(
          tester
              .getSize(find.byKey(const ValueKey('queue-remove-selected')))
              .height,
          greaterThanOrEqualTo(44),
        );
        expect(
          tester.takeException(),
          isNull,
          reason: '$locale selection embedded=$embedded',
        );
        await tester.tap(find.byTooltip(lokalText('Cancel')));
        await tester.pumpAndSettle();
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a rejected reorder restores authoritative rows and permits retry',
    (tester) async {
      tester.view.physicalSize = const Size(440, 1024);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final player = _QueuePlayer()..rejectNextMove = true;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [playerProvider.overrideWith(() => player)],
          child: MaterialApp(
            theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.dark)),
            home: const Scaffold(body: QueueList()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _drag(tester, 'queue-grip-0', 190);
      expect(player.upcomingIds.first, 'a');
      expect(find.text('Could not reorder queue. Try again.'), findsOneWidget);
      await _drag(tester, 'queue-grip-0', 190);
      expect(player.upcomingIds.first, isNot('a'));
      expect(player.upcomingMoves, hasLength(2));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}

class _ManualOnlyPlayer extends _QueuePlayer {
  @override
  PlayerState build() =>
      PlayerState(queue: [_track('d'), _track('e'), _track('f')]);
}
