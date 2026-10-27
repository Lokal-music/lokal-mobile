import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/ios_widget_snapshot.dart';

class IosWidgetPublicationCapability {
  const IosWidgetPublicationCapability({
    required this.available,
    this.committedRevision = 0,
    this.unavailableReason,
  });
  final bool available;
  final int committedRevision;
  final IosWidgetUnavailableReason? unavailableReason;
}

enum IosWidgetUnavailableReason {
  notConfigured,
  invalidConfiguration,
  sharedContainerUnavailable,
  storageNeedsRepair,
  unsupportedPlatform,
  unknown,
}

class IosWidgetPublicationReceipt {
  IosWidgetPublicationReceipt({
    required this.revision,
    Map<String, String> artworkByAlias = const {},
    this.lastArtwork,
    this.artworkDegraded = false,
  }) : artworkByAlias = Map.unmodifiable(artworkByAlias);

  final int revision;
  final Map<String, String> artworkByAlias;
  final String? lastArtwork;
  final bool artworkDegraded;
}

/// Implemented by the optional native bridge after resolving the installed
/// App Group. Neither capability checks nor publication may construct a player.
abstract interface class IosWidgetPublicationTransport {
  Future<IosWidgetPublicationCapability> capability();
  Future<IosWidgetPublicationReceipt> publish(
    IosWidgetSnapshot metadata,
    Map<String, Uint8List> artworkByAlias, {
    required bool reloadTimelines,
  });
}

enum IosWidgetPublicationPhase {
  idle,
  unavailable,
  publishing,
  failed,
  disposed,
}

typedef IosWidgetArtworkLoader = Future<Map<String, Uint8List>> Function();

class _PublicationRequest {
  const _PublicationRequest(this.metadata, this.loadArtwork, this.reload);
  final IosWidgetSnapshot metadata;
  final IosWidgetArtworkLoader? loadArtwork;
  final bool reload;
}

/// Serializes meaningful host publication requests and coalesces pending work.
/// The runtime sampler supplies canonical source timestamps and decides when a
/// seek/state/metadata change or heartbeat warrants a request. This class never
/// polls, fabricates a playhead or replaces the actual sampled timestamp.
class IosWidgetPublicationCoordinator {
  IosWidgetPublicationCoordinator({
    required this.transport,
    this.debounce = const Duration(milliseconds: 250),
    this.operationTimeout = const Duration(seconds: 5),
    this.artworkTimeout = const Duration(seconds: 2),
  });

  static const maximumRevision = 9007199254740991;
  static const maximumArtworkBytes = 12 * 1024 * 1024;
  final IosWidgetPublicationTransport transport;
  final Duration debounce, operationTimeout, artworkTimeout;
  final phase = ValueNotifier(IosWidgetPublicationPhase.idle);
  IosWidgetPublicationReceipt? get lastReceipt => _lastReceipt;
  bool get lastArtworkDegraded => _lastArtworkDegraded;
  IosWidgetUnavailableReason? get unavailableReason =>
      _capability?.unavailableReason;

  Timer? _timer;
  Future<void>? _worker;
  Future<Map<String, Uint8List>>? _ownedArtwork;
  IosWidgetPublicationCapability? _capability;
  IosWidgetPublicationReceipt? _lastReceipt;
  _PublicationRequest? _pending;
  _PublicationRequest? _blockedRequest;
  int _issuedRevision = 0;
  bool _disposed = false;
  bool _lastArtworkDegraded = false;

  void submit(
    IosWidgetSnapshot metadata, {
    IosWidgetArtworkLoader? loadArtwork,
    bool reloadTimelines = true,
  }) {
    if (_disposed) return;
    _pending = _PublicationRequest(metadata, loadArtwork, reloadTimelines);
    _schedule();
  }

