import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';

import '../data/entities/ios_transfer_receipt_entity.dart';

import '../models/ios_transfer_models.dart';
import '../models/ios_transfer_import.dart';
import '../models/ios_transfer_recovery.dart';
import '../models/ios_transfer_cleanup.dart';
import '../models/ios_transfer_orphan.dart';
import 'link/link_protocol.dart' show linkUuid;
import 'ios_transfer_coordinator_port.dart';

Uint8List _prepareIntents(List<IosTransferIntent> intents, String clientId) {
  if (intents.isEmpty ||
      intents.length > iosTransferMaximumJobs ||
      intents.map((intent) => intent.id).toSet().length != intents.length) {
    throw const FormatException('Invalid transfer batch.');
  }
  for (final intent in intents) {
    intent.validate(submission: true);
    if ((intent.expectedBytes ?? 0) > 8 * 1024 * 1024 * 1024) {
      throw const FormatException('Transfer file exceeds its size limit.');
    }
  }
  final bytes = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'clientID': clientId,
        'intents': [for (final intent in intents) intent.toJson()],
      }),
    ),
  );
  if (bytes.length > iosTransferMaximumBytes) {
    throw const FormatException('Transfer request exceeds its byte limit.');
  }
  return bytes;
}

// Keep the isolate closure outside the transport's lexical context. A local
// ownership-check closure can otherwise capture the transport and its Futures.
Future<Uint8List> _encodeSubmission(
  List<IosTransferIntent> intents,
  String clientId,
) => Isolate.run(() => _prepareIntents(intents, clientId));

/// One application coordinator owns this transport. Native storage/networking
/// survives Dart/engine replacement; this class owns only typed calls and the
/// foreground change subscription. No credentials or durable Dart journal.
class IosTransferTransport implements IosTransferCoordinatorPort {
  IosTransferTransport({
    this.channel = const MethodChannel('lokal/transfers'),
    bool? supported,
  }) : supported = supported ?? Platform.isIOS {
    _changes = StreamController<void>.broadcast(
      onListen: () {
        final ready = _start();
        _observationReady = ready;
        unawaited(ready);
      },
      onCancel: () => unawaited(_stop()),
    );
  }

  static final _owners = <(BinaryMessenger, String), IosTransferTransport>{};
  final MethodChannel channel;
  final bool supported;
  late final StreamController<void> _changes;
  bool _disposed = false;
  String? _subscription;
  String? _observedClient;
  Future<void>? _observationReady;
  final _submissions = <Future<IosTransferSummary>>{};
  int _submissionEpoch = 0;
  bool _submissionsPaused = false;
  (BinaryMessenger, String) get _key => (channel.binaryMessenger, channel.name);
  @override
  Stream<void> get changes => _changes.stream;

  Future<Object?> _call(String method, [Object? payload]) async {
    if (!supported || _disposed) {
      throw StateError('Native transfer transport unavailable.');
    }
    final Uint8List? bytes;
    if (payload == null) {
      bytes = null;
    } else {
      bytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
      final budget = method == 'enqueue' ? iosTransferMaximumBytes : 8192;
      if (bytes.length > budget) {
        throw const FormatException('Transfer request exceeds its byte limit.');
      }
    }
    return _invoke(method, bytes);
  }

  Future<Object?> _invoke(String method, Uint8List? bytes) async {
    if (!supported || _disposed) {
      throw StateError('Native transfer transport unavailable.');
    }
    final raw = await channel.invokeMethod<Object?>(method, bytes);
    if (raw is! Uint8List ||
        raw.isEmpty ||
        raw.length > iosTransferMaximumBytes) {
      throw const FormatException('Invalid native transfer response.');
    }
    try {
      return jsonDecode(utf8.decode(raw, allowMalformed: false));
    } on FormatException {
      // JSON exceptions otherwise quote the response, including music metadata.
      throw const FormatException('Invalid native transfer response.');
    }
  }

  @override
  Future<IosTransferCapability> capability() async {
    if (!supported) return const IosTransferCapability(available: false);
    try {
      return IosTransferCapability.fromJson(await _call('capability'));
    } on MissingPluginException {
      return const IosTransferCapability(available: false);
    }
  }

