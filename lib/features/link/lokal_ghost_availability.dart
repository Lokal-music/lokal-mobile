import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../models/song.dart';
import '../../services/network_cache_service.dart';
import '../../services/lokal_remote_credentials_store.dart';

/// The paired desktop's HTTP media endpoint does not need a remote-control
/// websocket. Share credentials across Library rows rather than reading
/// secure storage separately for every desktop song in a large list.
@visibleForTesting
bool desktopStreamingCredentialsMatch({
  required String storedUsername,
  required String storedBaseUrl,
  required String? desktopId,
  required String? desktopUserId,
  required String? credentialOrigin,
}) =>
    desktopId != null &&
    credentialOrigin != null &&
    storedUsername == desktopId + ':' + (desktopUserId ?? 'guest') &&
    storedBaseUrl == credentialOrigin;

final _lokalDesktopCredentialsAvailableProvider =
    FutureProvider.autoDispose.family<bool, int>((ref, serverId) async {
  try {
    final credentials = await ref
        .read(lokalRemoteCredentialsStoreProvider)
        .read();
    final server = await Database.networkServers.get(serverId);
    if (server == null) return false;
    return desktopStreamingCredentialsMatch(
      storedUsername: server.username ?? '',
      storedBaseUrl: server.baseUrl ?? '',
      desktopId: credentials?.desktopId,
      desktopUserId: credentials?.desktopUserId,
      credentialOrigin: credentials?.origin.toString(),
    );
  } catch (_) {
    return false;
  }
});

final lokalSongAvailableProvider = FutureProvider.autoDispose.family<bool, Song>((
  ref,
  song,
) async {
  if (song.sourceType != 'lokal') return true;
  final serverId = song.remoteServerId, remoteId = song.remoteId;
  if (serverId == null || remoteId == null) return false;
  // Cached desktop originals remain playable when the PC is disconnected.
  if (await NetworkCacheService().getPath(serverId, remoteId) != null) {
    return true;
  }
  return ref.watch(_lokalDesktopCredentialsAvailableProvider(serverId).future);
});
