import 'dart:async';

import '../models/ios_transfer_import.dart';
import '../models/ios_transfer_cleanup.dart';
import '../models/ios_transfer_models.dart';
import '../models/ios_transfer_recovery.dart';
import 'ios_transfer_coordinator_port.dart';
import 'ios_transfer_import_store.dart';
import 'ios_transfer_media.dart';

enum IosTransferCoordinatorIssue {
  transport,
  conflict,
  invalidMedia,
  mediaUnavailable,
  mediaTimeout,
  missingReservation,
  missingValidation,
  cleanupRequired,
  invalidProtocol,
}

/// One root app-isolate owner, with actual Isar transactions and native leases.
/// No timers poll paused jobs. Product activation still requires the native
/// capability; only isolated integration probes may opt into unfinished APIs.
class IosTransferImportCoordinator {
  IosTransferImportCoordinator({
    required this.native,
    required Future<IosTransferImportStore> Function() store,
    required this.readMedia,
    this.allowUnreleasedAdapterForIntegration = false,
  }) : _openStore = store;

  final IosTransferCoordinatorPort native;
  final Future<IosTransferImportStore> Function() _openStore;
  final IosTransferMediaReader readMedia;
  final bool allowUnreleasedAdapterForIntegration;
  final _updates = StreamController<void>.broadcast();
  final _issues = <String, IosTransferCoordinatorIssue>{};
  final _frozen = <String, IosTransferImportWork>{};
  final _completed = <String>{};
  final _pendingReservations = <String, bool>{};
  IosTransferImportStore? _store;
  StreamSubscription<void>? _observation;
  Future<void>? _starting, _running, _foregrounding;
  IosTransferImportLease? _active;
  IosTransferCleanupLease? _activeCleanup;
  Completer<void>? _activeCancellation;
  (String, Future<void>)? _lastRelease;
  bool _disposed = false, _enabled = false, _eligible = false;
  bool _dirty = false, _needsRecovery = true;
  int _epoch = 0;

  bool get enabled => _enabled;
  bool get busy => _running != null;
  Stream<void> get updates => _updates.stream;
  Map<String, IosTransferCoordinatorIssue> get issues =>
      Map.unmodifiable(_issues);
  String _key(IosTransferJob job) => '${job.id}:${job.revision}';
  bool _current(int epoch) => !_disposed && _enabled && epoch == _epoch;
  void _check(int epoch) {
    if (!_current(epoch)) throw StateError('Import coordinator retired.');
  }

  void _notify() {
    if (!_updates.isClosed) _updates.add(null);
  }

  void _cancelActive() {
    final cancellation = _activeCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
  }

  void _listen() {
    _observation = native.changes.listen(
      (_) {
        unawaited(requestDrain());
      },
      onError: (Object _, StackTrace _) {
        _enabled = false;
        _epoch++;
        _cancelActive();
        _issues['root'] = IosTransferCoordinatorIssue.transport;
        _notify();
      },
    );
  }

  Future<void> start() => _starting ??= _start();
  Future<void> _start() async {
    final epoch = _epoch;
    try {
      final capability = await native.capability();
      if (_disposed || epoch != _epoch) return;
      _eligible =
          capability.canCopyToLibrary ||
          (allowUnreleasedAdapterForIntegration &&
              capability.available &&
              capability.download);
      if (!_eligible) return;
      _store = await _openStore();
      if (_disposed || epoch != _epoch) return;
      _listen();
      await native.recover();
      if (_disposed || epoch != _epoch) return;
      await native.drainImports();
      if (_disposed || epoch != _epoch) return;
      _enabled = true;
      _issues.remove('root');
      await requestDrain();
    } catch (_) {
      if (!_disposed && epoch == _epoch) {
        _enabled = false;
        _issues['root'] = IosTransferCoordinatorIssue.transport;
        _starting = null;
        _notify();
      }
    }
  }

  /// Lifecycle/user retry is explicit. Unrelated progress events do not retry
  /// failed media or spin on a storage/pairing conflict.
  Future<void> foreground() =>
      _foregrounding ??= _foreground().whenComplete(() {
        _foregrounding = null;
      });

