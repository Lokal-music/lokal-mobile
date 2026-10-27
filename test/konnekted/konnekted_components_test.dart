import 'package:flick/features/konnekted/lokal_home_greeting.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/konnekted/konnekted_data.dart';
import 'package:flick/features/konnekted/konnekted_destination.dart';
import 'package:flick/features/konnekted/konnekted_dock.dart';
import 'package:flick/features/konnekted/konnekted_home.dart';
import 'package:flick/features/konnekted/konnekted_library.dart';
import 'package:flick/features/konnekted/lokal_mixes.dart';
import 'package:flick/features/settings/lokal/lokal_settings_group.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _song = Song(
  id: 'test-track',
  title: 'A long track title to exercise the compact dock',
  artist: 'An artist with a long display name',
  duration: Duration(minutes: 3),
  fileType: 'FLAC',
);

// Lokal glass reads the performance-mode setting, so every pump has a scope.
Widget _app(Widget child, {double scale = 1}) => ProviderScope(
  child: MaterialApp(
    theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.dark)),
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(320, 568),
        textScaler: TextScaler.linear(scale),
        padding: const EdgeInsets.only(top: 24, bottom: 24),
        disableAnimations: true,
      ),
      child: Scaffold(body: child),
    ),
  ),
);

Song _track(String id) => Song(
  id: id,
  title: 'Track $id',
  artist: 'Artist $id',
  duration: const Duration(minutes: 3),
  fileType: 'FLAC',
);