  Future<IosTransferPairing?> currentPairing() async {
    final raw = await _call('currentPairing');
    return raw == null ? null : IosTransferPairing.fromJson(raw);
  }

  Future<IosTransferSummary> summary() async =>
      IosTransferSummary.fromJson(await _call('summary'));
  @override
  Future<IosTransferSummary> recover() async =>
      IosTransferSummary.fromJson(await _call('recover'));

  Future<List<IosTransferJob>> page({int offset = 0, int limit = 100}) async {
    if (offset < 0 ||
        offset > iosTransferMaximumJobs ||
        limit < 1 ||
        limit > 100) {
      throw const FormatException('Invalid transfer page.');
    }
    final raw = await _call('page', {'offset': offset, 'limit': limit});
    if (raw is! List || raw.length > limit) {
      throw const FormatException('Invalid native transfer page.');
    }
    return List.unmodifiable(raw.map(IosTransferJob.fromJson));
  }

  Future<IosTransferSummary> enqueue(List<IosTransferIntent> intents) {
    final task = _enqueue(intents, _submissionEpoch);
    _submissions.add(task);
    return task.whenComplete(() => _submissions.remove(task));
  }

  Future<IosTransferSummary> _enqueue(
    List<IosTransferIntent> intents,
    int epoch,
  ) async {
    if (!supported || _disposed || _submissionsPaused) {
      throw StateError('Native transfer transport unavailable.');
    }
    final client = _subscription, ready = _observationReady;
    if (client == null || ready == null) {
      throw StateError('Submission requires the active root transfer client.');
    }
    // Freeze consent before the first await; large plans are validated/encoded
    // away from the audio/UI isolate and submitted as one native transaction.
    final frozen = List<IosTransferIntent>.unmodifiable(intents);
    void check() {
      if (_disposed ||
          _submissionsPaused ||
          _submissionEpoch != epoch ||
          _subscription != client ||
          _observedClient != client ||
          !identical(_owners[_key], this)) {
        throw StateError('Transfer submission was retired.');
      }
    }

    await ready;
    check();
    final bytes = await _encodeSubmission(frozen, client);
    check();
    final result = await _invoke('enqueue', bytes);
    check();
    return IosTransferSummary.fromJson(result);
  }

  /// Fence app encoding synchronously, then invalidate already dispatched
  /// native tickets and await their replies. This is not OS task cancellation
  /// or the final storage clear barrier; the mutation owner must perform both.
  @override
  Future<void> pauseSubmissions() {
    _submissionsPaused = true;
    _submissionEpoch++;
    final pending = _submissions.toList();
    final fence = _subscription == null
        ? Future<Object?>.value(true)
        : _importCall('retireSubmissions', {});
    return () async {
      try {
        if (await fence != true) {
          throw const FormatException(
            'Invalid native submission retirement response.',
          );
        }
      } finally {
        await Future.wait([
          for (final task in pending)
            task.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        ]);
      }
    }();
  }

  @override
  void resumeSubmissions() {
    if (!_disposed) _submissionsPaused = false;
  }

  Future<IosTransferJob> _control(String method, IosTransferJob job) async {
    return IosTransferJob.fromJson(
      await _call(method, {'id': job.id, 'revision': job.revision}),
    );
  }

  Future<IosTransferJob> cancel(IosTransferJob job) => _control('cancel', job);
  Future<IosTransferJob> retry(IosTransferJob job) => _control('retry', job);
  @override
  Future<IosTransferJob> verify(IosTransferJob job) => _control('verify', job);

  Future<Object?> _importCall(
    String method,
    Map<String, Object> payload,
  ) async {
    final client = _subscription;
    final ready = _observationReady;
    if (client == null || ready == null) {
      throw StateError('Import requires the active root transfer client.');
    }
    await ready;
    void checkOwner() {
      if (_disposed ||
          !supported ||
          _subscription != client ||
          _observedClient != client ||
          !identical(_owners[_key], this)) {
        throw StateError('Import transfer client was replaced.');
      }
    }

    checkOwner();
    if (payload['clientID'] != null && payload['clientID'] != client) {
      throw StateError('Import lease belongs to a retired transfer client.');
    }
    final result = await _call(method, {...payload, 'clientID': client});
    checkOwner();
    return result;
  }

