// Actual Isar/app coordinator and actual fixture file I/O. The native port is
// explicitly a fixture; --ffprobe additionally uses the real host reader.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:isar_community/isar.dart';
import 'package:flick/data/entities/ios_transfer_receipt_entity.dart';
import 'package:flick/data/entities/song_entity.dart';
import 'package:flick/models/ios_transfer_import.dart';
import 'package:flick/models/ios_transfer_cleanup.dart';
import 'package:flick/models/ios_transfer_models.dart';
import 'package:flick/models/ios_transfer_recovery.dart';
import 'package:flick/models/ios_transfer_orphan.dart';
import 'package:flick/services/ios_transfer_coordinator_port.dart';
import 'package:flick/services/ios_transfer_import_coordinator.dart';
import 'package:flick/services/ios_transfer_import_store.dart'
    show IosTransferImportResult;
import 'package:flick/services/ios_transfer_media.dart';

import 'ios_import_store_contracts.dart' show Fixture, require;

class NativeFixture implements IosTransferCoordinatorPort {
  NativeFixture(this.fixture);
  final Fixture fixture;
  final events = StreamController<void>.broadcast();
  String phase = 'staged';
  bool enabled = true, staging = true, published = false, cleaned = false;
  bool losePublicationReply = false;
  int publications = 0,
      acknowledgements = 0,
      workReads = 0,
      candidateReads = 0,
      drains = 0;
  int capabilityFailures = 0;
  Completer<void>? startupDrain, startupDrainEntered;
  int? songId;
  int sequence = 0;
  IosTransferImportLease? active;
  IosTransferCleanupLease? activeCleanup;
  IosTransferOrphanLease? activeOrphan;
  int orphanClaims = 0;
  IosTransferCleanupResolution? resolution;
  int cleanupCalls = 0, finalizations = 0;
  int recoveries = 0;
  int submissionPauses = 0, submissionResumes = 0;
  Completer<void>? recoveryEntered, recoveryWait;
  bool loseCleanupReply = false, loseFinalizationReply = false;
  final released = Completer<void>();
  static const client = 'b7d96b93-6526-4f1f-a1af-688ffb5c799d';
  IosTransferJob get job => fixture.job(phase);
  int get currentRevision => phase == 'cancelled' ? 2 : 1;
  String get target => fixture.target.relativePath;
  void event() {
    if (!events.isClosed) events.add(null);
  }

  @override
  Stream<void> get changes => events.stream;
  @override
  Future<IosTransferCapability> capability() async {
    if (capabilityFailures > 0) {
      capabilityFailures--;
      throw StateError('Fixture initial storage unavailable');
    }
    return IosTransferCapability(
      available: true,
      download: true,
      libraryImport: enabled,
    );
  }

  @override
  Future<IosTransferSummary> recover() async {
    recoveries++;
    if (recoveryWait != null) {
      if (!recoveryEntered!.isCompleted) recoveryEntered!.complete();
      await recoveryWait!.future;
    }
    active = null;
    return IosTransferSummary.fromJson({
      'generation': 1,
      'total': 1,
      'counts': {phase: 1},
      'progress': [],
      'pauses': [],
      'persistenceFailed': false,
    });
  }

  @override
  Future<void> drainImports() async {
    drains++;
    if (drains == 1 && startupDrain != null) {
      startupDrainEntered!.complete();
      await startupDrain!.future;
    }
  }

  @override
  Future<void> pauseSubmissions() async {
    submissionPauses++;
  }

  @override
  void resumeSubmissions() {
    submissionResumes++;
  }

  @override
  Future<IosTransferImportWorkPage> importWorkPage({
    IosTransferWorkCursor? after,
    int limit = 100,
  }) async {
    workReads++;
    return IosTransferImportWorkPage.fromJson(
      {
        'generation': 1,
        'entries': [
          if (songId != null && !cleaned && after == null)
            {
              'job': {...fixture.document, 'phase': 'validating'},
              'songID': songId,
              'targetRelativePath': target,
              'publicationRecorded': published,
              'currentRevision': currentRevision,
              'currentPhase': phase,
            },
        ],
      },
      limit: limit,
      after: after,
    );
  }

  @override
  Future<IosTransferImportCandidatePage> importCandidatesPage({
    IosTransferWorkCursor? after,
    int limit = 100,
  }) async {
    candidateReads++;
    return IosTransferImportCandidatePage.fromJson(
      {
        'generation': 1,
        'entries': [
          if (after == null &&
              {'staged', 'validating', 'importing'}.contains(phase))
            {...fixture.document, 'phase': phase},
        ],
      },
      limit: limit,
      after: after,
    );
  }

  bool historyEligible = false,
      historyCompacted = false,
      loseHistoryReply = false;
  int historyCompactions = 0, historyReads = 0;
  Completer<void>? historyEntered, historyWait;

  @override
  Future<IosTransferImportWorkPage> completedHistoryPage({
    IosTransferWorkCursor? after,
    int limit = 100,
  }) async {
    historyReads++;
    return IosTransferImportWorkPage.fromJson(
      {
        'generation': 1,
        'entries': [
          if (after == null &&
              historyEligible &&
              phase == 'complete' &&
              !historyCompacted)
            {
              'job': {...fixture.document, 'phase': 'validating'},
              'songID': songId,
              'targetRelativePath': target,
              'publicationRecorded': true,
              'currentRevision': 1,
              'currentPhase': 'complete',
            },
        ],
      },
      limit: limit,
      after: after,
    );
  }

