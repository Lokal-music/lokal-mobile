import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/app_preferences_service.dart';
import 'package:flick/services/automix_stem_clip.dart';

Map<String, dynamic> preparedManifest(
  String outgoingHash,
  String incomingHash,
  String mixedHash,
  int bytes,
) => {
  'schema': AutoMixStemClip.schema,
  'source': {'outgoingSha256': outgoingHash, 'incomingSha256': incomingHash},
  'clip': {'sha256': mixedHash, 'bytes': bytes, 'durationSeconds': 16.0},
  'timeline': {
    'outStart': 158.0,
    'inStart': 6.0,
    'resumeIn': 22.0,
    'length': 16.0,
    'masterGain': .9,
  },
};

Song local(String id, String path) => Song(
  id: id,
  title: id,
  artist: 'Artist',
  filePath: path,
  duration: const Duration(minutes: 3),
  fileType: 'FLAC',
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      AppPreferencesService.automixStemClipsKey: true,
    });
    AutoMixStemClipCache.instance.invalidate();
  });

  test(
    'a model pair selects only matching local, fingerprinted clip',
    () async {
      final dir = await Directory.systemTemp.createTemp('lokal-stem-android-');
      addTearDown(() async => dir.delete(recursive: true));
      final outgoing = File('${dir.path}/out.flac');
      final incoming = File('${dir.path}/in.flac');
      await outgoing.writeAsString('outgoing audio');
      await incoming.writeAsString('incoming audio');
      final clipFile = File(
        '${outgoing.path}.lokal-stem-to-${List.filled(24, 'f').join()}.wav',
      );
      final wav = List<int>.filled(256, 0);
      wav.setRange(0, 4, 'RIFF'.codeUnits);
      wav.setRange(8, 12, 'WAVE'.codeUnits);
      await clipFile.writeAsBytes(wav);
      final a = sha256.convert(await outgoing.readAsBytes()).toString();
      final b = sha256.convert(await incoming.readAsBytes()).toString();
      final c = sha256.convert(await clipFile.readAsBytes()).toString();
      final manifest = File('${clipFile.path}.json');
      await manifest.writeAsString(
        jsonEncode(preparedManifest(a, b, c, wav.length)),
      );
      final result = await AutoMixStemClipCache.instance.read(
        local('out', outgoing.path),
        local('in', incoming.path),
      );
      expect(result, isNotNull);
      expect(result!.resume, const Duration(seconds: 22));
      expect(
        AutoMixStemClip.suitableForCues(
          result,
          outgoingStart: 158.1,
          incomingStart: 5.9,
        ),
        isTrue,
      );
      expect(
        AutoMixStemClip.suitableForCues(
          result,
          outgoingStart: 145,
          incomingStart: 6,
        ),
        isFalse,
      );

      // A fresh resolver must not accept a clip after the selected source
      // changes, even when the user transfers a same-named audio file.
      await incoming.writeAsString('different incoming audio');
      AutoMixStemClipCache.instance.invalidate();
      expect(
        await AutoMixStemClipCache.instance.read(
          local('out', outgoing.path),
          local('in', incoming.path),
        ),
        isNull,
      );
    },
  );

  test('opt-out never imports a prepared clip', () async {
    SharedPreferences.setMockInitialValues({
      AppPreferencesService.automixStemClipsKey: false,
    });
    AutoMixStemClipCache.instance.invalidate();
    expect(
      await AutoMixStemClipCache.instance.read(
        local('out', '/tmp/out.flac'),
        local('in', '/tmp/in.flac'),
      ),
      isNull,
    );
  });

  test(
    'corrupt timeline, forged hashes and mismatched clip size are rejected',
    () {
      final sha = List.filled(64, 'a').join();
      final raw = preparedManifest(sha, sha, sha, 256);
      expect(
        AutoMixStemClip.parse(
          raw,
          'mix.wav',
          outgoingSha: sha,
          incomingSha: sha,
          clipSha: sha,
          clipBytes: 256,
        ),
        isNotNull,
      );
      expect(
        AutoMixStemClip.parse(
          raw,
          'mix.wav',
          outgoingSha: sha,
          incomingSha: sha,
          clipSha: sha,
          clipBytes: 257,
        ),
        isNull,
      );
      (raw['timeline'] as Map)['resumeIn'] = 2.0;
      expect(
        AutoMixStemClip.parse(
          raw,
          'mix.wav',
          outgoingSha: sha,
          incomingSha: sha,
          clipSha: sha,
          clipBytes: 256,
        ),
        isNull,
      );
      (raw['timeline'] as Map)['resumeIn'] = 22.0;
      (raw['timeline'] as Map)['length'] = double.nan;
      expect(
        AutoMixStemClip.parse(
          raw,
          'mix.wav',
          outgoingSha: sha,
          incomingSha: sha,
          clipSha: sha,
          clipBytes: 256,
        ),
        isNull,
      );
    },
  );
}
