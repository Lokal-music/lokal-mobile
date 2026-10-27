import 'dart:convert';
import 'dart:io';

import 'package:flick/models/song.dart';
import 'package:flick/services/automix_advanced_report.dart';
import 'package:flick/services/automix_analysis_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';

Map<String, dynamic> sample(int size, int modified) => {
  'schema': 'lokal-automix-advanced-v1',
  'source': {
    'size': size,
    'mtimeMs': modified,
    'sha256': List.filled(64, 'a').join(),
  },
  'analyzer': {
    'id': 'disco-eth/cue-detr',
    'revision': List.filled(40, 'b').join(),
  },
  'durationSeconds': 180.0,
  'bpm': 120.0,
  'transitionCues': {
    'entrances': [
      {'time': 6.0, 'confidence': 0.95},
    ],
    'exits': [
      {'time': 158.0, 'confidence': 0.95},
    ],
  },
};

void main() {
  test('validates offline cue roles and exact source revision', () {
    final raw = sample(1000, 1760000000000);
    final model = AutoMixAdvancedReport.parse(
      raw,
      sourceSize: 1000,
      sourceModifiedMs: 1760000000000,
      expectedDuration: 180,
    );
    expect(model, isNotNull);
    expect(model!.entrances, [6]);
    expect(model.exits, [158]);
    expect(model.bpm, 120);
    expect(
      AutoMixAdvancedReport.parse(
        raw,
        sourceSize: 1001,
        sourceModifiedMs: 1760000000000,
        expectedDuration: 180,
      ),
      isNull,
    );
    expect(
      AutoMixAdvancedReport.parse(
        raw,
        sourceSize: 1000,
        sourceModifiedMs: 1760000005000,
        expectedDuration: 180,
      ),
      isNull,
    );
    expect(
      AutoMixAdvancedReport.parse(
        raw,
        sourceSize: 1000,
        sourceModifiedMs: 1760000000000,
        expectedDuration: 170,
      ),
      isNull,
    );
  });

  test('rejects NaN, invalid confidence, and forged report provenance', () {
    final original = sample(1000, 100);
    final invalid = jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
    (invalid['transitionCues'] as Map)['entrances'] = [
      {'time': 15.0, 'confidence': 0.1},
    ];
    expect(
      AutoMixAdvancedReport.parse(
        invalid,
        sourceSize: 1000,
        sourceModifiedMs: 100,
        expectedDuration: 180,
      ),
      isNull,
    );
    (invalid['transitionCues'] as Map)['entrances'] = [
      {'time': double.nan, 'confidence': 0.9},
    ];
    expect(
      AutoMixAdvancedReport.parse(
        invalid,
        sourceSize: 1000,
        sourceModifiedMs: 100,
        expectedDuration: 180,
      ),
      isNull,
    );
    invalid['analyzer'] = {'id': 'unrecognized-model', 'revision': 'x'};
    expect(
      AutoMixAdvancedReport.parse(
        invalid,
        sourceSize: 1000,
        sourceModifiedMs: 100,
        expectedDuration: 180,
      ),
      isNull,
    );
  });

  test(
    'copied audio accepts the sidecar by full content hash, not old mtime',
    () async {
      final dir = await Directory.systemTemp.createTemp('lokal-automix-copy-');
      addTearDown(() async => dir.delete(recursive: true));
      final audio = File('${dir.path}/copied.mp3');
      await audio.writeAsString('identical bytes after copy');
      final stat = await audio.stat();
      final report = sample(
        stat.size,
        stat.modified.millisecondsSinceEpoch - 60000,
      );
      (report['source'] as Map)['sha256'] = sha256
          .convert(await audio.readAsBytes())
          .toString();
      final sidecar = File('${audio.path}${AutoMixAdvancedReport.suffix}');
      await sidecar.writeAsString(jsonEncode(report));
      final loaded = await AutoMixAdvancedReport.read(
        audio.path,
        stat,
        const Duration(minutes: 3),
      );
      expect(loaded?.exits, [158]);

      // A different audio file with the same byte count but altered content
      // must not get the source report even when the stored file stamp is old.
      await audio.writeAsString('different bytes after copy');
      expect(
        await AutoMixAdvancedReport.read(
          audio.path,
          await audio.stat(),
          const Duration(minutes: 3),
        ),
        isNull,
      );
    },
  );

  test('model-only sidecar works without a waveform cache', () async {
    final dir = await Directory.systemTemp.createTemp('lokal-advanced-cues-');
    addTearDown(() async => dir.delete(recursive: true));
    final audio = File('${dir.path}/track.flac');
    await audio.writeAsString('fake audio bytes');
    final stamp = await audio.stat();
    final sidecar = File('${audio.path}${AutoMixAdvancedReport.suffix}');
    await sidecar.writeAsString(
      jsonEncode(sample(stamp.size, stamp.modified.millisecondsSinceEpoch)),
    );
    var waveformCalls = 0;
    final cache = AutoMixAnalysisCache(
      directory: () async => Directory('${dir.path}/derived'),
      loadWaveform: (id) async {
        waveformCalls++;
        return null;
      },
    );
    final track = Song(
      id: '14',
      title: 'Prepared',
      artist: 'Artist',
      duration: const Duration(minutes: 3),
      filePath: audio.path,
      fileType: 'FLAC',
    );
    final result = await cache.read(track);
    expect(result, isNotNull);
    expect(result!.modelEntrances, [6]);
    expect(result.modelExits, [158]);
    expect(result.analyzedBpm, 120);
    expect(waveformCalls, 1);
    // No automatic model execution; a new instance reuses the same report.
    final second = await cache.read(track);
    expect(second!.modelEntrances, [6]);
    expect(waveformCalls, 1);

    // A fresh app session reuses the separately saved verified cues without
    // consulting Isar again. The presence and positive BPM are persisted.
    final restarted = AutoMixAnalysisCache(
      directory: () async => Directory('${dir.path}/derived'),
      loadWaveform: (id) async {
        fail('validated model report must not require fresh Isar data');
      },
    );
    final afterRestart = await restarted.read(track);
    expect(afterRestart?.modelEntrances, [6]);
    expect(afterRestart?.analyzedBpm, 120);

    await sidecar.writeAsString('corrupt');
    expect(await cache.read(track), isNull);
  });
}