  Future<void> _foreground() async {
    if (_disposed) return;
    if (!_eligible || _store == null) {
      await start();
      return;
    }
    if (!_enabled) {
      _epoch++;
      _cancelActive();
      await _running;
      await _observation?.cancel();
      if (_disposed) return;
      final epoch = _epoch;
      _listen();
      try {
        await native.recover();
        await native.drainImports();
        _store = await _openStore();
        if (_disposed || epoch != _epoch) return;
        _enabled = true;
      } catch (_) {
        if (!_disposed && epoch == _epoch) {
          _enabled = false;
          _issues['root'] = IosTransferCoordinatorIssue.transport;
          _notify();
        }
        return;
      }
    }
    _issues.clear();
    _needsRecovery = true;
    await requestDrain();
  }

  Future<void> requestDrain() {
    if (!_enabled || _disposed) return Future.value();
    _dirty = true;
    if (_running != null) return _running!;
    final epoch = _epoch;
    return _running = () async {
      try {
        while (_dirty && _current(epoch)) {
          _dirty = false;
          if (_needsRecovery) {
            _needsRecovery = false;
            await _recoverWork(epoch);
          }
          IosTransferWorkCursor? cursor;
          var visited = 0;
          do {
            _check(epoch);
            final page = await native.importCandidatesPage(after: cursor);
            _check(epoch);
            visited += page.entries.length;
            if (visited > iosTransferMaximumJobs) {
              throw const FormatException('Import candidate budget exceeded.');
            }
            for (final job in page.entries) {
              _check(epoch);
              final key = _key(job);
              if (_pendingReservations.remove(key) == true) {
                _issues[key] = IosTransferCoordinatorIssue.cleanupRequired;
              }
              if (!_issues.containsKey(_key(job)) &&
                  !_completed.contains(_key(job))) {
                await _import(job, epoch);
              }
              await Future<void>.delayed(Duration.zero);
            }
            cursor = page.nextCursor;
          } while (cursor != null);
          for (final key in _pendingReservations.keys) {
            _issues[key] = IosTransferCoordinatorIssue.cleanupRequired;
          }
          _pendingReservations.clear();
        }
      } catch (_) {
        if (_current(epoch)) {
          _enabled = false;
          _epoch++;
          _cancelActive();
          _issues['root'] = IosTransferCoordinatorIssue.transport;
        }
      } finally {
        _running = null;
        _notify();
      }
    }();
  }

  Future<void> _release(IosTransferImportLease lease) {
    if (_lastRelease?.$1 == lease.leaseId) return _lastRelease!.$2;
    final released = () async {
      try {
        await native.releaseImport(lease);
      } catch (_) {
        // Completion/cancellation may already have retired this lease. A
        // current-client barrier still has to prove that old file work drained.
        await native.drainImports();
      }
    }();
    _lastRelease = (lease.leaseId, released);
    return released;
  }

  Future<void> _releaseCleanup(IosTransferCleanupLease lease) {
    if (_lastRelease?.$1 == lease.leaseId) return _lastRelease!.$2;
    final released = () async {
      try {
        await native.releaseImportCleanup(lease);
      } catch (_) {
        await native.drainImports();
      }
    }();
    _lastRelease = (lease.leaseId, released);
    return released;
  }

  Future<void> _recoverWork(int epoch) async {
    _frozen.clear();
    _pendingReservations.clear();
    int? afterId;
    var pendingCount = 0;
    do {
      _check(epoch);
      final page = await _store!.pendingReservations(afterId: afterId);
      _check(epoch);
      pendingCount += page.entries.length;
      if (pendingCount > iosTransferMaximumJobs) {
        throw const FormatException('Import reservation budget exceeded.');
      }
      for (final entry in page.entries) {
        _pendingReservations[entry.operationKey] = entry.retiring;
      }
      if (page.nextId != null && page.nextId! <= (afterId ?? 0)) {
        throw const FormatException('Invalid import reservation cursor.');
      }
      afterId = page.nextId;
    } while (afterId != null);
    IosTransferWorkCursor? cursor;
    var pages = 0;
    do {
      _check(epoch);
      final page = await native.importWorkPage(after: cursor);
      _check(epoch);
      if (++pages > (iosTransferMaximumJobs + 99) ~/ 100) {
        throw const FormatException('Import recovery budget exceeded.');
      }
      for (final work in page.entries) {
        _frozen[_key(work.job)] = work;
        if (_issues.containsKey(_key(work.job))) continue;
        if (work.isCurrentRevision &&
            {
              IosTransferPhase.validating,
              IosTransferPhase.importing,
            }.contains(work.currentPhase)) {
          if (_pendingReservations[_key(work.job)] == true) {
            await _cleanupWork(work, epoch);
          }
          continue;
        }
        if (work.isCurrentRevision &&
            work.currentPhase == IosTransferPhase.complete) {
          await _finishHistorical(work, epoch);
          _pendingReservations.remove(_key(work.job));
        } else {
          await _cleanupWork(work, epoch);
        }
      }
      cursor = page.nextCursor;
    } while (cursor != null);
  }

