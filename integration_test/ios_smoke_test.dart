import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flick/app/app.dart';
import 'package:flick/features/konnekted/konnekted_shell.dart';
import 'package:flick/features/onboarding/screens/onboarding_screen.dart';
import 'package:flick/l10n/l10n.dart';
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
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show SizedBox;
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

Future<int> _expectPlaybackProgress(
  WidgetTester tester,
  PlayerService player,
) async {
  // Establish a baseline after initial seek/position events have arrived. A
  // retained position from a previous backend must not pass a playback check.
  await tester.pump(const Duration(milliseconds: 500));
  final initial = player.positionNotifier.value;
  for (var i = 0; i < 24; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (player.positionNotifier.value - initial >
        const Duration(milliseconds: 300)) {
      expect(player.isPlayingNotifier.value, true);
      return (player.positionNotifier.value - initial).inMilliseconds;
    }
  }
  fail('The actual playback position did not advance after $initial');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iPhone cold launch, native scanner/add-ons and real playback', (
    tester,
  ) async {
    final startupErrors = <String>[];
    final testErrorHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      startupErrors.add(details.toString());
      testErrorHandler?.call(details);
    };
    addTearDown(() => FlutterError.onError = testErrorHandler);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lyrics_auto_fetch', false);
    debugPrint('iOS smoke: real application bootstrap');
    await app.bootstrapForIntegrationTest();
    for (
      var i = 0;
      i < 30 && find.byType(FlickPlayerApp).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.byType(FlickPlayerApp), findsOneWidget);
    if (find.byType(OnboardingScreen).evaluate().isNotEmpty) {
      await tester.tap(find.text(lokalText('Skip Setup')));
    }
    for (
      var i = 0;
      i < 30 && find.byType(KonnektedShell).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.byType(KonnektedShell), findsOneWidget);
    expect(tester.takeException(), isNull, reason: startupErrors.join('\n\n'));
    final identity = await const MethodChannel('lokal/app_info')
        .invokeMapMethod<String, dynamic>('get');
    expect(identity?['version'], isNotEmpty);

    final directory = await (await getTemporaryDirectory()).createTemp(
      'ios-native-smoke-',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
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

    debugPrint('iOS smoke: native scanner passed; executing QuickJS');

    final guest = await MorneyeEngine.start(
      code: 'registerExtension({echo(value) { return {value}; }});',
      bootstrap: morneyeBootstrap,
      configJson: jsonEncode({
        'permissions': {'network': [], 'storage': false},
        'settings': {},
      }),
      host: (_, _) => 'null',
    );
    late final Object? quickJsResult;
    try {
      final echoed = jsonDecode(
        await guest.invoke(
          method: 'echo',
          argsJson: '[42]',
          timeoutMs: BigInt.from(5000),
        ),
      );
      expect(echoed, {'value': 42});
      quickJsResult = echoed;
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
    final systemProgress = await _expectPlaybackProgress(tester, player);
    expect(player.currentEngineType, AudioEngineType.iosSystem);
    await binding.takeScreenshot('ios-main-player');
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
    final dspProgress = await _expectPlaybackProgress(tester, player);
    expect(player.currentEngineType, AudioEngineType.iosRust);
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
    final wavpackProgress = await _expectPlaybackProgress(tester, player);
    expect(player.currentEngineType, AudioEngineType.iosRust);
    binding.reportData = {
      ...?binding.reportData,
      'version': identity?['version'],
      'native_scan_files': scan.totalFiles,
      'native_scan_sample_rate': scan.newOrModified.single.sampleRate,
      'quickjs_echo': quickJsResult,
      'system_wav_progress_ms': systemProgress,
      'rust_dsp_progress_ms': dspProgress,
      'rust_wavpack_progress_ms': wavpackProgress,
      'ffmpeg_wavpack_conversion': 'passed',
      'onboarding_to_app_shell': 'passed',
    };
    await player.pause();
    await tester.pumpWidget(const SizedBox.shrink());
    player.dispose();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
