import 'dart:convert';
import 'dart:io';

import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;

import '../data/entities/song_entity.dart';
import '../models/ios_transfer_models.dart';
import '../models/ios_transfer_upload.dart';
import 'ios_library_scan_epoch.dart';
import 'link/link_protocol.dart' show linkUuid;

/// Native bytes, native pairing and an actual current Isar row jointly define
/// admission. This never grants arbitrary paths or exports a CUE segment as a
/// whole recording. External/bookmarked and network files use the foreground
/// transfer path until they have a separately qualified source adapter.
class IosTransferUploadAdmission {
  IosTransferUploadAdmission({required this.isar, required this.port});
  final Isar isar;
  final IosTransferUploadPort port;

  Future<IosTransferSummary> enqueueSong({
    required int songId,
    required IosTransferPairing expectedPairing,
    required void Function(IosTransferIntent intent) prepared,
    IosTransferIntent? frozenIntent,
    String? reviewedSourcePath,
  }) => IosLibraryScanEpoch.run(() async {
    IosTransferUploadContext? context;
    IosTransferUploadGrant? grant;
    final song = _current(songId);
    if (reviewedSourcePath != null && song.filePath != reviewedSourcePath) {
      throw StateError(
        'The selected source changed. Review the copy plan again.',
      );
    }
    final binding = _binding(song);
    void check() {
      IosLibraryScanEpoch.requireCurrent();
      if (_binding(_current(songId)) != binding) {
        throw StateError('The library song changed. Select it again.');
      }
    }

    try {
      context = await port.uploadSourceContext();
      check();
      if (jsonEncode(context.pairing.scope.toJson()) !=
              jsonEncode(expectedPairing.scope.toJson()) ||
          context.pairing.desktopUserId != expectedPairing.desktopUserId) {
        throw StateError('The paired desktop changed. Review the copy again.');
      }
      final canonical = await File(song.filePath).resolveSymbolicLinks();
      check();
      if (!p.posix.isWithin(context.canonicalRootPath, canonical)) {
        throw StateError('This source requires foreground transfer.');
      }
      // Pass the original path, not its resolved target: native openat rejects
      // symlinks in every component, including links within the Music root.
      final lexicalRoot = p.posix.isWithin(context.rootPath, song.filePath)
          ? context.rootPath
          : context.canonicalRootPath;
      if (!p.posix.isWithin(lexicalRoot, song.filePath) ||
          p.posix.normalize(song.filePath) != song.filePath) {
        throw StateError('This source requires foreground transfer.');
      }
      final relative = p.posix.relative(song.filePath, from: lexicalRoot);
      grant = await port.authorizeUploadSource(
        contextId: context.id,
        relativePath: relative,
        songId: songId.toString(),
      );
      check();
      if (grant.songId != songId.toString()) {
        throw const FormatException('Upload source identity changed.');
      }
      final candidate = IosTransferIntent(
        id: frozenIntent?.id ?? linkUuid(),
        createdMs:
            frozenIntent?.createdMs ?? DateTime.now().millisecondsSinceEpoch,
        identity: IosTransferIdentity(
          scope: context.pairing.scope,
          desktopUserId: context.pairing.desktopUserId,
          sourceId: frozenIntent?.identity.sourceId ?? 'phone-song-$songId',
          localSongId: songId.toString(),
        ),
        metadata: _metadata(song),
        expectedBytes: grant.bytes,
        expectedSha256: grant.sha256,
      );
      candidate.validate();
      if (frozenIntent != null &&
          jsonEncode(candidate.toJson()) != jsonEncode(frozenIntent.toJson())) {
        throw StateError(
          'The recording changed. Its original upload cannot be retried.',
        );
      }
      final intent = frozenIntent ?? candidate;
      // The caller retains this exact intent for a lost acknowledgement. It
      // must recover the native journal, never silently mint a replacement.
      prepared(intent);
      check();
      return await port.enqueueUpload(intent, grantId: grant.id);
    } finally {
      // Native grants also expire and consent retirement drains source reads.
      // Release failures must not hide the admission result/ambiguous reply.
      for (final id in [grant?.id, context?.id]) {
        if (id != null) {
          try {
            await port.releaseUploadSource(id);
          } catch (_) {
            /* bounded native expiry */
          }
        }
      }
    }
  });

  SongEntity _current(int id) {
    final song = id > 0 ? isar.songEntitys.getSync(id) : null;
    if (song == null ||
        song.sourceType != null ||
        !p.posix.isAbsolute(song.filePath) ||
        song.startOffsetMs != null ||
        song.endOffsetMs != null) {
      throw StateError(
        'Select a current local recording for background upload.',
      );
    }
    return song;
  }

  static IosTransferMetadata _metadata(SongEntity song) => IosTransferMetadata(
    title: song.title,
    artist: song.artist,
    album: song.album,
    albumArtist: song.albumArtist,
    genre: song.genre,
    fileExtension: p.posix
        .extension(song.filePath)
        .replaceFirst('.', '')
        .toLowerCase(),
    durationMs: song.durationMs,
    sampleRate: song.sampleRate,
    bitDepth: song.bitDepth,
    bitrate: song.bitrate,
    trackNumber: song.trackNumber,
    discNumber: song.discNumber,
    year: song.year,
  );

  static String _binding(SongEntity song) => jsonEncode({
    'id': song.id,
    'path': song.filePath,
    'source': song.sourceType,
    'start': song.startOffsetMs,
    'end': song.endOffsetMs,
    'added': song.dateAdded.microsecondsSinceEpoch,
    'modified': song.lastModified?.microsecondsSinceEpoch,
    'metadata': _metadata(song).toJson(),
  });
}
