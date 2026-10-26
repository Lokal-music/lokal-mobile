import 'package:flutter_test/flutter_test.dart';
import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/song_engine_routing.dart';

Song _song({
  required String id,
  required String fileType,
  String? filePath,
  int? sampleRate,
}) {
  return Song(
    id: id,
    title: 'title',
    artist: 'artist',
    duration: const Duration(minutes: 3),
    fileType: fileType,
    filePath: filePath,
    sampleRate: sampleRate,
  );
}

void main() {
  group('resolveEngineForSong', () {
    test('keeps the route preference for system-decodable tracks', () {
      for (final preferred in AudioEngineType.values) {
        expect(
          resolveEngineForSong(
            preferred: preferred,
            requiresRustDecoder: false,
          ),
          preferred,
        );
      }
    });

    test(
      'verified E-AC-3 JOC routes to Android Media3 from every selected engine',
      () {
        for (final preferred in AudioEngineType.values.where(
          (mode) =>
              mode != AudioEngineType.iosSystem &&
              mode != AudioEngineType.iosRust,
        )) {
          expect(
            resolveEngineForSong(
              preferred: preferred,
              requiresRustDecoder: false,
              isAtmosJoc: true,
            ),
            AudioEngineType.normalAndroid,
            reason: 'Atmos objects cannot pass through the Rust PCM decoder',
          );
        }
        final song = _song(
          id: 'joc',
          fileType: 'E-AC-3 JOC',
          filePath: '/music/atmos.m4a',
        ).copyWith(atmosEncoded: true, atmosAvailable: true);
        expect(song.atmosEncoded, isTrue);
        expect(song.filePath, '/music/atmos.m4a');
      },
    );

    test('iPhone codec fallback never selects an Android output', () {
      expect(
        resolveEngineForSong(
          preferred: AudioEngineType.iosSystem,
          requiresRustDecoder: true,
        ),
        AudioEngineType.iosRust,
      );
      expect(
        resolveEngineForSong(
          preferred: AudioEngineType.iosSystem,
          requiresRustDecoder: false,
          isAtmosJoc: true,
        ),
        AudioEngineType.iosSystem,
      );
      expect(
        resolveEngineForSong(
          preferred: AudioEngineType.iosRust,
          requiresRustDecoder: false,
        ),
        AudioEngineType.iosRust,
      );
    });

    test(
      'iPhone add-on streaming retains its adapter when DSP is selected',
      () {
        for (final preferred in [
          AudioEngineType.iosSystem,
          AudioEngineType.iosRust,
        ]) {
          expect(
            resolveEngineForSong(
              preferred: preferred,
              requiresRustDecoder: true,
              requiresSystemStreaming: true,
            ),
            AudioEngineType.iosSystem,
          );
        }
        expect(
          resolveEngineForSong(
            preferred: AudioEngineType.rustOboe,
            requiresRustDecoder: false,
            requiresSystemStreaming: true,
          ),
          AudioEngineType.rustOboe,
        );
      },
    );

    test('routes Rust-decoder containers to the shared Rust output', () {
      expect(
        resolveEngineForSong(
          preferred: AudioEngineType.normalAndroid,
          requiresRustDecoder: true,
        ),
        AudioEngineType.rustOboe,
      );
    });

    test('keeps Rust-capable preferences untouched', () {
      for (final preferred in [
        AudioEngineType.rustOboe,
        AudioEngineType.usbDacExperimental,
        AudioEngineType.dapInternalHighRes,
      ]) {
        expect(
          resolveEngineForSong(preferred: preferred, requiresRustDecoder: true),
          preferred,
        );
      }
    });
  });

  group('Song.requiresRustDecoder', () {
    test('covers DSF/DFF from the file extension and metadata', () {
      expect(
        _song(
          id: '1',
          fileType: 'dsf',
          filePath: '/music/a.dsf',
        ).requiresRustDecoder,
        isTrue,
      );
      expect(_song(id: '2', fileType: 'DSD').requiresRustDecoder, isTrue);
    });

    test('covers WavPack DSD and PCM payloads', () {
      expect(
        _song(
          id: '3',
          fileType: 'WV-DSD',
          filePath: '/music/a.wv',
          sampleRate: 2822400,
        ).requiresRustDecoder,
        isTrue,
      );
      expect(
        _song(
          id: '4',
          fileType: 'wv',
          filePath: '/music/b.wv',
          sampleRate: 44100,
        ).requiresRustDecoder,
        isTrue,
      );
      expect(
        _song(
          id: '5',
          fileType: 'wv',
          filePath: '/music/b.wv',
          sampleRate: 44100,
        ).isWavPack,
        isTrue,
      );
    });

    test('leaves regular PCM formats on the system tier', () {
      expect(
        _song(
          id: '6',
          fileType: 'FLAC',
          filePath: '/music/c.flac',
          sampleRate: 44100,
        ).requiresRustDecoder,
        isFalse,
      );
    });
  });
}
