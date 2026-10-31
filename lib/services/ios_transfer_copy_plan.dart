import 'dart:convert';

import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;

import '../data/entities/network_server_entity.dart';
import '../data/entities/song_entity.dart';
import '../models/ios_transfer_models.dart';
import '../models/lokal_remote_state.dart';
import 'ios_library_scan_epoch.dart';
import 'ios_pairing_retirement.dart';
import 'ios_transfer_session.dart';
import 'link/link_file_copy.dart';
import 'link/link_protocol.dart' show linkUuid;
import 'link/desktop_genre_reconciliation.dart';

/// Adapts the existing explicit desktop copy preview. It never silently falls
/// back after any native submission, nor labels queued work as completed work.
class IosTransferCopyAdapter {
  IosTransferCopyAdapter({required this.isar, required this.session});
  final Isar isar;
  final IosTransferSession session;

  Future<IosTransferCopyPlan?> prepare(
    LinkCopyPlan plan,
    LokalRemoteCredentials credentials,
  ) async {
    final check = IosLibraryScanEpoch.consentGuard();
    final capability = await session.native.capability();
    check();
    if (!capability.canCopyToLibrary || !capability.upload) return null;
    // Existing private copies and sources needing bookmark/network/CUE export
    // retain their foreground path as a complete plan, before any job exists.
    if (plan.toMusicFolder.isNotEmpty ||
        plan.toDesktop.any(
          (song) =>
              song.sourceType != null ||
              song.startOffsetMs != null ||
              song.endOffsetMs != null ||
              song.filePath == null ||
              int.tryParse(song.id) == null,
        )) {
      return null;
    }
    if (plan.total > iosTransferMaximumJobs ||
        credentials.desktopId == null ||
        credentials.pairingID == null) {
      throw StateError('This copy plan cannot use background transfers.');
    }
    await session.start();
    check();
    final context = await session.native.uploadSourceContext();
    try {
      check();
      final expected = IosTransferScope(
        desktopId: credentials.desktopId!,
        origin: credentials.origin.toString(),
        pairingId: credentials.pairingID,
      );
      if (!IosPairingRetirement.sameScope(expected, context.pairing.scope) ||
          credentials.desktopUserId != context.pairing.desktopUserId) {
        throw StateError('The paired desktop changed. Review the copy again.');
      }
      if (plan.toDesktop.any(
        (song) =>
            !(p.posix.isWithin(context.rootPath, song.filePath!) ||
                p.posix.isWithin(context.canonicalRootPath, song.filePath!)),
      )) {
        return null;
      }
      final server = isar.networkServerEntitys.getSync(plan.server.id);
      if (server == null ||
          server.protocol != 'lokal' ||
          Uri.tryParse(server.baseUrl)?.origin !=
              Uri.parse(context.pairing.scope.origin).origin ||
          server.username !=
              '${context.pairing.scope.desktopId}:${context.pairing.desktopUserId ?? 'guest'}') {
        throw StateError(
          'The desktop library connection changed. Review the copy again.',
        );
      }
      final serverBinding = _serverBinding(server);
      void current() {
        check();
        final row = isar.networkServerEntitys.getSync(server.id);
        if (!session.active ||
            row == null ||
            _serverBinding(row) != serverBinding) {
          throw StateError(
            'The desktop library connection changed. Review the copy again.',
          );
        }
      }

      final downloads = <IosTransferIntent>[];
      final bindings = <int, String>{};
      final sources = <String>{};
      for (final entry in plan.toPhone) {
        final source = entry.track['id']?.toString();
        if (source == null || !sources.add(source)) {
          throw const FormatException('Invalid desktop copy plan.');
        }
        final existingId = entry.existing == null
            ? null
            : int.tryParse(entry.existing!.id);
        if (entry.existing != null) {
          final row = existingId == null
              ? null
              : isar.songEntitys.getSync(existingId);
          if (row == null ||
              row.remoteServerId != server.id ||
              row.remoteId != source) {
            throw StateError(
              'A selected library song changed. Review the copy again.',
            );
          }
        }
        if (existingId != null) {
          bindings[existingId] = _songBinding(
            isar.songEntitys.getSync(existingId)!,
          );
        }
        final track = entry.track;
        final intent = IosTransferIntent(
          id: linkUuid(),
          createdMs: DateTime.now().millisecondsSinceEpoch,
          identity: IosTransferIdentity(
            scope: context.pairing.scope,
            sourceId: source,
            localSongId: existingId?.toString(),
            localServerId: server.id,
            desktopUserId: context.pairing.desktopUserId,
          ),
          metadata: IosTransferMetadata.fromJson({
            'title': track['title'] ?? '',
            'artist': track['artist'] ?? '',
            'fileExtension': (track['fileType']?.toString() ?? 'bin')
                .toLowerCase(),
            'album': ?track['album'],
            'albumArtist': ?(track['albumArtist'] ?? track['album_artist']),
            'genre': ?desktopLinkGenres(track),
            if (track['duration'] case final num seconds when seconds.isFinite)
              'durationMs': (seconds * 1000).round(),
            for (final entry in const {
              'sampleRate': 'sample_rate',
              'bitDepth': 'bit_depth',
              'bitrate': 'bitrate',
              'trackNumber': 'track_number',
              'discNumber': 'disc_number',
              'year': 'year',
            }.entries)
              entry.key: ?_number(track[entry.key] ?? track[entry.value]),
          }),
        );
        intent.validate(submission: true);
        downloads.add(intent);
      }
      final uploads = <({int id, String path})>[];
      for (final song in plan.toDesktop) {
        final id = int.parse(song.id), path = song.filePath!;
        final row = isar.songEntitys.getSync(id);
        if (id <= 0 ||
            row == null ||
            row.filePath != path ||
            row.sourceType != null ||
            row.startOffsetMs != null ||
            row.endOffsetMs != null ||
            !sources.add('phone:$id')) {
          throw StateError(
            'A selected library song changed. Review the copy again.',
          );
        }
        uploads.add((id: id, path: path));
      }
      current();
      return IosTransferCopyPlan._(
        session,
        context.pairing,
        List.unmodifiable(downloads),
        List.unmodifiable(uploads),
        current,
        () {
          current();
          for (final entry in bindings.entries) {
            final row = isar.songEntitys.getSync(entry.key);
            if (row == null || _songBinding(row) != entry.value) {
              throw StateError(
                'A selected library song changed. Review the copy again.',
              );
            }
          }
        },
      );
    } finally {
      try {
        await session.native.releaseUploadSource(context.id);
      } catch (_) {
        /* native expiry */
      }
    }
  }

