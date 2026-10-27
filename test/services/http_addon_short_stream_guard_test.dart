import 'package:flutter_test/flutter_test.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/android_audio_engine.dart';

Song _song(Duration duration, {String source = 'konnekted.progressive'}) =>
    Song(
      id: 'qobuz-recording',
      title: 'Full recording',
      artist: 'Fixture',
      duration: duration,
      fileType: 'FLAC',
      sourcePackage: source,
    );

void main() {
  test('HTTP add-on 30-second stream is not a full 4-minute track', () {
    expect(
      AndroidAudioEngine.isTruncatedHttpAddonAudio(
        _song(const Duration(minutes: 4)),
        const Duration(seconds: 30),
      ),
      isTrue,
    );
  });

  test('genuinely short songs and local media remain playable', () {
    expect(
      AndroidAudioEngine.isTruncatedHttpAddonAudio(
        _song(const Duration(seconds: 30)),
        const Duration(seconds: 30),
      ),
      isFalse,
    );
    expect(
      AndroidAudioEngine.isTruncatedHttpAddonAudio(
        _song(const Duration(minutes: 4), source: 'local'),
        const Duration(seconds: 30),
      ),
      isFalse,
    );
    expect(
      AndroidAudioEngine.isTruncatedHttpAddonAudio(
        _song(const Duration(minutes: 4)),
        const Duration(minutes: 4),
      ),
      isFalse,
    );
    expect(
      AndroidAudioEngine.isTruncatedHttpAddonAudio(
        _song(const Duration(minutes: 4)),
        null,
      ),
      isFalse,
    );
  });
}
