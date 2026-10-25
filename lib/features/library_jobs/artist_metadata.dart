import 'package:flick/core/utils/artist_credits.dart';

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:isar_community/isar.dart';
import 'package:flick/data/database.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/apple_music/apple_music_metadata_service.dart';

/// One worker warms new artists and persists their portraits. Rows subscribe
/// only to their own path, rather than rebuilding the library for every result.
class ArtistMetadata extends Notifier<Map<String, String>> {
  ArtistMetadata({List<String> Function(Song)? parseCredits})
    : _parseCredits = parseCredits ?? songArtistNames;

  final List<String> Function(Song) _parseCredits;
  final _seen = <String>{};
  final _queue = Queue<String>();
  final _seenCredits = <(String, String?)>{};
  List<Song>? _pendingWarmup;
  Future<void>? _warming;
  bool _seeded = false;
  bool _working = false;
  static String key(String name) => name.trim().toLowerCase();
  @override
  Map<String, String> build() => const {};

  void warm(List<Song> songs) {
    _pendingWarmup = songs;
    _warming ??= _warmCredits().whenComplete(() => _warming = null);
  }

  @visibleForTesting
  Future<void> get warmupIdle => _warming ?? Future<void>.value();

  Future<void> _warmCredits() async {
    // A library listener runs on the UI isolate. Never parse thousands of
    // artist credits synchronously there, nor reparse unchanged credits on
    // every sample-rate/artwork write. Keep only the newest pending snapshot.
    await Future<void>.delayed(Duration.zero);
    while (_pendingWarmup != null && ref.mounted) {
      final songs = _pendingWarmup!;
      _pendingWarmup = null;
      for (var i = 0; i < songs.length; i++) {
        final song = songs[i];
        if (_seenCredits.add((song.artist, song.albumArtist))) {
          for (final name in _parseCredits(song)) {
            if (!_seen.add(key(name))) continue;
            if (_seeded) {
              _queue.addFirst(name);
            } else {
              _queue.addLast(name);
            }
          }
        }
        if ((i + 1) % 64 == 0) {
          await Future<void>.delayed(Duration.zero);
          if (!ref.mounted || _pendingWarmup != null) break;
        }
      }
      _seeded = true;
      if (ref.mounted) unawaited(_drain());
    }
  }

  Future<void> _drain() async {
    if (_working) return;
    _working = true;
    try {
      while (_queue.isNotEmpty && ref.mounted) {
        final name = _queue.removeFirst();
        try {
          await refresh(name);
        } catch (_) {
          /* Retry unavailable artists next session or manually. */
        }
        if (ref.mounted) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }
    } finally {
      _working = false;
    }
  }

  Future<void> refresh(String name, {bool force = false}) async {
    if (!Database.isInitialized) return;
    final previous = await Database.artists
        .filter()
        .nameEqualTo(name, caseSensitive: false)
        .findFirst();
    var path = previous?.artPath;
    if (!force && path != null && await File(path).exists()) {
      if (ref.mounted) state = {...state, key(name): path};
      return;
    }
    final api = AppleMusicMetadataService.instance;
    final artist = await api.resolveArtist(name, refresh: force);
    if (artist == null || !ref.mounted) return;
    final info = await api.getArtistInfo(artist.artistId, refresh: force);
    final image = info?.imageUrl;
    if (image == null || image.isEmpty || !ref.mounted) return;
    // Cache a bounded portrait, shared by the list and full artist header.
    final file = await DefaultCacheManager()
        .getImageFile(image, maxWidth: 600, maxHeight: 600)
        .where((event) => event is FileInfo)
        .cast<FileInfo>()
        .last;
    if (!ref.mounted) return;
    final cachedPath = file.file.path;
    // Re-read after network I/O: another metadata writer may have created it.
    await Database.instance.writeTxn(() async {
      final row =
          await Database.artists
              .filter()
              .nameEqualTo(name, caseSensitive: false)
              .findFirst() ??
          (ArtistEntity()..name = name);
      row.artPath = cachedPath;
      await Database.artists.put(row);
    });
    if (ref.mounted) state = {...state, key(name): cachedPath};
  }
}

final artistMetadataProvider =
    NotifierProvider<ArtistMetadata, Map<String, String>>(ArtistMetadata.new);
