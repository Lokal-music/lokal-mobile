import 'dart:convert';
import 'dart:io';

import 'package:flick/models/song.dart';
import 'package:flick/services/automix_advanced_report.dart';
import 'package:flick/services/automix_analysis_cache.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> sample(int size, int modified) => {
  'schema':'lokal-automix-advanced-v1',
  'source':{'size':size,'mtimeMs':modified,'sha256':'a' * 64},
  'analyzer':{'id':'disco-eth/cue-detr','revision':'b' * 40},
  'durationSeconds':180.0,
  'bpm':120.0,
  'transitionCues':{
    'entrances':[{'time':6.0,'confidence':0.95}],
    'exits':[{'time':158.0,'confidence':0.95}],
  },
};

void main() {
  test('validates offline cue roles and exact source revision', () {
    final raw = sample(1000, 1760000000000);
    final model = AutoMixAdvancedReport.parse(raw,
      sourceSize:1000, sourceModifiedMs:1760000000000,
      expectedDuration:180);
    expect(model, isNotNull);
    expect(model!.entrances, [6]);
    expect(model.exits, [158]);
    expect(model.bpm, 120);
    expect(AutoMixAdvancedReport.parse(raw,
      sourceSize:1001, sourceModifiedMs:1760000000000,
      expectedDuration:180), isNull);
    expect(AutoMixAdvancedReport.parse(raw,
      sourceSize:1000, sourceModifiedMs:1760000005000,
      expectedDuration:180), isNull);
    expect(AutoMixAdvancedReport.parse(raw,
      sourceSize:1000, sourceModifiedMs:1760000000000,
      expectedDuration:170), isNull);
  });

  test('rejects NaN, invalid confidence, and forged report provenance', () {
    final original = sample(1000, 100);
    final invalid = jsonDecode(jsonEncode(original)) as Map<String,dynamic>;
    (invalid['transitionCues'] as Map)['entrances'] = [
      {'time':15.0,'confidence':0.1},
    ];
    expect(AutoMixAdvancedReport.parse(invalid,
      sourceSize:1000,sourceModifiedMs:100,expectedDuration:180),isNull);
    (invalid['transitionCues'] as Map)['entrances'] = [
      {'time':double.nan,'confidence':0.9},
    ];
    expect(AutoMixAdvancedReport.parse(invalid,
      sourceSize:1000,sourceModifiedMs:100,expectedDuration:180),isNull);
    invalid['analyzer'] = {'id':'unrecognized-model','revision':'x'};
    expect(AutoMixAdvancedReport.parse(invalid,
      sourceSize:1000,sourceModifiedMs:100,expectedDuration:180),isNull);
  });

  test('model-only sidecar works without a waveform cache', () async {
    final dir = await Directory.systemTemp.createTemp('lokal-advanced-cues-');
    addTearDown(() async => dir.delete(recursive:true));
    final audio = File('${dir.path}/track.flac');
    await audio.writeAsString('fake audio bytes');
    final stamp = await audio.stat();
    final sidecar = File('${audio.path}${AutoMixAdvancedReport.suffix}');
    await sidecar.writeAsString(jsonEncode(sample(
      stamp.size,stamp.modified.millisecondsSinceEpoch,
    )));
    var waveformCalls = 0;
    final cache = AutoMixAnalysisCache(
      directory:() async => Directory('${dir.path}/derived'),
      loadWaveform:(id) async { waveformCalls++; return null; },
    );
    final track = Song(
      id:'14',title:'Prepared',artist:'Artist',
      duration:const Duration(minutes:3),filePath:audio.path,fileType:'FLAC',
    );
    final result = await cache.read(track);
    expect(result, isNotNull);
    expect(result!.modelEntrances,[6]);
    expect(result.modelExits,[158]);
    expect(result.analyzedBpm,120);
    expect(waveformCalls,1);
    // No automatic model execution; a new instance reuses the same report.
    final second = await cache.read(track);
    expect(second!.modelEntrances,[6]);
    expect(waveformCalls,1);

    await sidecar.writeAsString('corrupt');
    expect((await cache.read(track))?.modelEntrances, isEmpty);
  });
}
