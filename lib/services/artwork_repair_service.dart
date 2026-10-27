import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../data/repositories/song_repository.dart';
import '../models/song.dart';
import '../features/discovery/discovery_http.dart';
import 'album_art_import_service.dart';
import 'artwork_pixel_validation.dart';
import 'graceful_http_client.dart';

/// An explicit maintenance operation, never a startup/background scan.
/// Only exact album/artist matches are eligible; user-selected artwork is
/// protected, and ambiguous catalogue editions are not guessed.
class ArtworkRepairProgress {
  const ArtworkRepairProgress({
    required this.total,
    required this.checked,
    required this.updated,
    required this.skipped,
    required this.failed,
    this.running = false,
    this.cancelled = false,
  });
  final int total;
  final int checked;
  final int updated;
  final int skipped;
  final int failed;
  final bool running;
  final bool cancelled;
}

String repairIdentity(String value) =>
    value.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

bool canRepairAlbum(Song song) {
  final album = repairIdentity(song.album ?? '');
  final artist = repairIdentity(song.albumArtist ?? song.artist);
  return album.isNotEmpty &&
      artist.isNotEmpty &&
      !const {
        'unknown album',
        'unknown',
        'untitled',
        'n/a',
        'various artists',
      }.contains(album) &&
      !const {'unknown artist', 'unknown', 'various artists'}.contains(artist);
}

/// A candidate must identify exactly the same album and album artist. Prefer
/// an unambiguous entry in a known catalogue, not the first fuzzy result.
AlbumArtCandidate? exactRepairCandidate(
  Song song,
  List<AlbumArtCandidate> candidates,
) {
  final album = repairIdentity(song.album ?? '');
  final artist = repairIdentity(song.albumArtist ?? song.artist);
  if (!canRepairAlbum(song)) return null;
  final exact = candidates
      .where(
        (candidate) =>
            repairIdentity(candidate.title) == album &&
            repairIdentity(candidate.artist) == artist,
      )
      .toList();
  for (final source in ['iTunes', 'Deezer', 'Cover Art Archive']) {
    final matches = exact
        .where((candidate) => candidate.sourceLabel == source)
        .toList();
    final urls = matches.map((candidate) => candidate.imageUrl).toSet();
    if (urls.length == 1) return matches.first;
    if (urls.length > 1) return null; // Multiple editions: do not guess.
  }
  // Other providers are used only if the image is unambiguous.
  final urls = exact.map((candidate) => candidate.imageUrl).toSet();
  return urls.length == 1 ? exact.first : null;
}

bool isCoverUpgrade({
  required int currentShortSide,
  required int newShortSide,
}) {
  return currentShortSide < 640 &&
      newShortSide >= 640 &&
      newShortSide >= currentShortSide * 1.5;
}

class ArtworkRepairService {
  ArtworkRepairService({
    SongRepository? repository,
    AlbumArtImportService? importer,
    http.Client? client,
  }) : _repository = repository ?? SongRepository(),
       _importer = importer ?? AlbumArtImportService.instance,
       _client = client ?? GracefulHttpClient(),
       _ownsClient = client == null;

  final SongRepository _repository;
  final AlbumArtImportService _importer;
  final http.Client _client;
  final bool _ownsClient;
  bool _cancel = false;
  bool _running = false;
  Completer<void>? _cancelRequest;

  void cancel() {
    _cancel = true;
    final request = _cancelRequest;
    if (request != null && !request.isCompleted) request.complete();
  }

  void dispose() {
    cancel();
    if (_ownsClient) _client.close();
  }

  Future<int?> _existingShortSide(Song song) async {
    final path = song.albumArt;
    if (path == null || path.isEmpty) return 0;
    if (path.startsWith('http:') ||
        path.startsWith('https:') ||
        path.startsWith('content:')) {
      return null;
    }
    final file = File(path);
    if (!await file.exists()) return 0;
    final length = await file.length();
    if (length <= 0 || length > 5 * 1024 * 1024) return null;
    return (await validateArtworkBytes(await file.readAsBytes()))?.shortSide ??
        0;
  }