  /// Private integration boundary; capability.libraryImport stays false until
  @override
  Future<IosTransferImportWorkPage> importWorkPage({
    IosTransferWorkCursor? after,
    int limit = 100,
  }) async {
    if (limit < 1 || limit > 100) {
      throw const FormatException('Invalid import recovery page size.');
    }
    return IosTransferImportWorkPage.fromJson(
      await _importCall('importWorkPage', {
        if (after != null) 'after': after.value,
        'limit': limit,
      }),
      limit: limit,
      after: after,
    );
  }

  @override
  Future<IosTransferImportCandidatePage> importCandidatesPage({
    IosTransferWorkCursor? after,
    int limit = 100,
  }) async {
    if (limit < 1 || limit > 100) {
      throw const FormatException('Invalid import candidate page size.');
    }
    return IosTransferImportCandidatePage.fromJson(
      await _importCall('importCandidatesPage', {
        if (after != null) 'after': after.value,
        'limit': limit,
      }),
      limit: limit,
      after: after,
    );
  }

  @override
  Future<void> drainImports() async {
    if (await _importCall('drainImports', {}) != true) {
      throw const FormatException('Invalid native import drainage response.');
    }
  }

  /// Private iPhone unlink primitive. The native journal atomically retires
  /// the exact pairing's network revisions, cancels its URLSession tasks and
  /// waits for callbacks plus outstanding native file work. It does NOT attest
  /// Isar/public-file retirement and must be called only inside the root
  /// mutation fence before removing pairing credentials.
  Future<IosTransferSummary> retireNetworkScope(IosTransferScope scope) async {
    scope.validate();
    return IosTransferSummary.fromJson(
      await _importCall('retireNetworkScope', {'scope': scope.toJson()}),
    );
  }

  /// Private cleanup claim only; product activation and the Isar decision are
  /// separate. Native revokes publication before draining the old file worker.
  @override
  Future<IosTransferCleanupLease> claimImportCleanup(
    IosTransferImportWork work,
  ) async {
    final claim = IosTransferCleanupLease.fromJson(
      await _importCall('claimImportCleanup', {
        'id': work.job.id,
        'revision': work.job.revision,
      }),
    );
    if (claim.clientId != _subscription) {
      throw StateError('Cleanup belongs to a retired transfer client.');
    }
    claim.validateFor(work);
    return claim;
  }

  @override
  Future<void> validateImportCleanup(IosTransferCleanupLease lease) async {
    if (await _importCall('validateImportCleanup', lease.control) != true) {
      throw const FormatException('Invalid native cleanup guard response.');
    }
  }

  @override
  Future<void> releaseImportCleanup(IosTransferCleanupLease lease) async {
    if (await _importCall('releaseImport', lease.control) != true) {
      throw const FormatException('Invalid native cleanup release response.');
    }
  }

  @override
  Future<IosTransferOrphanLease> claimOrphanCleanup(
    IosTransferWorkCursor key, {
    required int songId,
  }) async {
    if (songId < 1 || songId >= 9223372036854775807) {
      throw const FormatException('Invalid orphan Song identity.');
    }
    final lease = IosTransferOrphanLease.fromJson(
      await _importCall('claimOrphanCleanup', {
        'id': key.jobId,
        'revision': key.revision,
        'songID': songId,
      }),
    );
    if (lease.clientId != _subscription ||
        lease.key.value != key.value ||
        lease.songId != songId) {
      throw StateError(
        'Orphan recovery belongs to another reservation or client.',
      );
    }
    return lease;
  }

  @override
  Future<void> validateOrphanCleanup(IosTransferOrphanLease lease) async {
    if (await _importCall('validateOrphanCleanup', lease.control) != true) {
      throw const FormatException('Invalid orphan recovery guard response.');
    }
  }

  @override
  Future<void> releaseOrphanCleanup(IosTransferOrphanLease lease) async {
    if (await _importCall('releaseImport', lease.control) != true) {
      throw const FormatException('Invalid orphan recovery release response.');
    }
  }

