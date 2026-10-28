import 'dart:async';

import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/konnekted/library/lokal_library_kit.dart';
import 'package:flick/features/link/lokal_ghost_availability.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/services/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Player extends PlayerNotifier {
  final calls = <({Song song, List<Song> queue, int? index})>[];
  @override
  PlayerState build() => const PlayerState();
  @override
  Future<void> play(
    Song song, {
    List<Song>? playlist,
    int? playlistIndex,
    PlaybackContext? context,
  }) async {
    calls.add((song: song, queue: playlist!, index: playlistIndex));
  }
}

class _Service implements PlayerService {
  int revision = 0;
  @override
  int get playbackRequestRevision => revision;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _desktop = Song(
  id: 'desktop',
  title: 'Desktop',
  artist: 'Artist',
  duration: Duration(minutes: 3),
  fileType: 'FLAC',
  sourceType: 'lokal',
  filePath: 'lokal://1/original',
  remoteServerId: 1,
  remoteId: 'original',
);
const _local = Song(
  id: 'local',
  title: 'Local',
  artist: 'Artist',
  duration: Duration(minutes: 3),
  fileType: 'FLAC',
  filePath: '/music/local.flac',
);

Future<void> _mount(
  WidgetTester tester,
  _Player player,
  _Service service,
  Future<bool> Function(Song) available,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playerProvider.overrideWith(() => player),
        playerServiceProvider.overrideWithValue(service),
        lokalSongAvailableProvider.overrideWith((ref, song) => available(song)),
      ],
      child: MaterialApp(
        theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.dark)),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              const queue = [_desktop, _local, _desktop];
              return Column(
                children: [
                  TextButton(
                    onPressed: () => unawaited(lokalPlay(context, ref, queue)),
                    child: const Text('Bulk'),
                  ),
                  TextButton(
                    onPressed: () => unawaited(
                      lokalPlay(context, ref, queue, startIndex: 2),
                    ),
                    child: const Text('Repeated'),
                  ),
                  TextButton(
                    onPressed: () => unawaited(
                      lokalPlay(context, ref, queue, startIndex: 1),
                    ),
                    child: const Text('Local'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('offline Play All retains full order and the phone-local index', (
    tester,
  ) async {
    final player = _Player();
    await _mount(tester, player, _Service(), (_) async => false);
    await tester.tap(find.text('Bulk'));
    await tester.pumpAndSettle();
    expect(player.calls.single.index, 1);
    expect(player.calls.single.song.id, 'local');
    expect(player.calls.single.queue.map((song) => song.id), [
      'desktop',
      'local',
      'desktop',
    ]);
  });

  testWidgets('explicit duplicate desktop tap retains its precise occurrence', (
    tester,
  ) async {
    final player = _Player();
    await _mount(tester, player, _Service(), (_) async => true);
    await tester.tap(find.text('Repeated'));
    await tester.pumpAndSettle();
    expect(player.calls.single.index, 2);
    expect(player.calls.single.song, same(player.calls.single.queue[2]));
  });

  testWidgets('explicit unavailable desktop tap never plays a different song', (
    tester,
  ) async {
    final player = _Player();
    await _mount(tester, player, _Service(), (_) async => false);
    await tester.tap(find.text('Repeated'));
    await tester.pumpAndSettle();
    expect(player.calls, isEmpty);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('newer local tap wins over a delayed bulk desktop probe', (
    tester,
  ) async {
    final player = _Player();
    final available = Completer<bool>();
    await _mount(tester, player, _Service(), (_) => available.future);
    await tester.tap(find.text('Bulk'));
    await tester.pump();
    await tester.tap(find.text('Local'));
    await tester.pump();
    available.complete(false);
    await tester.pumpAndSettle();
    expect(player.calls, hasLength(1));
    expect(player.calls.single.index, 1);
  });

  testWidgets('a new service play or pause retires the old library preflight', (
    tester,
  ) async {
    final player = _Player(), service = _Service();
    final available = Completer<bool>();
    await _mount(tester, player, service, (_) => available.future);
    await tester.tap(find.text('Bulk'));
    await tester.pump();
    service.revision++;
    available.complete(true);
    await tester.pumpAndSettle();
    expect(player.calls, isEmpty);
  });

  testWidgets('disposing a page during preflight cannot access its dead ref', (
    tester,
  ) async {
    final player = _Player();
    final available = Completer<bool>();
    await _mount(tester, player, _Service(), (_) => available.future);
    await tester.tap(find.text('Bulk'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    available.complete(false);
    await tester.pump();
    expect(player.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
