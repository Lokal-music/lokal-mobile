import 'package:flick/features/flow/domain/flow_models.dart';
import 'package:flick/features/flow/flow_controller.dart';
import 'package:flick/features/flow/flow_library.dart';
import 'package:flick/features/flow/flow_playback.dart';
import 'package:flick/features/flow/flow_screen.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/konnekted/konnekted_data.dart';
import 'package:flick/features/konnekted/konnekted_home.dart';
import 'package:flick/features/konnekted/lokal_home_greeting.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _ScreenFlow extends FlowController {
  _ScreenFlow(this.data);
  final FlowData data;
  @override
  Future<FlowData> build() async => data;
}

class _ScreenPlayer extends PlayerNotifier {
  @override
  PlayerState build() => const PlayerState();
}

class _InactivePlayback implements FlowPlayback {
  @override
  bool ownsSession(int seed) => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      LokalTheme.sans,
    )..addFont(rootBundle.load('assets/fonts/DMSans-Regular.ttf'))).load();
  });
  final songs = List.generate(
    20,
    (i) => Song(
      id: '$i',
      title: 'Track $i',
      artist: 'Artist $i',
      duration: const Duration(minutes: 3),
      fileType: 'FLAC',
      filePath: '/library/$i.flac',
    ),
  );

  Future<void> pump(
    WidgetTester tester, {
    required Future<FlowLibrary> Function() load,
    FlowData? data,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          flowControllerProvider.overrideWith(
            () => _ScreenFlow(data ?? FlowData()),
          ),
          flowLibraryProvider.overrideWith((ref) => load()),
          playerProvider.overrideWith(_ScreenPlayer.new),
          flowPlaybackProvider.overrideWithValue(_InactivePlayback()),
        ],
        // The desktop-style infinity orb animates indefinitely in production.
        // Disable motion here so pumpAndSettle can exercise loading states.
        child: MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: const FlowScreen(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('15 likes shows locked progress and disabled playback', (
    tester,
  ) async {
    await pump(
      tester,
      load: () async => FlowLibrary(
        songs: songs,
        favoriteIds: {for (var i = 0; i < 15; i++) '$i'},
      ),
    );
    expect(find.text('Your Flow is taking shape'), findsOneWidget);
    expect(find.textContaining('15 / 16 local favorites'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Play'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('empty library explains scanning; no placeholder tracks appear', (
    tester,
  ) async {
    await pump(
      tester,
      load: () async => FlowLibrary(songs: [], favoriteIds: {}),
    );
    expect(find.text('Your local library is empty'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets(
    'unlocked but all fresh candidates banned shows filter-empty state',
    (tester) async {
      await pump(
        tester,
        load: () async => FlowLibrary(
          songs: songs,
          favoriteIds: {for (var i = 0; i < 16; i++) '$i'},
        ),
        data: FlowData(
          config: FlowConfig(discovery: 1),
          bannedIds: ['16', '17', '18', '19'],
        ),
      );
      expect(find.text('No tracks match this Flow'), findsOneWidget);
      expect(find.text('Tune Flow'), findsOneWidget);
      expect(find.text('Your Flow is taking shape'), findsNothing);
    },
  );

  testWidgets('library failure has an actionable error state', (tester) async {
    await pump(
      tester,
      load: () async => throw StateError('Library unavailable'),
    );
    expect(find.text('Could not load Flow'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.textContaining('Library unavailable'), findsOneWidget);
  });

  testWidgets(
    'Home Flow shares the header and can scroll it away at large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            konnektedLibraryProvider.overrideWithValue(const AsyncData([])),
            konnektedFavoritesProvider.overrideWithValue(const AsyncData([])),
            konnektedRecentSongsProvider.overrideWith(
              (ref) => Stream.value([]),
            ),
            konnektedGreetingProvider.overrideWith(
              (ref) => Stream.value(
                const LokalHomeMessages(
                  'Good morning',
                  'Music for your morning.',
                ),
              ),
            ),
            flowControllerProvider.overrideWith(() => _ScreenFlow(FlowData())),
            flowLibraryProvider.overrideWith(
              (ref) async => FlowLibrary(songs: [], favoriteIds: {}),
            ),
            playerProvider.overrideWith(_ScreenPlayer.new),
            flowPlaybackProvider.overrideWithValue(_InactivePlayback()),
          ],
          child: MaterialApp(
            theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.light)),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: Scaffold(
              body: KonnektedHome(onNavigate: (_) {}, onPlay: (_, _) {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final mode = find.bySemanticsLabel('Flow');
      await tester.ensureVisible(mode);
      await tester.pumpAndSettle();
      await tester.tap(mode);
      await tester.pumpAndSettle();
      expect(find.byType(FlowScreen), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
      expect(find.byType(NestedScrollView), findsOneWidget);
      final nested = tester.state<NestedScrollViewState>(
        find.byType(NestedScrollView),
      );
      nested.outerController.jumpTo(
        nested.outerController.position.maxScrollExtent,
      );
      await tester.pumpAndSettle();
      final empty = find.text('Your local library is empty');
      await tester.scrollUntilVisible(
        empty,
        180,
        scrollable: find
            .descendant(
              of: find.byType(FlowScreen),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Scrollable &&
                    widget.axisDirection == AxisDirection.down,
              ),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(empty, findsOneWidget);
      expect(tester.getRect(empty).bottom, lessThanOrEqualTo(568));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
