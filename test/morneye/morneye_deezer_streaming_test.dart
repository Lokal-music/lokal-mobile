import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/morneye/morneye_live_playback.dart';
import 'package:flick/features/morneye/morneye_packages.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';

List<int> _flac(int depth, int rate) {
  final h = List<int>.filled(42, 0);
  h.setRange(0, 4, [0x66, 0x4c, 0x61, 0x43]);
  h[7] = 34;
  h[18] = (rate >> 12) & 255;
  h[19] = (rate >> 4) & 255;
  h[20] = ((rate & 15) << 4) | (((depth - 1) >> 4) & 1);
  h[21] = ((depth - 1) & 15) << 4;
  return h;
}

void main() {
  test('Deezer native Search identity needs no redundant metadata fetch', () {
    expect(providerIdentityIsDeezer('deezer', {
      'id': '123456789', 'provider_id': 'deezer',
    }), isTrue);
    expect(providerIdentityIsDeezer('deezer-web', {
      'id': '123456789', 'provider_id': 'deezer',
    }), isTrue);
    expect(providerIdentityIsDeezer('deezer', {
      'id': 'spotify:abc', 'provider_id': 'deezer',
    }), isFalse);
    expect(providerIdentityIsDeezer('deezer', {
      'id': '123456789', 'provider_id': 'spotify',
    }), isFalse);
    expect(providerIdentityIsDeezer('tidal', {
      'id': '123456789', 'provider_id': 'deezer',
    }), isFalse);
  });

  test('Deezer direct FLAC passes the existing verified live gate', () {
    final bytes = [..._flac(16, 44100), ...List<int>.filled(65536 - 42, 0)];
    expect(MorneyeLiveSession.playableMime(bytes, 'audio.flac'), 'audio/flac');
    final details = MorneyeLiveSession.readFlacStreamInfo(bytes);
    expect(details?.bitDepth, 16);
    expect(details?.sampleRate, 44100);
  });

  test('Deezer encrypted temporary bytes never become playable FLAC', () {
    final encrypted = List<int>.filled(65536, 0x55);
    expect(MorneyeLiveSession.playableMime(encrypted, 'audio.flac'), isNull);
    expect(MorneyeLiveSession.playableMime(encrypted, 'audio.flac.encrypted'),
        isNull);
  });

  test('Deezer transfer progress does not regress after resolver 5%', () {
    final status = MorneyeProgressText('Track', 'Deezer');
    expect(status.update(message: 'Resolving Deezer stream…'),
        contains('Resolving Deezer stream'));
    expect(status.update(percent: 38, message: 'Receiving audio…'),
        contains('38%'));
    expect(status.update(percent: 5, message: 'Receiving audio…'), isNull);
    expect(status.update(percent: 40, message: 'Receiving audio…'),
        contains('40%'));
  });
}
