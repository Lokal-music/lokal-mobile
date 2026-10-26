import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/music_videos/music_video_surface.dart';

Future<void> main() async {
  var hasNode = false;
  try {
    hasNode = (await Process.run('node', ['--version'])).exitCode == 0;
  } on ProcessException {
    /* CI explicitly requires Node before this selection. */
  }
  test(
    'production iframe script owns its actual clock, errors and release handshake',
    () async {
      final temp = await Directory.systemTemp.createTemp('lokal-video-js-');
      try {
        final html = File('${temp.path}/player.html');
        await html.writeAsString(musicVideoEmbedHtml('abcdefghijk'));
        final result = await Process.run('node', [
          'test/fixtures/music_video_iframe_contract.mjs',
          html.path,
        ]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect((jsonDecode(result.stdout as String) as Map)['checks'], 4);
      } finally {
        await temp.delete(recursive: true);
      }
    },
    skip: hasNode
        ? false
        : 'Node.js is required for the iframe JavaScript contract.',
  );
}
