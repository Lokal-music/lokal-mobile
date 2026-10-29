import 'package:flick/services/tidal_atmos_metadata.dart';
import 'package:flick/features/morneye/morneye_packages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('finds Dolby Atmos in the catalog modes, not only the quality tier', () {
    expect(tidalAtmosAvailable({
      'audioQuality': 'LOW', 'audioModes': ['STEREO', 'DOLBY_ATMOS'],
    }), isTrue);
    expect(tidalAtmosAvailable({'audio_mode': 'DOLBY_ATMOS'}), isTrue);
    expect(tidalAtmosAvailable({'audio_modes': 'DOLBY_ATMOS'}), isTrue);
    expect(tidalAtmosAvailable({'audio_quality': 'DOLBY_ATMOS'}), isTrue);
  });

  test('Mornye Tidal search maps its string audio_modes to Atmos', () {
    final track = MorneyeTrack.of({
      'id': '123',
      'name': 'Atmos version',
      'artists': ['Artist'],
      'audio_quality': 'High',
      'audio_modes': 'DOLBY_ATMOS',
    }, 'a-1234567890');
    expect(track.atmosAvailable, isTrue);
    expect(track.quality, 'High');


  });

  test('Amazon comma-separated audio modes remain explicit, not inferred from codec', () {
    expect(tidalAtmosAvailable({'audio_modes': 'STEREO,DOLBY_ATMOS'}), isTrue);
    expect(tidalAtmosAvailable({'audio_modes': 'STEREO; ATMOS'}), isTrue);
    expect(tidalAtmosAvailable({'audio_modes': 'STEREO', 'audio_codec': 'ac4'}), isFalse);
  });

  test('lossless, hi-res and multichannel alone do not prove Atmos', () {
    expect(tidalAtmosAvailable({
      'audioQuality': 'HI_RES_LOSSLESS', 'audioModes': ['STEREO'],
    }), isFalse);
    expect(tidalAtmosAvailable({
      'codec': 'eac3', 'channels': 6, 'audioMode': 'STEREO',
    }), isFalse);
    expect(tidalAtmosAvailable({}), isFalse);
  });
}