  @override
  Future<void> compactCompletedImport(
    IosTransferImportLease lease, {
    required int songId,
  }) async {
    await validateImport(lease, requiresWrite: false);
    historyEntered?.complete();
    await historyWait?.future;
    await validateImport(lease, requiresWrite: false);
    final receipt = await fixture.db.iosTransferReceiptEntitys
        .getByOperationKey('${job.id}:1');
    require(
      receipt?.state == 'committed' && receipt?.localSongId == songId,
      'History proof follows actual committed Isar, even after Song deletion',
    );
    require(
      lease.reconcileOnly && phase == 'complete' && cleaned,
      'Only fully acknowledged fixture history can compact',
    );
    historyCompactions++;
    historyCompacted = true;
    event();
    if (loseHistoryReply) {
      loseHistoryReply = false;
      throw StateError('Lost history acknowledgement');
    }
  }

  @override
  Future<IosTransferJob> verify(IosTransferJob job) async =>
      throw StateError('Not a downloaded fixture');
  @override
  Future<IosTransferImportLease> claimImport(
    IosTransferJob requested, {
    bool reconcileOnly = false,
  }) async {
    require(active == null, 'One coordinator lease at a time');
    if (phase == 'staged') {
      require(!reconcileOnly, 'Only a writer advances staging');
      phase = 'validating';
      event();
    }
    require(
      phase != 'complete' || reconcileOnly,
      'Complete fixture never gains write permission',
    );
    return active = IosTransferImportLease.fromJson({
      'job': {...fixture.document, 'phase': phase},
      'leaseID':
          'a7d96b93-6526-4f1f-a1af-${(++sequence).toRadixString(16).padLeft(12, '0')}',
      'clientID': client,
      'reconcileOnly': reconcileOnly,
      'targetRelativePath': target,
      if (!reconcileOnly && staging) 'sourcePath': fixture.audio.path,
    });
  }

  @override
  Future<void> validateImport(
    IosTransferImportLease lease, {
    bool requiresWrite = true,
  }) async {
    require(
      active?.leaseId == lease.leaseId &&
          (!requiresWrite || !lease.reconcileOnly),
      'Current fixture authority',
    );
  }

  @override
  Future<IosTransferPublishedImport> publishImport(
    IosTransferImportLease lease, {
    required int songId,
  }) async {
    await validateImport(lease);
    require(
      this.songId == null || this.songId == songId,
      'Exact frozen Song binding',
    );
    this.songId = songId;
    publications++;
    if (!published) await fixture.publishFixture();
    published = true;
    phase = 'importing';
    event();
    if (losePublicationReply) {
      losePublicationReply = false;
      throw StateError('Fixture lost publication reply');
    }
    return IosTransferPublishedImport.fromJson({
      'job': {...fixture.document, 'phase': phase},
      'songID': songId,
      'receipt': {
        'relativePath': target,
        'bytes': job.receivedBytes,
        'sha256': job.receivedSha256,
      },
    });
  }

  @override
  Future<IosTransferJob> acknowledgeImport(
    IosTransferImportLease lease, {
    required int songId,
  }) async {
    await validateImport(lease, requiresWrite: false);
    final receipt = await fixture.db.iosTransferReceiptEntitys
        .getByOperationKey('${job.id}:1');
    require(
      receipt?.state == 'committed' && receipt?.localSongId == songId,
      'Actual committed Isar receipt must precede native attestation',
    );
    require(
      published && this.songId == songId,
      'Native fixture has matching publication',
    );
    acknowledgements++;
    phase = 'complete';
    cleaned = true;
    active = null;
    event();
    return job;
  }

  @override
  Future<void> releaseImport(IosTransferImportLease lease) async {
    require(
      active?.leaseId == lease.leaseId,
      'Release only the actual fixture lease',
    );
    active = null;
    if (!released.isCompleted) released.complete();
  }

  @override
  Future<IosTransferCleanupLease> claimImportCleanup(
    IosTransferImportWork work,
  ) async {
    require(
      active == null && activeCleanup == null && songId == work.songId,
      'Cleanup requires the actual frozen fixture reservation',
    );
    return activeCleanup = IosTransferCleanupLease.fromJson({
      'permission': 'cleanup',
      'job': {...fixture.document, 'phase': 'validating'},
      'songID': songId,
      'targetRelativePath': target,
      'clientID': client,
      'leaseID':
          'a7d96b93-6526-4f1f-a1af-${(++sequence).toRadixString(16).padLeft(12, '0')}',
      'currentRevision': currentRevision,
      'currentPhase': phase,
      'publicationRecorded': published,
      if (resolution != null)
        'resolution': {
          'mode': resolution!.mode.name,
          'abandonment': resolution!.abandonment?.name,
        },
    });
  }

  @override
  Future<void> validateImportCleanup(IosTransferCleanupLease lease) async {
    require(
      activeCleanup?.leaseId == lease.leaseId,
      'Current fixture cleanup authority',
    );
  }

