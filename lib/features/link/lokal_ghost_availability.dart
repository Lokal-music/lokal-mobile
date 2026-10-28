import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../models/song.dart';
import '../../services/network_cache_service.dart';
import '../../providers/lokal_remote_provider.dart';

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

/// A bounded authenticated HTTP probe of the paired desktop. The remote
/// control *WebSocket* is optional: the GET state endpoint is available
/// independently and proves the PC is online before advertising an uncached
/// audio stream. This probe runs once per linked server, not once per row.
@visibleForTesting
Future<bool> desktopHttpReachable(
  Future<void> Function() probe, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  try {
    await probe().timeout(timeout);
    return true;
  } catch (_) {
    return false;
  }
}

final _lokalDesktopCredentialsAvailableProvider =
    FutureProvider.autoDispose.family<bool, int>((ref, serverId) async {
  // Both saveConfiguration and forgetConfiguration publish a new controller
  // config. Watching it prevents mounted Library rows retaining obsolete
  // results after pairing changes while keeping one HTTP probe per server.
  ref.watch(lokalRemoteControllerProvider.select((state) => state.config));
  try {
    final credentials = await ref
        .read(lokalRemoteCredentialsStoreProvider)
        .read();
    final server = await Database.networkServers.get(serverId);
    if (server == null || credentials == null ||
        !desktopStreamingCredentialsMatch(
          storedUsername: server.username ?? '',
          storedBaseUrl: server.baseUrl ?? '',
          desktopId: credentials.desktopId,
          desktopUserId: credentials.desktopUserId,
          credentialOrigin: credentials.origin.toString(),
        )) return false;

    return desktopHttpReachable(() async {
      await ref.read(lokalRemoteServiceProvider).fetchState(credentials);
    });
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
  // Subscribe before the async cache lookup so a disposed row does not try to
  // watch a provider after its widget has already left the screen.
  final pairedDesktop = ref.watch(
    _lokalDesktopCredentialsAvailableProvider(serverId).future,
  );
  // Cached desktop originals remain playable when the PC is disconnected.
  if (await NetworkCacheService().getPath(serverId, remoteId) != null) {
    return true;
  }
  return pairedDesktop;
});
