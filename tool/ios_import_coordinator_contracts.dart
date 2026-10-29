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
import 'package:flick/models/ios_transfer_models.dart';
import 'package:flick/models/ios_transfer_recovery.dart';
import 'package:flick/services/ios_transfer_coordinator_port.dart';
import 'package:flick/services/ios_transfer_import_coordinator.dart';
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
  final released = Completer<void>();
  static const client = 'b7d96b93-6526-4f1f-a1af-688ffb5c799d';
  IosTransferJob get job => fixture.job(phase);
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
              'currentRevision': 1,
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
  }) => IosTransferImportCoordinator(
    native: native,
    store: () async => fixture.store(),
    readMedia: reader ?? readMedia,
  );
  try {
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
      'Actual root coordinator/Isar contracts passed: ordered completion, one identity, durable media, lost publication and staging after database reopen, deleted history, missing reservation refusal, blocked-reader retirement/mutation barrier, capability gating and no idle/history polling. Native RPC is a fixture; reader=${options.containsKey('--ffprobe') ? 'actual host FFprobe.' : 'generated WAV fixture.'}',
    );
  } finally {
    await root.delete(recursive: true);
  }
}