  static int? _number(Object? value) {
    if (value == null) return null;
    if (value is! num || !value.isFinite || value != value.truncateToDouble()) {
      throw const FormatException('Invalid desktop audio metadata.');
    }
    return value.toInt();
  }

  static String _songBinding(SongEntity row) => jsonEncode({
    'id': row.id,
    'path': row.filePath,
    'remote': row.remoteId,
    'server': row.remoteServerId,
    'start': row.startOffsetMs,
    'end': row.endOffsetMs,
    'added': row.dateAdded.microsecondsSinceEpoch,
  });

  static String _serverBinding(NetworkServerEntity server) => jsonEncode({
    'id': server.id,
    'protocol': server.protocol,
    'origin': server.baseUrl,
    'account': server.username,
  });
}

class IosTransferCopyPlan {
  IosTransferCopyPlan._(
    this._session,
    this._pairing,
    this.downloads,
    this._uploads,
    this._check,
    this._checkDownloads,
  );
  final IosTransferSession _session;
  final IosTransferPairing _pairing;
  final List<IosTransferIntent> downloads;
  final List<({int id, String path})> _uploads;
  final void Function() _check, _checkDownloads;
  final _frozenUploads = <int, IosTransferIntent>{};
  final _admittedUploads = <int>{};
  bool _downloadsAdmitted = false, _submitting = false;
  int get total => downloads.length + _uploads.length;

  Future<void> submit({
    void Function(int queued, int total)? onProgress,
  }) async {
    if (_submitting) {
      throw StateError('This copy plan is already being submitted.');
    }
    _submitting = true;
    try {
      _check();
      onProgress?.call(
        (_downloadsAdmitted ? downloads.length : 0) + _admittedUploads.length,
        total,
      );
      if (!_downloadsAdmitted && downloads.isNotEmpty) {
        _checkDownloads();
        await _session.native.enqueue(downloads);
        _downloadsAdmitted = true;
        onProgress?.call(downloads.length + _admittedUploads.length, total);
        _check();
      }
      for (final song in _uploads) {
        if (_admittedUploads.contains(song.id)) continue;
        _check();
        await _session.enqueueUploadSong(
          songId: song.id,
          reviewedSourcePath: song.path,
          expectedPairing: _pairing,
          frozenIntent: _frozenUploads[song.id],
          prepared: (intent) {
            _check();
            _frozenUploads[song.id] = intent;
          },
        );
        _admittedUploads.add(song.id);
        onProgress?.call(
          (_downloadsAdmitted ? downloads.length : 0) + _admittedUploads.length,
          total,
        );
        _check();
      }
    } finally {
      _submitting = false;
    }
  }
}
