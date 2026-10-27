import 'package:flick/models/song.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/services/ios_widget_state_sampler.dart';
import 'package:flutter_test/flutter_test.dart';

Song song(String id) => Song(
  id: id,
  title: 'Track $id',
  artist: 'Artist',
  duration: const Duration(minutes: 3),
  fileType: 'FLAC',
  filePath: '/owned/$id.flac',
);

void main() {
  late DateTime now;
  late List<IosWidgetSample> samples;
  late IosWidgetStateSampler sampler;
  PlayerState state({
    bool playing = true,
    bool buffering = false,
    int position = 0,
    double rate = 1,
  }) => PlayerState(
    currentSong: song('a'),
    isPlaying: playing,
    isBuffering: buffering,
    position: Duration(milliseconds: position),
    duration: const Duration(minutes: 3),
    playbackSpeed: rate,
  );
  setUp(() {
    now = DateTime.utc(2026, 10, 27);
    samples = [];
    sampler = IosWidgetStateSampler(
      accentArgb: 0xff123456,
      onSample: samples.add,
      clock: () => now,
    );
  });
  tearDown(() => sampler.dispose());

  test('position ticks do not reload; existing events provide a metadata-only heartbeat', () {
    sampler.observe(state());
    for (var i = 1; i <= 120; i++) {
      now = now.add(const Duration(milliseconds: 500));
      sampler.observe(state(position: i * 500));
    }
    expect(samples, hasLength(2));
    expect(samples.last.reason, IosWidgetSampleReason.heartbeat);
    expect(samples.last.reloadTimelines, false);
    expect(samples.last.loadArtwork, false);
    expect(samples.last.metadata.toJson()['positionMs'], 60000);
  });

  test(
    'a seek republishes the actual sample without rereading unchanged art',
    () {
      sampler.observe(state(position: 1000));
      now = now.add(const Duration(seconds: 1));
      sampler.observe(state(position: 50000));
      expect(samples.last.reason, IosWidgetSampleReason.seek);
      expect(samples.last.metadata.toJson()['positionMs'], 50000);
      expect(samples.last.reloadTimelines, true);
      expect(samples.last.loadArtwork, false);
    },
  );

  test('theme and completed-art events cannot reanchor an old playhead', () {
    sampler.observe(state(position: 1000));
    final sourceTime = now.millisecondsSinceEpoch;
    now = now.add(const Duration(seconds: 10));
    sampler.setAccent(0xffaabbcc);
    expect(samples.last.metadata.toJson()['updatedAtMs'], sourceTime);
    expect(samples.last.metadata.toJson()['positionMs'], 1000);
    final count = samples.length;
    sampler.artworkMaterialized('/owned/other.flac');
    expect(samples, hasLength(count));
    sampler.artworkMaterialized('/owned/a.flac');
    expect(samples.last.reason, IosWidgetSampleReason.artwork);
    expect(samples.last.loadArtwork, true);
    expect(samples.last.metadata.toJson()['updatedAtMs'], sourceTime);
  });

  test('paused state needs no recurring heartbeat', () {
    sampler.observe(state(playing: false));
    for (var i = 0; i < 5; i++) {
      now = now.add(const Duration(minutes: 1));
      sampler.observe(state(playing: false));
    }
    expect(samples, hasLength(1));
  });

  test(
    'buffering preserves requested playback but freezes projected progress',
    () {
      sampler.observe(state(position: 1000));
      now = now.add(const Duration(seconds: 1));
      sampler.observe(state(position: 1000, buffering: true));
      expect(samples.last.metadata.toJson()['isPlaying'], true);
      expect(samples.last.metadata.toJson()['isBuffering'], true);
      expect(
        samples.last.metadata.projectedPositionAt(
          now.add(const Duration(seconds: 2)).millisecondsSinceEpoch,
        ),
        1000,
      );
      now = now.add(const Duration(seconds: 2));
      sampler.observe(state(position: 1000));
      expect(samples.last.metadata.toJson()['isBuffering'], false);
      expect(
        samples.last.metadata.projectedPositionAt(
          now.add(const Duration(seconds: 2)).millisecondsSinceEpoch,
        ),
        3000,
      );
    },
  );

  test(
    'invalid rates remain bounded and cannot create a publication storm',
    () {
      sampler.observe(state(rate: double.nan));
      now = now.add(const Duration(milliseconds: 500));
      sampler.observe(state(position: 500, rate: double.nan));
      expect(samples, hasLength(1));
      expect(samples.single.metadata.toJson()['playbackRate'], 1.0);
    },
  );

  test('recommendations are supplied explicitly and their art candidates match the wire', () {
    sampler.observe(state());
    expect(samples.last.metadata.toJson()['recommendations'], isEmpty);
    sampler.setRecommendations([for (var i = 0; i < 100; i++) song('rec-$i')]);
    expect(samples.last.metadata.toJson()['recommendations'], hasLength(12));
    expect(samples.last.artworkSources, hasLength(13));
    expect(samples.last.artworkSources.first.id, 'a');
    expect(() => samples.last.artworkSources.clear(), throwsUnsupportedError);
  });

  test('backward wall clock changes publish the new real timestamp safely', () {
    sampler.observe(state());
    now = now.subtract(const Duration(minutes: 3));
    sampler.observe(state());
    expect(samples, hasLength(2));
    expect(
      samples.last.metadata.toJson()['updatedAtMs'],
      now.millisecondsSinceEpoch,
    );
  });

  test(
    'dispose stops player, theme, recommendation and artwork observations',
    () {
      sampler.observe(state());
      sampler.dispose();
      sampler.observe(state(position: 10000));
      sampler.setAccent(0);
      sampler.setRecommendations([song('b')]);
      sampler.artworkMaterialized('/owned/a.flac');
      sampler.republishLatest();
      expect(samples, hasLength(1));
    },
  );
}
