import 'package:flick/features/morneye/morneye_playback_quality.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const options = [
    {'id': 'ac4', 'kind': 'spatial'},
    {'id': 'eac3', 'kind': 'lossless'},
    {'id': 'best', 'kind': 'lossless'},
    {'id': 'high', 'kind': 'lossy'},
  ];

  test('every listed addon setting controls both playback and download', () {
    for (final selected in ['ac4', 'eac3', 'best', 'high']) {
      for (final playback in [true, false]) {
        expect(
          resolveMorneyeRequestQuality(
            forPlayback: playback,
            requested: null,
            configured: selected,
            options: options,
            provider: 'amazon',
          ),
          selected,
        );
      }
    }
    expect(
      chooseMorneyeDownloadQuality(
        requested: 'high',
        configured: 'ac4',
        options: options,
        provider: 'amazon',
      ),
      'high',
      reason: 'An explicit per-song action overrides the saved preference',
    );
  });

  test('missing manifest option does not create a speculative codec claim', () {
    expect(
      chooseMorneyeDownloadQuality(
        requested: null,
        configured: 'AC-4',
        options: options,
        provider: 'amazon',
      ),
      'best',
      reason: 'The exact selected tier must exist in the installed manifest',
    );
    for (final configured in ['ac4', 'eac3']) {
      expect(
        chooseMorneyeDownloadQuality(
          requested: null,
          configured: configured,
          options: const [],
          provider: 'amazon',
        ),
        'default',
      );
    }
    expect(
      chooseMorneyeDownloadQuality(
        requested: null,
        configured: 'DOLBY_ATMOS',
        options: const [],
        provider: 'tidal',
      ),
      'HI_RES_LOSSLESS',
    );
  });

  test('manifest preferences do not certify catalogue Atmos or iOS decoding', () {
    expect(
      isMorneyeAtmosQuality('AC-4'),
      isTrue,
    );
    expect(
      isMorneyeAtmosQuality('eac3'),
      isFalse,
      reason: 'Plain E-AC-3 is not evidence of JOC Atmos',
    );
    expect(
      explicitMorneyePlaybackTier(
        atmosRequested: true,
        provider: 'amazon',
        atmosCodec: 'eac3-joc',
      ),
      'eac3',
    );
    expect(
      explicitMorneyePlaybackTier(
        atmosRequested: true,
        provider: 'amazon',
        atmosCodec: 'ac4',
      ),
      'ac4',
    );
    expect(explicitMorneyePlaybackTier(atmosRequested: false), isNull);
  });
}
