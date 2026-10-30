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

    test('AC-4 and JOC use independent native decoder lifecycles', () {
      final ac4 = version('/cache/amazon.mp4', atmos: true)
          .copyWith(fileType: 'AC-4');
      expect(androidDolbyCodec(atmos), 'eac3_joc');
      expect(androidDolbyCodec(ac4), 'ac4');
      expect(androidDolbyCodec(stereo), 'normal');
      expect(shouldResetAndroidAtmosDecoder(atmos, ac4), isTrue);
      expect(shouldResetAndroidAtmosDecoder(ac4, atmos), isTrue);
      expect(shouldResetAndroidAtmosDecoder(ac4, stereo), isTrue);
      expect(shouldResetAndroidAtmosDecoder(stereo, ac4), isTrue);
      expect(shouldResetAndroidAtmosDecoder(ac4, ac4), isFalse);
      expect(androidAudioSourceIdentity(ac4), isNot(androidAudioSourceIdentity(atmos)));
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

    test('selected Amazon AC-4 or E-AC-3 is the requested playback tier', () {
      const amazon = <dynamic>[
        {'id': 'ac4', 'kind': 'spatial', 'label': 'Dolby Atmos (AC-4)'},
        {'id': 'eac3', 'kind': 'spatial', 'label': 'Dolby Digital Plus'},
        {'id': 'best', 'kind': 'lossless', 'label': 'FLAC'},
        {'id': 'opus', 'kind': 'lossy', 'label': 'Opus'},
      ];
      expect(isMorneyeAtmosQuality('ac4'), isTrue);
      expect(isMorneyeAtmosQuality('AC-4'), isTrue);
      expect(isMorneyeAtmosQuality('eac3'), isFalse,
          reason: 'Plain E-AC-3 is not Dolby Atmos');
      expect(morneyeSpatialOption(amazon[1] as Map), isTrue);
      for (final configured in ['ac4', 'eac3']) {
        expect(chooseMorneyeDownloadQuality(
          requested: null, configured: configured,
          options: amazon, provider: 'amazon',
        ), configured);
      }
      expect(chooseMorneyeDownloadQuality(
        requested: 'ac4', configured: 'best',
        options: amazon, provider: 'amazon',
      ), 'ac4');
      expect(resolveMorneyeRequestQuality(
        forPlayback: false, requested: null, configured: 'ac4',
        options: amazon, provider: 'amazon',
      ), 'ac4', reason: 'Explicit addon download setting is preserved');
    });

    test('selected Tidal Atmos is requested without creating a catalogue badge', () {
      expect(chooseMorneyeDownloadQuality(
        requested: null, configured: 'DOLBY_ATMOS',
        options: options, provider: 'tidal',
      ), 'DOLBY_ATMOS');
      expect(chooseMorneyeDownloadQuality(
        requested: null, configured: 'ATMOS',
        options: [], provider: 'tidal-web',
      ), 'HI_RES_LOSSLESS');
    });

    test('Amazon E-AC-3 selection follows the installed manifest', () {
      const incomplete = <dynamic>[
        {'id': 'eac3', 'label': 'Dolby Digital Plus'},
        {'id': 'best', 'kind': 'lossless'},
      ];
      for (final provider in ['amazon', 'amazon-web']) {
        for (final configured in ['eac3', 'EAC3', null]) {
          expect(chooseMorneyeDownloadQuality(
            requested: null, configured: configured,
            options: incomplete, provider: provider,
          ), configured == 'eac3' ? 'eac3' : 'best');
        }
        expect(chooseMorneyeDownloadQuality(
          requested: null, configured: 'eac3', options: [], provider: provider,
        ), 'default');
        expect(chooseMorneyeDownloadQuality(
          requested: null, configured: null,
          options: [{'id': 'eac3'}], provider: provider,
        ), 'default');
      }
      expect(isMorneyeAtmosQuality('eac3'), isFalse);
      expect(chooseMorneyeDownloadQuality(
        requested: null, configured: 'eac3',
        options: incomplete, provider: 'other',
      ), 'eac3');
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
      ), 'LOSSLESS');
    });

    test('add-on quality settings control playback and downloads', () {
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

    test('manifest-selected Atmos works without non-spatial options', () {
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
