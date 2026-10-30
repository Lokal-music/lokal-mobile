import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flick/data/entities/ios_transfer_receipt_entity.dart';
import 'package:flick/data/entities/ios_song_identity_entity.dart';
import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/data/entities/song_entity.dart';
import 'package:flick/models/ios_transfer_models.dart';
import 'package:flick/models/ios_transfer_import.dart';
import 'package:flick/services/ios_transfer_import_coordinator.dart';
import 'package:flick/services/ios_transfer_import_store.dart';
import 'package:flick/services/ios_transfer_media_probe.dart';
import 'package:flick/services/ios_transfer_session.dart';
import 'package:flick/services/ios_transfer_transport.dart';
import 'package:flick/services/link/link_protocol.dart' show linkUuid;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';

/// Installed real coordinator/channel/native file writer + Isar + bundled
/// reader. Only authorization and the desktop HTTP response are fixtures.
/// A DEBUG-only ephemeral host owns separate storage; no real pairing, product
/// journal or music directory is modified. This is not OS suspension acceptance.
Future<Map<String, Object>> probeIosImportPipeline(File generatedWav) async {
  const control = MethodChannel('lokal/transfers-integration-control');
  const pairing = '579d4066-94a7-4d77-8102-3aeb89c4db64';
  const desktop = 'integration-fixture-pc';
  final bytes = await generatedWav.readAsBytes();
  final digest = sha256.convert(bytes).toString();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var requests = 0;
  String? serverFailure;
  server.listen((request) async {
    try {
      if (request.method != 'GET' ||
          request.uri.path != '/api/remote/files/generated-original' ||
          request.headers.value('x-remote-token') !=
              'lokal-integration-fixture') {
        request.response.statusCode = HttpStatus.unauthorized;
      } else {
        requests++;
        request.response.headers.contentType = ContentType('audio', 'wav');
        request.response.headers.set('x-content-sha256', digest);
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
      }
      await request.response.close();
    } catch (error) {
      serverFailure = error.runtimeType.toString();
    }
  });
  Isar? database;
  IosTransferSession? session;
  final product = IosTransferTransport();
  try {
    final original = await product.summary().timeout(
      const Duration(seconds: 10),
    );
    final originalPairing = (await product.currentPairing())?.scope.toJson();
    expect(
      original.total,
      0,
      reason: 'Integration app must have no product transfer jobs',
    );
    final raw = await control
        .invokeMethod<Object?>(
          'configure',
          Uint8List.fromList(utf8.encode(jsonEncode({'port': server.port}))),
        )
        .timeout(const Duration(seconds: 10));
    expect(raw, isA<Uint8List>());
    final paths = jsonDecode(utf8.decode(raw! as Uint8List)) as Map;
    final music = paths['musicRoot'] as String;
    final id = linkUuid();
    final db = await Isar.open(
      [
        SongEntitySchema,
        NetworkServerEntitySchema,
        IosTransferReceiptEntitySchema,
        IosSongIdentityEntitySchema,
      ],
      name: 'import_probe_${id.replaceAll('-', '')}',
      directory: paths['databaseDirectory'] as String,
      relaxedDurability: false,
    );
    database = db;
    final origin = 'http://127.0.0.1:${server.port}';
    await db.writeTxn(
      () => db.networkServerEntitys.put(
        NetworkServerEntity()
          ..id = 3
          ..label = 'Generated integration fixture'
          ..protocol = 'lokal'
          ..baseUrl = origin
          ..username = '$desktop:guest',
      ),
    );
    final native = IosTransferTransport(
      channel: const MethodChannel('lokal/transfers-integration'),
    );
    final coordinator = IosTransferImportCoordinator(
      native: native,
      store: () async => IosTransferImportStore(db, musicRoot: music),
      readMedia: const IosTransferMediaProbe().inspect,
      allowUnreleasedAdapterForIntegration: true,
    );
    final owner = IosTransferSession(native: native, coordinator: coordinator);
    session = owner;
    await owner.start().timeout(const Duration(seconds: 20));
    expect(coordinator.enabled, true, reason: coordinator.issues.toString());
    await native
        .enqueue([
          IosTransferIntent.fromJson({
            'id': id,
            'identity': {
              'desktopID': desktop,
              'origin': origin,
              'pairingID': pairing,
              'sourceID': 'generated-original',
              'localServerID': 3,
            },
            'metadata': {
              'title': 'Generated integration',
              'artist': 'Lokal test',
              'fileExtension': 'wav',
            },
            'createdMs': DateTime.now().millisecondsSinceEpoch,
            'expectedBytes': bytes.length,
            'expectedSHA256': digest,
          }),
        ])
        .timeout(const Duration(seconds: 10));
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    IosTransferJob? completed;
    while (DateTime.now().isBefore(deadline)) {
      expect(coordinator.issues, isEmpty);
      final jobs = await native.page().timeout(const Duration(seconds: 10));
      expect(jobs, hasLength(1));
      final job = jobs.single;
      if (job.phase == IosTransferPhase.complete) {
        completed = job;
        break;
      }
      expect({
        IosTransferPhase.failed,
        IosTransferPhase.cancelled,
        IosTransferPhase.interrupted,
      }, isNot(contains(job.phase)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(completed, isNotNull, reason: 'Actual import did not complete');
    await owner.foreground().timeout(const Duration(seconds: 20));
    expect(coordinator.issues, isEmpty);
    final receipts = await db.iosTransferReceiptEntitys.where().findAll();
    expect(receipts, hasLength(1));
    final receipt = receipts.single;
    expect(receipt.operationKey, '$id:1');
    expect(receipt.state, 'committed');
    expect(receipt.bytes, bytes.length);
    expect(receipt.sha256, digest);
    final song = (await db.songEntitys.get(receipt.localSongId))!;
    expect(await db.songEntitys.count(), 1);
    expect(song.sourceType, isNull);
    expect(song.metadataComplete, true);
    expect(song.sampleRate, 44100);
    expect(song.filePath.startsWith('$music/Desktop Copies/'), true);
    expect(
      sha256.convert(await File(song.filePath).readAsBytes()).toString(),
      digest,
    );
    final saved = await IosTransferImportStore(db, musicRoot: music).peek(
      IosTransferJob.fromJson({
        ...completed!.intent.toJson(),
        'revision': 1,
        'direction': 'download',
        'phase': 'importing',
        'updatedMs': completed.updatedMs,
        'receivedBytes': bytes.length,
        'receivedSHA256': digest,
      }),
      // The native journal selected this relative path, not this probe.
      IosTransferLibraryTarget(receipt.relativePath),
    );
    expect(saved!.validatedMedia!.recognized, true);
    await owner.foreground().timeout(const Duration(seconds: 20));
    expect(await db.songEntitys.count(), 1);
    expect(requests, 1);
    expect(serverFailure, isNull);
    final unchanged = await product.summary().timeout(
      const Duration(seconds: 10),
    );
    expect(unchanged.total, original.total);
    expect(unchanged.generation, original.generation);
    expect((await product.currentPairing())?.scope.toJson(), originalPairing);
    final capability = await product.capability();
    expect(capability.libraryImport, false);
    expect(capability.upload, false);
    return {
      'scope': 'Installed real native transport/coordinator/Isar/publication/bundled reader; synthetic localhost authorization; ephemeral session, no OS suspension claim',
      'complete': true,
      'one_song_one_receipt': true,
      'verified_public_bytes': true,
      'real_native_lease_guards': true,
      'actual_bundled_media_reader': true,
      'foreground_reconciliation_idempotent': true,
      'production_storage_and_keychain_untouched': true,
      'product_background_import_enabled': false,
    };
  } finally {
    try {
      await session?.dispose().timeout(const Duration(seconds: 20));
    } finally {
      await product.dispose();
      try {
        await database?.close();
      } finally {
        try {
          await server.close(force: true);
        } finally {
          final reset = await control
              .invokeMethod<Object?>('reset')
              .timeout(const Duration(seconds: 20));
          expect(jsonDecode(utf8.decode(reset! as Uint8List)), true);
        }
      }
    }
  }
}
