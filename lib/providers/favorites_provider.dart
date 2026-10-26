import 'lokal_remote_provider.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/song.dart';
import '../services/favorites_service.dart';
import 'player_provider.dart';

/// Provider for the FavoritesService.
final favoritesServiceProvider = Provider<FavoritesService>((ref) => FavoritesService());

/// State for favorites management.
class FavoritesState {
  final Set<String> favoriteIds;
  final List<Song> favoriteSongs;
  /// ID -> timestamp/rank when the heart was added, not file import time.
  final Map<String, int> likedRanks;
  final bool isLoading;

  const FavoritesState({
    this.favoriteIds = const {},
    this.favoriteSongs = const [],
    this.likedRanks = const {},
    this.isLoading = true,
  });

  FavoritesState copyWith({
    Set<String>? favoriteIds,
    List<Song>? favoriteSongs,
    Map<String, int>? likedRanks,
    bool? isLoading,
  }) {
    return FavoritesState(
      favoriteIds: favoriteIds ?? this.favoriteIds,
      favoriteSongs: favoriteSongs ?? this.favoriteSongs,
      likedRanks: likedRanks ?? this.likedRanks,
      isLoading: isLoading ?? this.isLoading,
    );
  }

  /// Check if a song is a favorite.
  bool isFavorite(String songId) => favoriteIds.contains(songId);

  /// Number of favorites.
  int get count => favoriteIds.length;
}

/// AsyncNotifier for favorites with autoDispose.
class FavoritesNotifier extends AsyncNotifier<FavoritesState> {
  @override
  Future<FavoritesState> build() async {
    // Keep the notification listener alive for every displayed favorite state.
    // Attach it to the consumer, not to the service: the service must not
    // rebuild just because a notification toggled a favorite.
    ref.watch(favoriteNotificationSyncProvider);
    final service = ref.watch(favoritesServiceProvider);

    final songs = await service.getFavorites();
    final ids = await service.getFavoriteIds();
    final likedRanks = await service.getFavoriteRanks();

    return FavoritesState(
      favoriteIds: ids,
      favoriteSongs: songs,
      likedRanks: likedRanks,
      isLoading: false,
    );
  }

  /// Toggle favorite status for a song.
  Future<bool> toggleFavorite(String songId, {Song? song}) async {
    final service = ref.read(favoritesServiceProvider);
    final isFavorite = await service.toggleFavorite(songId, song: song);

    // Refresh state
    ref.invalidateSelf();

    return isFavorite;
  }

  /// Add a song to favorites.
  Future<void> addFavorite(String songId, {Song? song}) async {
    final service = ref.read(favoritesServiceProvider);
    await service.addFavorite(songId, song: song);
    ref.invalidateSelf();
  }

  /// Remove a song from favorites.
  Future<void> removeFavorite(String songId) async {
    final service = ref.read(favoritesServiceProvider);
    await service.removeFavorite(songId);
    ref.invalidateSelf();
  }

  /// Clear all favorites.
  Future<void> clearFavorites() async {
    final service = ref.read(favoritesServiceProvider);
    await service.clearFavorites();
    ref.invalidateSelf();
  }
}

/// Main favorites provider.
final favoritesProvider =
    AsyncNotifierProvider.autoDispose<FavoritesNotifier, FavoritesState>(
      FavoritesNotifier.new,
    );

/// Convenience provider to check if a specific song is a favorite.
/// Usage: ref.watch(isSongFavoriteProvider(songId))
final isSongFavoriteProvider = Provider.autoDispose.family<bool, String>((
  ref,
  songId,
) {
  if (songId.startsWith('desktop:')) {
    final snapshot = ref.watch(lokalRemoteControllerProvider).snapshot,
        id = songId.substring(8);
    if (snapshot?.currentTrack?.id == id) return snapshot!.currentTrack!.liked;
    final matches = snapshot?.queue.where((track) => track.id == id);
    return matches != null && matches.isNotEmpty ? matches.first.liked : false;
  }
  final favorites = ref.watch(favoritesProvider).value;
  return favorites?.isFavorite(songId) ?? false;
});

/// Favorites count provider.
final favoritesCountProvider = Provider.autoDispose<int>((ref) {
  return ref.watch(favoritesProvider).value?.count ?? 0;
});

/// Syncs favorites state from lock screen/notification toggles back into
/// Riverpod so the app UI reflects changes made via the media session.
final favoriteNotificationSyncProvider = Provider<void>((ref) {
  final service = ref.watch(playerServiceProvider);
  final notifier = service.favoriteNotificationToggleNotifier;

  void listener() {
    // FavoritesService caches the liked IDs per instance. Recreate that
    // service as well as reloading its consumers after a notification toggle.
    ref.invalidate(favoritesServiceProvider);
    ref.invalidate(favoritesProvider);
  }

  notifier.addListener(listener);
  ref.onDispose(() => notifier.removeListener(listener));
  return;
});
