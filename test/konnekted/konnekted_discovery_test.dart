import 'package:flick/features/discovery/spotify_discovery.dart';
import 'package:flick/features/konnekted/lokal_home_greeting.dart';

import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/discovery/lastfm_discovery.dart';
import 'package:flick/features/konnekted/konnekted_data.dart';
import 'package:flick/features/konnekted/konnekted_destination.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flick/features/konnekted/konnekted_discovery_view.dart';
import 'package:flick/features/konnekted/konnekted_home.dart';
import 'package:flick/features/settings/lokal/lokal_settings_group.dart';
import 'package:flick/models/song.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song _song(
  String id,
  String artist,
  String title, {
  String? album,
  int? track,
}) => Song(
  id: id,
  title: title,
  artist: artist,
  album: album,
  trackNumber: track,
  duration: const Duration(minutes: 3),
  fileType: 'FLAC',
);

final _library = [
  _song(
    '1',
    'Estelle',
    'American Boy (feat. Kanye West)',
    album: 'Shine',
    track: 2,
  ),
  _song('2', 'Estelle', 'Wait a Minute', album: 'Shine', track: 1),
  _song('3', 'Daft Punk', 'One More Time'),
];

/// A Last.fm that recommends one song you have and one you don't.
Future<Map<String, dynamic>> _lastfm(
  String method,
  Map<String, String> params,
) async {
  Map<String, dynamic> track(String artist, String title) => {
    'name': title,
    'artist': {'name': artist},
  };
  return switch (method) {
    'user.getRecentTracks' => {
      'recenttracks': {
        'track': [
          {
            ...track('Daft Punk', 'One More Time'),
            'date': {
              'uts': '${DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60}',
            },
          },
        ],
        '@attr': {'totalPages': '1'},
      },
    },
    'user.getTopTracks' => {
      'toptracks': {'track': []},
    },
    'user.getTopArtists' => {
      'topartists': {
        'artist': [
          {'name': 'Estelle'},
        ],
      },
    },
    'user.getTopAlbums' => {
      'topalbums': {
        'album': [
          {
            'name': 'Shine',
            'artist': {'name': 'Estelle'},
          },
        ],
      },
    },
    'track.getSimilar' => {
      'similartracks': {
        'track': [
          track('Estelle', 'American Boy'),
          track('Nobody', 'Not Here'),
          track('Somebody', 'Elsewhere'),
        ],
      },
    },
    'artist.getSimilar' => {
      'similarartists': {'artist': []},
    },
    'artist.getTopTracks' => {
      'toptracks': {'track': []},
    },
    _ => throw StateError(method),
  };
}

Widget _app(Widget child, {String? account = 'me'}) => ProviderScope(
  overrides: [
    konnektedLibraryProvider.overrideWithValue(AsyncData(_library)),
    konnektedFavoritesProvider.overrideWithValue(const AsyncData([])),
    konnektedRecentSongsProvider.overrideWith((ref) => Stream.value([])),
    konnektedGreetingProvider.overrideWith(
      (ref) => Stream.value(const LokalHomeMessages('Good morning', 'Hello.')),
    ),
    konnektedLastfmAccountProvider.overrideWith((ref) async => account),
    konnektedLastfmCallProvider.overrideWithValue(_lastfm),
  ],
  child: MaterialApp(
    theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.dark)),
    home: Scaffold(body: child),
  ),
);

class _ReadyYoutube extends KonnektedDiscoveryNotifier {
  @override
  KonnektedDiscoveryState build() => const KonnektedDiscoveryState(
    source: KonnektedDiscoverySource.youtube,
    data: LokalDiscovery(
      account: 'YouTube Music',
      page: 0,
      mixes: [LokalDiscoveryMix(id: 'RDTMAKtest', title: 'Supermix')],
      liked: [LokalDiscoveryTrack(title: 'A liked song', artist: 'Artist')],
      history: [LokalDiscoveryTrack(title: 'History song', artist: 'Artist')],
      quickPicks: [LokalDiscoveryTrack(title: 'Quick YT pick', artist: 'Artist')],
    ),
  );
  @override
  Future<void> load({bool refresh = false}) async {}
}