  void _schedule() {
    if (_disposed || _worker != null || _timer != null) return;
    _timer = Timer(debounce, () {
      _timer = null;
      unawaited(flush());
    });
  }

  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    if (_disposed) return Future.value();
    return _worker ??= _drain().whenComplete(() {
      _worker = null;
      // A listener may submit fresh state while failure/unavailable is being
      // announced. Retained failed work must not spin; fresh work must not be
      // lost merely because the former worker has not completed its microtask.
      if (_pending != null && !identical(_pending, _blockedRequest)) {
        _schedule();
      }
    });
  }

  /// Recheck an unavailable/repaired profile or storage explicitly. A failed
  /// request never creates a retry timer or an uncontrolled background loop.
  Future<void> retry() async {
    if (_disposed) return;
    await _worker;
    if (_disposed) return;
    _capability = null;
    await flush();
  }

  Future<void> _drain() async {
    if (_capability == null) {
      try {
        final value = await transport.capability().timeout(operationTimeout);
        if (_disposed) return;
        if (value.committedRevision < 0 ||
            value.committedRevision > maximumRevision) {
          throw const FormatException('Invalid widget revision');
        }
        _capability = value;
        if (value.committedRevision > _issuedRevision) {
          _issuedRevision = value.committedRevision;
        }
      } catch (_) {
        _blockedRequest = _pending;
        _setPhase(IosWidgetPublicationPhase.failed);
        return;
      }
    }
    if (_capability?.available != true) {
      _blockedRequest = _pending;
      _setPhase(IosWidgetPublicationPhase.unavailable);
      return;
    }
    while (!_disposed && _pending != null) {
      final request = _pending!;
      _pending = null;
      _blockedRequest = null;
      _setPhase(IosWidgetPublicationPhase.publishing);
      var degraded = false;
      var images = <String, Uint8List>{};
      try {
        if (request.loadArtwork != null) {
          // A timed-out loader remains owned until its real future completes.
          // Later metadata can proceed, but another image job cannot pile up
          // behind a stuck native file read.
          if (_ownedArtwork == null) {
            final loading = Future<Map<String, Uint8List>>.sync(
              request.loadArtwork!,
            );
            _ownedArtwork = loading;
            unawaited(
              loading.then<void>(
                (_) {
                  if (identical(_ownedArtwork, loading)) _ownedArtwork = null;
                },
                onError: (Object _, StackTrace _) {
                  if (identical(_ownedArtwork, loading)) _ownedArtwork = null;
                },
              ),
            );
            images = await loading.timeout(artworkTimeout);
          } else {
            degraded = true;
          }
        }
      } catch (_) {
        degraded = true;
      }
      if (_disposed) return;
      // An obsolete artwork result cannot publish its former song/state.
      if (_pending != null) continue;
      try {
        if (_issuedRevision == maximumRevision) {
          throw const FormatException('Widget revision exhausted');
        }
        final revision = ++_issuedRevision;
        final metadata = IosWidgetSnapshot.fromJson({
          ...request.metadata.toJson(),
          'revision': revision,
        });
        final fields = metadata.toJson();
        if ((fields['updatedAtMs']! as int) == 0) {
          throw const FormatException('Missing sampled widget timestamp');
        }
        final aliases = <String>{
          if (fields['current'] case final Map current) current['id'] as String,
          for (final row in fields['recommendations']! as List)
            (row as Map)['id'] as String,
        };
        final bounded = <String, Uint8List>{};
        var bytes = 0;
        for (final entry in images.entries) {
          if (!aliases.contains(entry.key) ||
              bounded.length == 13 ||
              entry.value.length > maximumArtworkBytes - bytes) {
            degraded = true;
            continue;
          }
          bytes += entry.value.length;
          bounded[entry.key] = Uint8List.fromList(entry.value)
              .asUnmodifiableView();
        }
        final receipt = await transport
            .publish(
              metadata,
              Map.unmodifiable(bounded),
              reloadTimelines: request.reload,
            )
            .timeout(operationTimeout);
        if (_disposed) return;
        if (receipt.revision != revision ||
            receipt.artworkByAlias.entries.any(
              (entry) =>
                  !aliases.contains(entry.key) || !_artworkName(entry.value),
            ) ||
            (receipt.lastArtwork != null &&
                !_artworkName(receipt.lastArtwork!))) {
          throw const FormatException('Invalid widget publication receipt');
        }
        if (_pending != null) continue;
        _lastReceipt = receipt;
        _lastArtworkDegraded = degraded || receipt.artworkDegraded;
        _setPhase(IosWidgetPublicationPhase.idle);
      } catch (_) {
        if (_pending != null) continue;
        // Retain the last request for explicit retry, without spinning.
        _pending = request;
        _blockedRequest = request;
        _setPhase(IosWidgetPublicationPhase.failed);
        return;
      }
    }
  }

  static bool _artworkName(String name) =>
      RegExp(r'^[a-f0-9]{64}\.(png|jpg)$').hasMatch(name);

  void _setPhase(IosWidgetPublicationPhase value) {
    if (!_disposed) phase.value = value;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _pending = null;
    phase.value = IosWidgetPublicationPhase.disposed;
    phase.dispose();
  }
}
