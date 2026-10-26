import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flick/app/app.dart';
import 'package:flick/features/konnekted/konnekted_shell.dart';
import 'package:flick/features/konnekted/konnekted_library.dart';
import 'package:flick/features/konnekted/konnekted_you.dart';
import 'package:flick/features/konnekted/konnekted_dock.dart';
import 'package:flick/features/search/screens/search_screen.dart';
import 'package:flick/features/search/widgets/search_filter_chips.dart';
import 'package:flick/features/search/providers/search_filter_provider.dart';
import 'package:flick/features/search/models/search_category.dart';
import 'package:flick/features/player/screens/full_player_screen.dart';
import 'package:flick/features/player/widgets/immersive_lyrics_stage.dart';
import 'package:flick/features/player/widgets/player_artwork_image.dart';
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
import 'package:flick/services/notification_service.dart';
import 'package:flick/services/equalizer_service.dart';
import 'package:flick/providers/equalizer_provider.dart';
import 'package:flick/features/morneye/morneye_bootstrap.dart';
import 'package:flick/src/rust/api/morneye_api.dart';
import 'package:flick/src/rust/api/scanner.dart' as scanner;
import 'package:flick/src/rust/api/metadata_editor.dart' as tags;
import 'package:flick/src/rust/api/audio_api.dart' as native_audio;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';

