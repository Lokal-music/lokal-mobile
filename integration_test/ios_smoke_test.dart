import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flick/app/app.dart';
import 'package:flick/main.dart' as app;
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/equalizer_service.dart';
import 'package:flick/providers/equalizer_provider.dart';
import 'package:flick/features/morneye/morneye_bootstrap.dart';
import 'package:flick/src/rust/api/morneye_api.dart';
import 'package:flick/src/rust/api/scanner.dart' as scanner;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';

Uint8List _tone() {
  const rate = 44100, frames = rate * 8;
  final bytes = ByteData(44 + frames * 2);
  void tag(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  bytes.setUint32(4, bytes.lengthInBytes - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, rate, Endian.little);
  bytes.setUint32(28, rate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  bytes.setUint32(40, frames * 2, Endian.little);
  for (var i = 0; i < frames; i++) {
    bytes.setInt16(
      44 + i * 2,
      (math.sin(i * 2 * math.pi * 440 / rate) * 1000).round(),
      Endian.little,
    );
  }
  return bytes.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iPhone cold launch, native scanner/add-ons and real playback', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lyrics_auto_fetch', false);
    await app.bootstrapForIntegrationTest();
    for (
      var i = 0;
      i < 30 && find.byType(FlickPlayerApp).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.byType(FlickPlayerApp), findsOneWidget);
    expect(tester.takeException(), isNull);
    final identity = await const MethodChannel('lokal/app_info')
        .invokeMapMethod<String, dynamic>('get');
    expect(identity?['version'], isNotEmpty);

    final directory = await Directory(
      '${(await getTemporaryDirectory()).path}/ios-native-smoke',
    ).create(recursive: true);
    final audio = File('${directory.path}/Generated tone.wav');
    await audio.writeAsBytes(_tone(), flush: true);
    final scan = await scanner.scanRootDir(
      rootPath: directory.path,
      knownFiles: {},
      scanOptions: const scanner.ScanOptions(
        filterNonMusicFilesAndFolders: false,
        forceFullRescan: true,
      ),
    );
    expect(scan.totalFiles, 1);
    expect(scan.newOrModified.single.sampleRate, 44100);

    final guest = await MorneyeEngine.start(
      code: 'registerExtension({echo(value) { return {value}; }});',
      bootstrap: morneyeBootstrap,
      configJson: jsonEncode({
        'permissions': {'network': [], 'storage': false},
        'settings': {},
      }),
      host: (_, _) => 'null',
    );
    try {
      final echoed = jsonDecode(
        await guest.invoke(
          method: 'echo',
          argsJson: '[42]',
          timeoutMs: BigInt.from(5000),
        ),
      );
      expect(echoed, {'value': 42});
    } finally {
      guest.close();
    }

    final player = PlayerService();
    final song = Song(
      id: 'ios-smoke',
      title: 'Generated tone',
      artist: 'Lokal test',
      duration: const Duration(seconds: 8),
      fileType: 'WAV',
      sampleRate: 44100,
      bitDepth: 16,
      filePath: audio.path,
    );
    await player.play(song, playlist: [song]);
    for (
      var i = 0;
      i < 20 && player.positionNotifier.value.inMilliseconds < 300;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(player.currentEngineType, AudioEngineType.iosSystem);
    expect(player.positionNotifier.value.inMilliseconds, greaterThan(250));
    await player.pause();
    expect(player.isPlayingNotifier.value, false);
    await player.seek(const Duration(seconds: 2));
    expect(
      player.positionNotifier.value.inMilliseconds,
      greaterThanOrEqualTo(1500),
    );

    // Ordinary graphic EQ must select a real iOS DSP backend, not a silent
    // Android AudioEffect call. Exercise the native Core Audio renderer too.
    await applyEqualizer(
      EqualizerState.initial().copyWith(
        graphicGainsDb: [3, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      ),
    );
    await player.syncIosProcessingRoute();
    await player.play(song, playlist: [song]);
    for (
      var i = 0;
      i < 24 && player.positionNotifier.value.inMilliseconds < 300;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(player.currentEngineType, AudioEngineType.iosRust);
    expect(player.positionNotifier.value.inMilliseconds, greaterThan(250));
    await player.pause();
    await applyEqualizer(EqualizerState.initial());
    await player.syncIosProcessingRoute();

    // Validate the FFmpeg iOS binaries and an actual Rust-only container.
    final wavpack = File('${directory.path}/Generated tone.wv');
    final conversion = await FFmpegKit.executeWithArguments([
      '-y',
      '-i',
      audio.path,
      '-c:a',
      'wavpack',
      wavpack.path,
    ]);
    expect(ReturnCode.isSuccess(await conversion.getReturnCode()), true);
    final wvSong = song.copyWith(
      id: 'ios-smoke-wavpack',
      filePath: wavpack.path,
      fileType: 'WV',
    );
    await player.play(wvSong, playlist: [wvSong]);
    for (
      var i = 0;
      i < 24 && player.positionNotifier.value.inMilliseconds < 300;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(player.currentEngineType, AudioEngineType.iosRust);
    expect(player.positionNotifier.value.inMilliseconds, greaterThan(250));
    await player.pause();
    player.dispose();
    await directory.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
