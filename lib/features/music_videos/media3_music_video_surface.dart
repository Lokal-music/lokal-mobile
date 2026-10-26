import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flick/features/discovery/youtube_music_store.dart';
import 'music_video_surface.dart';

/// Android's native Media3 player runs two tracks of this very same music
/// video (audio-only + video-only), not Lokal's unrelated album recording.
/// It owns its own timeline and lets Flutter draw all transport controls.
class Media3MusicVideoSurface extends StatefulWidget {
  const Media3MusicVideoSurface({super.key, required this.videoId});
  final String videoId;

  @override
  State<Media3MusicVideoSurface> createState() => _Media3MusicVideoSurfaceState();
}

class _Media3MusicVideoSurfaceState extends State<Media3MusicVideoSurface> {
  static const _resolver = MethodChannel('com.mossapps.flick/youtube_stream');
  Map<String, dynamic>? _media;
  MethodChannel? _player;
  Timer? _poller;
  bool _fallback = false;
  bool _loading = true;
  bool _playing = false;
  bool _buffering = true;
  bool _ready = false;
  bool _fill = false;
  double? _dragPosition;
  int _position = 0;
  int _duration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  @override
  void didUpdateWidget(covariant Media3MusicVideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoId != widget.videoId) {
      _poller?.cancel();
      _player = null;
      _media = null;
      _fallback = false;
      _loading = true;
      _ready = false;
      _position = 0;
      _duration = 0;
      unawaited(_resolve());
    }
  }

  Future<void> _resolve() async {
    final videoId = widget.videoId;
    if (!Platform.isAndroid || !validMusicVideoId(videoId)) {
      if (mounted) setState(() { _fallback = true; _loading = false; });
      return;
    }
    try {
      final session = await YoutubeMusicSessionStore().read();
      if (!mounted || videoId != widget.videoId) return;
      final result = await _resolver.invokeMapMethod<String, dynamic>(
        'resolveVideo', {
          'videoId': videoId,
          if (session != null) ...{
            'cookie': [for (final entry in session.cookies.entries) '${entry.key}=${entry.value}'].join('; '),
            'visitorData': session.visitorData,
          },
        },
      ).timeout(const Duration(seconds: 55));
      if (!mounted || videoId != widget.videoId) return;
      final audio = Uri.tryParse(result?['audioUrl'] as String? ?? '');
      final video = Uri.tryParse(result?['videoUrl'] as String? ?? '');
      bool allowed(Uri? uri) => uri?.scheme == 'https' &&
          (uri!.host == 'googlevideo.com' ||
              uri.host.endsWith('.googlevideo.com'));
      if (!allowed(audio) || !allowed(video)) throw const FormatException('No compatible direct video');
      setState(() {
        _media = Map<String, dynamic>.from(result!);
        _loading = false;
      });
    } catch (_) {
      if (mounted && videoId == widget.videoId) {
        setState(() { _fallback = true; _loading = false; });
      }
    }
  }

  void _created(int id) {
    _player = MethodChannel('lokal/media3_video/$id');
    _poller?.cancel();
    unawaited(_refresh());
    _poller = Timer.periodic(const Duration(milliseconds: 400), (_) {
      unawaited(_refresh());
    });
  }

  Future<void> _refresh() async {
    final player = _player;
    if (player == null || _fallback) return;
    try {
      final status = await player.invokeMapMethod<String, dynamic>('snapshot');
      if (!mounted || player != _player) return;
      if (status?['error'] != null) {
        _poller?.cancel();
        setState(() => _fallback = true);
        return;
      }
      setState(() {
        _playing = status?['playing'] == true;
        _buffering = status?['buffering'] == true;
        _ready = status?['ready'] == true;
        _position = (status?['positionMs'] as num?)?.toInt() ?? 0;
        _duration = (status?['durationMs'] as num?)?.toInt() ?? 0;
      });
    } catch (_) {
      // The AndroidView may still be registering its platform channel.
      // Preparation timeout / media errors will be surfaced by native status.
    }
  }

  Future<void> _command(String method, [Map<String, Object?> args = const {}]) async {
    try {
      await _player?.invokeMethod<Object?>(method, args);
      if (mounted) unawaited(_refresh());
    } on PlatformException {
      if (mounted) setState(() => _fallback = true);
    } on MissingPluginException {
      if (mounted) setState(() => _fallback = true);
    }
  }

  @override
  void dispose() {
    _poller?.cancel();
    // Pause the native audio owner before Lokal optionally resumes song audio.
    unawaited(_player?.invokeMethod<Object?>('pause').catchError((Object _) => null) ?? Future<Object?>.value(null));
    _player = null;
    super.dispose();
  }

  String _clock(int milliseconds) {
    final seconds = milliseconds ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (_fallback) {
      // An unavailable or expired native stream must remain watchable via
      // the official embed, rather than crash or leave a black stage.
      return MusicVideoSurface(key: ValueKey('youtube:${widget.videoId}'),
          videoId: widget.videoId);
    }
    if (_loading || _media == null) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        AndroidView(
          key: ValueKey('native:${widget.videoId}'),
          viewType: 'lokal/media3_music_video',
          creationParamsCodec: const StandardMessageCodec(),
          creationParams: {
            'audioUrl': _media!['audioUrl'],
            'videoUrl': _media!['videoUrl'],
            'headers': _media!['headers'] ?? <String, String>{},
          },
          onPlatformViewCreated: _created,
        ),
        if (!_ready || _buffering)
          const IgnorePointer(
            child: Center(child: CircularProgressIndicator(color: Colors.white)),
          ),
        Positioned(
          left: 0, right: 0, bottom: 0,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter, end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0xD9000000)],
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 26, 10, 5),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 35,
                        child: IconButton(
                          tooltip: _playing ? 'Pause video' : 'Play video',
                          icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                              color: Colors.white),
                          padding: EdgeInsets.zero,
                          onPressed: () => _command(_playing ? 'pause' : 'play'),
                        ),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: Colors.white,
                            inactiveTrackColor: Colors.white38,
                            thumbColor: Colors.white,
                            trackHeight: 2,
                          ),
                          child: Slider(
                            value: (_dragPosition ?? _position.toDouble())
                                .clamp(0, _duration <= 0 ? 1 : _duration)
                                .toDouble(),
                            min: 0,
                            max: (_duration <= 0 ? 1 : _duration).toDouble(),
                            onChanged: _duration <= 0 ? null : (v) =>
                                setState(() => _dragPosition = v),
                            onChangeEnd: (v) {
                              setState(() => _dragPosition = null);
                              unawaited(_command('seek', {'positionMs': v.toInt()}));
                            },
                          ),
                        ),
                      ),
                      Text('${_clock(_position)} / ${_clock(_duration)}',
                          style: const TextStyle(fontSize: 11, color: Colors.white)),
                      IconButton(
                        tooltip: _fill ? 'Fit video' : 'Fill video',
                        icon: Icon(_fill ? Icons.fit_screen_rounded : Icons.aspect_ratio_rounded,
                            color: Colors.white, size: 21),
                        onPressed: () {
                          setState(() => _fill = !_fill);
                          unawaited(_command('fill', {'fill': _fill}));
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
