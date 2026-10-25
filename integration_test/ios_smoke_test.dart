import 'dart:convert';
import 'dart:io';

import 'package:flick/app/app.dart';
import 'package:flick/features/konnekted/konnekted_shell.dart';
import 'package:flick/features/konnekted/konnekted_library.dart';
import 'package:flick/features/konnekted/konnekted_you.dart';
import 'package:flick/features/settings/lokal/lokal_settings_page.dart';
import 'package:flick/features/onboarding/screens/onboarding_screen.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/main.dart' as app;
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/app_preferences_service.dart';
import 'package:flick/services/replaygain_service.dart';
import 'package:flick/services/playback_secure_storage.dart';
import 'package:flick/services/link/lokal_link_service.dart';
import 'package:flick/services/equalizer_service.dart';
import 'package:flick/providers/equalizer_provider.dart';
import 'package:flick/features/morneye/morneye_bootstrap.dart';
import 'package:flick/src/rust/api/morneye_api.dart';
import 'package:flick/src/rust/api/scanner.dart' as scanner;
import 'package:flick/src/rust/api/metadata_editor.dart' as tags;
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show SizedBox;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';

import '../test/fixtures/generated_audio.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
    final playbackPreferences = AppPreferencesService();
    await playbackPreferences.setReplayGainMode(ReplayGainMode.off);
    await playbackPreferences.setReplayGainPreampDb(0);
    await playbackPreferences.setReplayGainPreventClipping(true);
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

    for (final destination in [
      (label: 'Library', type: KonnektedLibrary, screenshot: 'ios-library'),
      (label: 'You', type: KonnektedYou, screenshot: 'ios-you'),
      (label: 'Settings', type: LokalSettingsPage, screenshot: 'ios-settings'),
    ]) {
      debugPrint('iOS smoke: navigate ${destination.label}');
      await tester.tap(find.byTooltip(lokalText(destination.label)));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(find.byType(destination.type), findsOneWidget);
      expect(tester.takeException(), isNull, reason: startupErrors.join('\n'));
      await binding.takeScreenshot(destination.screenshot);
    }
    await tester.tap(find.byTooltip(lokalText('Home')));
    await tester.pump(const Duration(milliseconds: 750));

    // Exercise the actual Keychain, including a legacy when-unlocked item.
    // No account tokens are needed, and fixture values never enter the report.
    debugPrint('iOS smoke: native Keychain legacy migration');
    const legacyStorage = FlutterSecureStorage();
    const playbackStorage = PlaybackSecureStorage();
    final credentialKey =
        'lokal.ios-smoke.${DateTime.now().microsecondsSinceEpoch}';
    addTearDown(() => playbackStorage.delete(key: credentialKey));
    await legacyStorage.write(key: credentialKey, value: 'generated-fixture');
    expect(await playbackStorage.read(key: credentialKey), 'generated-fixture');
    expect(await playbackStorage.containsKey(key: credentialKey), true);
    await playbackStorage.write(key: credentialKey, value: 'updated-fixture');
    expect((await playbackStorage.readAll())[credentialKey], 'updated-fixture');
    await playbackStorage.delete(key: credentialKey);
    expect(await playbackStorage.containsKey(key: credentialKey), false);
    binding.reportData = {
      ...?binding.reportData,
      'keychain_legacy_migration': 'passed',
      'library_you_settings_navigation': 'passed',
    };

    final directory = await (await getTemporaryDirectory()).createTemp(
      'ios-native-smoke-',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final audio = File('${directory.path}/Generated tone.wav');
    await audio.writeAsBytes(generatedPcmTone(), flush: true);
    final tagged = await tags.writeTags(
      path: audio.path,
      fields: const tags.TagEditFields(
        title: 'Generated tone',
        artist: 'Lokal test',
        album: 'Native fixtures',
        albumArtist: 'Various fixtures',
      ),
    );
    expect(tagged.success, true, reason: tagged.error);
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
    expect(scan.newOrModified.single.albumArtist, 'Various fixtures');

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

    // Independent pitch is not implemented by just_audio on iOS. Changing it
    // during playback must reopen the track through native SoundTouch, retain
    // its position, and return to AVPlayer when processing is reset.
    await player.play(song, playlist: [song]);
    expect(player.currentEngineType, AudioEngineType.iosSystem);
    await player.setPitchSemitones(3);
    expect(player.currentEngineType, AudioEngineType.iosRust);
    final pitchProgress = await _expectPlaybackProgress(tester, player);
    await player.setPitchSemitones(0);
    expect(player.currentEngineType, AudioEngineType.iosSystem);
    final pitchResetProgress = await _expectPlaybackProgress(tester, player);
    await player.pause();

    // Positive normalization cannot be implemented by AVPlayer's capped volume.
    // Use Rust gain, including a live switch back when normalization is disabled.
    final normalizedSong = song.copyWith(
      id: 'ios-smoke-replaygain',
      replaygainTrackGain: 3,
      replaygainTrackPeak: 0.1,
    );
    await playbackPreferences.setReplayGainMode(ReplayGainMode.track);
    await player.play(normalizedSong, playlist: [normalizedSong]);
    expect(player.currentEngineType, AudioEngineType.iosRust);
    expect(player.replayGainState.gainDb, 3);
    final normalizationProgress = await _expectPlaybackProgress(tester, player);
    await playbackPreferences.setReplayGainMode(ReplayGainMode.off);
    await player.applyReplayGainFromSettings();
    expect(player.currentEngineType, AudioEngineType.iosSystem);
    expect(player.replayGainState.gainDb, 0);
    await _expectPlaybackProgress(tester, player);
    await player.pause();

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
    await player.pause();

    // Generated fixtures avoid redistributing copyrighted recordings. Decode
    // each through its intended production backend, with native metadata and
    // progress checks. These are compatibility checks, not output fidelity tests.
    final codecResults = <String, Object>{};
    Song? opusFixture;
    binding.reportData = {
      ...?binding.reportData,
      'version': identity?['version'],
      'native_scan_files': scan.totalFiles,
      'native_scan_sample_rate': scan.newOrModified.single.sampleRate,
      'native_scan_album_artist': scan.newOrModified.single.albumArtist,
      'quickjs_echo': quickJsResult,
      'system_wav_progress_ms': systemProgress,
      'rust_dsp_progress_ms': dspProgress,
      'rust_pitch_progress_ms': pitchProgress,
      'system_pitch_reset_progress_ms': pitchResetProgress,
      'rust_positive_replaygain_progress_ms': normalizationProgress,
      'rust_wavpack_progress_ms': wavpackProgress,
      'ffmpeg_wavpack_conversion': 'passed',
      'onboarding_to_app_shell': 'passed',
      'codec_corpus': codecResults,
    };
    for (final fixture in [
      (
        name: 'mp3-vbr',
        extension: 'mp3',
        encoder: ['-c:a', 'libmp3lame', '-q:a', '4'],
        sampleRate: 44100,
        engine: AudioEngineType.iosSystem,
      ),
      (
        name: 'aac',
        extension: 'm4a',
        encoder: ['-c:a', 'aac', '-b:a', '128k'],
        sampleRate: 44100,
        engine: AudioEngineType.iosSystem,
      ),
      (
        name: 'alac',
        extension: 'm4a',
        encoder: ['-c:a', 'alac'],
        sampleRate: 44100,
        engine: AudioEngineType.iosSystem,
      ),
      (
        name: 'flac-96k-stereo',
        extension: 'flac',
        encoder: ['-c:a', 'flac', '-ar', '96000', '-ac', '2'],
        sampleRate: 96000,
        engine: AudioEngineType.iosSystem,
      ),
      (
        name: 'aiff',
        extension: 'aiff',
        encoder: ['-c:a', 'pcm_s16be'],
        sampleRate: 44100,
        engine: AudioEngineType.iosSystem,
      ),
      (
        name: 'vorbis',
        extension: 'ogg',
        encoder: ['-c:a', 'libvorbis', '-q:a', '4'],
        sampleRate: 44100,
        engine: AudioEngineType.iosRust,
      ),
      (
        name: 'opus',
        extension: 'opus',
        encoder: ['-c:a', 'libopus', '-ar', '48000'],
        sampleRate: 48000,
        engine: AudioEngineType.iosRust,
      ),
    ]) {
      debugPrint('iOS codec corpus: ${fixture.name}');
      final folder = await Directory('${directory.path}/${fixture.name}')
          .create();
      final file = File('${folder.path}/Été 音楽.${fixture.extension}');
      final encoded = await FFmpegKit.executeWithArguments([
        '-y',
        '-i',
        audio.path,
        ...fixture.encoder,
        file.path,
      ]);
      expect(
        ReturnCode.isSuccess(await encoded.getReturnCode()),
        true,
        reason: 'Fixture generation failed: ${fixture.name}',
      );
      final metadata = await scanner.scanRootDir(
        rootPath: folder.path,
        knownFiles: {},
        scanOptions: const scanner.ScanOptions(
          filterNonMusicFilesAndFolders: false,
          forceFullRescan: true,
        ),
      );
      expect(metadata.newOrModified, hasLength(1), reason: fixture.name);
      expect(
        metadata.newOrModified.single.sampleRate,
        fixture.sampleRate,
        reason: fixture.name,
      );
      final track = song.copyWith(
        id: 'ios-corpus-${fixture.name}',
        filePath: file.path,
        fileType: fixture.extension.toUpperCase(),
        sampleRate: fixture.sampleRate,
      );
      if (fixture.name == 'opus') opusFixture = track;
      await player.play(track, playlist: [track]);
      final progress = await _expectPlaybackProgress(tester, player);
      expect(player.currentEngineType, fixture.engine, reason: fixture.name);
      await player.pause();
      expect(player.isPlayingNotifier.value, false, reason: fixture.name);
      codecResults[fixture.name] = {
        'engine': player.currentEngineType.name,
        'source_sample_rate': metadata.newOrModified.single.sampleRate,
        'progress_ms': progress,
      };
    }
    // A system player's internal playlist can reach an unsupported codec
    // without calling PlayerService.play. Check the real auto-advance/error
    // handoff, rather than only explicitly selecting a Rust-only track.
    final successor = opusFixture!;
    final queueStart = song.copyWith(id: 'ios-smoke-queue-start');
    await player.play(queueStart, playlist: [queueStart, successor]);
    expect(player.currentEngineType, AudioEngineType.iosSystem);
    await player.seek(const Duration(seconds: 7));
    for (
      var i = 0;
      i < 48 && player.currentEngineType != AudioEngineType.iosRust;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(player.currentSongNotifier.value?.id, successor.id);
    expect(player.currentEngineType, AudioEngineType.iosRust);
    final queueProgress = await _expectPlaybackProgress(tester, player);
    binding.reportData!['system_to_rust_queue_progress_ms'] = queueProgress;
    await player.pause();

    debugPrint('iOS smoke: real Bonjour desktop discovery and HTTP probe');
    const fixtureId = String.fromEnvironment(
      'LOKAL_IOS_DISCOVERY_FIXTURE',
      defaultValue: 'lokal-ios-local-fixture',
    );
    final link = LokalLinkService();
    addTearDown(link.close);
    final desktops = await link.discover();
    final fixture = desktops
        .where((desktop) => desktop.id == fixtureId)
        .toList();
    expect(
      fixture,
      hasLength(1),
      reason: 'Native Bonjour did not resolve the fixture',
    );
    expect(
      desktops.any((desktop) => desktop.id == '$fixtureId-unsupported'),
      false,
    );
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client
          .getUrl(fixture.single.origin.resolve('/lokal-ios-discovery-probe'))
          .timeout(const Duration(seconds: 5));
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 5));
      expect(jsonDecode(body), {'id': fixtureId, 'proto': 1});
    } finally {
      client.close(force: true);
    }
    binding.reportData!['bonjour_fixture_discovery_and_http'] = 'passed';
    binding.reportData!['bonjour_unsupported_protocol_filtered'] = true;

    await tester.pumpWidget(const SizedBox.shrink());
    player.dispose();
  }, timeout: const Timeout(Duration(minutes: 4)));
}
