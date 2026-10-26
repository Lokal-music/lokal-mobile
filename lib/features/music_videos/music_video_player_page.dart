import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flick/features/internet_radio/radio_providers.dart';
import 'package:flick/features/player/screens/full_player_screen.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/player_provider.dart';

export 'music_video_surface.dart' show musicVideoEmbedHtml;

/// Music Videos and song actions route into full player, not a separate
/// browsing page. Never play song audio beside YouTube's own video audio.
Future<void> openMusicVideo(
  BuildContext context,
  Song song,
  String videoId,
) async {
  if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(videoId)) return;
  final container = ProviderScope.containerOf(context, listen: false);
  if (container.read(isPlayingProvider)) {
    await container.read(playerProvider.notifier).pause();
  }
  if (container.read(radioPlayerProvider).station != null) {
    await container.read(radioPlayerProvider.notifier).stop();
  }
  if (!context.mounted) return;
  // Video is a full-screen player route, not a child of the current
  // Videos tab Navigator. Pushing on the root ensures the shell's persistent
  // mini-player/footer cannot remain *inside* the video player.
  await Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute(
      builder: (_) => FullPlayerScreen(
        heroTag: 'music-video:${song.id}',
        videoSong: song,
        videoId: videoId,
      ),
    ),
  );
}

/// Legacy entry point retained for other callers: identical player surface.
class MusicVideoPlayerPage extends StatelessWidget {
  const MusicVideoPlayerPage({
    super.key,
    required this.song,
    required this.videoId,
  });

  final Song song;
  final String videoId;

  @override
  Widget build(BuildContext context) => FullPlayerScreen(
    heroTag: 'music-video:${song.id}',
    videoSong: song,
    videoId: videoId,
  );
}
