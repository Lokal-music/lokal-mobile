import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/widgets/common/overflow_marquee_title.dart';
import 'package:flick/data/repositories/recently_played_repository.dart';
import 'package:flick/features/konnekted/konnekted_destination.dart';
import 'package:flick/features/konnekted/konnekted_you.dart';
import 'package:flick/features/settings/lokal/lokal_settings_group.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/milestone_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _song = Song(
  id: '1',
  title: 'Midnight City',
  artist: 'M83',
  duration: Duration(minutes: 4),
  fileType: 'FLAC',
);

ListeningRecap _recap(ListeningRecapPeriod period, {int plays = 12}) {
  final now = DateTime(2026, 10, 20, 21);
  final range = period.rangeFor(now);
  return ListeningRecap(
    period: period,
    start: range.start,
    endExclusive: range.endExclusive,
    totalPlays: plays,
    totalListeningTime: Duration(minutes: plays * 4),
    uniqueSongs: 1,
    uniqueArtists: 1,
    activeDays: 2,
    peakHour: 21,
    topSong: null,
    topArtist: RankedRecapArtist(
      artist: 'M83',
      plays: plays,
      uniqueSongs: 1,
      listeningTime: Duration(minutes: plays * 4),
      lastPlayedAt: now,
    ),
    topAlbum: null,
    topSongs: [
      RankedRecapSong(
        song: _song,
        plays: plays,
        listeningTime: Duration(minutes: plays * 4),
        lastPlayedAt: now,
      ),
    ],
    topArtists: [
      RankedRecapArtist(
        artist: 'M83',
        plays: plays,
        uniqueSongs: 1,
        listeningTime: Duration(minutes: plays * 4),
        lastPlayedAt: now,
      ),
    ],
    topAlbums: const [],
  );
}

Widget _app({
  required ValueChanged<KonnektedDestination> onNavigate,
  Map<ListeningRecapPeriod, ListeningRecap> recaps = const {},
  YouAccounts accounts = const YouAccounts(),
  int? streak,
  List<MilestoneRecord> milestones = const [],
  bool persistentDock = false,
  double textScale = 1,
  VoidCallback? onDockTap,
}) => ProviderScope(
  overrides: [
    youRecapsProvider.overrideWith((ref) => Stream.value(recaps)),
    youAccountsProvider.overrideWithValue(accounts),
    youStreakProvider.overrideWith((ref) async => streak),
    youMilestonesProvider.overrideWith((ref) async => milestones),
  ],
  child: MaterialApp(
    theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.dark)),
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(390, 2400),
        padding: const EdgeInsets.only(top: 24, bottom: 24),
        textScaler: TextScaler.linear(textScale),
        disableAnimations: true,
      ),
      child: Scaffold(
        body: persistentDock
            ? Stack(
                children: [
                  Positioned.fill(
                    child: Navigator(
                      onGenerateRoute: (_) => MaterialPageRoute<void>(
                        builder: (_) => KonnektedYou(onNavigate: onNavigate),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 180,
                    child: Material(
                      color: Colors.blue,
                      child: InkWell(
                        onTap: onDockTap,
                        child: const Center(
                          child: Text('Persistent miniplayer'),
                        ),
                      ),
                    ),
                  ),
                ],
              )
            : KonnektedYou(onNavigate: onNavigate),
      ),
    ),
  ),
);