  Future<Uint8List?> _fetchArtwork(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return null;
    if (_cancel) return null;
    try {
      final builder = BytesBuilder(copy: false);
      await DiscoveryHttp(_client).transfer(
        uri,
        headers: const {'Accept': 'image/*'},
        maxBytes: artworkMaxBytes,
        deadline: const Duration(seconds: 12),
        onChunk: builder.add,
        cancel: _cancelRequest!.future,
        followArtworkRedirects: true,
      );
      return builder.takeBytes();
    } catch (_) {
      return null;
    }
  }

  Future<ArtworkRepairProgress> refresh({
    required void Function(ArtworkRepairProgress) onProgress,
  }) async {
    if (_running) throw StateError('Artwork refresh already running');
    _running = true;
    _cancel = false;
    _cancelRequest = Completer<void>();
    var total = 0, checked = 0, updated = 0, skipped = 0, failed = 0;
    void report() => onProgress(
      ArtworkRepairProgress(
        total: total,
        checked: checked,
        updated: updated,
        skipped: skipped,
        failed: failed,
        running: _running,
        cancelled: _cancel,
      ),
    );
    try {
      final songs = await _repository.getAllSongs();
      final eligible = <String, List<Song>>{};
      for (final song in songs) {
        final path = song.filePath;
        if (path == null ||
            !p.isAbsolute(path) ||
            _importer.isCustomArtworkPath(song.albumArt) ||
            !canRepairAlbum(song)) {
          continue;
        }
        final key =
            '${repairIdentity(song.album!)}|'
            '${repairIdentity(song.albumArtist ?? song.artist)}';
        eligible.putIfAbsent(key, () => []).add(song);
      }
      total = eligible.values.fold<int>(
        0,
        (sum, tracks) => sum + tracks.length,
      );
      report();
      for (final group in eligible.values) {
        if (_cancel) break;
        final low = <(Song, int)>[];
        for (final song in group) {
          if (_cancel) break;
          try {
            if (!await File(song.filePath!).exists()) {
              skipped++;
              checked++;
            } else {
              final side = await _existingShortSide(song);
              if (side != null && side < 640) {
                low.add((song, side));
              } else {
                skipped++;
                checked++;
              }
            }
          } catch (_) {
            failed++;
            checked++;
          }
          report();
        }
        if (_cancel || low.isEmpty) continue;
        AlbumArtCandidate? candidate;
        try {
          candidate = exactRepairCandidate(
            low.first.$1,
            await _importer.searchOnlineCandidates(low.first.$1),
          );
        } catch (_) {
          /* Offline catalogue: leave originals untouched. */
        }
        if (_cancel) break;
        if (candidate == null) {
          skipped += low.length;
          checked += low.length;
          report();
          continue;
        }
        final bytes = await _fetchArtwork(candidate.imageUrl);
        if (_cancel) break;
        if (bytes == null) {
          failed += low.length;
          checked += low.length;
          report();
          continue;
        }
        final newSide = (await validateArtworkBytes(bytes))?.shortSide ?? 0;
        for (final (song, currentSide) in low) {
          if (_cancel) break;
          try {
            if (!isCoverUpgrade(
              currentShortSide: currentSide,
              newShortSide: newSide,
            )) {
              skipped++;
            } else {
              // Reload the row: the original Song is an immutable snapshot and
              // cannot reveal an artwork edit made during the network lookup.
              final latest = await _repository.getSongById(song.id);
              if (_cancel) break;
              if (latest == null ||
                  latest.filePath != song.filePath ||
                  latest.albumArt != song.albumArt ||
                  _importer.isCustomArtworkPath(latest.albumArt) ||
                  exactRepairCandidate(latest, [candidate]) == null ||
                  await _existingShortSide(latest) != currentSide) {
                skipped++;
                continue;
              }
              if (_cancel) break;
              await _importer.applyImageBytesToSong(song: latest, bytes: bytes);
              updated++;
            }
          } catch (_) {
            failed++;
          } finally {
            checked++;
            report();
          }
        }
        // One album request at a time, to avoid provider rate-limit bursts.
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    } finally {
      _running = false;
      _cancelRequest = null;
      report();
    }
    return ArtworkRepairProgress(
      total: total,
      checked: checked,
      updated: updated,
      skipped: skipped,
      failed: failed,
      cancelled: _cancel,
    );
  }
}