void main() {
  testWidgets('Home and Library use identical trailing header coordinates', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        SafeArea(
          bottom: false,
          child: KonnektedHomeTopBar(onSettings: () {}, onAppearance: () {}),
        ),
      ),
    );
    await tester.pump();
    final homeDiscord = tester.getRect(find.byTooltip('Discord'));
    final homeSettings = tester.getRect(find.byTooltip('Settings'));

    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          konnektedLibraryProvider.overrideWithValue(const AsyncData([])),
        ],
        child: _app(KonnektedLibrary(onNavigate: (_) {})),
      ),
    );
    await tester.pump();
    final libraryDiscord = tester.getRect(find.byTooltip('Discord'));
    final librarySettings = tester.getRect(find.byTooltip('Settings'));
    expect(libraryDiscord.center, homeDiscord.center);
    expect(librarySettings.center, homeSettings.center);
    expect(find.text('Library'), findsOneWidget);
    final addButton = tester.getRect(
      find.bySemanticsLabel('Add music, playlists and folders'),
    );
    final title = tester.getRect(find.text('Library'));
    expect(title.left, closeTo(20, .1));
    expect(title.right, lessThanOrEqualTo(addButton.left));
    expect(addButton.right + 10, closeTo(libraryDiscord.left, .1));
    expect((title.center.dy - addButton.center.dy).abs(), lessThan(2));
    await tester.tap(find.bySemanticsLabel('Add music, playlists and folders'));
    await tester.pumpAndSettle();
    expect(find.text('New playlist'), findsOneWidget);
    expect(find.text('Import a playlist link'), findsOneWidget);
    expect(find.text('Import M3U'), findsOneWidget);
    expect(find.text('Add a music folder'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('2x text keeps Library title visible and Home actions aligned', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        SafeArea(
          bottom: false,
          child: KonnektedHomeTopBar(onSettings: () {}, onAppearance: () {}),
        ),
        scale: 2,
      ),
    );
    await tester.pump();
    final homeDiscord = tester.getRect(find.byTooltip('Discord'));
    final homeSettings = tester.getRect(find.byTooltip('Settings'));

    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          konnektedLibraryProvider.overrideWithValue(const AsyncData([])),
        ],
        child: _app(KonnektedLibrary(onNavigate: (_) {}), scale: 2),
      ),
    );
    await tester.pump();
    final title = tester.getRect(find.text('Library'));
    final row = tester.getRect(
      find.ancestor(of: find.text('Library'), matching: find.byType(Row)).first,
    );
    expect(row.height, greaterThan(44));
    expect(title.height, greaterThan(44));
    expect(title.top, greaterThanOrEqualTo(row.top));
    expect(title.bottom, lessThanOrEqualTo(row.bottom));
    expect(title.left, closeTo(20, .1));
    final add = tester.getRect(
      find.bySemanticsLabel('Add music, playlists and folders'),
    );
    final discord = tester.getRect(find.byTooltip('Discord'));
    expect(add.right + 10, closeTo(discord.left, .1));
    expect(title.right, lessThanOrEqualTo(add.left));
    expect(
      tester.getRect(find.byTooltip('Discord')).center,
      homeDiscord.center,
    );
    expect(
      tester.getRect(find.byTooltip('Settings')).center,
      homeSettings.center,
    );
    expect(tester.takeException(), isNull);
  });

  setUpAll(() async {
    for (final (family, asset) in [
      (LokalTheme.sans, 'assets/fonts/DMSans-Regular.ttf'),
      ('NotoSansSC', 'assets/fonts/NotoSansSC-Regular.ttf'),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
  });
  testWidgets('Home modes share the logo and header actions row', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(393, 852)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(
        KonnektedHomeTopBar(
          onSettings: () {},
          onAppearance: () {},
          selectedTab: KonnektedHomeTab.discovery,
          greeting: const LokalHomeMessages('Header greeting', 'Listening now'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final logo = tester.getRect(find.bySemanticsLabel('Appearance'));
    final mode = tester.getRect(find.bySemanticsLabel('Discovery'));
    final discord = tester.getRect(find.bySemanticsLabel('Discord'));
    final settings = tester.getRect(find.bySemanticsLabel('Settings'));
    final greeting = tester.getRect(find.text('Header greeting'));

    expect(mode.left, greaterThanOrEqualTo(logo.right));
    expect(mode.right, lessThanOrEqualTo(discord.left));
    expect(discord.right, lessThan(settings.left));
    expect((mode.center.dy - logo.center.dy).abs(), lessThan(2));
    expect((mode.center.dy - settings.center.dy).abs(), lessThan(2));
    expect(greeting.top, greaterThan(mode.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Compact header reveals selected mode without shrinking tabs', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 568)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tabs = <KonnektedHomeTab>[];
    await tester.pumpWidget(
      _app(
        KonnektedHomeTopBar(
          onSettings: () {},
          onAppearance: () {},
          selectedTab: KonnektedHomeTab.flow,
          onTabChanged: tabs.add,
          greeting: const LokalHomeMessages('Header greeting', 'Listening now'),
        ),
        scale: 2,
      ),
    );
    await tester.pumpAndSettle();

    final logo = tester.getRect(find.bySemanticsLabel('Appearance'));
    final flow = tester.getRect(find.bySemanticsLabel('Flow'));
    final discord = tester.getRect(find.bySemanticsLabel('Discord'));
    expect(flow.left, greaterThanOrEqualTo(logo.right));
    expect(flow.right, lessThanOrEqualTo(discord.left));
    expect(flow.height, greaterThanOrEqualTo(44));
    expect(
      tester.getRect(find.text('Header greeting')).top,
      greaterThan(flow.bottom),
    );

    final semantics = tester.ensureSemantics();
    final node = tester.getSemantics(find.bySemanticsLabel('Flow'));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    tester.binding.pipelineOwner.semanticsOwner!.performAction(
      node.id,
      SemanticsAction.tap,
    );
    await tester.pump();
    expect(tabs, [KonnektedHomeTab.flow]);
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home header tabs remain readable and screen-reader actionable', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 568)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final selected = <KonnektedHomeTab>[];
    await tester.pumpWidget(
      _app(
        KonnektedHomeTopBar(
          onSettings: () {},
          onAppearance: () {},
          selectedTab: KonnektedHomeTab.local,
          onTabChanged: selected.add,
        ),
        scale: 2,
      ),
    );
    final semantics = tester.ensureSemantics();
    final discovery = find.bySemanticsLabel('Discovery');
    expect(discovery, findsOneWidget);
    // Never shrink the mode controls with FittedBox on a narrow device.
    expect(tester.getSize(discovery).height, greaterThanOrEqualTo(44));
    final node = tester.getSemantics(discovery);
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    tester.binding.pipelineOwner.semanticsOwner!.performAction(
      node.id,
      SemanticsAction.tap,
    );
    await tester.pump();
    expect(selected, [KonnektedHomeTab.discovery]);
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Your Mixes play with their own queues', (tester) async {
    final mixes = [
      for (final name in ['Daily Mix', 'New Arrivals', 'Most Played'])
        LokalMix(
          id: name,
          name: name,
          type: LokalMixType.daily,
          tracks: [for (var i = 0; i < 4; i++) _track('$name $i')],
        ),
    ];
    final played = <(Song, List<Song>)>[];
    tester.view
      ..physicalSize = const Size(412, 915)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(
        ListView(
          children: [
            KonnektedYourMixes(
              mixes: mixes,
              onPlay: (song, queue) => played.add((song, queue)),
            ),
          ],
        ),
      ),
    );
    await tester.ensureVisible(find.text('Most Played'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Most Played'));
    expect(played.last.$1, mixes[2].tracks.first);
    expect(played.last.$2, mixes[2].tracks);
    expect(find.text('4 songs'), findsNWidgets(3));
  });

  testWidgets(
    'Cover Flow has no redundant heading; a tap plays with it queued',
    (tester) async {
      final recent = [_track('r1'), _track('r2'), _track('r3')];
      const mix = LokalMix(
        id: 'm',
        name: 'Daily Mix',
        type: LokalMixType.daily,
        tracks: [],
      );
      Song? played;
      List<Song>? queue;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            konnektedMadeForYouProvider.overrideWithValue(
              AsyncData([
                for (final song in recent)
                  LokalMadeForYouPick(song: song, mix: mix),
              ]),
            ),
          ],
          child: _app(
            KonnektedCoverFlowSection(
              onPlay: (song, shelf) {
                played = song;
                queue = shelf;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('MADE FOR YOU'), findsNothing);
      expect(find.text('RECENT'), findsNothing);
      expect(find.text('NEW'), findsNothing);
      expect(
        find.text('Track r2'),
        findsOneWidget,
      ); // The shelf starts in the middle.
      final stage = find.bySemanticsLabel(RegExp('^Cover Flow'));
      await tester.tapAt(tester.getCenter(stage) + const Offset(150, 0));
      await tester.pumpAndSettle();
      expect(played?.id, 'r3');
      expect(queue?.map((s) => s.id), ['r1', 'r2', 'r3']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('no mixes, no sections', (tester) async {
    await tester.pumpWidget(
      _app(
        Column(
          children: [KonnektedYourMixes(mixes: const [], onPlay: (_, _) {})],
        ),
      ),
    );
    expect(find.text('Your Mixes'), findsNothing);
  });

  testWidgets(
    'empty home uses real provider boundaries and opens Flow and import',
    (tester) async {
      final opened = <KonnektedDestination>[];
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
                  'In a groove',
                  'Your listening streak has some momentum.',
                ),
              ),
            ),
          ],
          child: _app(
            KonnektedHome(
              onNavigate: opened.add,
              onPlay: (_, _) =>
                  fail('No music should be playable in an empty library'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('In a groove'), findsOneWidget);
      expect(
        find.text('Your listening streak has some momentum.'),
        findsOneWidget,
      );
      // Top right opens Settings; the logo, top left, opens Appearance.
      expect(find.bySemanticsLabel('Search your music'), findsNothing);
      await tester.tap(find.bySemanticsLabel('Settings'));
      await tester.tap(find.bySemanticsLabel('Appearance'));
      expect(find.byTooltip('Settings'), findsOneWidget);
      // Flow is now a third Home mode, not a separate Cover Flow button.
      expect(find.bySemanticsLabel('Flow'), findsOneWidget);
      expect(find.bySemanticsLabel('Discovery'), findsOneWidget);
      expect(opened, [
        KonnektedDestination.settings,
        const KonnektedDestination.settingsAt(LokalSettingsGroup.themeAccent),
      ]);
      await tester.scrollUntilVisible(
        find.text('Add your music'),
        180,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView).first,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add your music'));
      expect(
        opened.last,
        const KonnektedDestination.settingsAt(
          LokalSettingsGroup.library,
          section: 'Folders',
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'library import and browse actions survive a narrow large-text screen',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final opened = <KonnektedDestination>[];
      var pickerOpened = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            konnektedLibraryProvider.overrideWithValue(const AsyncData([])),
          ],
          child: _app(
            KonnektedLibrary(
              onNavigate: opened.add,
              onAddFolder: (_) => pickerOpened++,
            ),
            scale: 2,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Add a music folder'), 160);
      await tester.pumpAndSettle();
      // The empty state opens the folder picker itself, not a settings page.
      await tester.tap(find.text('Add a music folder'));
      expect(pickerOpened, 1);
      await tester.scrollUntilVisible(find.text('Albums'), 180);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Albums'));
      expect(opened, [KonnektedDestination.albums]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Library: a gear opens Settings › Library, no duplicate rows', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(412, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final opened = <KonnektedDestination>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          konnektedLibraryProvider.overrideWithValue(const AsyncData([])),
        ],
        child: _app(KonnektedLibrary(onNavigate: opened.add)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Discord'), findsOneWidget);
    expect(
      tester.getCenter(find.byTooltip('Discord')).dx,
      lessThan(tester.getCenter(find.byTooltip('Settings')).dx),
    );
    await tester.tap(find.byTooltip('Settings'));
    expect(opened, [KonnektedDestination.settings]);
    for (final gone in ['Classipod', 'Listening hub', 'Manage library']) {
      expect(find.text(gone), findsNothing);
    }
    expect(find.text('Spotify library'), findsOneWidget);
    expect(find.text('Linked playlists'), findsOneWidget);
  });

  testWidgets('shelf reports errors and retry without pretending to be empty', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      _app(
        SingleChildScrollView(
          child: KonnektedSongShelf(
            title: 'Favorites',
            songs: AsyncError(StateError('Unavailable'), StackTrace.empty),
            emptyTitle: 'Empty favorites',
            emptyMessage: 'No favorites yet',
            onSeeAll: () {},
            onRetry: () => retries++,
            onPlay: (_, _) {},
          ),
        ),
      ),
    );
    expect(find.text('Couldn’t load this shelf'), findsOneWidget);
    expect(find.text('Empty favorites'), findsNothing);
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('shelf playback passes the tapped track and its real queue', (
    tester,
  ) async {
    Song? played;
    List<Song>? queue;
    await tester.pumpWidget(
      _app(
        SingleChildScrollView(
          child: KonnektedSongShelf(
            title: 'Recent music',
            songs: const AsyncData([_song]),
            emptyTitle: 'Empty',
            emptyMessage: 'Empty',
            onSeeAll: () {},
            onRetry: () {},
            onPlay: (song, shelf) {
              played = song;
              queue = shelf;
            },
          ),
        ),
        scale: 2,
      ),
    );
    await tester.tap(find.text(_song.title));
    expect(played, same(_song));
    expect(queue, [_song]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'mini player is absent without a current song and never opens a native player',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentSongProvider.overrideWithValue(null),
            isPlayingProvider.overrideWith(
              (ref) => throw StateError('Must not be read without a song'),
            ),
          ],
          child: _app(KonnektedMiniPlayer(onOpen: () {}, onQueue: () {})),
        ),
      );
      expect(find.byType(KonnektedMiniPlayerContent), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pulling the mini player up hands the drag to Now Playing', (
    tester,
  ) async {
    final moves = <String>[];
    await tester.pumpWidget(
      _app(
        Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            height: 58,
            child: KonnektedMiniPlayerContent(
              song: _song,
              isPlaying: true,
              onOpen: () => moves.add('tap'),
              onPlayPause: () {},
              onPrevious: () {},
              onNext: () {},
              onQueue: () {},
              progress: const SizedBox(),
              onPullUpStart: () => moves.add('start'),
              onPullUpUpdate: (dy) => moves.add('move'),
              onPullUpEnd: (v) => moves.add(v < 0 ? 'up' : 'end'),
            ),
          ),
        ),
      ),
    );
    final mini = find.byType(KonnektedMiniPlayerContent);
    await tester.fling(mini, const Offset(0, -120), 1200);
    await tester.pumpAndSettle();
    expect(moves.first, 'start');
    expect(moves, contains('move'));
    expect(moves.last, 'up');

    // A drag that starts downward is left alone.
    moves.clear();
    await tester.drag(mini, const Offset(0, 80));
    await tester.pumpAndSettle();
    expect(moves, isEmpty);
  });

  testWidgets('compact dock keeps player, pause, queue, and all tabs usable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var playerOpens = 0;
    var pauseTaps = 0;
    var queueOpens = 0;
    var selected = KonnektedTab.listen;
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) => Align(
            alignment: Alignment.bottomCenter,
            child: KonnektedDock(
              selected: selected,
              onSelect: (tab) => setState(() => selected = tab),
              miniPlayer: KonnektedMiniPlayerContent(
                song: _song,
                isPlaying: true,
                onOpen: () => playerOpens++,
                onPlayPause: () => pauseTaps++,
                onPrevious: () {},
                onNext: () {},
                onQueue: () => queueOpens++,
                progress: const LinearProgressIndicator(value: .25),
              ),
            ),
          ),
        ),
        scale: 2,
      ),
    );
    await tester.tap(find.bySemanticsLabel(RegExp('Open player for')));
    await tester.tap(find.byTooltip('Pause'));
    await tester.tap(find.byTooltip('Open queue'));
    for (final tab in KonnektedTab.values) {
      await tester.tap(find.bySemanticsLabel(tab.label));
      await tester.pump();
      expect(selected, tab);
      expect(
        tester.getSemantics(find.bySemanticsLabel(tab.label)),
        matchesSemantics(
          label: tab.label,
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          hasTapAction: true,
          hasFocusAction: true,
          isFocusable: true,
        ),
      );
    }
    expect(playerOpens, 1);
    expect(pauseTaps, 1);
    expect(queueOpens, 1);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  Widget dock({
    required KonnektedTab selected,
    required ValueChanged<KonnektedTab> onSelect,
    bool collapsed = false,
    VoidCallback? onExpand,
  }) => Align(
    alignment: Alignment.bottomCenter,
    child: KonnektedDock(
      selected: selected,
      onSelect: onSelect,
      collapsed: collapsed,
      onExpand: onExpand,
      miniPlayer: KonnektedMiniPlayerContent(
        song: _song,
        isPlaying: false,
        onOpen: () {},
        onPlayPause: () {},
        onPrevious: () {},
        onNext: () {},
        onQueue: () {},
        progress: const SizedBox.shrink(),
      ),
    ),
  );

  testWidgets('dragging the lens across the tab capsule picks a tab', (
    tester,
  ) async {
    var selected = KonnektedTab.listen;
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) => dock(
            selected: selected,
            onSelect: (tab) => setState(() => selected = tab),
          ),
        ),
      ),
    );
    final home = tester.getCenter(find.bySemanticsLabel('Home'));
    final you = tester.getCenter(find.bySemanticsLabel('You'));
    final gesture = await tester.startGesture(home);
    await gesture.moveBy(const Offset(20, 0));
    await gesture.moveTo(you);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, KonnektedTab.settings);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrolled-down dock tucks the mini player between circles', (
    tester,
  ) async {
    var expands = 0;
    var collapsed = false;
    late StateSetter set;
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) {
            set = setState;
            return dock(
              selected: KonnektedTab.library,
              onSelect: (_) {},
              collapsed: collapsed,
              onExpand: () => expands++,
            );
          },
        ),
      ),
    );
    final openHeight = tester.getSize(find.byType(KonnektedDock)).height;
    expect(find.byTooltip('Open queue'), findsOneWidget);

    set(() => collapsed = true);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(KonnektedDock)).height,
      lessThan(openHeight),
    );
    // The hidden tabs leave the semantics tree; the shrunken capsule stays.
    expect(find.bySemanticsLabel('Home'), findsNothing);
    expect(find.byTooltip('Open queue'), findsNothing);
    expect(find.bySemanticsLabel(RegExp('Open player for')), findsOneWidget);
    expect(find.bySemanticsLabel('Search'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Show tabs. Library'));
    expect(expands, 1);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('dock without a song is one row and never collapses', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        Align(
          alignment: Alignment.bottomCenter,
          child: KonnektedDock(
            selected: KonnektedTab.explore,
            onSelect: (_) {},
            hasMiniPlayer: false,
            collapsed: true,
            miniPlayer: const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(KonnektedDock)).height,
      KonnektedDock.reservedHeight(hasMiniPlayer: false, systemInset: 24),
    );
    expect(find.bySemanticsLabel('Home'), findsOneWidget);
  });
}
