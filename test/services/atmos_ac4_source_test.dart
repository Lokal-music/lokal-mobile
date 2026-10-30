import 'package:flick/services/atmos_playback_support.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AC-4 detection reads actual codec metadata, never catalogue flags', () async {
    expect(
      await AtmosPlaybackSupport.isAc4File(
        'fixture.m4a',
        probeStreams: (_) async => [
          {'codec_type': 'audio', 'codec_name': 'ac4'},
        ],
      ),
      isTrue,
    );
    expect(
      await AtmosPlaybackSupport.isAc4File(
        'fixture.m4a',
        probeStreams: (_) async => [
          {'codec_type': 'audio', 'codec_name': 'ac-4'},
        ],
      ),
      isTrue,
    );
    expect(
      await AtmosPlaybackSupport.isAc4File(
        'fixture.m4a',
        probeStreams: (_) async => [
          {'codec_type': 'audio', 'codec_name': 'eac3', 'profile': 'Dolby Atmos'},
        ],
      ),
      isFalse,
    );
    expect(
      await AtmosPlaybackSupport.isAc4File(
        'fixture.m4a',
        probeStreams: (_) async => [
          {'codec_type': 'video', 'codec_name': 'ac4'},
        ],
      ),
      isFalse,
    );
  });

  test('missing/invalid native media does not invent AC-4', () async {
    expect(
      await AtmosPlaybackSupport.isAc4File(
        'missing.m4a',
        probeStreams: (_) async => throw StateError('missing input'),
      ),
      isFalse,
    );
  });
}