  Map<String, Object> _cleanupDecision(
    IosTransferCleanupLease lease,
    IosTransferReceiptEntity receipt, {
    required bool finalized,
  }) {
    final job = lease.job, identity = lease.job.intent.identity;
    final committed = receipt.state == 'committed';
    if (receipt.id < 1 ||
        receipt.schemaVersion != 1 ||
        receipt.operationKey != '${job.id}:${job.revision}' ||
        receipt.jobId != job.id ||
        receipt.revision != job.revision ||
        receipt.localSongId != lease.songId ||
        receipt.serverId != identity.localServerId ||
        receipt.desktopId != identity.scope.desktopId ||
        receipt.desktopUserId != identity.desktopUserId ||
        receipt.pairingId != identity.scope.pairingId ||
        receipt.origin != identity.scope.origin ||
        receipt.sourceId != identity.sourceId ||
        receipt.relativePath != lease.target.relativePath ||
        receipt.bytes != job.receivedBytes ||
        receipt.sha256 != job.receivedSha256 ||
        committed != (receipt.committedAt != null) ||
        (committed && !lease.publicationRecorded) ||
        (!committed && receipt.state != (finalized ? 'retired' : 'retiring'))) {
      throw const FormatException(
        'Cleanup requires the exact durable Isar decision.',
      );
    }
    return {
      ...lease.control,
      'songID': lease.songId,
      'mode': committed ? 'committed' : 'abandoned',
      'isarState': receipt.state,
    };
  }

  /// Caller has crossed the actual Isar writer barrier. Passing a prepared
  /// receipt cannot authorize deletion, and committed history always preserves
  /// public Music. Native retains provenance after the returned resolution.
  @override
  Future<IosTransferResolvedCleanup> resolveImportCleanup(
    IosTransferCleanupLease lease, {
    required IosTransferReceiptEntity receipt,
  }) async {
    final payload = _cleanupDecision(lease, receipt, finalized: false);
    final mode = payload['mode'] == 'committed'
        ? IosTransferCleanupMode.committed
        : IosTransferCleanupMode.abandoned;
    final result = IosTransferResolvedCleanup.fromJson(
      await _importCall('resolveImportCleanup', payload),
    );
    result.validateFor(lease, mode);
    return result;
  }

  /// Only after Isar retirement (or durable committed history). This removes
  /// native bookkeeping, not files or Songs, then the caller releases cleanup.
  @override
  Future<void> finalizeImportCleanup(
    IosTransferCleanupLease lease, {
    required IosTransferReceiptEntity receipt,
  }) async {
    if (await _importCall(
          'finalizeImportCleanup',
          _cleanupDecision(lease, receipt, finalized: true),
        ) !=
        true) {
      throw const FormatException('Invalid native cleanup finalization.');
    }
  }

  /// Private integration boundary; capability.libraryImport stays false until
  /// the media/database/scanner/clear/unpair coordinator is accepted.
  @override
  Future<IosTransferImportLease> claimImport(
    IosTransferJob job, {
    bool reconcileOnly = false,
  }) async {
    final lease = IosTransferImportLease.fromJson(
      await _importCall('claimImport', {
        'id': job.id,
        'revision': job.revision,
        'reconcileOnly': reconcileOnly,
      }),
    );
    if (lease.clientId != _subscription) {
      throw StateError(
        'Native import reply belongs to another transfer client.',
      );
    }
    if (lease.job.id != job.id ||
        lease.job.revision != job.revision ||
        lease.reconcileOnly != reconcileOnly ||
        (job.receivedBytes != null &&
            job.receivedBytes != lease.job.receivedBytes) ||
        (job.receivedSha256 != null &&
            job.receivedSha256 != lease.job.receivedSha256) ||
        jsonEncode(lease.job.intent.toJson()) !=
            jsonEncode(job.intent.toJson())) {
      throw const FormatException(
        'Native import claim changed its frozen intent.',
      );
    }
    return lease;
  }

