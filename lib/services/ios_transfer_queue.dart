import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/ios_transfer_models.dart';
import 'ios_transfer_transport.dart';

enum IosTransferQueueNotice {
  none,
  unavailable,
  refreshFailed,
  changed,
  actionFailed,
  noMatch,
  cleanupPending,
}

enum IosTransferQueueAction {
  cancel,
  retryDownload,
  prepareUpload,
  matchUpload,
  cleanupUpload,
}

/// A foreground view of the native journal, borrowing the app-root transport.
/// No second journal, automatic POST retry or per-screen native client owner.
class IosTransferQueueController extends ChangeNotifier {
  IosTransferQueueController({
    required this.native,
    required this.ensureReady,
    required this.prepareUpload,
    this.recoverSession,
  });
  final IosTransferTransport native;
  final Future<void> Function() ensureReady;
  final Future<void> Function(IosTransferJob job) prepareUpload;
  final Future<void> Function()? recoverSession;
  StreamSubscription<void>? _observation;
  Timer? _debounce;
  Future<void>? _starting, _refreshing;
  bool _disposed = false, _loading = false, _available = false, _stale = true;
  int _limit = 50;
  String? _acting;
  List<IosTransferJob> _jobs = const [];
  IosTransferSummary? _summary;
  IosTransferQueueNotice _notice = IosTransferQueueNotice.none;
  bool get loading => _loading;
  bool get available => _available;
  bool get stale => _stale;
  String? get acting => _acting;
  List<IosTransferJob> get jobs => _jobs;
  IosTransferSummary? get summary => _summary;
  IosTransferQueueNotice get notice => _notice;
  bool get hasMore => _jobs.length < (_summary?.total ?? 0);
  bool get canRecover =>
      !_disposed &&
      _available &&
      !_loading &&
      _acting == null &&
      recoverSession != null &&
      native.acceptingSubmissions;
  bool get canAct =>
      !_disposed &&
      _available &&
      !_loading &&
      !_stale &&
      _acting == null &&
      _summary?.persistenceFailed == false &&
      native.acceptingSubmissions;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start() => _starting ??= _start();
  Future<void> _start() async {
    _loading = true;
    _notify();
    try {
      final capability = await native.capability();
      if (_disposed) return;
      if (!capability.canCopyToLibrary || !capability.upload) {
        _notice = IosTransferQueueNotice.unavailable;
        return;
      }
      await ensureReady();
      if (_disposed) return;
      _available = true;
      _observation = native.changes.listen(
        (_) {
          _debounce ??= Timer(const Duration(milliseconds: 300), () {
            _debounce = null;
            unawaited(refresh());
          });
        },
        onError: (Object _) {
          _stale = true;
          _notice = IosTransferQueueNotice.refreshFailed;
          _notify();
        },
      );
      await refresh();
    } catch (_) {
      if (!_disposed) {
        _stale = true;
        _notice = IosTransferQueueNotice.refreshFailed;
      }
    } finally {
      _loading = false;
      _notify();
    }
  }

  Future<void> reload() {
    if (_disposed) return Future.value();
    if (_available) return refresh();
    _starting = null;
    return start();
  }

  Future<void> recoverStorage() async {
    if (!canRecover || _summary?.persistenceFailed != true) return;
    _acting = 'recovery';
    _notice = IosTransferQueueNotice.none;
    _notify();
    try {
      await recoverSession!();
    } catch (_) {
      if (!_disposed) _notice = IosTransferQueueNotice.actionFailed;
    } finally {
      _acting = null;
      if (!_disposed) {
        await refresh();
        if (_summary?.persistenceFailed == true) {
          _notice = IosTransferQueueNotice.actionFailed;
        }
      }
      _notify();
    }
  }

