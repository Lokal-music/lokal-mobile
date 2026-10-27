import 'dart:convert';
import 'dart:io';

import 'package:flick/data/entities/song_audio_cache_entity.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/automix_analysis_cache.dart';
import 'package:flutter_test/flutter_test.dart';

Song localSong(String path, {String id = '14', int? startOffsetMs}) => Song(
  id: id, title: 'Local track', artist: 'Artist',
  filePath: path, fileType: 'FLAC',
  duration: const Duration(minutes: 3),
  startOffsetMs: startOffsetMs,
);

SongAudioCacheEntity waveform(int updatedAt) => SongAudioCacheEntity()
  ..songId = 14
  ..version = 1
  ..computedAt = updatedAt
  ..lufs = -13
  ..peaks = [
    ...List<double>.filled(8, 0),
    ...List<double>.filled(210, 0.8),
    ...List<double>.generate(12, (i) => .7 * (1 - i / 12)),
    ...List<double>.filled(10, 0),
  ];

void main() {
  test('cue profile derives silence and energy from cached waveforms', () {
    final profile = AutoMixProfile.fromWaveform(
      waveform(0).peaks, const Duration(minutes: 3), lufs: -13,
    );
    expect(profile, isNotNull);
    expect(profile!.leadInSeconds, greaterThan(4));
    expect(profile.audibleEndSeconds, lessThan(180));
    expect(profile.energy, closeTo(17 / 22, .001));
    final restored = AutoMixProfile.fromJson(jsonDecode(jsonEncode(profile.toJson())));
    expect(restored!.audibleEndSeconds, profile.audibleEndSeconds);
    expect(restored.entrances, profile.entrances);
    expect(AutoMixProfile.fromJson({'duration': double.nan}), isNull);
  });

  test('persistent cache reuses analysis and invalidates when file changes', () async {
    final dir = await Directory.systemTemp.createTemp('lokal-automix-profile-');
    addTearDown(() async => dir.delete(recursive: true));
    final source = File('${dir.path}/track.flac');
    await source.writeAsString('original content');
    final storage = Directory('${dir.path}/profiles');
    var calls = 0;
    var updatedAt = DateTime.now().add(const Duration(seconds: 10)).millisecondsSinceEpoch;
    Future<SongAudioCacheEntity?> load(int id) async {
      calls++;
      return waveform(updatedAt);
    }
    AutoMixAnalysisCache cache() => AutoMixAnalysisCache(
      loadWaveform: load, directory: () async => storage,
    );
    final first = cache();
    final profile = await first.read(localSong(source.path));
    expect(profile, isNotNull);
    expect(await first.read(localSong(source.path)), isNotNull);
    expect(calls, 1);
    expect(storage.listSync().whereType<File>().length, 1);

    // A new app session must read the persisted profile, not decode or
    // recompute the analysis from Isar.
    final second = cache();
    expect(await second.read(localSong(source.path)), isNotNull);
    expect(calls, 1);

    await source.writeAsString('modified audio content, different length');
    updatedAt = DateTime.now().add(const Duration(seconds: 10)).millisecondsSinceEpoch;
    expect(await second.read(localSong(source.path)), isNotNull);
    expect(calls, 2);
    expect(storage.listSync().whereType<File>().length, 2);
  });

  test('corrupted derived files are regenerated without re-decoding audio', () async {
    final dir = await Directory.systemTemp.createTemp('lokal-automix-corrupt-');
    addTearDown(() async => dir.delete(recursive: true));
    final source = File('${dir.path}/local.flac');
    await source.writeAsString('unchanged source');
    final storage = Directory('${dir.path}/profiles');
    var count = 0;
    AutoMixAnalysisCache create() => AutoMixAnalysisCache(
      directory: () async => storage,
      loadWaveform: (id) async {
        count++;
        return waveform(DateTime.now().add(const Duration(seconds: 4))
            .millisecondsSinceEpoch);
      },
    );
    final track = localSong(source.path);
    expect(await create().read(track), isNotNull);
    final jsonFile = storage.listSync().whereType<File>().single;
    await jsonFile.writeAsString('{damaged');
    expect(await create().read(track), isNotNull);
    expect(count, 2, reason: 'corruption uses existing Isar peaks');
    expect(jsonDecode(await jsonFile.readAsString()), isA<Map>());
  });

  test('does not reuse stale waveform data or signed streaming handles', () async {
    final dir = await Directory.systemTemp.createTemp('lokal-automix-stale-');
    addTearDown(() async => dir.delete(recursive: true));
    final source = File('${dir.path}/audio.flac');
    await source.writeAsString('track');
    var calls = 0;
    final cache = AutoMixAnalysisCache(
      directory: () async => Directory('${dir.path}/analysis'),
      loadWaveform: (id) async {
        calls++;
        return waveform(1); // stale relative to the local file
      },
    );
    expect(await cache.read(localSong(source.path)), isNull);
    expect(await cache.read(localSong(source.path, startOffsetMs: 1200)), isNull);
    expect(await cache.read(localSong('https://example.test/signed?token=private')), isNull);
    expect(await cache.read(localSong(source.path, id: 'pending:12')), isNull);
    expect(calls, 1);
  });
}
