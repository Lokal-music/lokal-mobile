import 'package:flutter_test/flutter_test.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/lyrics_service.dart';

class _FakeLyrics extends LyricsService {
  final requested = <String>[];

  @override
  Future<LyricsData?> loadLyricsForSong(
    Song song, {
    bool forceRefresh = false,
    bool fetchOnline = false,
    bool refreshOnline = false,
    String source = 'auto',
    bool Function()? stillCurrent,
  }) async {
    requested.add('local:${song.id}');
    return const LyricsData(
      lines: [LyricsLine(timestamp: Duration(seconds: 2), text: 'Local')],
      isSynchronized: true,
      rawContent: '',
      source: 'local',
    );
  }

  @override
  Future<LyricsData?> fetchOnlineLyrics(
    Song song, {
    String source = 'auto',
    bool Function()? stillCurrent,
  }) async {
    requested.add('$source:${song.id}');
    if (source == 'lyricsplus') {
      return const LyricsData(
        lines: [
          LyricsLine(
            timestamp: Duration(seconds: 4),
            text: 'Word timed',
            words: [LyricsWord(
              start: Duration(seconds: 4),
              end: Duration(seconds: 5),
              text: 'Word',
            )],
          ),
        ],
        isSynchronized: true,
        rawContent: '',
        source: 'LyricsPlus',
      );
    }
    return null;
  }
}

void main() {
  final song = Song(
    id: 'hit-probe-imagination',
    title: 'Imagination',
    artist: 'Novacub',
    duration: const Duration(minutes: 3),
    fileType: 'FLAC',
  );

  test('only providers returning actual lyrics receive a hit, with timing quality', () async {
    final service = _FakeLyrics();
    final oldRevision = LyricsService.sourceHitsRevision.value;
    await service.probeSourceHits(song);

    expect(LyricsService.sourceHitFor(song, 'local')?.status, 'hit');
    expect(LyricsService.sourceHitFor(song, 'local')?.timing, 'Line');
    expect(LyricsService.sourceHitFor(song, 'lyricsplus')?.status, 'hit');
    expect(LyricsService.sourceHitFor(song, 'lyricsplus')?.timing, 'Syllable');
    expect(LyricsService.sourceHitFor(song, 'lrclib')?.status, 'miss');
    expect(LyricsService.sourceHitsRevision.value, greaterThan(oldRevision));

    final count = service.requested.length;
    await service.probeSourceHits(song);
    expect(service.requested, hasLength(count), reason: 'reuse ten-minute result');
    final different = Song(
      id: 'hit-probe-other-song',
      title: 'Different recording',
      artist: 'Novacub',
      duration: const Duration(minutes: 3),
      fileType: 'FLAC',
    );
    expect(LyricsService.sourceHitFor(different, 'lyricsplus'), isNull,
        reason: 'no false hits carried across songs');
  });
}