  Future<void> _cleanupWork(IosTransferImportWork work, int epoch) async {
    final key = _key(work.job);
    IosTransferCleanupLease? lease;
    try {
      lease = await native.claimImportCleanup(work);
      _activeCleanup = lease;
      _check(epoch);
      lease.validateFor(work);
      var decision = await _store!.peek(work.job, work.target);
      _check(epoch);
      if (decision == null || decision.receipt.localSongId != lease.songId) {
        _issues[key] = IosTransferCoordinatorIssue.missingReservation;
        return;
      }
      final active = lease;
      Future<void> guard() => native.validateImportCleanup(active);
      if (decision.committed && lease.currentRevision == work.job.revision) {
        // Current importing/complete history uses the ordinary receipt-only
        // acknowledgement. Never turn committed data into abandonment.
        await _releaseCleanup(active);
        _activeCleanup = null;
        lease = null;
        _check(epoch);
        await _import(work.job, epoch);
        _pendingReservations.remove(key);
        return;
      }
      final mode = decision.committed
          ? IosTransferCleanupMode.committed
          : IosTransferCleanupMode.abandoned;
      if (lease.resolution != null && lease.resolution!.mode != mode) {
        _issues[key] = IosTransferCoordinatorIssue.conflict;
        return;
      }
      if (!decision.committed) {
        if (decision.receipt.state == 'retired' && lease.resolution == null) {
          _issues[key] = IosTransferCoordinatorIssue.cleanupRequired;
          return;
        }
        decision = (await _store!.beginRetirement(
          work.job,
          work.target,
          isCurrent: () => _current(epoch),
          validateCleanupAuthority: guard,
        ))!;
        _check(epoch);
      }
      if (lease.resolution == null) {
        final handled = await native.resolveImportCleanup(
          active,
          receipt: decision.receipt,
        );
        _check(epoch);
        handled.validateFor(active, mode);
      }
      if (!decision.committed && decision.receipt.state != 'retired') {
        decision = (await _store!.retireReservation(
          work.job,
          work.target,
          isCurrent: () => _current(epoch),
          validateOwnership: guard,
        ))!;
        _check(epoch);
      }
      await native.finalizeImportCleanup(active, receipt: decision.receipt);
      _check(epoch);
      _pendingReservations.remove(key);
      _frozen.remove(key);
      _completed.add(key);
      _issues.remove(key);
    } catch (error) {
      if (_current(epoch)) {
        _issues[key] = _classify(error);
        _needsRecovery = true;
      }
    } finally {
      try {
        if (lease != null) await _releaseCleanup(lease);
      } finally {
        if (identical(_activeCleanup, lease)) _activeCleanup = null;
      }
    }
  }

  Future<void> _finishHistorical(IosTransferImportWork work, int epoch) async {
    IosTransferImportLease? lease;
    try {
      lease = await native.claimImport(work.job, reconcileOnly: true);
      _active = lease;
      _check(epoch);
      final result = await _store!.peek(lease.job, lease.target);
      _check(epoch);
      if (result == null ||
          !result.committed ||
          result.receipt.localSongId != work.songId) {
        _issues[_key(work.job)] =
            IosTransferCoordinatorIssue.missingReservation;
        return;
      }
      await native.acknowledgeImport(lease, songId: work.songId);
      _check(epoch);
      _completed.add(_key(work.job));
    } catch (error) {
      if (_current(epoch)) _issues[_key(work.job)] = _classify(error);
    } finally {
      try {
        if (lease != null) await _release(lease);
      } finally {
        if (identical(_active, lease)) _active = null;
      }
    }
  }

