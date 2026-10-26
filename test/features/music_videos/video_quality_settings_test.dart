import 'package:flick/features/music_videos/video_quality_settings.dart';
import 'package:flick/features/music_videos/media3_music_video_surface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults to existing 1080p quality and offers 360p through 4K', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(videoQualityProvider), 1080);
    expect(videoQualityHeights, containsAll([0, 360, 480, 720, 1080, 1440, 2160]));
    expect(effectiveVideoHeight(0), 2160);
    expect(effectiveVideoHeight(480), 480);
    expect(videoQualityLabel(0), 'Auto (best available)');
    expect(videoQualityLabel(2160), '2160p');
  });

  test('chosen video quality is persisted for the next session', () async {
    final first = ProviderContainer();
    expect(first.read(videoQualityProvider), defaultVideoQualityHeight);
    await first.read(videoQualityProvider.notifier).select(720);
    expect(first.read(videoQualityProvider), 720);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getInt('lokal.music_video.max_height'), 720);
    first.dispose();

    final second = ProviderContainer();
    addTearDown(second.dispose);
    second.read(videoQualityProvider);
    // The notifier hydrates its persisted selection asynchronously.
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(second.read(videoQualityProvider), 720);
  });

  test('a new selection survives an in-flight preferences restoration', () async {
    SharedPreferences.setMockInitialValues({
      'lokal.music_video.max_height': 360,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(videoQualityProvider), defaultVideoQualityHeight);

    // select() updates the view before awaiting the preferences instance.
    // The pending restore must not overwrite this newer value with 360p.
    await container.read(videoQualityProvider.notifier).select(720);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(videoQualityProvider), 720);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('lokal.music_video.max_height'), 720);
  });

  test('rapid selections persist the most recent resolution', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(videoQualityProvider);
    final notifier = container.read(videoQualityProvider.notifier);
    await Future.wait([notifier.select(720), notifier.select(480)]);
    expect(container.read(videoQualityProvider), 480);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('lokal.music_video.max_height'), 480);
  });

  test('ignores unsupported values and forwards actual height to Media3', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(videoQualityProvider);
    await container.read(videoQualityProvider.notifier).select(9999);
    expect(container.read(videoQualityProvider), 1080);
    const player = Media3MusicVideoSurface(
      videoId: 'abcdefghijk',
      maxVideoHeight: 480,
    );
    expect(effectiveVideoHeight(player.maxVideoHeight), 480);
  });
}
