import 'package:flutter/foundation.dart';

import '../models/ios_widget_snapshot.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import 'ios_widget_snapshot_builder.dart';

enum IosWidgetSampleReason { metadata, seek, heartbeat, artwork }

class IosWidgetSample {
  IosWidgetSample(
    this.metadata,
    this.reason,
    Iterable<Song> artworkSources, {
    required this.loadArtwork,
  }) : artworkSources = List.unmodifiable(artworkSources);
  final IosWidgetSnapshot metadata;
  final IosWidgetSampleReason reason;
  final List<Song> artworkSources;
  final bool loadArtwork;
  bool get reloadTimelines => reason != IosWidgetSampleReason.heartbeat;
}

/// Observes existing canonical events; creates no ticker, player or discovery.
/// The source timestamp belongs to the last actual player observation, even
/// when a later theme or materialized-cover event causes publication.
class IosWidgetStateSampler {
  IosWidgetStateSampler({
    required int accentArgb,
    required this.onSample,
    DateTime Function()? clock,
    this.heartbeat = const Duration(minutes: 1),
    this.seekThreshold = const Duration(seconds: 1),
  }) : _accent = accentArgb,
       _clock = clock ?? DateTime.now;

  static double _rate(PlayerState? state) {
    final value = state?.playbackSpeed;
    return value != null && value.isFinite && value >= .25 && value <= 4
        ? value
        : 1.0;
  }

  final ValueChanged<IosWidgetSample> onSample;
  final DateTime Function() _clock;
  final Duration heartbeat, seekThreshold;
  int _accent;
  PlayerState? _state;
  DateTime? _sampledAt, _lastEmittedAt;
  List<Object?>? _lastSignature, _lastArtworkSignature;
  List<Song> _recommendations = const [];
  IosWidgetFlowKind _flowKind = IosWidgetFlowKind.none;
  String _flowStatus = '';
  bool _disposed = false;

  void observe(PlayerState state) {
    if (_disposed) return;
    final now = _clock();
    final previous = _state;
    final previousTime = _sampledAt;
    _state = state;
    _sampledAt = now;
    if (!listEquals(_lastSignature, _signature()) ||
        (previousTime != null && now.isBefore(previousTime))) {
      _emit(IosWidgetSampleReason.metadata);
      return;
    }
    if (previous != null && previousTime != null) {
      final elapsed = now.difference(previousTime).inMilliseconds;
      final rate = _rate(previous);
      var expected =
          previous.position.inMilliseconds +
          (previous.isPlaying && !previous.isBuffering
              ? (elapsed * rate).round()
              : 0);
      if (previous.duration > Duration.zero) {
        expected = expected.clamp(0, previous.duration.inMilliseconds);
      }
      if ((state.position.inMilliseconds - expected).abs() >=
          seekThreshold.inMilliseconds) {
        _emit(IosWidgetSampleReason.seek);
        return;
      }
    }
    if (state.isPlaying &&
        _lastEmittedAt != null &&
        now.difference(_lastEmittedAt!) >= heartbeat) {
      _emit(IosWidgetSampleReason.heartbeat);
    }
  }

  void setAccent(int value) {
    if (_disposed || _accent == value) return;
    _accent = value;
    if (_state != null) _emit(IosWidgetSampleReason.metadata);
  }

  /// Only an existing recommendation owner may supply these rows. The sampler
  /// never labels the manual queue as recommendations or starts source work.
  void setRecommendations(
    Iterable<Song> songs, {
    IosWidgetFlowKind kind = IosWidgetFlowKind.none,
    String status = '',
  }) {
    if (_disposed) return;
    _recommendations = List.unmodifiable(songs.take(48));
    _flowKind = kind;
    _flowStatus = status;
    if (_state != null && !listEquals(_lastSignature, _signature())) {
      _emit(IosWidgetSampleReason.metadata);
    }
  }

  void artworkMaterialized(String source) {
    if (_disposed || _state == null) return;
    if (_songs.any((song) => song.filePath == source)) {
      _emit(IosWidgetSampleReason.artwork, forceArtwork: true);
    }
  }

  void republishLatest() {
    if (!_disposed && _state != null) {
      _emit(IosWidgetSampleReason.metadata, forceArtwork: true);
    }
  }

  Iterable<Song> get _songs sync* {
    if (_state?.currentSong case final current?) yield current;
    yield* _recommendations;
  }

  List<Object?> _signature() => [
    _state?.isPlaying,
    _state?.isBuffering,
    _state?.duration,
    _rate(_state),
    _state?.upNext.length,
    _accent,
    _flowKind,
    _flowStatus,
    for (final song in _songs) ...[
      song.id,
      song.title,
      song.artist,
      song.album,
      song.albumArt,
      song.filePath,
    ],
  ];

  void _emit(IosWidgetSampleReason reason, {bool forceArtwork = false}) {
    final state = _state!;
    final metadata = buildIosWidgetSnapshot(
      state,
      updatedAt: _sampledAt!,
      revision: 1,
      accentArgb: _accent,
      recommendations: _recommendations,
      flowKind: _flowKind,
      flowStatus: _flowStatus,
    );
    final fields = metadata.toJson();
    final aliases = <String>{
      if (fields['current'] case final Map current) current['id'] as String,
      for (final row in fields['recommendations']! as List)
        (row as Map)['id'] as String,
    };
    final seen = <String>{};
    final songs = [
      for (final song in _songs)
        if (aliases.contains(iosWidgetTrackAlias(song.id)) && seen.add(song.id))
          song,
    ];
    final artSignature = <Object?>[
      for (final song in songs) ...[song.id, song.albumArt, song.filePath],
    ];
    final load =
        forceArtwork || !listEquals(_lastArtworkSignature, artSignature);
    _lastSignature = _signature();
    _lastArtworkSignature = artSignature;
    _lastEmittedAt = _clock();
    onSample(IosWidgetSample(metadata, reason, songs, loadArtwork: load));
  }

  void dispose() {
    _disposed = true;
  }
}