  Future<void> refresh() {
    if (_disposed || !_available) return Future.value();
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<void> _refresh() async {
    _loading = true;
    _notify();
    try {
      // A journal generation must surround all pages. Progress can advance in
      // the final summary without changing the durable job generation.
      for (var attempt = 0; attempt < 2; attempt++) {
        final before = await native.summary();
        if (_disposed) return;
        final rows = <IosTransferJob>[];
        final count = math.min(_limit, before.total);
        while (rows.length < count) {
          final page = await native.page(
            offset: rows.length,
            limit: math.min(100, count - rows.length),
          );
          if (_disposed) return;
          if (page.isEmpty) break;
          rows.addAll(page);
        }
        final after = await native.summary();
        if (_disposed) return;
        if (before.generation != after.generation ||
            before.total != after.total ||
            rows.length != count ||
            rows.map((row) => row.id).toSet().length != rows.length) {
          continue;
        }
        _jobs = List.unmodifiable(rows);
        _summary = after;
        _stale = false;
        if (_notice == IosTransferQueueNotice.refreshFailed ||
            _notice == IosTransferQueueNotice.changed) {
          _notice = IosTransferQueueNotice.none;
        }
        return;
      }
      _stale = true;
      _notice = IosTransferQueueNotice.changed;
    } catch (_) {
      if (!_disposed) {
        _stale = true;
        _notice = IosTransferQueueNotice.refreshFailed;
      }
    } finally {
      _loading = false;
      _notify();
    }
  }

  Future<void> loadMore() async {
    if (_disposed || _loading || !hasMore) return;
    _limit = math.min(iosTransferMaximumJobs, _limit + 50);
    await refresh();
  }

  Set<IosTransferQueueAction> actions(IosTransferJob job) => {
    if (job.phase.canCancel) IosTransferQueueAction.cancel,
    if (job.direction == 'download' && job.phase.canRetry)
      IosTransferQueueAction.retryDownload,
    if (job.direction == 'upload') ...{
      if ({
        IosTransferPhase.queued,
        IosTransferPhase.waiting,
      }.contains(job.phase))
        IosTransferQueueAction.prepareUpload,
      if ({
        IosTransferPhase.interrupted,
        IosTransferPhase.failed,
      }.contains(job.phase))
        IosTransferQueueAction.matchUpload,
      if ({
        IosTransferPhase.complete,
        IosTransferPhase.cancelled,
      }.contains(job.phase))
        IosTransferQueueAction.cleanupUpload,
    },
  };

  bool canActOn(IosTransferJob job, IosTransferQueueAction action) =>
      canAct &&
      (action == IosTransferQueueAction.cancel ||
          action == IosTransferQueueAction.cleanupUpload ||
          !(_summary?.pauses.any(
                (pause) =>
                    jsonEncode(pause.scope.toJson()) ==
                    jsonEncode(job.intent.identity.scope.toJson()),
              ) ??
              false));

  Future<void> resumePause(IosTransferPause pause) async {
    if (!canAct ||
        pause.reason == 'pairingChanged' ||
        !(_summary?.pauses.any(
              (current) =>
                  current.reason == pause.reason &&
                  jsonEncode(current.scope.toJson()) ==
                      jsonEncode(pause.scope.toJson()),
            ) ??
            false)) {
      return;
    }
    _acting = 'connection';
    _notice = IosTransferQueueNotice.none;
    _notify();
    try {
      await native.resumeFromQueue(pause.scope);
    } catch (_) {
      if (!_disposed) _notice = IosTransferQueueNotice.actionFailed;
    } finally {
      _acting = null;
      if (!_disposed) await refresh();
      _notify();
    }
  }

  Future<void> act(IosTransferJob job, IosTransferQueueAction action) async {
    if (!canActOn(job, action) ||
        !actions(job).contains(action) ||
        !_jobs.any(
          (row) =>
              row.id == job.id &&
              row.revision == job.revision &&
              row.phase == job.phase &&
              jsonEncode(row.intent.toJson()) ==
                  jsonEncode(job.intent.toJson()),
        )) {
      return;
    }
    _acting = job.id;
    _notice = IosTransferQueueNotice.none;
    _notify();
    try {
      switch (action) {
        case IosTransferQueueAction.cancel:
          final cancelled = await native.cancelFromQueue(job);
          if (cancelled.direction == 'upload' && !_disposed) {
            try {
              await native.cleanupUploadBody(cancelled);
            } catch (_) {
              _notice = IosTransferQueueNotice.cleanupPending;
            }
          }
        case IosTransferQueueAction.retryDownload:
          await native.retryDownloadFromQueue(job);
        case IosTransferQueueAction.prepareUpload:
          await prepareUpload(job);
        case IosTransferQueueAction.matchUpload:
          final matched = await native.matchUploadedOriginal(job);
          if (matched == null) {
            _notice = IosTransferQueueNotice.noMatch;
          } else if (!_disposed) {
            try {
              await native.cleanupUploadBody(matched);
            } catch (_) {
              _notice = IosTransferQueueNotice.cleanupPending;
            }
          }
        case IosTransferQueueAction.cleanupUpload:
          await native.cleanupUploadBody(job);
      }
    } catch (_) {
      if (!_disposed) _notice = IosTransferQueueNotice.actionFailed;
    } finally {
      _acting = null;
      if (!_disposed) await refresh();
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    unawaited(_observation?.cancel());
    // The root session, not this screen, owns native/coordinator disposal.
    super.dispose();
  }
}
