import 'dart:convert';
import 'dart:io';

import 'package:flick/features/music_videos/music_video_surface.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fixtures/generated_ios_video.dart';
import '../../fixtures/native_web_video_document.dart';

void main() {
  test(
    'offline iframe scripts forward real media commands without autoplay',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lokal-native-video-',
      );
      try {
        for (final paused in [false, true]) {
          final file = File('${directory.path}/fixture.html');
          await file.writeAsString(
            nativeWebVideoFixtureDocument(
              videoId: 'abcdefghijk',
              appId: 'app.lokal.mobile',
              deferAutoplayToHost: true,
              startPaused: paused,
              initialPosition: const Duration(milliseconds: 2345),
            ),
          );
          final result = await Process.run('node', [
            'test/fixtures/native_video_fixture_contract.mjs',
            file.path,
            paused ? 'paused' : 'ready',
          ]);
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
          expect((jsonDecode(result.stdout as String) as Map)['checks'], 8);
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
  test('offline native fixture retains the exact production bridge and reset flags', () {
    for (final paused in [false, true]) {
      final production = musicVideoEmbedHtml(
        'abcdefghijk',
        appId: 'app.lokal.mobile',
        deferAutoplayToHost: true,
        startPaused: paused,
        initialPosition: const Duration(milliseconds: 2345),
      );
      final bridge = RegExp(r'<script>([\s\S]*?)</script>')
          .firstMatch(production)!
          .group(1)!;
      final fixture = nativeWebVideoFixtureDocument(
        videoId: 'abcdefghijk',
        appId: 'app.lokal.mobile',
        deferAutoplayToHost: true,
        startPaused: paused,
        initialPosition: const Duration(milliseconds: 2345),
      );
      expect(fixture, contains(bridge));
      expect(fixture, isNot(contains('https://www.youtube.com')));
      expect(fixture, contains('data:video/mp4;base64,'));
      expect(fixture, contains('getVideoPlaybackQuality'));
      expect(fixture, contains('media.currentTime'));
      expect(fixture, contains('const lokalInitialSeconds = 2.345;'));
      final encodedChild = RegExp(r'frame.srcdoc = (.+);')
          .firstMatch(fixture)!
          .group(1)!;
      final child = jsonDecode(encodedChild) as String;
      expect(child, contains('<video id="media"'));
      expect(child, endsWith('</script></body></html>'));
    }
  });

  test(
    'generated media carries MP4 H.264 and AAC tracks for real WebKit decoding',
    () {
      final bytes = base64Decode(iosNativeVideoFixtureBase64);
      final data = latin1.decode(bytes);
      expect(data.substring(4, 8), 'ftyp');
      expect(data, contains('avc1'));
      expect(data, contains('mp4a'));
    },
  );
}
