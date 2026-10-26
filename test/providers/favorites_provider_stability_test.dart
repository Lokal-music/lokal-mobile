import 'dart:async';

import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/favorites_provider.dart';
import 'package:flick/services/favorites_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoSongs implements SongRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GatedFavorites extends FavoritesService {
  _GatedFavorites(this.saved) : super(songRepository: _NoSongs());

  final List<Song> saved;
  final reloadStarted = Completer<void>();
  final allowReload = Completer<void>();
  int reads = 0;

  @override
  Future<List<Song>> getFavorites() async {
    reads++;
    if (reads == 2) {
      reloadStarted.complete();
      await allowReload.future;
    }
    return List<Song>.of(saved);
  }

  @override
  Future<Set<String>> getFavoriteIds() async =>
      saved.map((song) => song.id).toSet();

  @override
  Future<Map<String, int>> getFavoriteRanks() async => {
    for (var i = 0; i < saved.length; i++) saved[i].id: i + 1,
  };

  @override
  Future<void> addFavorite(String id, {Song? song}) async {
    if (song != null) saved.add(song);
  }
}

Song _song(String id) => Song(
  id: id,
  title: 'Track ' + id,
  artist: 'Artist',
  fileType: 'OPUS',
  duration: const Duration(minutes: 3),
);

void main() {
  testWidgets('liking another track keeps existing Liked rows mounted and usable',
      (tester) async {
    final service = _GatedFavorites([_song('a'), _song('b')]);
    late WidgetRef widgetRef;
    var loadingFrames = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          favoritesServiceProvider.overrideWithValue(service),
          favoriteNotificationSyncProvider.overrideWith((ref) {}),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                widgetRef = ref;
                final favorites = ref.watch(favoritesProvider);
                if (!favorites.hasValue) {
                  loadingFrames++;
                  return const CircularProgressIndicator();
                }
                return Column(
                  children: [
                    for (final song in favorites.requireValue.favoriteSongs)
                      Text(song.title, key: ValueKey(song.id)),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Track a'), findsOneWidget);
    expect(find.text('Track b'), findsOneWidget);
    final initialLoading = loadingFrames;

    final update = widgetRef.read(favoritesProvider.notifier)
        .addFavorite('c', song: _song('c'));
    await service.reloadStarted.future;
    await tester.pump();
    // This refresh used to invalidate the AsyncNotifier, briefly replacing
    // the playable rows with a loading state and losing their live callbacks.
    expect(find.text('Track a'), findsOneWidget);
    expect(find.text('Track b'), findsOneWidget);
    expect(loadingFrames, initialLoading);

    service.allowReload.complete();
    await update;
    await tester.pumpAndSettle();
    expect(find.text('Track a'), findsOneWidget);
    expect(find.text('Track b'), findsOneWidget);
    expect(find.text('Track c'), findsOneWidget);
    expect(loadingFrames, initialLoading);
  });
}