  /// Private publication only; the root coordinator must still prove media and
  /// atomically commit its prepared Song plus Isar receipt before completion.
  @override
  Future<IosTransferPublishedImport> publishImport(
    IosTransferImportLease lease, {
    required int songId,
  }) async {
    if (lease.reconcileOnly || songId < 1) {
      throw StateError(
        'Publication requires a writer and prepared Song identity.',
      );
    }
    final result = IosTransferPublishedImport.fromJson(
      await _importCall('publishImport', {...lease.control, 'songID': songId}),
    );
    result.validateFor(lease, songId: songId);
    return result;
  }

  /// The root must first prove its durable committed Isar receipt. This call
  /// only acknowledges native job history and drains private retained staging.
  @override
  Future<IosTransferJob> acknowledgeImport(
    IosTransferImportLease lease, {
    required int songId,
  }) async {
    if (songId < 1) {
      throw const FormatException('Invalid completed Song identity.');
    }
    final result = IosTransferJob.fromJson(
      await _importCall('acknowledgeImport', {
        ...lease.control,
        'songID': songId,
      }),
    );
    if (result.phase != IosTransferPhase.complete ||
        result.id != lease.job.id ||
        result.revision != lease.job.revision ||
        result.receivedBytes != lease.job.receivedBytes ||
        result.receivedSha256 != lease.job.receivedSha256 ||
        jsonEncode(result.intent.toJson()) !=
            jsonEncode(lease.job.intent.toJson())) {
      throw const FormatException('Invalid native import completion.');
    }
    return result;
  }

  @override
  Future<void> validateImport(
    IosTransferImportLease lease, {
    bool requiresWrite = true,
  }) async {
    if (requiresWrite && lease.reconcileOnly) {
      throw StateError(
        'Receipt reconciliation cannot authorize a library write.',
      );
    }
    final result = await _importCall(
      requiresWrite ? 'validateImport' : 'validateImportReconciliation',
      lease.control,
    );
    if (result != true) {
      throw const FormatException('Invalid native import guard response.');
    }
  }

  @override
  Future<void> releaseImport(IosTransferImportLease lease) async {
    final result = await _importCall('releaseImport', lease.control);
    if (result != true) {
      throw const FormatException('Invalid native import release response.');
    }
  }

  Future<IosTransferSummary> resume(IosTransferScope scope) async {
    scope.validate();
    return IosTransferSummary.fromJson(await _call('resume', scope.toJson()));
  }

  Future<void> _start() async {
    if (!supported || _disposed) return;
    final id = linkUuid();
    _subscription = id;
    _owners[_key] = this;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'changed' || call.arguments != null) {
        throw MissingPluginException();
      }
      if (!_disposed &&
          identical(_owners[_key], this) &&
          _subscription == id &&
          !_changes.isClosed) {
        _changes.add(null);
      }
    });
    try {
      await channel.invokeMethod<void>(
        'observe',
        Uint8List.fromList(utf8.encode(jsonEncode({'clientID': id}))),
      );
      if (!_disposed && _subscription == id && identical(_owners[_key], this)) {
        _observedClient = id;
      }
      if (_disposed || _subscription != id || !identical(_owners[_key], this)) {
        await _stopNative(id);
      }
    } catch (error, stack) {
      if (!_disposed &&
          _subscription == id &&
          identical(_owners[_key], this) &&
          !_changes.isClosed) {
        _changes.addError(error, stack);
      }
    }
  }

  Future<void> _stopNative(String id) async {
    await channel.invokeMethod<void>(
      'stopObserving',
      Uint8List.fromList(utf8.encode(jsonEncode({'clientID': id}))),
    );
  }

  Future<void> _stop() async {
    _submissionEpoch++;
    _submissionsPaused = true;
    final id = _subscription;
    _subscription = null;
    _observedClient = null;
    _observationReady = null;
    if (!supported || id == null) return;
    if (identical(_owners[_key], this)) {
      _owners.remove(_key);
      channel.setMethodCallHandler(null);
    }
    try {
      await _stopNative(id);
    } on MissingPluginException {
      // An engine from before this protocol has no native observation to stop.
    } on PlatformException {
      // Detaching the UI does not revoke persisted jobs or the native owner.
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _stop();
    await Future.wait([
      for (final task in _submissions.toList())
        task.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    ]);
    await _changes.close();
  }
}
