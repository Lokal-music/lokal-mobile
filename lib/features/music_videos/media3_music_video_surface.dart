import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flick/features/discovery/youtube_music_store.dart';
import 'music_video_surface.dart';

import 'music_video_controller.dart';
export 'music_video_controller.dart';

/// Android's native Media3 player runs two tracks of this very same music
/// video (audio-only + video-only), not Lokal's unrelated album recording.
/// It owns its own timeline and lets Flutter draw all transport controls.
class Media3MusicVideoSurface extends StatefulWidget {
  const Media3MusicVideoSurface({
    super.key, required this.videoId, this.controller, this.onFullscreen,
    this.showControls = true,
  });
  final String videoId;
  final Media3MusicVideoController? controller;
  /// Enlarge the same native player into device fullscreen when requested.
  final VoidCallback? onFullscreen;
  final bool showControls;

  @override
  State<Media3MusicVideoSurface> createState() => _Media3MusicVideoSurfaceState();
}

class _Media3MusicVideoSurfaceState extends State<Media3MusicVideoSurface>
    with WidgetsBindingObserver {
  static const _resolver = MethodChannel('com.mossapps.flick/youtube_stream');
  Map<String, dynamic>? _media;
  MethodChannel? _player;
  Timer? _poller;
  Timer? _watchdog;
  bool _fallback = false;
  bool _loading = true;
  bool _playing = false;
  bool _buffering = true;
  bool _ready = false;
  bool _fill = false;
  double? _dragPosition;
  int _position = 0;
  int _duration = 0;
  int? _controllerLease;
  bool _releaseRequested = false;
  Completer<void> _nativeCreated = Completer<void>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controllerLease = widget.controller?.attach(_command);
    unawaited(_resolve());
  }

  @override
  void didUpdateWidget(covariant Media3MusicVideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.detach(_controllerLease);
      _controllerLease = widget.controller?.attach(_command);
    }
    if (oldWidget.videoId != widget.videoId) {
      _controllerLease = widget.controller?.attach(_command);
      _releaseRequested = false;
      _nativeCreated = Completer<void>();
      widget.controller?.reset();
      _poller?.cancel();
      _watchdog?.cancel();
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
      widget.controller?.fallback();
      return;
    }
    try {
      // Secure storage failure must not disable anonymous video playback.
      final session = await YoutubeMusicSessionStore().read().catchError(
        (Object _) => null,
      );
      if (!mounted || _releaseRequested || videoId != widget.videoId) return;
      final result = await _resolver.invokeMapMethod<String, dynamic>(
        'resolveVideo', {
          'videoId': videoId,
          if (session != null) ...{
            'cookie': [for (final entry in session.cookies.entries) '${entry.key}=${entry.value}'].join('; '),
            'visitorData': session.visitorData,
          },
        },
      ).timeout(const Duration(seconds: 55));
      if (!mounted || _releaseRequested || videoId != widget.videoId) return;
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
      _watchdog?.cancel();
      _watchdog = Timer(const Duration(seconds: 35), () {
        if (mounted && !_ready && !_fallback && videoId == widget.videoId) {
          setState(() => _fallback = true);
          widget.controller?.fallback();
        }
      });
    } catch (_) {
      if (mounted && videoId == widget.videoId) {
        setState(() { _fallback = true; _loading = false; });
        widget.controller?.fallback();
      }
    }
  }

  void _created(int id) {
    _player = MethodChannel('lokal/media3_video/$id');
    if (!_nativeCreated.isCompleted) _nativeCreated.complete();
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
      if (!mounted || _fallback || _releaseRequested || player != _player) return;
      if (status?['error'] != null) {
        _poller?.cancel();
        setState(() => _fallback = true);
        widget.controller?.fallback();
        return;
      }
      setState(() {
        _playing = status?['playing'] == true;
        _buffering = status?['buffering'] == true;
        _ready = status?['ready'] == true;
        if (_ready) _watchdog?.cancel();
        _position = (status?['positionMs'] as num?)?.toInt() ?? 0;
        _duration = (status?['durationMs'] as num?)?.toInt() ?? 0;
      });
      if (widget.controller?.owns(_controllerLease) == false) return;
      widget.controller?.update(
        positionMs: _position,
        durationMs: _duration,
        playing: _playing,
        buffering: _buffering,
      );
    } catch (_) {
      // The AndroidView may still be registering its platform channel.
      // Preparation timeout / media errors will be surfaced by native status.
    }
  }

  Future<void> _command(String method, [Map<String, Object?> args = const {}]) async {
    if (method == 'release') {
      _releaseRequested = true;
      // Await a native view already being created before acknowledging that its
      // audio has yielded. Pending resolution cannot create a view after this.
      if (_media != null && _player == null && !_fallback) {
        await _nativeCreated.future.timeout(const Duration(seconds: 3));
      }
      await _player?.invokeMethod<Object?>('pause');
      return;
    }
    try {
      await _player?.invokeMethod<Object?>(method, args);
      if (mounted) unawaited(_refresh());
    } on PlatformException {
      if (mounted) setState(() => _fallback = true);
      widget.controller?.fallback();
    } on MissingPluginException {
      if (mounted) setState(() => _fallback = true);
      widget.controller?.fallback();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_command('pause'));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller?.detach(_controllerLease);
    _poller?.cancel();
    _watchdog?.cancel();
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
          videoId: widget.videoId, controller: widget.controller);
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
        if (!widget.showControls && widget.onFullscreen != null)
          Positioned(
            top: 8,
            right: 8,
            child: Material(
              color: Colors.black45,
              shape: const CircleBorder(),
              child: IconButton(
                tooltip: 'Full-screen video',
                icon: const Icon(Icons.fullscreen_rounded, color: Colors.white),
                onPressed: widget.onFullscreen,
              ),
            ),
          ),
        if (widget.showControls)
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
                      if (widget.onFullscreen != null)
                        IconButton(
                          tooltip: 'Full-screen video',
                          icon: const Icon(Icons.fullscreen_rounded,
                              color: Colors.white, size: 23),
                          onPressed: widget.onFullscreen,
                        ),
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
