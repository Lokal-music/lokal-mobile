import 'package:flick/features/flow/domain/flow_models.dart';
import 'package:flick/features/flow/flow_controller.dart';
import 'package:flick/features/flow/flow_library.dart';
import 'package:flick/features/flow/flow_playback.dart';
import 'package:flick/features/flow/flow_screen.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flutter/material.dart';
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
}
