import '../services/link/library_sync_notification.dart';
import '../services/link/file_copy_notification.dart';
import '../data/database.dart';
import '../services/album_art_service.dart';
import '../services/link/link_download_outbox.dart';
import '../services/favorites_service.dart';

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import '../services/player_service.dart';
import '../services/notification_service.dart';
import '../services/link/lokal_link_service.dart';
import '../services/link/link_protocol.dart';
import '../services/link/link_journal.dart';
import '../services/link/link_sync_coordinator.dart';
import '../services/link/link_profile_service.dart';
import '../services/link/link_file_copy.dart';
import '../services/link/lokal_desktop_source.dart';
import 'favorites_provider.dart';
import 'playlist_provider.dart';
import '../core/theme/lokal_appearance.dart';

import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/lokal_remote_state.dart';
import '../services/lokal_remote_credentials_store.dart';
import '../services/lokal_remote_service.dart';

final lokalRemoteCredentialsStoreProvider =
    Provider<LokalRemoteCredentialsStore>(
      (ref) => SecureLokalRemoteCredentialsStore(),
    );

final lokalRemoteServiceProvider = Provider<LokalRemoteService>((ref) {
  final service = LokalRemoteService();
  ref.onDispose(service.close);
  return service;
});

final lokalLinkServiceProvider = Provider<LokalLinkService>((ref) {
  final service = LokalLinkService();
  ref.onDispose(() => unawaited(service.close()));
  return service;
});

final linkedDesktopProfileProvider = FutureProvider<LinkedProfile?>((
  ref,
) async {
  final credentials = await ref
      .watch(lokalRemoteCredentialsStoreProvider)
      .read();
  if (credentials?.desktopId == null) return null;
  return LinkProfileService.load(credentials!);
});

final lokalRemoteControllerProvider =
    NotifierProvider<LokalRemoteController, LokalRemoteControllerState>(
      LokalRemoteController.new,
    );