  Future<void> _import(IosTransferJob job, int epoch) async {
    final key = _key(job);
    IosTransferImportLease? lease;
    _activeCancellation = Completer<void>();
    try {
      if (job.phase == IosTransferPhase.downloaded) {
        job = await native.verify(job);
        _check(epoch);
      }
      IosTransferImportResult? previous;
      if ({
        IosTransferPhase.validating,
        IosTransferPhase.importing,
      }.contains(job.phase)) {
        lease = await native.claimImport(job, reconcileOnly: true);
        _active = lease;
        _check(epoch);
        previous = await _store!.peek(lease.job, lease.target);
        _check(epoch);
        if (previous?.committed == true) {
          await _acknowledge(lease, previous!, epoch);
          _completed.add(key);
          return;
        }
        await _release(lease);
        _active = null;
        lease = null;
        _check(epoch);
      }
      lease = await native.claimImport(job);
      _active = lease;
      _check(epoch);
      final active = lease;
      Future<void> guard() => native.validateImport(active);
      previous ??= await _store!.peek(active.job, active.target);
      _check(epoch);
      final frozen = _frozen[key];
      if (frozen != null &&
          (previous == null || frozen.songId != previous.receipt.localSongId)) {
        _issues[key] = IosTransferCoordinatorIssue.missingReservation;
        return;
      }
      var prepared = await _store!.prepare(
        active.job,
        active.target,
        isCurrent: () => _current(epoch),
        validateOwnership: guard,
      );
      _check(epoch);
      if (prepared.committed) {
        await _acknowledge(active, prepared, epoch);
        _completed.add(key);
        return;
      }
      var media = prepared.validatedMedia;
      if (media == null) {
        if (active.sourcePath == null) {
          _issues[key] = IosTransferCoordinatorIssue.missingValidation;
          return;
        }
        media = await readMedia(
          active,
          isCurrent: () => _current(epoch),
          validateOwnership: guard,
          cancelled: _activeCancellation!.future,
        );
        _check(epoch);
        prepared = await _store!.recordMediaValidation(
          active.job,
          active.target,
          media,
          isCurrent: () => _current(epoch),
          validateOwnership: guard,
        );
        _check(epoch);
      }
      final published = await native.publishImport(
        active,
        songId: prepared.receipt.localSongId,
      );
      _check(epoch);
      published.validateFor(active, songId: prepared.receipt.localSongId);
      final committed = await _store!.commit(
        published.job,
        published.receipt,
        media,
        isCurrent: () => _current(epoch),
        validateOwnership: guard,
      );
      _check(epoch);
      await _acknowledge(active, committed, epoch);
      _completed.add(key);
      _frozen.remove(key);
      _issues.remove(key);
    } catch (error) {
      if (_current(epoch)) {
        _issues[key] = _classify(error);
        _needsRecovery = true;
      }
    } finally {
      try {
        if (lease != null) await _release(lease);
      } finally {
        if (identical(_active, lease)) _active = null;
        _activeCancellation = null;
        _notify();
      }
    }
  }

  Future<void> _acknowledge(
    IosTransferImportLease lease,
    IosTransferImportResult result,
    int epoch,
  ) async {
    if (!result.committed) {
      throw const FormatException('Uncommitted import cannot be acknowledged.');
    }
    final completed = await native.acknowledgeImport(
      lease,
      songId: result.receipt.localSongId,
    );
    _check(epoch);
    if (completed.phase != IosTransferPhase.complete) {
      throw const FormatException('Incomplete native acknowledgement.');
    }
  }

  IosTransferCoordinatorIssue _classify(Object error) {
    if (error is IosTransferImportException) {
      return IosTransferCoordinatorIssue.conflict;
    }
    if (error is FormatException) {
      return IosTransferCoordinatorIssue.invalidProtocol;
    }
    if (error is IosTransferMediaException) {
      return switch (error.reason) {
        IosTransferMediaFailure.invalid =>
          IosTransferCoordinatorIssue.invalidMedia,
        IosTransferMediaFailure.timeout =>
          IosTransferCoordinatorIssue.mediaTimeout,
        _ => IosTransferCoordinatorIssue.mediaUnavailable,
      };
    }
    return IosTransferCoordinatorIssue.transport;
  }

  /// Revoke app writes before a caller takes the actual Isar clear/delete
  /// writer barrier. Native OS-task cancellation and submission epochs must
  /// also be integrated by that caller before product import is enabled.
  Future<void> pauseForMutation() async {
    _enabled = false;
    _epoch++;
    _dirty = false;
    _cancelActive();
    final active = _active;
    if (active != null) await _release(active);
    final cleanup = _activeCleanup;
    if (cleanup != null) await _releaseCleanup(cleanup);
    await _running;
    await _starting;
    await _foregrounding;
    await native.drainImports();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _enabled = false;
    _epoch++;
    _cancelActive();
    final active = _active;
    if (active != null) {
      try {
        await _release(active);
      } catch (_) {}
    }
    final cleanup = _activeCleanup;
    if (cleanup != null) {
      try {
        await _releaseCleanup(cleanup);
      } catch (_) {}
    }
    await _running;
    await _starting;
    await _foregrounding;
    await _observation?.cancel();
    await _updates.close();
  }
}
