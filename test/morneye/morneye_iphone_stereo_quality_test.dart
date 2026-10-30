import 'package:flick/features/morneye/morneye_playback_quality.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const options = [
    {'id': 'ac4', 'kind': 'spatial'},
    {'id': 'eac3', 'kind': 'lossless'},
    {'id': 'best', 'kind': 'lossless'},
    {'id': 'high', 'kind': 'lossy'},
  ];
  test('ordinary Amazon playback excludes AC-4 and plain E-AC-3 configured downloads', () {
    for (final configured in ['ac4', 'AC-4', 'eac3', 'EAC3']) {
      expect(
        resolveMorneyeRequestQuality(
          forPlayback: true,
          requested: null,
          configured: configured,
          options: options,
          provider: 'amazon',
        ),
        'best',
      );
    }
    expect(
      chooseMorneyeDownloadQuality(
        requested: null,
        configured: null,
        options: options,
        provider: 'amazon',
      ),
      'best',
    );
    expect(
      resolveMorneyeRequestQuality(
        forPlayback: true,
        requested: null,
        configured: 'high',
        options: options,
        provider: 'amazon',
      ),
      'high',
    );
  });
  test('spatial defaults with sparse manifests never become an ordinary spatial request', () {
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
    expect(
      chooseMorneyeDownloadQuality(
        requested: null,
        configured: 'unknown_spatial',
        options: const [
          {'id': 'unknown_spatial', 'kind': 'spatial'},
          {'id': 'HIGH'},
        ],
        provider: 'amazon',
      ),
      'HIGH',
    );
  });
  test(
    'explicit saving and provider-specific normal settings remain distinct',
    () {
      expect(
        resolveMorneyeRequestQuality(
          forPlayback: false,
          requested: null,
          configured: 'ac4',
          options: options,
          provider: 'amazon',
        ),
        'ac4',
      );
      expect(
        chooseMorneyeDownloadQuality(
          requested: null,
          configured: 'eac3',
          options: const [],
          provider: 'other',
        ),
        'eac3',
      );
      expect(explicitMorneyePlaybackTier(atmosRequested: false), isNull);
    },
  );
}