  @override
  Future<IosTransferResolvedCleanup> resolveImportCleanup(
    IosTransferCleanupLease lease, {
    required IosTransferReceiptEntity receipt,
  }) async {
    await validateImportCleanup(lease);
    final actual = await fixture.db.iosTransferReceiptEntitys.getByOperationKey(
      receipt.operationKey,
    );
    require(
      actual?.state == receipt.state &&
          actual?.localSongId == lease.songId &&
          {'retiring', 'committed'}.contains(actual?.state),
      'Actual Isar decision precedes native cleanup attestation',
    );
    if (resolution == null) {
      cleanupCalls++;
      if (receipt.state == 'committed') {
        resolution = IosTransferCleanupResolution.fromJson({
          'mode': 'committed',
        });
      } else {
        phase = 'cancelled';
        final file = File(fixture.store().absolutePath(fixture.target));
        var outcome = preservePublic ? 'preservedByRequest' : 'missingFile';
        if (await file.exists()) {
          final digest = (await sha256.bind(file.openRead()).first).toString();
          if (!preservePublic &&
              published &&
              digest == lease.job.receivedSha256) {
            await file.delete();
            outcome = 'removedOwnedFile';
          } else if (!preservePublic) {
            outcome = 'preservedUserFile';
          }
        }
        resolution = IosTransferCleanupResolution.fromJson({
          'mode': 'abandoned',
          'abandonment': outcome,
        });
      }
      staging = false;
      event();
    }
    if (loseCleanupReply) {
      loseCleanupReply = false;
      throw StateError('Fixture lost resolved cleanup reply');
    }
    return IosTransferResolvedCleanup.fromJson({
      'id': lease.job.id,
      'revision': lease.job.revision,
      'songID': lease.songId,
      'resolution': {
        'mode': resolution!.mode.name,
        'abandonment': resolution!.abandonment?.name,
      },
    });
  }

  @override
  Future<void> finalizeImportCleanup(
    IosTransferCleanupLease lease, {
    required IosTransferReceiptEntity receipt,
  }) async {
    await validateImportCleanup(lease);
    final actual = await fixture.db.iosTransferReceiptEntitys.getByOperationKey(
      receipt.operationKey,
    );
    require(
      resolution != null &&
          actual?.state == receipt.state &&
          (resolution!.mode == IosTransferCleanupMode.committed
              ? actual?.state == 'committed'
              : actual?.state == 'retired'),
      'Actual durable Isar finalization precedes native bookkeeping removal',
    );
    cleaned = true;
    finalizations++;
    if (loseFinalizationReply) {
      loseFinalizationReply = false;
      throw StateError('Fixture lost finalization reply');
    }
    event();
  }

  bool preservePublic = false;
  @override
  Future<void> preserveImportPublicFile(IosTransferCleanupLease lease) async {
    await validateImportCleanup(lease);
    preservePublic = true;
  }

  @override
  Future<void> releaseImportCleanup(IosTransferCleanupLease lease) async {
    await validateImportCleanup(lease);
    activeCleanup = null;
  }

  @override
  Future<IosTransferOrphanLease> claimOrphanCleanup(
    IosTransferWorkCursor key, {
    required int songId,
  }) async {
    if (this.songId != null ||
        currentRevision <= key.revision ||
        key.jobId != job.id) {
      throw StateError('Fixture has custody or no retired revision');
    }
    require(
      active == null && activeCleanup == null && activeOrphan == null,
      'Orphan fixture crosses one owner barrier',
    );
    orphanClaims++;
    return activeOrphan = IosTransferOrphanLease.fromJson({
      'permission': 'orphanCleanup',
      'id': key.jobId,
      'revision': key.revision,
      'songID': songId,
      'clientID': client,
      'leaseID':
          'a7d96b93-6526-4f1f-a1af-${(++sequence).toRadixString(16).padLeft(12, '0')}',
      'currentJob': {
        ...fixture.document,
        'phase': phase,
        'revision': currentRevision,
      },
    });
  }

  @override
  Future<void> validateOrphanCleanup(IosTransferOrphanLease lease) async {
    require(
      activeOrphan?.leaseId == lease.leaseId,
      'Current orphan fixture guard',
    );
  }

  @override
  Future<void> releaseOrphanCleanup(IosTransferOrphanLease lease) async {
    await validateOrphanCleanup(lease);
    activeOrphan = null;
  }
}

