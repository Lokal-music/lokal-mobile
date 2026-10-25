import 'package:flick/features/search/models/global_search_results.dart';
import 'package:flick/features/search/models/search_category.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _track = Song(
  id: 'lyrics-review-test-track',
  title: 'Example',
  artist: 'Example Artist',
  duration: Duration(minutes: 3),
  fileType: 'FLAC',
  filePath: '/music/lyrics-review-test-track.flac',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('metadata search must not claim zero Lyrics matches before scanning', () {
    final result = GlobalSearchResults(
      query: 'example',
      songs: const [_track],
    );
    expect(result.counts[SearchCategory.songs], 1);
    expect(result.counts.containsKey(SearchCategory.lyrics), isFalse);
  });

  test('clearing a manual lyric override invalidates all search instances', () async {
    final service = LyricsService();
    final revision = LyricsService.contentRevision.value;
    var notifications = 0;
    void count() => notifications++;
    LyricsService.contentRevision.addListener(count);
    addTearDown(() => LyricsService.contentRevision.removeListener(count));

    await service.clearManualLyricsPathForSong(_track);

    expect(LyricsService.contentRevision.value, revision + 1);
    expect(notifications, 1);
  });
}
