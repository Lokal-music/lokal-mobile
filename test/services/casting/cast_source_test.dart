import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/casting/cast_source.dart';

void main() {
  test('only receiver-accessible HTTP sources bypass the phone server', () {
    expect(
      receiverDirectUrl('https://music.example/audio?token=fixture'),
      isNotNull,
    );
    expect(receiverDirectUrl('http://192.168.1.20/track.flac'), isNotNull);
    for (final value in [
      '/Music/track.wav',
      'content://track',
      'lokal-extension://track',
      'file:///track.wav',
      'http://localhost/audio',
      'http://127.0.0.1/audio',
      'http://[::1]/audio',
      'http://0.0.0.0/audio',
      'https://user:secret@example.invalid/audio',
    ]) {
      expect(receiverDirectUrl(value), isNull, reason: value);
    }
  });
  test('header-protected streams require an authorized phone copy', () {
    expect(
      receiverDirectUrl(
        'https://music.example/audio',
        headers: {'Authorization': 'Bearer fixture'},
      ),
      isNull,
    );
    expect(
      receiverDirectUrl(
        'https://music.example/audio',
        headers: {'Cookie': 'fixture'},
      ),
      isNull,
    );
  });
  test('actual URL container precedes catalog format and query strings are ignored', () {
    expect(
      castAudioContentType('https://music.example/audio.mp3?x=.flac', 'FLAC'),
      'audio/mpeg',
    );
    expect(
      castAudioContentType('https://music.example/audio', 'ALAC'),
      'audio/mp4',
    );
    expect(
      castAudioContentType('https://music.example/audio.aac', 'AAC'),
      'audio/aac',
    );
    expect(
      castAudioContentType('https://music.example/stream.m3u8', 'AAC'),
      'application/vnd.apple.mpegurl',
    );
  });
}