Future<void> main(List<String> arguments) async {
  final options = <String, String>{};
  for (var index = 0; index < arguments.length; index += 2) {
    options[arguments[index]] = arguments[index + 1];
  }
  Isar.initializeIsarCore(
    libraries: {Abi.current(): options['--isar-library']!},
  );
  final source = File(options['--audio']!);
  final original =
      (jsonDecode(
            await File('test/fixtures/ios_transfer_intents_v1.json')
                .readAsString(),
          ) as List).single
          as Map;
  final root = await Directory.systemTemp.createTemp('ios-root-coordinator-');
  var mediaReads = 0;
  Future<IosTransferMediaInfo> readMedia(
    IosTransferImportLease lease, {
    required bool Function() isCurrent,
    required Future<void> Function() validateOwnership,
    Future<void>? cancelled,
  }) async {
    mediaReads++;
    await validateOwnership();
    require(isCurrent(), 'Media starts under current app epoch');
    final IosTransferMediaInfo result;
    if (options['--ffprobe'] case final String executable) {
      final process = await Process.run(
        executable,
        IosTransferMedia.arguments(lease.sourcePath!),
      );
      if (process.exitCode != 0) {
        throw const IosTransferMediaException(IosTransferMediaFailure.invalid);
      }
      result = IosTransferMedia.parse(
        process.stdout as String,
        expectedBytes: lease.job.receivedBytes!,
      );
    } else {
      require(
        (await File(lease.sourcePath!).readAsBytes()).length == 64044,
        'Exact generated WAV fixture',
      );
      result = Fixture.media;
    }
    await validateOwnership();
    require(isCurrent(), 'Media finishes under current app epoch');
    return result;
  }

  Future<void> scenario(
    String name,
    Future<void> Function(Fixture, NativeFixture) run, {
    bool existing = true,
  }) async {
    final directory = await Directory('${root.path}/$name').create();
    final audio = await source.copy('${directory.path}/retained.download');
    final bytes = await audio.readAsBytes();
    final data = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(original)) as Map,
    );
    (data['metadata'] as Map)['fileExtension'] = 'wav';
    if (!existing) (data['identity'] as Map).remove('localSongID');
    data.addAll({
      'revision': 1,
      'direction': 'download',
      'updatedMs': 2000,
      'expectedBytes': bytes.length,
      'expectedSHA256': sha256.convert(bytes).toString(),
      'receivedBytes': bytes.length,
      'receivedSHA256': sha256.convert(bytes).toString(),
    });
    final fixture = Fixture(directory, audio, data);
    await fixture.open();
    await fixture.seed(existing: existing);
    final native = NativeFixture(fixture);
    try {
      await run(fixture, native);
    } finally {
      await native.events.close();
      await fixture.close();
    }
  }

  IosTransferImportCoordinator coordinator(
    Fixture fixture,
    NativeFixture native, {
    IosTransferMediaReader? reader,
    Future<void> Function(IosTransferImportResult, bool Function())?
    didComplete,
  }) => IosTransferImportCoordinator(
    native: native,
    store: () async => fixture.store(),
    readMedia: reader ?? readMedia,
    didComplete: didComplete,
  );
  try {
    await scenario('committed-audio-before-optional-sidecars', (
      fixture,
      native,
    ) async {
      var completed = 0;
      final owner = coordinator(
        fixture,
        native,
        didComplete: (result, isCurrent) async {
          require(
            result.committed && native.phase == 'complete' && isCurrent(),
            'Optional sidecars run only after actual Isar commit and native acknowledgement',
          );
          final stored = await fixture.db.songEntitys.get(
            result.receipt.localSongId,
          );
          require(
            stored != null && stored.sourceType == null,
            'Sidecars receive the committed local recording identity',
          );
          completed++;
          throw StateError('Optional desktop lyrics unavailable');
        },
      );
      try {
        await owner.start();
        require(
          completed == 1 &&
              owner.issues.isEmpty &&
              native.acknowledgements == 1,
          'Unavailable optional sidecars cannot invalidate the completed audio import',
        );
      } finally {
        await owner.dispose();
      }
    });
    await scenario('mutation-preserves-published-preparation', (
      fixture,
      native,
    ) async {
      await fixture.prepare();
      native.enabled = false;
      native.phase = 'importing';
      native.songId = 42;
      native.published = true;
      final file = File(fixture.store().absolutePath(fixture.target));
      await file.parent.create(recursive: true);
      await fixture.audio.copy(file.path);
      final owner = coordinator(fixture, native);
      try {
        await owner.start();
        await owner.pauseForMutation();
        await owner.reconcileImportsForMutation(
          fixture.job().intent.identity.scope,
        );
        require(
          !owner.enabled &&
              native.publications == 0 &&
              native.preservePublic &&
              native.cleanupCalls == 1 &&
              native.finalizations == 1 &&
              owner.issues.isEmpty,
          'Held mutation reconciles actual Isar without activating ordinary imports',
        );
        require(
          (await fixture.store().peek(
                    fixture.job(),
                    fixture.target,
                  ))!.receipt.state ==
                  'retired' &&
              await file.exists() &&
              (await file.readAsBytes()).length ==
                  fixture.job().receivedBytes &&
              (await fixture.db.songEntitys.get(42))!.sourceType == 'lokal',
          'Prepared retirement preserves the public file and original Song before user metadata action',
        );
      } finally {
        await owner.dispose();
      }
    });
    await scenario('mutation-retires-orphan-after-network', (
      fixture,
      native,
    ) async {
      await fixture.prepare();
      native.enabled = false;
      native.phase = 'cancelled';
      final owner = coordinator(fixture, native);
      try {
        await owner.start();
        await owner.pauseForMutation();
        await owner.reconcileImportsForMutation(
          fixture.job().intent.identity.scope,
          afterNetworkRetirement: true,
        );
        require(
          (await fixture.store().pendingReservations()).entries.isEmpty &&
              native.orphanClaims == 1 &&
              native.cleanupCalls == 0 &&
              native.publications == 0,
          'Post-cancellation mutation retires only verified orphan bookkeeping',
        );
      } finally {
        await owner.dispose();
      }
    });
    await scenario('mutation-refuses-missing-Isar', (fixture, native) async {
      native.enabled = false;
      native.phase = 'importing';
      native.songId = 42;
      native.published = true;
      final owner = coordinator(fixture, native);
      try {
        await owner.start();
        await owner.pauseForMutation();
        var refused = false;
        try {
          await owner.reconcileImportsForMutation(
            fixture.job().intent.identity.scope,
          );
        } on StateError {
          refused = true;
        }
        require(
          refused &&
              native.cleanupCalls == 0 &&
              native.finalizations == 0 &&
              native.publications == 0 &&
              native.preservePublic,
          'Missing Isar binding blocks mutation without deleting files or inventing commitment',
        );
      } finally {
        await owner.dispose();
      }
    });
    await scenario('coalesced-foreground-mutation', (fixture, native) async {
      final owner = coordinator(fixture, native);
      try {
        await owner.start();
        await owner.pauseForMutation();
        native.recoveryEntered = Completer<void>();
        native.recoveryWait = Completer<void>();
        final before = native.recoveries;
        final resuming = owner.resumeAfterMutation();
        await native.recoveryEntered!.future;
        final first = owner.foreground(), second = owner.foreground();
        require(
          identical(first, second),
          'Concurrent foreground calls share one lifecycle operation',
        );
        var mutationFinished = false;
        final mutation = owner.pauseForMutation().then(
          (_) => mutationFinished = true,
        );
        await Future<void>.delayed(Duration.zero);
        require(
          !mutationFinished,
          'Mutation waits for the actual old lifecycle recovery',
        );
        native.recoveryWait!.complete();
        await Future.wait([resuming, first, second, mutation]);
        require(
          !owner.enabled &&
              owner.issues.isEmpty &&
              native.recoveries == before + 1,
          'A stale lifecycle cannot re-enable writes or override a mutation barrier',
        );
        native.recoveryWait = null;
        await owner.foreground();
        require(
          !owner.enabled && native.recoveries == before + 1,
          'An unrelated foreground cannot release a held clear/unpair mutation',
        );
        final resumes = native.submissionResumes;
        await owner.resumeAfterMutation();
        require(
          owner.enabled && native.submissionResumes == resumes + 1,
          'Only the mutation owner explicitly resumes fresh submissions after its storage barrier',
        );
      } finally {
        await owner.dispose();
      }
    });
    for (final mode in [
      'owned',
      'edited',
      'lost-resolution',
      'lost-finalization',
    ]) {
      await scenario('root-cleanup-$mode', (fixture, native) async {
        await fixture.prepare();
        await fixture.publishFixture();
        native.songId = 42;
        native.phase = 'cancelled';
        native.published = true;
        native.loseCleanupReply = mode == 'lost-resolution';
        native.loseFinalizationReply = mode == 'lost-finalization';
        final file = File(fixture.store().absolutePath(fixture.target));
        if (mode == 'edited') await file.writeAsString('preserved user audio');
        var owner = coordinator(fixture, native);
        try {
          await owner.start();
          if (mode == 'lost-resolution') {
            require(
              (await fixture.store().peek(
                        fixture.job(),
                        fixture.target,
                      ))!.receipt.state ==
                      'retiring' &&
                  native.resolution != null &&
                  !native.cleaned,
              'Lost native resolution retains actual Isar retiring and native provenance',
            );
            await owner.dispose();
            await fixture.close();
            await fixture.open();
            owner = coordinator(fixture, native);
            await owner.start();
          } else if (mode == 'lost-finalization') {
            require(
              native.cleaned &&
                  (await fixture.store().peek(
                        fixture.job(),
                        fixture.target,
                      ))!.receipt.state ==
                      'retired',
              'Lost finalization reply leaves actual Isar retirement and native removal complete',
            );
            await owner.foreground();
          }
          require(
            owner.enabled &&
                owner.issues.isEmpty &&
                native.cleanupCalls == 1 &&
                native.finalizations == 1,
            'Root finalizes one cleanup without repeating file handling after lost replies',
          );
          require(
            (await fixture.store().peek(
                      fixture.job(),
                      fixture.target,
                    ))!.receipt.state ==
                    'retired' &&
                (await fixture.db.songEntitys.get(42))!.sourceType == 'lokal',
            'Actual Isar retirement preserves the remote recording and its identity',
          );
          if (mode == 'edited') {
            require(
              await file.readAsString() == 'preserved user audio',
              'Edited public bytes remain intact',
            );
          } else {
            require(
              !await file.exists(),
              'Owned canceled copy is removed only by the explicit native-port fixture',
            );
          }
        } finally {
          await owner.dispose();
        }
      });
    }
    await scenario('committed-cancel-history', (fixture, native) async {
      await fixture.prepare();
      await fixture.publishFixture();
      await fixture.commit();
      await fixture.db.writeTxn(() => fixture.db.songEntitys.delete(42));
      native.songId = 42;
      native.published = true;
      native.phase = 'cancelled';
      final owner = coordinator(fixture, native);
      try {
        await owner.start();
        require(
          owner.issues.isEmpty &&
              native.resolution?.mode == IosTransferCleanupMode.committed &&
              native.cleaned,
          'Canceled native history reconciles the actual committed Isar decision',
        );
        require(
          await File(fixture.store().absolutePath(fixture.target)).exists() &&
              await fixture.db.songEntitys.count() == 0,
          'Committed cleanup preserves public Music and never resurrects a deleted Song',
        );
      } finally {
        await owner.dispose();
      }
    });
    await scenario('isar-only-orphan', (fixture, native) async {
      await fixture.prepare();
      native.phase = 'cancelled';
      final unrelated = File(fixture.store().absolutePath(fixture.target));
      await unrelated.parent.create(recursive: true);
      await unrelated.writeAsString('User-owned file without native custody');
      final owner = coordinator(fixture, native);
      try {
        await owner.start();
        require(
          owner.enabled &&
              owner.issues.isEmpty &&
              native.orphanClaims == 1 &&
              (await fixture.store().pendingReservations()).entries.isEmpty,
          'Isar-only reservation retires after a newer-revision no-custody barrier',
        );
        require(
          native.publications == 0 &&
              native.acknowledgements == 0 &&
              native.cleanupCalls == 0 &&
              native.finalizations == 0 &&
              (await fixture.db.songEntitys.get(42))!.sourceType == 'lokal' &&
              await unrelated.readAsString() ==
                  'User-owned file without native custody',
          'Orphan retirement preserves Song and public bytes without invoking file cleanup',
        );
        await fixture.close();
        await fixture.open();
        require(
          (await fixture.store().peek(
                fixture.job(),
                fixture.target,
              ))!.receipt.state ==
              'retired',
          'Bookkeeping retirement survives database reopen',
        );
        await owner.foreground();
        require(
          native.orphanClaims == 1,
          'Retired orphan is absent from recovery pages',
        );
      } finally {
        await owner.dispose();
      }
    });
    await scenario('retiring-current-candidate', (fixture, native) async {
      await fixture.prepare();
      await fixture.store().beginRetirement(
        fixture.job(),
        fixture.target,
        isCurrent: () => true,
        validateCleanupAuthority: () async {},
      );
      native.phase = 'validating';
      final owner = coordinator(fixture, native);
      try {
        await owner.start();
        require(
          owner.issues['${native.job.id}:1'] ==
                  IosTransferCoordinatorIssue.cleanupRequired &&
              native.publications == 0,
          'Durable retiring reservation blocks a late current candidate',
        );
      } finally {
        await owner.dispose();
      }
    });
    for (final lostReply in [false, true]) {
      await scenario('completed-history-$lostReply', (fixture, native) async {
        await fixture.prepare();
        await fixture.publishFixture();
        await fixture.commit();
        await fixture.db.writeTxn(() => fixture.db.songEntitys.delete(42));
        native
          ..phase = 'complete'
          ..songId = 42
          ..published = true
          ..cleaned = true
          ..historyEligible = true
          ..loseHistoryReply = lostReply;
        final before = await File(fixture.store().absolutePath(fixture.target))
            .readAsBytes();
        final owner = coordinator(fixture, native);
        try {
          await owner.start();
          require(
            owner.enabled &&
                native.historyCompactions == 1 &&
                await fixture.db.iosTransferReceiptEntitys.count() == 1 &&
                await fixture.db.songEntitys.get(42) == null,
            'Compaction requires durable committed Isar and retains receipt/deleted Song identity',
          );
          require(
            sha256.convert(before).toString() ==
                sha256
                    .convert(
                      await File(fixture.store().absolutePath(fixture.target))
                          .readAsBytes(),
                    )
                    .toString(),
            'History cleanup preserves actual public audio bytes',
          );
          await owner.foreground();
          require(
            owner.enabled &&
                owner.issues.isEmpty &&
                native.historyCompactions == 1 &&
                native.publications == 0 &&
                native.acknowledgements == 0,
            'Lost compaction reply converges without reimport or repeated native completion',
          );
        } finally {
          await owner.dispose();
        }
      });
    }
    await scenario('history-missing-receipt', (fixture, native) async {
      native
        ..phase = 'complete'
        ..songId = 42
        ..published = true
        ..cleaned = true
        ..historyEligible = true;
      final owner = coordinator(fixture, native);
      try {
        await owner.start();
        require(
          owner.enabled &&
              owner.issues.containsKey('history') &&
              native.historyCompactions == 0,
          'Missing Isar proof refuses history cleanup without disabling copy ownership',
        );
      } finally {
        await owner.dispose();
      }
    });
    await scenario('history-retired-root', (fixture, native) async {
      await fixture.prepare();
      await fixture.publishFixture();
      await fixture.commit();
      native
        ..phase = 'complete'
        ..songId = 42
        ..published = true
        ..cleaned = true
        ..historyEligible = true
        ..historyEntered = Completer<void>()
        ..historyWait = Completer<void>();
      final owner = coordinator(fixture, native);
      final starting = owner.start();
      await native.historyEntered!.future;
      final pausing = owner.pauseForMutation();
      await native.released.future;
      native.historyWait!.complete();
      await pausing;
      await starting;
      require(
        native.historyCompactions == 0 &&
            await fixture.db.iosTransferReceiptEntitys.count() == 1,
        'Retired root cannot compact after the library mutation fence',
      );
      await owner.dispose();
    });
    await scenario('complete', (fixture, native) async {
      final owner = coordinator(fixture, native);
      try {
        await owner.start();
        require(
          native.phase == 'complete' &&
              native.acknowledgements == 1 &&
              owner.issues.isEmpty,
          'Root completes actual Isar transaction before native acknowledgement',
        );
        final song = (await fixture.db.songEntitys.get(42))!;
        require(
          song.sourceType == null &&
              song.fileType == 'WAV' &&
              song.sampleRate == 16000 &&
              song.bitDepth == 16,
          'Actual reader quality and existing Song ID commit together',
        );
        final receipt = (await fixture.db.iosTransferReceiptEntitys
            .getByOperationKey('${native.job.id}:1'))!;
        require(
          receipt.validatedMediaJson != null && receipt.state == 'committed',
          'Durable media and completion retained',
        );
        final reads = mediaReads,
            recovery = native.workReads,
            acknowledgements = native.acknowledgements;
        for (var event = 0; event < 20; event++) {
          native.event();
          await owner.requestDrain();
        }
        require(
          mediaReads == reads &&
              native.workReads == recovery &&
              native.acknowledgements == acknowledgements,
          'Progress/change events do not reprobe media, scan completed history or acknowledge forever',
        );
        final idle = native.candidateReads;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        require(
          idle == native.candidateReads,
          'No periodic paused/idle polling',
        );
      } finally {
        await owner.dispose();
      }
    });
    await scenario('startup-drain', (fixture, native) async {
      native.startupDrain = Completer<void>();
      native.startupDrainEntered = Completer<void>();
      final owner = coordinator(fixture, native);
      try {
        final starting = owner.start();
        await native.startupDrainEntered!.future;
        native.event();
        await Future<void>.delayed(Duration.zero);
        require(
          native.candidateReads == 0 && native.publications == 0,
          'No app write/candidate drain can start before the prior native file worker barrier',
        );
        native.startupDrain!.complete();
        await starting;
        require(
          native.phase == 'complete' && owner.issues.isEmpty,
          'Startup resumes only after native drainage',
        );
      } finally {
        if (native.startupDrain?.isCompleted == false) {
          native.startupDrain!.complete();
        }
        await owner.dispose();
      }
    });
    await scenario('mutation-during-startup', (fixture, native) async {
      native.startupDrain = Completer<void>();
      native.startupDrainEntered = Completer<void>();
      final owner = coordinator(fixture, native);
      try {
        final starting = owner.start();
        await native.startupDrainEntered!.future;
        final mutation = owner.pauseForMutation();
        await owner.foreground();
        require(
          !owner.enabled &&
              native.submissionPauses == 1 &&
              native.publications == 0,
          'Mutation retires startup submissions before awaiting its blocked file drain',
        );
        native.startupDrain!.complete();
        await Future.wait([starting, mutation]);
        require(
          !owner.enabled && native.publications == 0,
          'A drained old startup cannot enable a held mutation',
        );
        await owner.resumeAfterMutation();
        require(
          owner.enabled && native.phase == 'complete' && owner.issues.isEmpty,
          'Explicit mutation completion retries a retired startup and finishes one import',
        );
      } finally {
        if (!native.startupDrain!.isCompleted) native.startupDrain!.complete();
        await owner.dispose();
      }
    });
    await scenario('startup-retry', (fixture, native) async {
      native.capabilityFailures = 1;
      final owner = coordinator(fixture, native);
      try {
        await owner.start();
        require(
          !owner.enabled && native.workReads == 0,
          'Unavailable startup cannot fabricate an empty owner',
        );
        await owner.foreground();
        require(
          owner.enabled && owner.issues.isEmpty && native.phase == 'complete',
          'A later foreground retries real initialization instead of caching startup failure forever',
        );
      } finally {
        await owner.dispose();
      }
    });
    await scenario('missing-media', (fixture, native) async {
      await fixture.prepare();
      native.phase = 'importing';
      native.published = true;
      native.songId = 42;
      native.staging = false;
      final reads = mediaReads, owner = coordinator(fixture, native);
      try {
        await owner.start();
        require(
          owner.issues.values.contains(
                IosTransferCoordinatorIssue.missingValidation,
              ) &&
              mediaReads == reads &&
              native.publications == 0 &&
              native.acknowledgements == 0,
          'Missing staging plus absent durable media proof never invents quality or adopts publication',
        );
      } finally {
        await owner.dispose();
      }
    });
    await scenario('failed-reader', (fixture, native) async {
      var attempts = 0;
      final owner = coordinator(
        fixture,
        native,
        reader:
            (
              lease, {
              required isCurrent,
              required validateOwnership,
              cancelled,
            }) async {
              attempts++;
              throw const IosTransferMediaException(
                IosTransferMediaFailure.invalid,
              );
            },
      );
      try {
        await owner.start();
        require(
          owner.issues.values.contains(
                IosTransferCoordinatorIssue.invalidMedia,
              ) &&
              native.publications == 0,
          'Invalid media stays prepared and cannot be published',
        );
        for (var event = 0; event < 10; event++) {
          native.event();
          await owner.requestDrain();
        }
        require(attempts == 1, 'Unrelated progress never retries failed media');
        await owner.foreground();
        require(
          attempts == 2,
          'Foreground explicitly retries blocked app work',
        );
      } finally {
        await owner.dispose();
      }
    });
    await scenario('new-identity', (fixture, native) async {
      final owner = coordinator(fixture, native);
      try {
        await owner.start();
        require(
          owner.issues.isEmpty && await fixture.db.songEntitys.count() == 1,
          'Remote original without a preassigned ID allocates exactly one actual Song',
        );
      } finally {
        await owner.dispose();
      }
    }, existing: false);
    await scenario('lost-publication', (fixture, native) async {
      native.losePublicationReply = true;
      final first = coordinator(fixture, native);
      await first.start();
      await first.dispose();
      require(
        native.phase == 'importing' &&
            native.published &&
            native.acknowledgements == 0,
        'Actual published fixture and uncertain Isar boundary survive a lost reply',
      );
      await fixture.close();
      await fixture.open();
      native.staging = false;
      await fixture.audio.delete();
      final reads = mediaReads;
      final next = coordinator(fixture, native);
      try {
        await next.start();
        require(
          next.issues.isEmpty &&
              native.phase == 'complete' &&
              mediaReads == reads,
          'Reopened real Isar media proof finishes without staging or a second reader',
        );
        require(
          await fixture.db.songEntitys.count() == 1,
          'Recovery never allocates a replacement identity',
        );
      } finally {
        await next.dispose();
      }
    });
    await scenario('deleted-after-commit', (fixture, native) async {
      await fixture.prepare();
      await fixture.commit();
      native.phase = 'importing';
      native.published = true;
      native.songId = 42;
      native.staging = false;
      await fixture.db.writeTxn(() => fixture.db.songEntitys.delete(42));
      final reads = mediaReads;
      final owner = coordinator(fixture, native);
      try {
        await owner.start();
        require(
          owner.issues.isEmpty &&
              native.phase == 'complete' &&
              mediaReads == reads &&
              native.publications == 0,
          'Historical committed receipt only acknowledges, never reads or republishes',
        );
        require(
          await fixture.db.songEntitys.get(42) == null,
          'Deleted Song is never resurrected',
        );
      } finally {
        await owner.dispose();
      }
    });
    await scenario('missing-reservation', (fixture, native) async {
      native.phase = 'importing';
      native.published = true;
      native.songId = 42;
      final owner = coordinator(fixture, native);
      try {
        await owner.start();
        require(
          owner.issues.values.contains(
                IosTransferCoordinatorIssue.missingReservation,
              ) &&
              native.publications == 0,
          'Native frozen work cannot adopt a new Isar reservation after its original is missing',
        );
        require(
          await fixture.db.iosTransferReceiptEntitys.count() == 0,
          'Missing receipt stays missing',
        );
      } finally {
        await owner.dispose();
      }
    });
    await scenario('retired-reader', (fixture, native) async {
      final entered = Completer<void>(), finish = Completer<void>();
      final owner = coordinator(
        fixture,
        native,
        reader:
            (
              lease, {
              required isCurrent,
              required validateOwnership,
              cancelled,
            }) async {
              entered.complete();
              await finish.future;
              return Fixture.media;
            },
      );
      final started = owner.start();
      await entered.future;
      final paused = owner.pauseForMutation();
      await native.released.future;
      finish.complete();
      await paused;
      await started;
      require(
        native.publications == 0 && native.acknowledgements == 0,
        'Retired reader cannot reach publication or completion',
      );
      await fixture.db.writeTxn(() => fixture.db.songEntitys.clear());
      await owner.requestDrain();
      require(
        await fixture.db.songEntitys.count() == 0,
        'No old app write follows the mutation barrier',
      );
      await owner.dispose();
    });
    await scenario('capability-off', (fixture, native) async {
      native.enabled = false;
      final owner = coordinator(fixture, native);
      try {
        await owner.start();
        require(
          !owner.enabled &&
              owner.issues.isEmpty &&
              !native.events.hasListener &&
              native.workReads == 0 &&
              native.candidateReads == 0,
          'Product capability false keeps the root inert and existing copy flows authoritative',
        );
      } finally {
        await owner.dispose();
      }
    });
    // ignore: avoid_print
    print(
      'Actual root coordinator/Isar contracts passed: ordered completion, one identity, durable media, lost publication/staging and cleanup replies across database reopen, retiring/native-resolution/Isar-retired/finalization ordering, edited-file preservation, deleted committed history, missing reservation refusal, bookkeeping-only orphan retirement and public-file preservation across reopen, coalesced foreground/mutation barrier, blocked-reader retirement, capability gating and no idle/history polling. Native RPC/file custody is a fixture; reader=${options.containsKey('--ffprobe') ? 'actual host FFprobe.' : 'generated WAV fixture.'}',
    );
  } finally {
    await root.delete(recursive: true);
  }
}