class _HiddenOnlyLastfm extends KonnektedDiscoveryNotifier {
  @override
  KonnektedDiscoveryState build() => const KonnektedDiscoveryState(
    source: KonnektedDiscoverySource.lastfm,
    data: LokalDiscovery(
      account: 'Last.fm',
      page: 0,
      quickPicks: [LokalDiscoveryTrack(title: 'Top Scrobble', artist: 'Artist')],
      history: [LokalDiscoveryTrack(title: 'Recent Scrobble', artist: 'Artist')],
    ),
  );
  @override
  Future<void> load({bool refresh = false}) async {}
}

class _ReadySpotifySnapshot extends KonnektedSpotifyDiscoveryNotifier {
  @override
  Future<SpotifyDiscoverySnapshot> build() async =>
      const SpotifyDiscoverySnapshot(
        enabled: true,
        connected: true,
        data: SpotifyDiscoveryData(
          account: 'Spotify',
          quickPicks: [],
          recentlyPlayed: [
            LokalDiscoveryTrack(title: 'Spotify history track', artist: 'Artist'),
          ],
          likedSongs: [LokalDiscoveryTrack(title: 'Like', artist: 'Artist')],
          artists: [],
          albums: [],
          freshFinds: [],
          mixes: [
            LokalDiscoveryMix(
              id: '37i9dQZF1E000000000001',
              title: 'Daily Mix 1',
              author: 'Spotify',
            ),
          ],
        ),
      );
}

class _ReadySpotify extends KonnektedDiscoveryNotifier {
  @override
  KonnektedDiscoveryState build() =>
      const KonnektedDiscoveryState(source: KonnektedDiscoverySource.spotify);
  @override
  Future<void> load({bool refresh = false}) async {}
}