/// Owns one authenticated desktop connection, including polling and bounded
/// reconnects. Paired desktop state is kept separate from the local engine.
class LokalRemoteController extends Notifier<LokalRemoteControllerState>
    implements RemoteFavoritesDelegate {
  static const _pollInterval = Duration(milliseconds: 1200);
  static const _maximumBackoff = Duration(seconds: 20);

  Timer? _pollTimer;
  Timer? _linkTimer;
  Timer? _statsDebounce;
  String? _notificationArtworkKey;
  String? _notificationArtwork;
  LinkSyncCoordinator? _linkSync;
  final _downloadOutbox = LinkDownloadOutbox();
  final _syncNotification = LibrarySyncNotification();
  final _copyNotification = FileCopyNotification();
  LinkFileCopy? _copyPlanner;
  bool _socketWanted = false, _openingSocket = false, _receivingTheme = false;
  DateTime _lastStatsSyncAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _statsSyncInFlight = false;
  Map<String, dynamic>? _desktopState;
  DateTime? _desktopStateAt;
  DateTime _lastActivity = DateTime.now(), _lastPhoneStateAt = DateTime.now();
  String _lastPhoneSignature = '';
  List<Song>? _lastPhoneQueue;
  double _lastPhoneProgress = 0;
  String? _notificationTrack;
  bool? _notificationPlaying;
  bool? _notificationFavorite;
  late final MediaNotificationOwner _notificationOwner = MediaNotificationOwner(
    onTogglePlayPause: () => unawaited(sendRawCommand('togglePlay')),
    onPlay: () => unawaited(sendRawCommand('play')),
    onPause: () => unawaited(sendRawCommand('pause')),
    onStop: () => unawaited(sendRawCommand('pause')),
    onNext: () => unawaited(sendRawCommand('next')),
    onToggleFavorite: () {
      final id = state.snapshot?.currentTrack?.id;
      if (id != null) unawaited(toggleFavorite('desktop:$id'));
    },
    onToggleShuffle: () => unawaited(
      sendRawCommand('setShuffle', !(state.snapshot?.shuffle ?? false)),
    ),
    onPrevious: () => unawaited(sendRawCommand('prev')),
    onSeek: (position) =>
        unawaited(sendRawCommand('seek', position.inMilliseconds / 1000)),
  );
  LokalRemoteCredentials? _credentials;
  Future<void>? _restoreTask;
  Future<void> _commandTail = Future<void>.value();
  var _polling = false;
  bool _syncInFlight = false;
  var _shouldPoll = false;
  var _failures = 0;
  var _generation = 0;
  var _disposed = false;

  @override
  LokalRemoteControllerState build() {
    _disposed = false;
    FavoritesService.remoteDelegate = this;
    final link = ref.read(lokalLinkServiceProvider);
    final messages = link.messages.listen(_onLinkMessage);
    final connections = link.connections.listen(_socketConnectionChanged);
    // Only play events may initiate background synchronization. Library,
    // metadata, likes and playlists still require explicit Sync now.
    final historyChanges = LinkJournal.instance.historyChanges.stream.listen(
      (_) => _scheduleStatsSync(const Duration(seconds: 15)),
    );
    ref.listen(lokalAppearanceProvider, (_, appearance) {
      if (!_receivingTheme && link.connected) unawaited(_sendTheme(appearance));
    });
    ref.onDispose(() {
      _copyPlanner?.cancel();
      _syncNotification.dispose();
      _copyNotification.dispose();
      _disposed = true;
      if (identical(FavoritesService.remoteDelegate, this))
        FavoritesService.remoteDelegate = null;
      _pollTimer?.cancel();
      _linkTimer?.cancel();
      _statsDebounce?.cancel();
      unawaited(historyChanges.cancel());
      unawaited(messages.cancel());
      unawaited(connections.cancel());
      NotificationService().release(_notificationOwner);
    });
    _restoreTask = _restore();
    unawaited(_restoreTask!);
    return const LokalRemoteControllerState();
  }

  Future<void> _restore() async {
    try {
      final credentials = await ref
          .read(lokalRemoteCredentialsStoreProvider)
          .read();
      if (_disposed || credentials == null) return;
      _credentials = credentials;
      state = state.copyWith(
        config: LokalRemoteConfig.fromCredentials(credentials),
        status: LokalRemoteConnectionStatus.disconnected,
        clearError: true,
      );
      if (credentials.desktopId != null && credentials.remoteToken.isNotEmpty) {
        scheduleMicrotask(() {
          if (!_disposed) unawaited(connect());
        });
      }
    } catch (_) {
      if (!_disposed) {
        state = state.copyWith(
          status: LokalRemoteConnectionStatus.unconfigured,
          error: 'Saved Lokal remote settings could not be read.',
        );
      }
    }
  }

  Future<void> _ensureRestored() async {
    final task = _restoreTask;
    if (task != null) await task;
  }

  Future<void> saveConfiguration({
    required String origin,
    required String remoteToken,
    required String apiKey,
  }) async {
    await _ensureRestored();
    disconnect();
    final normalized = LokalRemoteService.normalizeOrigin(origin);
    final credentials = LokalRemoteCredentials(
      origin: normalized,
      remoteToken: remoteToken.trim(),
      apiKey: apiKey.trim(),
    );
    await ref.read(lokalRemoteCredentialsStoreProvider).write(credentials);
    if (_disposed) return;
    _generation++;
    _shouldPoll = false;
    _pollTimer?.cancel();
    _credentials = credentials;
    state = LokalRemoteControllerState(
      config: LokalRemoteConfig.fromCredentials(credentials),
      status: LokalRemoteConnectionStatus.disconnected,
    );
  }

  Future<void> forgetConfiguration() async {
    disconnect();
    await ref.read(lokalRemoteCredentialsStoreProvider).clear();
    if (_disposed) return;
    _generation++;
    _shouldPoll = false;
    _pollTimer?.cancel();
    _credentials = null;
    ref.invalidate(linkedDesktopProfileProvider);
    state = const LokalRemoteControllerState();
  }

  void disconnect() {
    _syncNotification.pause();
    _socketWanted = false;
    _notificationArtworkKey = null;
    _notificationArtwork = null;
    _linkTimer?.cancel();
    _statsDebounce?.cancel();
    _linkSync = null;
    unawaited(ref.read(lokalLinkServiceProvider).disconnect());
    NotificationService().release(_notificationOwner);
    _generation++;
    _shouldPoll = false;
    _pollTimer?.cancel();
    if (_disposed) return;
    state = state.copyWith(
      status: state.config == null
          ? LokalRemoteConnectionStatus.unconfigured
          : LokalRemoteConnectionStatus.disconnected,
      clearSnapshot: true,
      clearError: true,
      commandInFlight: false,
      socketConnected: false,
      controlsDesktop: false,
    );
  }

  Future<void> connect() async {
    _lastActivity = DateTime.now();
    await _ensureRestored();
    if (_disposed) return;
    if (_credentials == null) {
      state = state.copyWith(
        status: LokalRemoteConnectionStatus.unconfigured,
        error: 'Save a Lokal desktop address before connecting.',
      );
      return;
    }
    _generation++;
    _shouldPoll = true;
    _failures = 0;
    _pollTimer?.cancel();
    state = state.copyWith(
      status: LokalRemoteConnectionStatus.connecting,
      clearError: true,
    );
    if (_credentials?.desktopId != null) {
      await _connectSocket();
    } else {
      await _poll();
    }
  }

  Future<void> refresh() async {
    _lastActivity = DateTime.now();
    if (state.socketConnected) {
      // Refreshing playback/connection state must not initiate library sync.
      _refreshSocketSnapshot();
      return;
    }
    if (!_shouldPoll) return connect();
    _pollTimer?.cancel();
    await _poll();
  }

  Future<void> sendCommand(LokalRemoteAction action, {double? value}) {
    _lastActivity = DateTime.now();
    final generation = _generation;
    Future<void> run() async {
      if (_disposed || generation != _generation) return;
      if (!state.reachable || _credentials == null) {
        throw const LokalRemoteNetworkException(
          'Connect to Lokal before sending a remote command.',
        );
      }
      final credentials = _credentials!;
      if (!_disposed) {
        state = state.copyWith(commandInFlight: true, clearError: true);
      }
      try {
        if (state.socketConnected) {
          await ref.read(lokalLinkServiceProvider).request('command', {
            'action': action.wireName,
            'value': value,
          });
        } else {
          await ref
              .read(lokalRemoteServiceProvider)
              .sendCommand(credentials, action, value: value);
        }
        if (!_disposed && generation == _generation) {
          if (!state.socketConnected) {
            _pollTimer?.cancel();
            unawaited(_poll());
          }
        }
      } catch (error) {
        if (!_disposed && generation == _generation) {
          _setFailure(error);
        }
        rethrow;
      } finally {
        if (!_disposed && generation == _generation) {
          state = state.copyWith(commandInFlight: false);
        }
      }
    }

    final next = _commandTail.then<void>((_) => run(), onError: (_) => run());
    _commandTail = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  @override
  Future<bool> isFavorite(String songId) async {
    final id = songId.replaceFirst('desktop:', ''), snapshot = state.snapshot;
    if (snapshot?.currentTrack?.id == id) return snapshot!.currentTrack!.liked;
    final matches = snapshot?.queue.where((track) => track.id == id);
    return matches != null && matches.isNotEmpty ? matches.first.liked : false;
  }

  @override
  Future<bool> toggleFavorite(String songId) async {
    final id = songId.replaceFirst('desktop:', ''),
        liked = await isFavorite(songId);
    await sendRawCommand('setTrackLike', {'trackId': id, 'liked': !liked});
    return !liked;
  }

  Future<List<LokalDiscoveredDesktop>> discoverDesktops() =>
      ref.read(lokalLinkServiceProvider).discover();

  Future<void> pairDesktop({
    required String origin,
    required String code,
    String? expectedDesktopId,
    bool syncTheme = false,
  }) async {
    await _ensureRestored();
    final credentials = await ref
        .read(lokalLinkServiceProvider)
        .pair(
          origin: LokalRemoteService.normalizeOrigin(origin),
          code: code,
          expectedDesktopId: expectedDesktopId,
        );
    disconnect();
    await ref.read(lokalRemoteCredentialsStoreProvider).write(credentials);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lokal.link.${credentials.desktopId}.theme', syncTheme);
    _credentials = credentials;
    ref.invalidate(linkedDesktopProfileProvider);
    state = LokalRemoteControllerState(
      config: LokalRemoteConfig.fromCredentials(credentials),
    );
    await connect();
  }

  Future<void> approveMerge() async {
    _lastActivity = DateTime.now();
    if (state.fileCopyProgress.busy)
      throw StateError('Wait for the current file copy to finish.');
    final sync = _linkSync;
    if (sync == null)
      throw const LokalRemoteNetworkException(
        'Connect to the paired desktop first.',
      );
    _syncNotification.begin(deviceName: state.desktopName);
    await sync.enableMerge();
    _lastActivity = DateTime.now();
  }

  /// The only post-merge entry point for a full desktop/phone library sync.
  /// Pairing, reconnecting, periodic link polls and local journal edits
  /// intentionally do not call this method.
  Future<void> syncNow() async {
    _lastActivity = DateTime.now();
    if (!state.socketConnected || _linkSync == null || !state.mergeApproved) {
      throw StateError('Connect and merge with your desktop before syncing.');
    }
    if (_syncInFlight || _linkSync!.busy || state.fileCopyProgress.busy) {
      throw StateError('A desktop sync or file copy is already running.');
    }
    _syncNotification.begin(deviceName: state.desktopName);
    await _syncLink();
    _lastActivity = DateTime.now();
  }

  LinkFileCopy _fileCopier() {
    final credentials = _credentials;
    if (credentials == null || !state.socketConnected) {
      throw const LokalRemoteNetworkException(
        'Connect to the paired desktop first.',
      );
    }
    final generation = _generation;
    late final LinkFileCopy copier;
    copier = LinkFileCopy(
      credentials: credentials,
      socket: ref.read(lokalLinkServiceProvider),
      connected: () =>
          !_disposed && generation == _generation && state.socketConnected,
      onProgress: (progress) {
        if (!_disposed && generation == _generation && !copier.cancelled) {
          state = state.copyWith(fileCopyProgress: progress);
          _copyNotification.update(progress);
        }
      },
    );
    return copier;
  }

  Future<LinkCopyPlan> prepareFileCopy() async {
    _lastActivity = DateTime.now();
    if (state.syncProgress.busy || state.fileCopyProgress.busy)
      throw StateError('Wait for the current library operation to finish.');
    final copier = _fileCopier();
    _copyPlanner = copier;
    try {
      return await copier.plan();
    } catch (_) {
      if (!_disposed)
        state = state.copyWith(
          fileCopyProgress: const LinkCopyProgress(phase: LinkCopyPhase.paused),
        );
      rethrow;
    } finally {
      if (identical(_copyPlanner, copier)) _copyPlanner = null;
    }
  }

  Future<void> copyMissingFiles(LinkCopyPlan plan) async {
    final copier = _fileCopier();
    try {
      await _copyNotification.begin(state.desktopName);
    } on Object {
      if (!_disposed)
        state = state.copyWith(
          fileCopyProgress: const LinkCopyProgress(phase: LinkCopyPhase.paused),
        );
      throw StateError(
        'Could not start background copying. Keep Lokal open and retry.',
      );
    }
    try {
      await copier.copy(plan);
    } finally {
      await _copyNotification.finish(state.fileCopyProgress);
      _lastActivity = DateTime.now();
    }
  }

  void cancelFileCopyPlan() {
    _copyPlanner?.cancel();
    if (state.fileCopyProgress.phase == LinkCopyPhase.checking) {
      state = state.copyWith(fileCopyProgress: const LinkCopyProgress());
    }
  }

  Future<void> setDesktopTarget(bool value) async {
    if (value && !state.reachable)
      throw const LokalRemoteNetworkException('Connect to your desktop first.');
    if (value) {
      if (!state.controlsDesktop) NotificationService().stopCurrentOwner();
      await PlayerService().pause();
    }
    if (_disposed) return;
    state = state.copyWith(controlsDesktop: value);
    if (!value) {
      NotificationService().release(_notificationOwner);
      _notificationTrack = null;
      PlayerService().refreshNotificationState();
    } else {
      _updateRemoteNotification();
    }
  }

  Future<void> sendRawCommand(String action, [Object? value]) async {
    _lastActivity = DateTime.now();
    if (state.socketConnected) {
      await ref.read(lokalLinkServiceProvider).request('command', {
        'action': action,
        'value': value,
      });
      return;
    }
    final actions = LokalRemoteAction.values.where(
      (item) => item.wireName == action,
    );
    if (actions.isEmpty)
      throw const LokalRemoteProtocolException(
        'Update Lokal on your PC to use this command.',
      );
    await sendCommand(
      actions.first,
      value: value is num ? value.toDouble() : null,
    );
  }

  Future<void> _connectSocket() async {
    final credentials = _credentials;
    if (credentials == null || _disposed || !_shouldPoll) return;
    final generation = _generation;
    _openingSocket = true;
    _socketWanted = true;
    try {
      await ref.read(lokalLinkServiceProvider).connect(credentials);
      if (_disposed || generation != _generation) return;
      _failures = 0;
      _pollTimer?.cancel();
      final prefs = await SharedPreferences.getInstance();
      final prefix = LinkSyncCoordinator.prefixFor(credentials);
      final lastSync = prefs.getInt('$prefix.last_sync');
      final initialProgress = LinkSyncProgress(
        phase: lastSync == null ? LinkSyncPhase.idle : LinkSyncPhase.complete,
        completedAt: lastSync == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(lastSync),
        catalogSongs: prefs.getInt('$prefix.catalog_songs'),
      );
      late final LinkSyncCoordinator coordinator;
      coordinator = LinkSyncCoordinator(
        socket: ref.read(lokalLinkServiceProvider),
        credentials: credentials,
        favorites: ref.read(favoritesServiceProvider),
        initialProgress: initialProgress,
        onProgress: (progress) {
          if (!_disposed &&
              generation == _generation &&
              identical(_linkSync, coordinator)) {
            state = state.copyWith(syncProgress: progress, mergeApproved: true);
            _syncNotification.update(progress, deviceName: state.desktopName);
          }
        },
        onChanged: () {
          if (!_disposed &&
              generation == _generation &&
              identical(_linkSync, coordinator)) {
            ref.invalidate(favoritesProvider);
            ref.invalidate(playlistsProvider);
          }
        },
        onProfileChanged: () {
          if (!_disposed &&
              generation == _generation &&
              identical(_linkSync, coordinator)) {
            ref.invalidate(linkedDesktopProfileProvider);
          }
        },
      );
      _linkSync = coordinator;
      state = state.copyWith(
        socketConnected: true,
        status: LokalRemoteConnectionStatus.connected,
        syncProgress: initialProgress,
        mergeApproved:
            prefs.getBool(
              '${LinkSyncCoordinator.prefixFor(credentials)}.merge',
            ) ==
            true,
        clearError: true,
      );
      _linkTimer?.cancel();
      _linkTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _tickLink(),
      );
      // Connection alone never starts a full library scan. Defer the first
      // bounded stats exchange until the socket and startup UI have settled.
      _lastStatsSyncAt = DateTime.now();
      _scheduleStatsSync(const Duration(seconds: 8));
      _publishLocalState();
    } catch (error) {
      if (_disposed || generation != _generation) return;
      final message = error.toString();
      if (message.contains('401')) {
        _socketWanted = false;
        _shouldPoll = false;
        _setFailure(const LokalRemoteAuthException());
        return;
      }
      if (message.contains('404') || message.contains('426')) {
        _socketWanted = false;
        state = state.copyWith(socketConnected: false);
        await _poll();
      } else {
        _setFailure(error);
        _pollTimer?.cancel();
        _pollTimer = Timer(_nextDelay(), () => unawaited(_connectSocket()));
      }
    } finally {
      _openingSocket = false;
    }
  }

  void _socketConnectionChanged(bool connected) {
    if (_disposed ||
        connected ||
        _openingSocket ||
        !_socketWanted ||
        !_shouldPoll)
      return;
    state = state.copyWith(
      socketConnected: false,
      status: LokalRemoteConnectionStatus.offline,
    );
    _failures++;
    _syncNotification.pause();
    _linkTimer?.cancel();
    _pollTimer?.cancel();
    _pollTimer = Timer(_nextDelay(), () => unawaited(_connectSocket()));
  }

  void _onLinkMessage(LinkMessage message) {
    if (_disposed || !_shouldPoll) return;
    if (const {'state', 'command', 'theme'}.contains(message.type))
      _lastActivity = DateTime.now();
    switch (message.type) {
      case 'hello':
        if (message.body['desktopId'] != _credentials?.desktopId) {
          disconnect();
          return;
        }
        state = state.copyWith(
          desktopName: message.body['name'] as String? ?? 'Lokal desktop',
          syncPreview: message.body['syncPreview'] is Map
              ? Map<String, dynamic>.from(message.body['syncPreview'] as Map)
              : null,
        );
        break;
      case 'state':
        _desktopState = Map<String, dynamic>.from(message.body);
        _desktopStateAt = DateTime.now();
        _refreshSocketSnapshot();
        break;
      case 'command':
        unawaited(() async {
          try {
            await _handlePhoneCommand(message.body);
            if (!_disposed && ref.read(lokalLinkServiceProvider).connected)
              ref.read(lokalLinkServiceProvider).send('ack', {
                'ok': true,
              }, id: message.id);
          } catch (_) {
            if (!_disposed && ref.read(lokalLinkServiceProvider).connected)
              ref.read(lokalLinkServiceProvider).send('ack', {
                'ok': false,
                'error': 'The phone could not complete this command.',
              }, id: message.id);
          }
        }());
        break;
      case 'theme':
        unawaited(_receiveTheme(message.body));
        break;
    }
  }

  void _refreshSocketSnapshot() {
    final raw = _desktopState, at = _desktopStateAt;
    if (raw == null || at == null || _disposed) return;
    final elapsed = raw['isPlaying'] == true
        ? DateTime.now().difference(at).inMilliseconds / 1000
        : 0.0;
    final progress = (raw['progress'] as num? ?? 0).toDouble() + elapsed;
    try {
      state = state.copyWith(
        snapshot: LokalRemoteSnapshot.fromJson({...raw, 'progress': progress}),
        status: LokalRemoteConnectionStatus.connected,
        lastSeenAt: at,
      );
    } on FormatException {
      state = state.copyWith(error: 'Desktop playback state was invalid.');
    }
    if (state.controlsDesktop) _updateRemoteNotification();
  }

  void _tickLink() {
    if (_disposed || !state.socketConnected) return;
    if (!state.syncProgress.busy &&
        !state.fileCopyProgress.busy &&
        !_downloadOutbox.busy &&
        DateTime.now().difference(_lastActivity) > const Duration(minutes: 3)) {
      disconnect();
      state = state.copyWith(
        error: 'Desktop link paused after 3 minutes without interaction. Reconnect when you need it.',
      );
      return;
    }
    _refreshSocketSnapshot();
    _publishLocalState();
    if (DateTime.now().difference(_lastStatsSyncAt) >=
        const Duration(minutes: 2)) {
      unawaited(_syncStats());
    }
  }

  void _scheduleStatsSync(Duration delay) {
    if (_disposed || !state.socketConnected || !state.mergeApproved) return;
    _statsDebounce?.cancel();
    _statsDebounce = Timer(delay, () => unawaited(_syncStats()));
  }

  Future<void> _syncStats() async {
    final coordinator = _linkSync;
    if (_disposed ||
        !state.socketConnected ||
        !state.mergeApproved ||
        !Database.isInitialized ||
        _syncInFlight ||
        _statsSyncInFlight ||
        state.fileCopyProgress.busy ||
        coordinator == null ||
        coordinator.busy) {
      return;
    }
    _statsDebounce?.cancel();
    _statsSyncInFlight = true;
    _lastStatsSyncAt = DateTime.now();
    try {
      await coordinator.synchronizeStats();
    } catch (_) {
      // Offline peers or malformed replies must never interrupt playback.
      // Journal cursors checkpoint only acknowledged/committed pages, so the
      // next connected tick or manual Sync now can safely retry.
    } finally {
      _statsSyncInFlight = false;
    }
  }

  Future<void> _syncLink() async {
    if (_syncInFlight || state.fileCopyProgress.busy || _linkSync?.busy == true)
      return;
    _syncInFlight = true;
    final generation = _generation;
    try {
      final credentials = _credentials;
      if (credentials != null)
        await _downloadOutbox.flush(
          credentials,
          connected: () => !_disposed && state.socketConnected,
        );
      // The coordinator deliberately skips when disconnected. For an
      // explicit user action, skipping is not success.
      final coordinator = _linkSync;
      if (_disposed ||
          generation != _generation ||
          !state.socketConnected ||
          coordinator == null ||
          !ref.read(lokalLinkServiceProvider).connected) {
        throw StateError('Desktop disconnected before library sync. Reconnect and retry.');
      }
      await coordinator.synchronize();
      if (_disposed ||
          generation != _generation ||
          !state.socketConnected ||
          !ref.read(lokalLinkServiceProvider).connected ||
          !identical(_linkSync, coordinator)) {
        throw StateError('Desktop disconnected during library sync. Reconnect and retry.');
      }
    } catch (_) {
      if (!_disposed && generation == _generation) {
        state = state.copyWith(
          error: 'Library sync paused. Your local data is safe; tap Sync now when connected.',
        );
      }
      _syncNotification.pause();
      rethrow;
    } finally {
      _syncInFlight = false;
    }
  }

  void _publishLocalState() {
    final socket = ref.read(lokalLinkServiceProvider);
    if (!socket.connected) return;
    final player = PlayerService(), song = player.currentSongNotifier.value;
    final queue = player.queueNotifier.value, now = DateTime.now();
    final progress = player.positionNotifier.value.inMilliseconds / 1000;
    final payload = <String, dynamic>{
      'target': 'phone',
      'isPlaying': player.isPlayingNotifier.value,
      'currentTrack': song == null ? null : LinkJournal.instance.songWire(song),
      'currentIndex': player.currentIndexNotifier.value,
      'duration': player.durationNotifier.value.inMilliseconds / 1000,
      'volume': player.currentVolume,
      'shuffle': player.isShuffleNotifier.value,
      'repeat': player.loopModeNotifier.value == LoopMode.one
          ? 'one'
          : player.loopModeNotifier.value == LoopMode.all
          ? 'all'
          : 'none',
    };
    final signature = jsonEncode(payload);
    final expected =
        _lastPhoneProgress +
        (player.isPlayingNotifier.value
            ? now.difference(_lastPhoneStateAt).inMilliseconds / 1000
            : 0);
    if (signature == _lastPhoneSignature &&
        identical(queue, _lastPhoneQueue) &&
        (progress - expected).abs() < 1.5)
      return;
    _lastPhoneSignature = signature;
    _lastPhoneQueue = queue;
    _lastPhoneProgress = progress;
    _lastPhoneStateAt = now;
    socket.send('state', {
      ...payload,
      'queue': queue.map(LinkJournal.instance.songWire).toList(),
      'progress': progress,
      'positionAt': now.millisecondsSinceEpoch,
    });
  }

  Future<void> _handlePhoneCommand(Map<String, dynamic> body) async {
    _lastActivity = DateTime.now();
    final player = PlayerService(),
        action = body['action'],
        value = body['value'];
    if (state.controlsDesktop && action != 'handoffToDesktop')
      await setDesktopTarget(false);
    switch (action) {
      case 'togglePlay':
        await player.togglePlayPause();
        break;
      case 'play':
        await player.resume();
        break;
      case 'pause':
        await player.pause();
        break;
      case 'next':
        await player.next();
        break;
      case 'prev':
        await player.previous();
        break;
      case 'seek':
        if (value is! num || !value.isFinite)
          throw const FormatException('Invalid seek.');
        await player.seek(Duration(milliseconds: (value * 1000).round()));
        break;
      case 'volume':
        if (value is! num || !value.isFinite)
          throw const FormatException('Invalid volume.');
        await player.setVolume(value.toDouble().clamp(0, 1));
        break;
      case 'setShuffle':
        if (value is! bool) throw const FormatException('Invalid shuffle.');
        if (player.isShuffleNotifier.value != value)
          await player.toggleShuffle();
        break;
      case 'setRepeat':
        await player.setLoopMode(
          value == 'one'
              ? LoopMode.one
              : value == 'all'
              ? LoopMode.all
              : LoopMode.off,
        );
        break;
      case 'reorderQueue':
        if (value is! Map || value['from'] is! int || value['to'] is! int)
          throw const FormatException('Invalid queue move.');
        await player.moveQueueItem(value['from'] as int, value['to'] as int);
        break;
      case 'removeFromQueue':
        if (value is! Map || value['index'] is! int)
          throw const FormatException('Invalid queue entry.');
        await player.removeFromQueue(value['index'] as int);
        break;
      case 'handoffToDesktop':
        await playOnDesktop();
        break;
      case 'handoff':
        if (value is! Map) throw const FormatException('Invalid handoff.');
        await _receiveHandoff(Map<String, dynamic>.from(value));
        break;
      default:
        throw const FormatException('Unsupported phone command.');
    }
    _publishLocalState();
  }

  Future<void> playOnDesktop() async {
    final player = PlayerService(), queue = player.queueNotifier.value;
    if (queue.isEmpty)
      throw const LokalRemoteProtocolException(
        'Choose a song on this phone first.',
      );
    final volume = player.currentVolume;
    final prefs = await SharedPreferences.getInstance();
    if (_credentials != null &&
        prefs.getBool('lokal.link.${_credentials!.desktopId}.send_downloads') ==
            true) {
      final resolved = await ref.read(lokalLinkServiceProvider).request(
        'command',
        {
          'action': 'resolveTracks',
          'value': {'queue': queue.map(LinkJournal.instance.songWire).toList()},
        },
      );
      for (final index in resolved.body['missing'] as List? ?? const []) {
        if (index is int &&
            index >= 0 &&
            index < queue.length &&
            !queue[index].isNetworkSource)
          await LokalDesktopSource.instance.uploadToDesktop(
            queue[index],
            _credentials!,
          );
      }
    }
    // The receiver accepts the queue before the sender gives up playback.
    await sendRawCommand('handoff', {
      'queue': queue.map(LinkJournal.instance.songWire).toList(),
      'index': player.currentIndexNotifier.value,
      'positionMs': player.positionNotifier.value.inMilliseconds,
    });
    for (var step = 9; step >= 0; step--) {
      await player.setVolume(volume * step / 10);
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    await player.pause();
    await player.setVolume(volume);
    await setDesktopTarget(true);
  }

  Future<void> playOnPhone() async {
    final snapshot = state.snapshot;
    if (snapshot == null || snapshot.queue.isEmpty)
      throw const LokalRemoteProtocolException(
        'No desktop queue is available.',
      );
    await _receiveHandoff({
      'queue': snapshot.queue.map((track) => track.toJson()).toList(),
      'index': snapshot.currentIndex,
      'positionMs': (snapshot.progress * 1000).round(),
    });
    await sendRawCommand('fadePause');
  }

  Future<void> _receiveHandoff(Map<String, dynamic> value) async {
    final raw = value['queue'], index = value['index'];
    if (raw is! List ||
        raw.isEmpty ||
        raw.length > 5000 ||
        index is! int ||
        index < 0 ||
        index >= raw.length ||
        _credentials == null)
      throw const FormatException('Invalid handoff queue.');
    final source = LokalDesktopSource.instance,
        server = await LokalDesktopSource.instance.ensureServer(_credentials!);
    final queue = <Song>[];
    for (final track in raw) {
      queue.add(
        await source.importTrack(
          server,
          Map<String, dynamic>.from(track as Map),
        ),
      );
    }
    // Cache the selected desktop file before changing either output.
    final selected = queue[index];
    if (selected.sourceType == 'lokal')
      await source.stream(
        server,
        selected.remoteId!,
        extension: selected.fileType,
      );
    final player = PlayerService(), volume = player.currentVolume;
    await setDesktopTarget(false);
    await player.setVolume(0);
    try {
      await player.play(selected, playlist: queue);
      await player.seek(
        Duration(
          milliseconds: math.max(0, (value['positionMs'] as num? ?? 0).round()),
        ),
      );
    } catch (_) {
      await player.setVolume(volume);
      rethrow;
    }
    for (var step = 1; step <= 10; step++) {
      await player.setVolume(volume * step / 10);
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  void _updateRemoteNotification() {
    final snapshot = state.snapshot, track = snapshot?.currentTrack;
    if (snapshot == null || track == null) return;
    final artworkKey = '$_generation:${track.id}';
    if (_notificationArtworkKey != artworkKey) {
      _notificationArtworkKey = artworkKey;
      _notificationArtwork = null;
      unawaited(_loadNotificationArtwork(artworkKey, track.id));
    }
    final position = Duration(milliseconds: (snapshot.progress * 1000).round());
    if (_notificationTrack == track.id &&
        _notificationPlaying == snapshot.isPlaying &&
        _notificationFavorite == track.liked &&
        NotificationService().isClaimed) {
      unawaited(
        NotificationService().updateFor(
          _notificationOwner,
          position: position,
          isPlaying: snapshot.isPlaying,
        ),
      );
      return;
    }
    _notificationTrack = track.id;
    _notificationPlaying = snapshot.isPlaying;
    _notificationFavorite = track.liked;
    unawaited(
      NotificationService().showFor(
        _notificationOwner,
        outputName: state.desktopName,
        song: Song(
          id: 'desktop:${track.id}',
          title: track.title,
          artist: track.artist,
          album: track.album,
          albumArt: _notificationArtwork,
          duration: Duration(milliseconds: (snapshot.duration * 1000).round()),
          fileType: track.fileType,
        ),
        isPlaying: snapshot.isPlaying,
        isLive: false,
        isFavorite: track.liked,
        isShuffle: snapshot.shuffle,
        position: position,
      ),
    );
  }

  Future<void> _loadNotificationArtwork(String key, String? trackId) async {
    final credentials = _credentials;
    if (credentials == null ||
        trackId == null ||
        credentials.desktopId == null ||
        !Database.isInitialized)
      return;
    try {
      final server = await LokalDesktopSource.instance.ensureServer(
        credentials,
      );
      final path = await AlbumArtService.instance.resolveArtworkPath(
        existingPath: 'lokal-cover://$trackId',
        audioSourcePath: 'lokal://${server.id}/$trackId',
      );
      if (_disposed ||
          !state.controlsDesktop ||
          _notificationArtworkKey != key ||
          path == null)
        return;
      _notificationArtwork = path;
      _notificationTrack = null; // Publish the local image to Android metadata.
      _updateRemoteNotification();
    } catch (_) {
      // Controls remain usable while an offline/missing cover uses Lokal art.
    }
  }

  Future<void> _sendTheme(LokalAppearance appearance) async {
    final prefs = await SharedPreferences.getInstance();
    if (_disposed ||
        prefs.getBool('lokal.link.${_credentials?.desktopId}.theme') != true ||
        !ref.read(lokalLinkServiceProvider).connected)
      return;
    final color = appearance.tokens.accent
        .toARGB32()
        .toRadixString(16)
        .padLeft(8, '0')
        .substring(2);
    ref.read(lokalLinkServiceProvider).send('theme', {
      'theme': appearance.theme.name,
      'accent': appearance.accent?.name,
      'accentColor': '#$color',
    });
  }

  Future<void> _receiveTheme(Map<String, dynamic> body) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('lokal.link.${_credentials?.desktopId}.theme') != true)
      return;
    // Appearance validates names against the phone's supported Lokal presets.
    _receivingTheme = true;
    try {
      await ref.read(lokalAppearanceProvider.notifier).adoptDesktopTheme(body);
    } finally {
      _receivingTheme = false;
    }
  }

  Future<void> _poll() async {
    if (_polling || _disposed || !_shouldPoll) return;
    final credentials = _credentials;
    if (credentials == null) return;
    _polling = true;
    final generation = _generation;
    try {
      final snapshot = await ref
          .read(lokalRemoteServiceProvider)
          .fetchState(credentials);
      if (_disposed || generation != _generation) return;
      _failures = 0;
      final previous = state.snapshot;
      final stale =
          previous != null &&
          previous.updatedAt > 0 &&
          snapshot.updatedAt > 0 &&
          snapshot.updatedAt < previous.updatedAt;
      if (!stale) {
        state = state.copyWith(
          status: LokalRemoteConnectionStatus.connected,
          snapshot: snapshot,
          clearError: true,
          lastSeenAt: DateTime.now(),
        );
      } else {
        state = state.copyWith(
          status: LokalRemoteConnectionStatus.connected,
          clearError: true,
          lastSeenAt: DateTime.now(),
        );
      }
    } catch (error) {
      if (!_disposed && generation == _generation) _setFailure(error);
    } finally {
      _polling = false;
      if (!_disposed && generation == _generation && _shouldPoll) {
        _schedulePoll(_nextDelay());
      }
    }
  }

  Duration _nextDelay() {
    if (_failures == 0) return _pollInterval;
    final seconds = math.min(
      _maximumBackoff.inSeconds,
      1.2 * math.pow(2, _failures - 1),
    );
    return Duration(milliseconds: (seconds * 1000).round());
  }

  void _schedulePoll(Duration delay) {
    _pollTimer?.cancel();
    _pollTimer = Timer(delay, () {
      _pollTimer = null;
      unawaited(_poll());
    });
  }

  void _setFailure(Object error) {
    _failures++;
    final status = error is LokalRemoteAuthException
        ? LokalRemoteConnectionStatus.unauthorized
        : LokalRemoteConnectionStatus.offline;
    final message = error is LokalRemoteException
        ? error.message
        : 'Could not reach Lokal on the local network.';
    state = state.copyWith(status: status, error: message);
  }
}