void _tall(WidgetTester tester) {
  tester.view
    ..physicalSize = const Size(390, 2400)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
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
  testWidgets('profile and account controls fit all locales at 2x on 320px', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(320, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final previous = l10n;
    addTearDown(() => LocaleController.instance.bind(previous));
    for (final locale in kSupportedLocales) {
      LocaleController.instance.bindLocale(locale);
      await tester.pumpWidget(
        _app(
          onNavigate: (_) {},
          textScale: 2,
          accounts: const YouAccounts(
            lastFm: 'A long profile name requiring truncation',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip(lokalText('Settings')), findsOneWidget);
      expect(
        tester.getSize(find.byTooltip(lokalText('Settings'))).height,
        greaterThanOrEqualTo(44),
      );
      expect(tester.takeException(), isNull, reason: locale.toString());
    }
  });
  testWidgets('You profile and edit action share the aligned header', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    _tall(tester);
    const longName = 'This is a very long Lokal profile name for scrolling';
    await tester.pumpWidget(
      _app(
        onNavigate: (_) {},
        accounts: const YouAccounts(lastFm: longName),
      ),
    );
    await tester.pump();

    final avatar = tester.getRect(find.bySemanticsLabel('Edit profile photo'));
    final profileName = tester.widget<OverflowMarqueeTitle>(
      find.byType(OverflowMarqueeTitle),
    );
    final edit = tester.getRect(find.byTooltip('Edit profile'));
    final discord = tester.getRect(find.byTooltip('Discord'));
    final settings = tester.getRect(find.byTooltip('Settings'));
    expect(profileName.title, longName);
    // The shared OverflowMarqueeTitle animates when motion is enabled.
    // These widget tests disable animations to avoid scheduling a perpetual ticker.
    expect(avatar.right, lessThan(edit.left));
    expect(edit.right + 10, closeTo(discord.left, .1));
    expect(discord.right + 10, closeTo(settings.left, .1));
    expect(settings.right, closeTo(390 - 16, .1));
    expect((avatar.center.dy - settings.center.dy).abs(), lessThan(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '2x text scales profile name without clipping or moving actions',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      _tall(tester);
      const longName = 'Long accessibility profile name that needs scrolling';
      await tester.pumpWidget(
        _app(
          onNavigate: (_) {},
          accounts: const YouAccounts(lastFm: longName),
          textScale: 2,
        ),
      );
      await tester.pump();

      final name = tester.getRect(find.byType(OverflowMarqueeTitle));
      final row = tester.getRect(
        find
            .ancestor(
              of: find.byType(OverflowMarqueeTitle),
              matching: find.byType(Row),
            )
            .first,
      );
      final discord = tester.getRect(find.byTooltip('Discord'));
      final settings = tester.getRect(find.byTooltip('Settings'));

      expect(row.height, greaterThan(44));
      expect(name.height, greaterThan(44));
      expect(name.top, greaterThanOrEqualTo(row.top));
      expect(name.bottom, lessThanOrEqualTo(row.bottom));
      expect(discord.center.dy, closeTo(settings.center.dy, .1));
      expect(discord.center.dy, closeTo(row.center.dy, .1));
      expect(settings.right, closeTo(390 - 16, .1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('empty: a default name, placeholders and no badges', (
    tester,
  ) async {
    _tall(tester);
    await tester.pumpWidget(_app(onNavigate: (_) {}));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('MINUTES THIS WEEK'), findsOneWidget);
    expect(find.text('DAY STREAK'), findsNothing);
    expect(find.text('RECAP'), findsOneWidget);
    for (final period in ['WEEK', 'MONTH', 'YEAR']) {
      expect(find.text(period), findsOneWidget);
    }
    expect(find.text('Nothing yet'), findsNWidgets(3));
    expect(find.text('No badges yet'), findsOneWidget);
    expect(find.text('CONNECTED'), findsNothing);
    expect(find.text('CONNECT'), findsNWidgets(3));
    // The old You rows are gone; Settings covers them.
    expect(find.text('Equalizer'), findsNothing);
    expect(find.text('Appearance'), findsNothing);
  });

  testWidgets('populated: name, minutes, streak, stats, badges, accounts', (
    tester,
  ) async {
    _tall(tester);
    await tester.pumpWidget(
      _app(
        onNavigate: (_) {},
        recaps: {
          for (final p in youRecapPeriods)
            p: _recap(
              p,
              plays: switch (p) {
                ListeningRecapPeriod.weekly => 12,
                ListeningRecapPeriod.monthly => 40,
                _ => 300,
              },
            ),
        },
        accounts: const YouAccounts(lastFm: 'gustave', youtubeMusic: true),
        streak: 6,
        milestones: [
          MilestoneRecord(
            type: MilestoneType.songs100,
            achievedAt: DateTime(2026, 10, 1),
          ),
        ],
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('gustave'), findsOneWidget);
    expect(find.text('G'), findsOneWidget);
    // 12 plays × 4 minutes this week, in the header and the stats.
    expect(find.text('48'), findsNWidgets(2));
    expect(find.text('6'), findsOneWidget);
    expect(find.text('48 min'), findsOneWidget);
    expect(find.text('1,200 min'), findsOneWidget);
    expect(find.text('9:00 PM'), findsOneWidget);
    expect(find.text('Midnight City'), findsOneWidget);
    expect(find.text('100 songs'), findsOneWidget);
    expect(find.text('CONNECTED'), findsNWidgets(2));
    expect(find.text('CONNECT'), findsOneWidget);

    // The stats follow the segmented control.
    await tester.tap(find.text('Month'));
    await tester.pump();
    expect(find.text('160'), findsOneWidget);
  });

  testWidgets('the gear, chips and rows open Settings where they belong', (
    tester,
  ) async {
    _tall(tester);
    final semantics = tester.ensureSemantics();
    final opened = <KonnektedDestination>[];
    await tester.pumpWidget(_app(onNavigate: opened.add));
    await tester.pump();

    expect(find.byTooltip('Discord'), findsOneWidget);
    expect(
      tester.getCenter(find.byTooltip('Discord')).dx,
      lessThan(tester.getCenter(find.byTooltip('Settings')).dx),
    );
    await tester.tap(find.byTooltip('Settings'));
    await tester.tap(find.bySemanticsLabel('Last.fm, not connected'));
    await tester.tap(find.bySemanticsLabel('ListenBrainz, not connected'));
    await tester.tap(find.bySemanticsLabel('YouTube, not connected'));
    await tester.tap(find.text('Full history'));
    await tester.tap(find.text('Help'));
    await tester.tap(find.text('About'));
    await tester.pump();

    semantics.dispose();

    const scrobbling = KonnektedDestination.settingsAt(
      LokalSettingsGroup.data,
      section: LokalDataSections.accounts,
    );
    expect(opened, [
      KonnektedDestination.settings,
      scrobbling,
      scrobbling,
      const KonnektedDestination.settingsAt(
        LokalSettingsGroup.data,
        section: LokalDataSections.accounts,
      ),
      KonnektedDestination.recentlyPlayed,
      const KonnektedDestination.settingsAt(
        LokalSettingsGroup.about,
        section: 'Help',
      ),
      const KonnektedDestination.settingsAt(
        LokalSettingsGroup.about,
        section: 'About',
      ),
    ]);
  });

  testWidgets('profile editor saves and resets the mobile username', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    _tall(tester);
    await tester.pumpWidget(_app(onNavigate: (_) {}));
    await tester.pump();

    await tester.tap(find.byTooltip('Edit profile'));
    await tester.pumpAndSettle();
    expect(find.text('Choose photo'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Lokal listener');
    await tester.tap(find.text('Save profile'));
    await tester.pumpAndSettle();

    expect(find.text('Lokal listener'), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).getString('lokal.you.profile.v1'),
      contains('Lokal listener'),
    );

    await tester.tap(find.byTooltip('Edit profile'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('Save profile'));
    await tester.pumpAndSettle();
    expect(find.text('You'), findsOneWidget);
  });

  testWidgets(
    'profile editor overlays the nested navigator and persistent miniplayer',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      _tall(tester);
      var dockTaps = 0;
      await tester.pumpWidget(
        _app(
          onNavigate: (_) {},
          persistentDock: true,
          onDockTap: () => dockTaps++,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Edit profile'));
      await tester.pumpAndSettle();

      final fieldContext = tester.element(find.byType(TextField));
      expect(
        ModalRoute.of(fieldContext)!.navigator,
        Navigator.of(fieldContext, rootNavigator: true),
      );
      expect(find.text('Save profile').hitTestable(), findsOneWidget);
      expect(find.text('Cancel').hitTestable(), findsOneWidget);
      // This point belongs to the dock underneath the editor's bottom padding.
      await tester.tapAt(const Offset(8, 2380));
      await tester.pump();
      expect(dockTaps, 0);
      await tester.enterText(find.byType(TextField), 'Overlay listener');
      await tester.tap(find.text('Save profile'));
      await tester.pumpAndSettle();
      expect(find.text('Overlay listener'), findsOneWidget);
      await tester.tap(find.text('Persistent miniplayer'));
      expect(dockTaps, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'root profile editor keeps actions above the keyboard and cancels cleanly',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      _tall(tester);
      await tester.pumpWidget(_app(onNavigate: (_) {}, persistentDock: true));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Edit profile'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pumpAndSettle();
      expect(
        tester.getBottomRight(find.text('Save profile')).dy,
        lessThanOrEqualTo(2080),
      );
      expect(find.text('Save profile').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Persistent miniplayer'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test('the name is an account username, else "You"', () {
    expect(const YouAccounts().name, 'You');
    expect(const YouAccounts(lastFm: '  ').name, 'You');
    expect(const YouAccounts(listenBrainz: 'lb').name, 'lb');
    expect(const YouAccounts(lastFm: 'fm', listenBrainz: 'lb').name, 'fm');
  });
}
