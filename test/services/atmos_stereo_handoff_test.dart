import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/morneye/morneye_playback_quality.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/android_audio_engine.dart';
import 'package:flick/services/player_service.dart';

Song version(String file, {bool atmos = false, String id = 'tidal:42'}) =>
    Song(
      id: id,
      title: 'Same recording',
      artist: 'Artist',
      duration: const Duration(minutes: 3),
      fileType: atmos ? 'E-AC-3 JOC' : 'FLAC',
      filePath: file,
      atmosAvailable: true,
      atmosEncoded: atmos,
    );

void main() {
  group('native Atmos -> stereo -> next track', () {
    final atmos = version('/cache/atmos.m4a', atmos: true);
    final stereo = version('/cache/stereo.flac');
    final other = version('/cache/other.flac', id: 'tidal:43');

    test('same catalogue ID is NOT the same audio source', () {
      expect(atmos.id, stereo.id);
      expect(androidAudioSourceIdentity(atmos),
          isNot(androidAudioSourceIdentity(stereo)));
      expect(androidAudioSourceIdentity(stereo),
          isNot(androidAudioSourceIdentity(other)));
      expect(shouldReplaceQueuedAudioSource(atmos, stereo), isTrue);
      expect(shouldReplaceQueuedAudioSource(stereo, atmos), isTrue);
      expect(shouldReplaceQueuedAudioSource(stereo, other), isFalse);
      expect(shouldReplaceQueuedAudioSource(stereo, stereo), isFalse);
    });

    test('new cached path invalidates old same-ID source', () {
      final fresh = version('/cache/stereo-new.flac');
      expect(androidAudioSourceIdentity(stereo),
          isNot(androidAudioSourceIdentity(fresh)));
      expect(shouldReplaceQueuedAudioSource(stereo, fresh), isTrue);
    });

    test('Android decoder is reset for both JOC<->stereo directions', () {
      expect(shouldResetAndroidAtmosDecoder(atmos, stereo), isTrue);
      expect(shouldResetAndroidAtmosDecoder(stereo, atmos), isTrue);
      expect(shouldResetAndroidAtmosDecoder(stereo, other), isFalse);
      expect(shouldResetAndroidAtmosDecoder(null, atmos), isFalse);
    });
  });

  group('provider quality isolation', () {
    final options = <dynamic>[
      {'id': 'DOLBY_ATMOS', 'kind': 'spatial'},
      {'id': 'HIGH', 'kind': 'lossy'},
      {'id': 'LOSSLESS', 'kind': 'lossless'},
      {'id': 'HI_RES_LOSSLESS', 'kind': 'lossless'},
    ];

    test('selected Tidal Atmos remains the requested tier', () {
      expect(chooseMorneyeDownloadQuality(
        requested: null, configured: 'DOLBY_ATMOS',
        options: options, provider: 'tidal',
      ), 'DOLBY_ATMOS');
      expect(chooseMorneyeDownloadQuality(
        requested: null, configured: 'ATMOS',
        options: [], provider: 'tidal-web',
      ), 'HI_RES_LOSSLESS');
    });

    test('only explicit Atmos requests choose JOC', () {
      expect(chooseMorneyeDownloadQuality(
        requested: 'DOLBY_ATMOS', configured: 'LOSSLESS',
        options: options, provider: 'tidal',
      ), 'DOLBY_ATMOS');
      expect(chooseMorneyeDownloadQuality(
        requested: 'DOLBY_ATMOS', configured: 'DOLBY_ATMOS',
        options: options, provider: 'tidal',
      ), 'DOLBY_ATMOS');
    });

    test('ordinary user-configured lossless tiers stay unchanged', () {
      expect(chooseMorneyeDownloadQuality(
        requested: null, configured: 'LOSSLESS',
        options: options, provider: 'tidal',
      ), 'LOSSLESS');
      expect(chooseMorneyeDownloadQuality(
        requested: 'HIGH', configured: 'DOLBY_ATMOS',
        options: options, provider: 'tidal',
      ), 'HIGH');
      expect(chooseMorneyeDownloadQuality(
        requested: null, configured: null,
        options: options, provider: 'tidal',
      ), 'HI_RES_LOSSLESS');
    });

    test('add-on quality settings govern playback and downloads', () {
      expect(resolveMorneyeRequestQuality(
        forPlayback: false, requested: null, configured: 'DOLBY_ATMOS',
        options: options, provider: 'tidal',
      ), 'DOLBY_ATMOS');
      expect(resolveMorneyeRequestQuality(
        forPlayback: true, requested: null, configured: 'DOLBY_ATMOS',
        options: options, provider: 'tidal',
      ), 'DOLBY_ATMOS');
      expect(resolveMorneyeRequestQuality(
        forPlayback: true, requested: 'DOLBY_ATMOS',
        configured: 'LOSSLESS', options: options, provider: 'tidal',
      ), 'DOLBY_ATMOS');
    });

    test('an installed Atmos-only manifest can honor the selected tier', () {
      expect(chooseMorneyeDownloadQuality(
        requested: null, configured: 'DOLBY_ATMOS',
        options: [{'id': 'DOLBY_ATMOS'}], provider: 'tidal',
      ), 'DOLBY_ATMOS');
      expect(chooseMorneyeDownloadQuality(
        requested: null, configured: 'DOLBY_ATMOS',
        options: [{'id': 'DOLBY_ATMOS'}], provider: 'qobuz',
      ), 'DOLBY_ATMOS');
    });
  });
}
