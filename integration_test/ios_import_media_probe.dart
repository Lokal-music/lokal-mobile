import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flick/models/ios_transfer_import.dart';
import 'package:flick/services/ios_transfer_media_probe.dart';
import 'package:flutter_test/flutter_test.dart';

/// Actual bundled native FFprobe/decoder over generated CI media. The lease
/// guard is explicitly a fixture: no user pairing, native import authority,
/// Song, file publication or OS suspension acceptance is inferred here.
Future<Map<String, Object>> probeIosImportMedia(File generatedWav) async {
  final root = await generatedWav.parent.createTemp('local-import-reader-');
  try {
    Future<IosTransferImportLease> lease(File file) async {
      final bytes = await file.readAsBytes();
      final digest = sha256.convert(bytes).toString();
      const id = '1e97c9b1-ec57-4ede-89e7-de6213202380';
      return IosTransferImportLease.fromJson({
        'job': {
          'id': id,
          'revision': 1,
          'direction': 'download',
          'phase': 'validating',
          'createdMs': 1000,
          'updatedMs': 2000,
          'identity': {
            'desktopID': 'generated-ci-fixture',
            'sourceID': 'local-media',
            'origin': 'http://127.0.0.1:5443',
            'localSongID': '42',
            'localServerID': 3,
            'pairingID': '24093104-64d4-44f7-8c8b-8b4b14399067',
          },
          'metadata': {
            'title': 'Generated audio',
            'artist': 'CI fixture',
            'fileExtension': 'wav',
          },
          'expectedBytes': bytes.length,
          'expectedSHA256': digest,
          'receivedBytes': bytes.length,
          'receivedSHA256': digest,
        },
        'leaseID': '3e97c9b1-ec57-4ede-89e7-de6213202380',
        'clientID': '4e97c9b1-ec57-4ede-89e7-de6213202380',
        'reconcileOnly': false,
        'targetRelativePath': 'Desktop Copies/Generated audio - $id-r1.wav',
        'sourcePath': file.path,
      });
    }

    const reader = IosTransferMediaProbe();
    var guardCalls = 0;
    Future<void> fixtureGuard() async {
      guardCalls++;
    }

    Future<IosTransferMediaInfo> inspect(File file) async => reader.inspect(
      await lease(file),
      isCurrent: () => true,
      validateOwnership: fixtureGuard,
    );
    final staged = await generatedWav.copy("${root.path}/source '曲' .download");
    final pcm = await inspect(staged);
    expect(pcm.codec, 'PCM_S16LE');
    expect(pcm.format, 'WAV');
    expect(pcm.sampleRate, 44100);
    expect(pcm.channels, 1);
    expect(pcm.bitDepth, 16);
    expect(pcm.durationMs, inInclusiveRange(7900, 8100));
    final flac = File('${root.path}/lossless.download');
    final aac = File('${root.path}/lossy.download');
    for (final entry in [
      (flac, ['-c:a', 'flac', '-f', 'flac']),
      (aac, ['-c:a', 'aac', '-f', 'ipod']),
    ]) {
      final conversion = await FFmpegKit.executeWithArguments([
        '-v',
        'quiet',
        '-nostdin',
        '-i',
        staged.path,
        ...entry.$2,
        entry.$1.path,
      ]);
      expect(ReturnCode.isSuccess(await conversion.getReturnCode()), true);
    }
    final lossless = await inspect(flac), lossy = await inspect(aac);
    expect(lossless.codec, 'FLAC');
    expect(lossless.format, 'FLAC');
    expect(lossless.bitDepth, 16);
    expect(lossy.codec, 'AAC');
    expect(lossy.format, 'M4A');
    expect(lossy.bitDepth, isNull);
    expect(lossy.sampleRate, 44100);
    expect(lossy.durationMs, inInclusiveRange(7900, 8200));
    expect(guardCalls, 6);
    for (final entry in {
      'corrupt.download': List<int>.filled(128, 7),
      'header-only.download': (await staged.readAsBytes()).take(44).toList(),
    }.entries) {
      final file = File('${root.path}/${entry.key}');
      await file.writeAsBytes(entry.value, flush: true);
      await expectLater(
        inspect(file),
        throwsA(isA<IosTransferMediaException>()),
      );
    }
    await expectLater(
      reader.inspect(
        await lease(staged),
        isCurrent: () => false,
        validateOwnership: fixtureGuard,
      ),
      throwsA(
        isA<IosTransferMediaException>().having(
          (error) => error.reason,
          'reason',
          IosTransferMediaFailure.retired,
        ),
      ),
    );
    return {
      'scope': 'Actual bundled iOS FFprobe over generated local fixtures; ownership callback is a fixture, product import disabled',
      'pcm16_unicode_download_suffix': true,
      'flac16': true,
      'aac_no_invented_bit_depth': true,
      'positive_duration_rate_channels': true,
      'corrupt_and_header_only_refused': true,
      'retired_before_execution_refused': true,
      'product_import_enabled': false,
    };
  } finally {
    await root.delete(recursive: true);
  }
}