import '../test/fixtures/generated_audio.dart';
import 'ios_live_video_probe.dart';

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

    // Real registered Cast bridge, without opting into discovery or prompting
    // for LAN access on startup. This does not establish receiver acceptance.
    const castChannel = MethodChannel('com.mossapps.flick/cast');
    final castBefore = await const MethodChannel('lokal/ios')
        .invokeMapMethod<String, dynamic>('castSenderState');
    expect(castBefore?['sdkInitialized'], false);
    await expectLater(
      castChannel.invokeMethod<double>('getVolume'),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'CAST_DISCONNECTED',
        ),
      ),
    );
    expect(
      await castChannel.invokeListMethod<dynamic>('getOutputRoutes'),
      isEmpty,
    );
    final castAfter = await const MethodChannel('lokal/ios')
        .invokeMapMethod<String, dynamic>('castSenderState');
    expect(castAfter?['sdkInitialized'], false);
    expect(castAfter?['pendingRequests'], 0);
    final castInitialized = await const MethodChannel('lokal/ios')
        .invokeMapMethod<String, dynamic>('initializeCastSenderForAcceptance');
    expect(castInitialized?['sdkInitialized'], true);
    expect(castInitialized?['discoveryActive'], false);

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

    // Exercise the post-#172 UX through the actual app and native plugins.
    // Empty queries make this independent of optional catalogue accounts/network.
    debugPrint('iOS smoke: updated search scopes and exclusive categories');
    await tester.tap(find.byTooltip('Search'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(SearchScreen), findsOneWidget);
    for (final scope in SearchScope.values) {
      final scopeControl = find.byType(SegmentedButton<SearchScope>);
      await tester.tap(
        find.descendant(
          of: scopeControl,
          matching: find.text(
            lokalText(scope == SearchScope.library ? 'Library' : 'Online'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      for (final category in visibleSearchCategories) {
        final chip = find.widgetWithText(ChoiceChip, category.label);
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.pump(const Duration(milliseconds: 200));
        final filters = tester.widget<SearchFilterChips>(
          find.byType(SearchFilterChips),
        );
        expect(filters.scope, scope);
        expect(filters.enabled, {category});
      }
    }
    await binding.takeScreenshot('ios-search-lyrics-filters');
    await tester.tap(find.byTooltip(lokalText('You')));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byTooltip('Edit profile'));
    await tester.pump(const Duration(seconds: 1));
    final saveProfile = find.widgetWithText(FilledButton, 'Save profile');
    expect(saveProfile, findsOneWidget);
    expect(saveProfile.hitTestable(), findsOneWidget);
    await binding.takeScreenshot('ios-profile-editor');
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pump(const Duration(milliseconds: 750));
    expect(saveProfile, findsNothing);
    await tester.tap(find.byTooltip(lokalText('Home')));
    await tester.pump(const Duration(milliseconds: 750));
    expect(tester.takeException(), isNull, reason: startupErrors.join('\n'));

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
      'cast_lazy_startup_and_explicit_sdk_initialization': 'passed',
      'library_you_settings_navigation': 'passed',
      'post172_search_scopes_and_four_exclusive_filters': 'passed',
      'post172_profile_editor_above_dock': 'passed',
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
    binding.reportData!.addAll({
      'native_scan_files': scan.totalFiles,
      'native_scan_sample_rate': scan.newOrModified.single.sampleRate,
      'native_scan_album_artist': scan.newOrModified.single.albumArtist,
    });

    // Keep the scanner's single-audio-file fixture free of artwork files.
    final artwork = File('${directory.path}/Generated artwork.png');
    final artworkData = await rootBundle.load('assets/branding/lokal_icon.png');
    await artwork.writeAsBytes(
      artworkData.buffer.asUint8List(
        artworkData.offsetInBytes,
        artworkData.lengthInBytes,
      ),
    );
    await File('${directory.path}/Generated tone.lrc').writeAsString(
      '[ar:Lokal test]\n[ti:Generated tone]\n'
      '[00:00.00]First generated lyric\n'
      '[00:03.00]Second generated lyric\n'
      '[00:03.00]Concurrent generated voice\n'
      '[00:06.00]Final generated lyric\n',
      flush: true,
    );

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
    binding.reportData!['quickjs_echo'] = quickJsResult;

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
      albumArt: artwork.path,
    );
    await player.play(song, playlist: [song]);
    final systemProgress = await _expectPlaybackProgress(tester, player);
    expect(player.currentEngineType, AudioEngineType.iosSystem);
    binding.reportData!['system_wav_progress_ms'] = systemProgress;
    await binding.takeScreenshot('ios-main-player');
    await player.pause();
    expect(player.isPlayingNotifier.value, false);

    // Controlled external-owner acknowledgements exercise the actual player
    // queue and AVPlayer. This is ownership coverage, not YouTube acceptance.
    final release = Completer<void>();
    final lease = await player.acquireExternalPlayback(() => release.future);
    final pendingResume = player.resume();
    await tester.pump(const Duration(milliseconds: 250));
    expect(player.isPlayingNotifier.value, false);
    expect(lease.isReleased, false);
    release.complete();
    await pendingResume;
    expect(lease.isReleased, true);
    binding.reportData!['external_owner_ack_gates_actual_avplayer_resume_ms'] =
        await _expectPlaybackProgress(tester, player);
    await player.pause();

    final delayedRelease = Completer<void>();
    final pausedLease = await player.acquireExternalPlayback(
      () => delayedRelease.future,
    );
    final beforeManualPause = player.playbackIntentRevision;
    final releasing = pausedLease.release();
    final manualPause = player.pause();
    final staleAutoResume = player.resumeAfterExternalPlayback(
      pausedLease,
      song,
      intentRevision: beforeManualPause,
    );
    delayedRelease.complete();
    await Future.wait([releasing, manualPause, staleAutoResume]);
    expect(player.isPlayingNotifier.value, false);
    binding.reportData!['manual_pause_wins_over_stale_video_exit_resume'] =
        'passed';

    // Repeat the queue/lyrics visit before dismissing: stale artwork anchors
    // after these temporary covers were the regression addressed by PR #174.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(
      find.descendant(
        of: find.byType(KonnektedMiniPlayerContent),
        matching: find.text(song.title),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(FullPlayerScreen), findsOneWidget);
    final playerRoute = ModalRoute.of(
      tester.element(find.byType(FullPlayerScreen)),
    )!;
    for (
      var frame = 0;
      frame < 24 && playerRoute.animation!.status != AnimationStatus.completed;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(playerRoute.animation!.status, AnimationStatus.completed);
    for (var visit = 0; visit < 2; visit++) {
      for (final panel in [l10n.queue, l10n.lyrics]) {
        // A panel header can repeat its footer label. Tap the actual control.
        final toggle = find.widgetWithText(InkWell, panel);
        expect(toggle, findsOneWidget);
        await tester.tap(toggle);
        for (var frame = 0; frame < 4; frame++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        await tester.tap(toggle);
        for (var frame = 0; frame < 4; frame++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
      }
    }
    await binding.takeScreenshot('ios-full-player-after-panels');
    for (var i = 0; i < 24 && find.text('Space').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.text('Space'), findsOneWidget);
    await tester.ensureVisible(find.text('Space'));
    await tester.pump(const Duration(milliseconds: 250));
    await player.seek(const Duration(seconds: 3));
    final artworkElements = find
        .descendant(
          of: find.byType(FullPlayerScreen),
          matching: find.byType(PlayerArtworkImage),
        )
        .evaluate()
        .toSet();
    expect(artworkElements, isNotEmpty);
    await tester.tap(find.text('Space'));
    await tester.pump(const Duration(milliseconds: 750));
    expect(find.byType(ImmersiveLyricsSubtitle), findsOneWidget);
    expect(find.byKey(const ValueKey('space-line:3000:1')), findsOneWidget);
    expect(find.byKey(const ValueKey('space-line:3000:2')), findsOneWidget);
    final spaceArtworkElements = find
        .descendant(
          of: find.byType(FullPlayerScreen),
          matching: find.byType(PlayerArtworkImage),
        )
        .evaluate()
        .toSet();
    expect(
      spaceArtworkElements,
      containsAll(artworkElements),
      reason: 'Space must preserve the actual player artwork elements.',
    );
    expect(player.currentSongNotifier.value?.id, song.id);
    expect(player.isPlayingNotifier.value, false);
    expect(
      player.positionNotifier.value.inMilliseconds,
      greaterThanOrEqualTo(2500),
    );
    await binding.takeScreenshot('ios-space-subtitles-over-player');
    await tester.tap(find.byKey(const ValueKey('space-exit-surface')));
    await tester.pump(const Duration(milliseconds: 750));
    expect(find.byType(ImmersiveLyricsSubtitle), findsNothing);
    binding.reportData!['post210_space_preserves_artwork_and_song_clock'] =
        'passed';
    binding.reportData!['post215_space_concurrent_lines'] = 'passed';
    Navigator.of(tester.element(find.byType(FullPlayerScreen))).pop();
    for (
      var frame = 0;
      frame < 24 && find.byType(FullPlayerScreen).evaluate().isNotEmpty;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.byType(FullPlayerScreen), findsNothing);
    expect(find.byType(KonnektedMiniPlayerContent), findsOneWidget);
    expect(tester.takeException(), isNull, reason: startupErrors.join('\n'));
    await binding.takeScreenshot('ios-mini-player-after-return');
    binding.reportData!['post172_queue_lyrics_repeat_and_artwork_return'] =
        'passed';
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
    binding.reportData!['rust_dsp_progress_ms'] = dspProgress;
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
    binding.reportData!['rust_pitch_progress_ms'] = pitchProgress;
    await player.setPitchSemitones(0);
    expect(player.currentEngineType, AudioEngineType.iosSystem);
    final pitchResetProgress = await _expectPlaybackProgress(tester, player);
    binding.reportData!['system_pitch_reset_progress_ms'] = pitchResetProgress;
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
    binding.reportData!['rust_positive_replaygain_progress_ms'] =
        normalizationProgress;
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
    binding.reportData!['rust_wavpack_progress_ms'] = wavpackProgress;
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
      if (fixture.engine == AudioEngineType.iosRust) {
        expect(
          native_audio.audioGetState(),
          'paused',
          reason: '${fixture.name} native pause acknowledgement',
        );
      }
      codecResults[fixture.name] = {
        'engine': player.currentEngineType.name,
        'source_sample_rate': metadata.newOrModified.single.sampleRate,
        'progress_ms': progress,
      };
    }
    for (var cycle = 0; cycle < 2; cycle++) {
      await player.resume();
      await _expectPlaybackProgress(tester, player);
      await player.pause();
      expect(
        player.isPlayingNotifier.value,
        false,
        reason: 'Opus pause cycle $cycle',
      );
      expect(
        native_audio.audioGetState(),
        'paused',
        reason: 'Opus acknowledged pause $cycle',
      );
    }
    binding.reportData!['opus_repeated_acknowledged_pause_resume'] = 'passed';
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

    // Real HTTP -> shared artwork cache -> Swift UIImage -> Now Playing.
    // The 40px remote fixture distinguishes this from the earlier local art.
    await NotificationService().updateNotification(
      song: successor.copyWith(
        albumArt: fixture.single.origin
            .resolve('/lokal-ios-notification-art.png')
            .toString(),
      ),
      isPlaying: false,
      duration: song.duration,
      position: const Duration(seconds: 2),
    );
    Map<String, dynamic>? nowPlaying;
    for (var attempt = 0; attempt < 24; attempt++) {
      await tester.pump(const Duration(milliseconds: 250));
      nowPlaying = await const MethodChannel('lokal/ios')
          .invokeMapMethod<String, dynamic>('nowPlayingMetadataState');
      if ((nowPlaying?['artworkWidth'] as num?)?.toInt() == 40) break;
    }
    expect(nowPlaying?['artworkWidth'], 40);
    expect(nowPlaying?['artworkHeight'], 40);
    expect(nowPlaying?['playbackRate'], 0);
    expect(nowPlaying?['durationSeconds'], 8);
    expect(nowPlaying?['elapsedSeconds'], closeTo(2, .01));
    binding.reportData!['post202_remote_artwork_and_native_metadata'] =
        'passed';

    final previousLocale = LocaleController.instance.value;
    try {
      await LocaleController.instance.select(const Locale('tr'));
      await tester.pump(const Duration(seconds: 1));
      expect(l10n.settings, 'Ayarlar');
      await tester.tap(find.byTooltip(lokalText('Library')));
      await tester.pump(const Duration(milliseconds: 750));
      expect(find.byType(KonnektedLibrary), findsOneWidget);
      for (final label in ['Beğenildi', 'Çalma listeleri', 'Albümler',
        'Sanatçılar', 'Türler', 'İndirilenler']) {
        expect(find.text(label), findsOneWidget);
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: find.text(label), matching: find.byType(RichText)),
        );
        expect(paragraph.didExceedMaxLines, isFalse, reason: label);
      }
      expect(tester.takeException(), isNull, reason: startupErrors.join('\n'));
      await binding.takeScreenshot('ios-turkish-library');
      binding.reportData!['post201_live_turkish_locale'] = 'passed';
    } finally {
      await LocaleController.instance.select(previousLocale);
      await tester.pump(const Duration(milliseconds: 500));
    }

    if (const bool.fromEnvironment('LOKAL_IOS_VIDEO_PROBE')) {
      await probeLiveIosVideo(tester, binding);
    }
    // Final destructive fence check: Swift's direct C ABI and Dart's FRB API
    // must share the same counter. This is not full media-reset recovery.
    await player.pause();
    final previousEpoch = native_audio.audioLocalRequestEpoch();
    final fence = await const MethodChannel('lokal/ios')
        .invokeMapMethod<String, dynamic>('invalidateLocalAudioRequestsForIntegrationTest');
    final advancedEpoch = BigInt.parse(fence!['epoch'] as String);
    expect(BigInt.parse(fence['previous'] as String), previousEpoch);
    expect(advancedEpoch, previousEpoch + BigInt.one);
    expect(native_audio.audioLocalRequestEpoch(), advancedEpoch);
    await expectLater(
      native_audio.audioResume(requestEpoch: previousEpoch),
      throwsA(predicate((Object error) =>
          error.toString().contains('AUDIO_LOCAL_REQUEST_RETIRED'))),
    );
    await native_audio.audioShutdown();
    binding.reportData!['native_swift_frb_request_fence'] = 'passed';
    await tester.pumpWidget(const SizedBox.shrink());
    player.dispose();
  }, timeout: const Timeout(Duration(minutes:
      bool.fromEnvironment('LOKAL_IOS_VIDEO_PROBE') ? 6 : 4)));
}