void main() {
  test('Morneye playback cache key isolates addon version, settings, tier and song', () {
    String key({
      String addon = 'qobuz', String digest = 'v1',
      String track = 'song-1', String settings = 'account-1',
      String tier = 'HI_RES_LOSSLESS',
    }) => morneyePlaybackCacheKey(
      addonKey: addon, addonDigest: digest, trackId: track,
      settingsFingerprint: settings, requestedTier: tier,
    );
    final original = key();
    expect(key(), original);
    expect(key(addon: 'tidal'), isNot(original));
    expect(key(digest: 'v2'), isNot(original));
    expect(key(track: 'song-2'), isNot(original));
    expect(key(settings: 'account-2'), isNot(original));
    expect(key(tier: 'LOSSLESS'), isNot(original));
  });

  test('Morneye percentage advances from actual transfer updates despite stale 5% messages', () {
    final text = MorneyeProgressText('Track', 'Qobuz');
    expect(text.update(percent: 5, message: 'Loading 5%'),
        contains('5%'));
    expect(text.update(percent: 36), contains('36%'));
    expect(text.update(percent: 5, message: 'Loading 5%'),
        contains('36%'));
    expect(text.update(percent: 79), contains('79%'));
    expect(text.update(percent: 79), isNull);
  });

  setUp(() {
    forgetLastfmSeeds();
    // Discovery remembers the chosen source in preferences.
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'Spotify cookie mixes appear first as horizontal cards and load the tapped native playlist',
    (tester) async {
      tester.view
        ..physicalSize = const Size(412, 1800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final played = <(Song, List<Song>)>[];
      final loaded = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            konnektedDiscoveryProvider.overrideWith(_ReadySpotify.new),
            konnektedSpotifyDiscoveryProvider.overrideWith(_ReadySpotifySnapshot.new),
            konnektedSpotifyMixLoaderProvider.overrideWithValue((id) async {
              loaded.add(id);
              return const [
                LokalDiscoveryTrack(title: 'American Boy', artist: 'Estelle'),
                LokalDiscoveryTrack(title: 'New song', artist: 'Artist'),
              ];
            }),
          ],
          child: _app(
            SingleChildScrollView(
              child: KonnektedDiscoveryView(
                onNavigate: (_) {},
                onPlay: (song, queue) => played.add((song, queue)),
                pendingSong: (track) =>
                    _song('pending:${track.key}', track.artist, track.title),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Mixed for you'), findsOneWidget);
      expect(find.text('Liked Songs'), findsNothing);
      expect(find.text('Like'), findsNothing);
      expect(find.text('Recently Played'), findsOneWidget);
      expect(find.text('Spotify history track'), findsOneWidget);
      expect(
        tester
            .widget<ListView>(find.byKey(const PageStorageKey('spotify-mixes')))
            .scrollDirection,
        Axis.horizontal,
      );
      await tester.tap(find.text('Daily Mix 1'));
      await tester.pumpAndSettle();
      expect(loaded, ['37i9dQZF1E000000000001']);
      expect(played.single.$1.id, '1');
      expect(played.single.$2.last.id, startsWith('pending:'));
    },
  );

  testWidgets(
    'YouTube personal mixes are first and use horizontal cover cards',
    (tester) async {
      tester.view
        ..physicalSize = const Size(412, 1800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            konnektedDiscoveryProvider.overrideWith(_ReadyYoutube.new),
          ],
          child: _app(
            SingleChildScrollView(
              child: KonnektedDiscoveryView(
                onNavigate: (_) {},
                onPlay: (_, __) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Supermix'), findsOneWidget);
      expect(find.bySemanticsLabel('YouTube'), findsOneWidget);
      expect(find.bySemanticsLabel('YouTube Music'), findsNothing);
      expect(find.text('Mixed for you'), findsOneWidget);
      expect(find.text('Quick Picks'), findsOneWidget);
      expect(find.text('Your Likes'), findsNothing);
      expect(find.text('A liked song'), findsNothing);
      expect(find.text('History'), findsNothing);
      expect(find.text('History song'), findsNothing);
      final shelf = tester.widget<ListView>(
        find.byKey(const PageStorageKey('youtube-music-mixes')),
      );
      expect(shelf.scrollDirection, Axis.horizontal);
    },
  );

  testWidgets('Last.fm with only hidden scrobbles shows the empty state',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          konnektedDiscoveryProvider.overrideWith(_HiddenOnlyLastfm.new),
        ],
        child: _app(
          SingleChildScrollView(
            child: KonnektedDiscoveryView(
              onNavigate: (_) {},
              onPlay: (_, __) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Nothing to recommend yet'), findsOneWidget);
    expect(find.text('Quick Picks'), findsNothing);
    expect(find.text('Scrobble History'), findsNothing);
    expect(find.text('Top Scrobble'), findsNothing);
    expect(find.text('Recent Scrobble'), findsNothing);
  });

  test('the library index finds your copy, and albums and artists', () {
    final index = KonnektedLibraryIndex(_library);
    expect(
      index
          .match(
            const LokalDiscoveryTrack(title: 'American Boy', artist: 'Estelle'),
          )
          ?.id,
      '1',
    );
    expect(
      index.match(
        const LokalDiscoveryTrack(title: 'American Boy', artist: 'Someone'),
      ),
      isNull,
    );
    expect(index.album('Shine', 'Estelle').map((s) => s.id), ['2', '1']);
    expect(index.artist('Estelle [feat. Joi]').length, 2);
    expect(
      identical(
        KonnektedLibraryIndex.of(_library),
        KonnektedLibraryIndex.of(_library),
      ),
      isTrue,
    );
  });

  testWidgets('Discovery plays your copy with the shelf, else looks it up', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(412, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final played = <(Song, List<Song>)>[];
    final asked = <String>[];
    await tester.pumpWidget(
      _app(
        SingleChildScrollView(
          child: KonnektedDiscoveryView(
            onNavigate: (_) {},
            onPlay: (song, queue) => played.add((song, queue)),
            pendingSong: (track) {
              asked.add(track.title);
              return _song('pending:${track.key}', track.artist, track.title);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Fresh Finds'), findsOneWidget);
    expect(find.text('Quick Picks'), findsNothing);
    expect(find.text('Scrobble History'), findsNothing);
    expect(find.text('Albums For You'), findsOneWidget);
    expect(find.text('Artists For You'), findsOneWidget);
    // Albums take priority as the first populated Last.fm section.
    expect(
      tester.getTopLeft(find.text('Albums For You')).dy,
      lessThan(tester.getTopLeft(find.text('Fresh Finds')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Albums For You')).dy,
      lessThan(tester.getTopLeft(find.text('Artists For You')).dy),
    );

    await tester.tap(
      find.bySemanticsLabel('Play American Boy by Estelle, in your library'),
    );
    expect(played.single.$1.id, '1');
    expect(played.single.$2.map((s) => s.id), ['1']);

    await tester.tap(find.bySemanticsLabel('Play Not Here by Nobody'));
    await tester.pumpAndSettle();
    expect(asked, contains('Not Here'));
    expect(played.last.$1.title, 'Not Here');

    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an online tap enters the queue immediately without a page download',
    (tester) async {
      tester.view
        ..physicalSize = const Size(412, 2400)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final played = <(Song, List<Song>)>[];
      final asked = <String>[];
      Song placeholder(LokalDiscoveryTrack track) => Song(
        id: 'pending:${track.key}',
        title: track.title,
        artist: track.artist,
        duration: Duration.zero,
        fileType: 'ONLINE',
        sourcePackage: Song.pendingSourcePackage,
      );
      await tester.pumpWidget(
        _app(
          SingleChildScrollView(
            child: KonnektedDiscoveryView(
              onNavigate: (_) {},
              onPlay: (song, queue) => played.add((song, queue)),
              findSong: (track, {onStatus, additionalProtectedPaths}) async {
                asked.add(track.title);
                return Song(
                  id: 'discovery:${track.title}',
                  title: track.title,
                  artist: track.artist,
                  duration: Duration.zero,
                  fileType: 'M4A',
                  filePath: '/cache/${track.title}.m4a',
                );
              },
              pendingSong: placeholder,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Play Not Here by Nobody'));
      await tester.pumpAndSettle();
      // The player owns resolution for the tapped song and the rest of the shelf.
      expect(asked, isEmpty);
      final (song, queue) = played.single;
      expect(song.id, startsWith('pending:'));
      expect(song.title, 'Not Here');
      expect(queue.map((s) => s.id), contains('1'));
      expect(queue, contains(song));
      final waiting = queue.where((s) => s.isPending).map((s) => s.title);
      expect(waiting, ['Not Here', 'Elsewhere']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Discovery fits a narrow screen with large text', (tester) async {
    tester.view
      ..physicalSize = const Size(320, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 2400),
            textScaler: TextScaler.linear(1.5),
          ),
          child: SingleChildScrollView(
            child: KonnektedDiscoveryView(
              onNavigate: (_) {},
              onPlay: (_, _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Fresh Finds'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without Last.fm, Discovery leads to Data Accounts', (
    tester,
  ) async {
    final opened = <KonnektedDestination>[];
    await tester.pumpWidget(
      _app(
        SingleChildScrollView(
          child: KonnektedDiscoveryView(
            onNavigate: opened.add,
            onPlay: (_, _) {},
          ),
        ),
        account: null,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open Accounts'));
    expect(opened, [
      const KonnektedDestination.settingsAt(
        LokalSettingsGroup.data,
        section: LokalDataSections.accounts,
      ),
    ]);
  });

  testWidgets('Home switches between Local and Discovery', (tester) async {
    tester.view
      ..physicalSize = const Size(412, 915)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(KonnektedHome(onNavigate: (_) {}, onPlay: (_, _) {})),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Local'), findsOneWidget);
    expect(find.text('Fresh Finds'), findsNothing);
    await tester.tap(find.bySemanticsLabel('Discovery'));
    await tester.pumpAndSettle();
    expect(find.text('Fresh Finds'), findsOneWidget);
    expect(find.text('Open Flow'), findsNothing);
    await tester.tap(find.bySemanticsLabel('Local'));
    await tester.pumpAndSettle();
    expect(find.text('Fresh Finds'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('long-press provider opens persisted shelf customization', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(412, 915)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(SingleChildScrollView(
        child: KonnektedDiscoveryView(
          onNavigate: (_) {},
          onPlay: (_, _) {},
        ),
      )),
    );
    await tester.pumpAndSettle();
    expect(find.text('Albums For You'), findsOneWidget);
    final semantics = tester.ensureSemantics();
    addTearDown(semantics.dispose);
    final provider = tester.getSemantics(find.bySemanticsLabel('Last.fm'));
    expect(provider.hasAction(SemanticsAction.longPress), isTrue);
    tester.binding.pipelineOwner.semanticsOwner!.performAction(
      provider.id, SemanticsAction.longPress,
    );
    await tester.pumpAndSettle();
    expect(find.text('Choose sections to show and drag to reorder.'),
        findsOneWidget);
    expect(find.byType(ReorderableListView), findsOneWidget);
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Albums For You'), findsNothing);
    expect(tester.takeException(), isNull);
  });


}
