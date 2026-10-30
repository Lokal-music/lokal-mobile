import 'dart:async';
import 'dart:convert';

import 'package:isar_community/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/database.dart';
import '../../data/repositories/song_repository.dart';
import '../../models/song.dart';
import '../../models/playlist.dart';
import 'link_protocol.dart';

/// Local append-only logs. Pairing never clears or replaces the phone's library.
class LinkJournal {
  LinkJournal._();
  static final instance = LinkJournal._();
  final changes = StreamController<void>.broadcast();
  /// Play-event updates only; used by the bounded stats sync scheduler.
  final historyChanges = StreamController<void>.broadcast();
  bool applyingRemote = false;
  final Map<String, String> _trackKeys = {};
  bool _keysLoaded = false;
  Future<void> _loadKeys() async {
    if (_keysLoaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('lokal.link.track_keys');
    if (raw != null)
      _trackKeys.addAll(Map<String, String>.from(jsonDecode(raw) as Map));
    _keysLoaded = true;
  }

  Future<String> trackKeyFor(Song song) async {
    await _loadKeys();
    return _trackKeys[song.id] ??
        linkTrackKey(song.artist, song.title, song.duration);
  }

  Future<void> registerTrackAlias(String songId, String key) async {
    await _loadKeys();
    if (_trackKeys.containsKey(songId)) return;
    _trackKeys[songId] = key;
    await (await SharedPreferences.getInstance()).setString(
      'lokal.link.track_keys',
      jsonEncode(_trackKeys),
    );
  }

  Future<void> _tail = Future<void>.value();
  Future<T> _serial<T>(Future<T> Function() work) {
    final next = _tail.then((_) => work());
    _tail = next.then<void>((_) {}, onError: (Object error) {});
    return next;
  }

  Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('lokal.link.device_id');
    if (id == null) {
      id = linkUuid();
      await prefs.setString('lokal.link.device_id', id);
    }
    return id;
  }

  Map<String, dynamic> songWire(Song song) => {
    'id': song.id,
    'title': song.title,
    'artist': song.artist,
    'album': song.album ?? '',
    'duration': song.duration.inMilliseconds / 1000,
    'track_key':
        _trackKeys[song.id] ??
        linkTrackKey(song.artist, song.title, song.duration),
    if (song.isPending && song.id.startsWith('pending:playlist:'))
      'online_ref': true,
    if (song.isPending &&
        song.id.startsWith('pending:playlist:') &&
        RegExp(r'^yt:[A-Za-z0-9_-]{11}$').hasMatch(song.remoteId ?? ''))
      'source_ref': song.remoteId,
    if (song.isPending &&
        song.id.startsWith('pending:playlist:') &&
        (song.albumArt ?? '').startsWith('https://'))
      'artwork_url': song.albumArt,
  };
  Future<Song?> match(
    Map<String, dynamic> track, {
    List<Song>? candidates,
  }) async {
    await _loadKeys();
    final songs = candidates ?? await SongRepository().getAllSongs();
    final alias = songs.where(
      (song) => _trackKeys[song.id] == track['track_key'],
    );
    final localAlias = alias.where((song) => !song.isNetworkSource);
    if (localAlias.isNotEmpty) return localAlias.first;
    final parts = (track['track_key']?.toString() ?? '').split('|');
    final duration = parts.isNotEmpty
        ? double.tryParse(parts.removeLast()) ?? 0
        : 0;
    final title = parts.isNotEmpty ? parts.removeLast() : '';
    final artist = parts.join('|');
    String normalize(String value) =>
        value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final remoteAlbum = track['album']?.toString().trim() ?? '';
    for (final song in [
      ...songs.where((s) => !s.isNetworkSource),
      ...songs.where((s) => s.isNetworkSource),
    ]) {
      final album = song.album?.trim() ?? '';
      if ((album.isEmpty ||
              remoteAlbum.isEmpty ||
              normalize(album) == normalize(remoteAlbum)) &&
          normalize(song.title) == title &&
          normalize(song.artist) == artist &&
          (song.duration.inMilliseconds / 1000 - duration).abs() <= 2)
        return song;
    }
    return alias.firstOrNull;
  }

  Future<void> recordPlay({
    required String eventId,
    required String songId,
    required int playedAt,
    required int msPlayed,
  }) async {
    if (!Database.isInitialized || msPlayed < 30000) return;
    await _serial(() async {
      // All persisted phone songs have numeric Isar IDs. Non-numeric online
      // placeholders cannot be found by scanning the entire local catalog.
      final numericId = int.tryParse(songId);
      if (numericId == null) return;
      final entity = await Database.instance.songEntitys.get(numericId);
      if (entity == null) return;
      final song = SongRepository().songFromEntity(entity);
      final event = PlayEventEntity()
        ..eventId = eventId
        ..deviceId = await deviceId()
        ..trackKey = await trackKeyFor(song)
        ..playedAt = playedAt
        ..msPlayed = msPlayed
        ..source = 'phone'
        ..trackJson = jsonEncode(songWire(song));
      final isar = Database.instance;
      await isar.writeTxn(() async {
        if (await isar.playEventEntitys
                .filter()
                .eventIdEqualTo(eventId)
                .findFirst() ==
            null)
          await isar.playEventEntitys.put(event);
      });
      changes.add(null);
      historyChanges.add(null);
    });
  }

  Future<void> append(
    String entity,
    String entityId,
    String op,
    Map<String, dynamic> fields,
  ) async {
    if (!Database.isInitialized || applyingRemote) return;
    await _serial(() async {
      final prefs = await SharedPreferences.getInstance();
      final clock = nextLinkClock(prefs.getString('lokal.link.hlc') ?? '');
      final item = LibraryOpEntity()
        ..opId = linkUuid()
        ..deviceId = await deviceId()
        ..hlc = clock
        ..entity = entity
        ..entityId = entityId
        ..op = op
        ..fieldsJson = jsonEncode(fields);
      await Database.instance.writeTxn(
        () => Database.instance.libraryOpEntitys.put(item),
      );
      await prefs.setString('lokal.link.hlc', clock);
      changes.add(null);
    });
  }

  Future<void> captureFavorites(Set<String> ids) async {
    if (!Database.isInitialized || applyingRemote) return;
    final prefs = await SharedPreferences.getInstance();
    final previous =
        (prefs.getStringList('lokal.link.favorites_snapshot') ?? []).toSet();
    final songs = {
      for (final song in await SongRepository().getAllSongs()) song.id: song,
    };
    for (final id in {...ids, ...previous})
      if (ids.contains(id) != previous.contains(id) && songs[id] != null) {
        final song = songs[id]!;
        await append(
          'like',
          await trackKeyFor(song),
          ids.contains(id) ? 'like' : 'unlike',
          songWire(song),
        );
      }
    await prefs.setStringList('lokal.link.favorites_snapshot', ids.toList());
  }

  Future<String> playlistUuid(String localId) async {
    final prefs = await SharedPreferences.getInstance(),
        key = 'lokal.link.playlist_uuid.$localId';
    var id = prefs.getString(key);
    if (id == null) {
      id = linkUuid();
      await prefs.setString(key, id);
    }
    await prefs.setString('lokal.link.playlist_local.$id', localId);
    return id;
  }

  Future<void> capturePlaylists(List<Playlist> playlists) async {
    if (!Database.isInitialized || applyingRemote) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('lokal.link.playlists_snapshot');
    final previous = raw == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final current = <String, dynamic>{};
    final songs = {
      for (final song in await SongRepository().getAllSongs()) song.id: song,
    };
    for (final playlist in playlists.where((p) => !p.isNetworkSource)) {
      final id = await playlistUuid(playlist.id);
      final prior = previous[id] is Map
          ? Map<String, dynamic>.from(previous[id] as Map)
          : null;
      if (prior == null)
        await append('playlist', id, 'playlist.create', {
          'name': playlist.name,
        });
      else if (prior['name'] != playlist.name)
        await append('playlist', id, 'playlist.rename', {
          'name': playlist.name,
        });
      final oldMembers = List<String>.from(prior?['members'] as List? ?? []);
      final members = <String>[];
      for (var position = 0; position < playlist.songIds.length; position++) {
        // Online Flow entries have snapshots even when never scanned locally.
        final songId = playlist.songIds[position];
        final song = songs[songId] ??
            playlist.songSnapshots[songId]?.toSong(songId);
        if (song == null) continue;
        final key = await trackKeyFor(song);
        members.add(key);
        final oldPosition = oldMembers.indexOf(key);
        if (oldPosition < 0 || oldPosition != position)
          await append(
            'playlist',
            id,
            oldPosition < 0 ? 'playlist.add' : 'playlist.move',
            {
              'track_key': key,
              'position': position.toDouble(),
              ...songWire(song),
            },
          );
      }
      for (final key in oldMembers.where((key) => !members.contains(key)))
        await append('playlist', id, 'playlist.remove', {'track_key': key});
      current[id] = {'name': playlist.name, 'members': members};
    }
    for (final id in previous.keys.where((id) => !current.containsKey(id)))
      await append('playlist', id, 'playlist.delete', {});
    await prefs.setString('lokal.link.playlists_snapshot', jsonEncode(current));
  }

  Future<Map<String, dynamic>> historyAfter(int cursor, {int limit = 250}) async {
    if (limit < 1 || limit > 250) {
      throw RangeError.range(limit, 1, 250, 'limit');
    }
    final rows = await Database.instance.playEventEntitys
        .where()
        .idGreaterThan(cursor)
        .limit(limit)
        .findAll();
    return {
      'items': [
        for (final row in rows)
          {
            'event_id': row.eventId,
            'device_id': row.deviceId,
            'track_key': row.trackKey,
            'file_hash': row.fileHash,
            'played_at': row.playedAt,
            'ms_played': row.msPlayed,
            'source': row.source,
            'track': jsonDecode(row.trackJson),
          },
      ],
      'cursor': rows.isEmpty ? cursor : rows.last.id,
      'hasMore': rows.length == limit,
    };
  }

  Future<Map<String, dynamic>> libraryAfter(int cursor) async {
    final rows = await Database.instance.libraryOpEntitys
        .where()
        .idGreaterThan(cursor)
        .limit(250)
        .findAll();
    return {
      'items': [for (final row in rows) wireOp(row)],
      'cursor': rows.isEmpty ? cursor : rows.last.id,
      'hasMore': rows.length == 250,
    };
  }

  Map<String, dynamic> wireOp(LibraryOpEntity row) => {
    'op_id': row.opId,
    'device_id': row.deviceId,
    'hlc': row.hlc,
    'entity': row.entity,
    'entity_id': row.entityId,
    'op': row.op,
    'fields': jsonDecode(row.fieldsJson),
  };
  Future<List<Map<String, dynamic>>> mergeLibrary(
    List<dynamic> rawItems,
  ) async {
    if (rawItems.length > 250)
      throw const FormatException('Library batch is too large.');
    return _serial(() async {
      final prefs = await SharedPreferences.getInstance();
      var clock = prefs.getString('lokal.link.hlc') ?? '';
      final accepted = <Map<String, dynamic>>[];
      await Database.instance.writeTxn(() async {
        for (final raw in rawItems) {
          final item = Map<String, dynamic>.from(raw as Map);
          if (item['op_id'] is! String ||
              item['device_id'] is! String ||
              item['entity_id'] is! String ||
              !RegExp(r'^\d{16}:\d{8}$')
                  .hasMatch(item['hlc']?.toString() ?? '') ||
              !{'like', 'playlist', 'track'}.contains(item['entity']))
            throw const FormatException('Invalid library operation.');
          final fields =
              item['fields'] ??
              jsonDecode(item['fields_json'] as String? ?? '{}');
          if (fields is! Map)
            throw const FormatException('Invalid library fields.');
          clock = nextLinkClock(clock, incoming: item['hlc'] as String);
          final existing = await Database.instance.libraryOpEntitys
              .filter()
              .opIdEqualTo(item['op_id'] as String)
              .findFirst();
          if (existing != null) {
            accepted.add(wireOp(existing));
            continue;
          }
          final row = LibraryOpEntity()
            ..opId = item['op_id'] as String
            ..deviceId = item['device_id'] as String
            ..hlc = item['hlc'] as String
            ..entity = item['entity'] as String
            ..entityId = item['entity_id'] as String
            ..op = item['op'] as String
            ..fieldsJson = jsonEncode(fields);
          await Database.instance.libraryOpEntitys.put(row);
          accepted.add({...item, 'fields': Map<String, dynamic>.from(fields)});
        }
      });
      await prefs.setString('lokal.link.hlc', clock);
      return accepted;
    });
  }

  Future<bool> wins(Map<String, dynamic> item, String field) async {
    String stamp(Map<String, dynamic> value) =>
        '${value['hlc']}:${value['device_id']}:${value['op_id']}';
    final rows = await Database.instance.libraryOpEntitys
        .filter()
        .entityIdEqualTo(item['entity_id'] as String)
        .findAll();
    bool touches(LibraryOpEntity row) {
      if (row.entity != item['entity']) return false;
      final fields = jsonDecode(row.fieldsJson) as Map;
      if (field == 'liked') return row.op == 'like' || row.op == 'unlike';
      if (field == 'name')
        return row.op == 'playlist.create' || row.op == 'playlist.rename';
      if (field == 'deleted')
        return row.op == 'playlist.delete' || row.op == 'playlist.create';
      if (field.startsWith('member:'))
        return [
              'playlist.add',
              'playlist.remove',
              'playlist.move',
            ].contains(row.op) &&
            fields['track_key'] == field.substring(7);
      return row.op == 'track.edit' && fields.containsKey(field);
    }

    for (final row in rows)
      if (touches(row) && stamp(wireOp(row)).compareTo(stamp(item)) > 0)
        return false;
    return true;
  }

  Future<List<Map<String, dynamic>>> mergeHistory(List<dynamic> rawItems) =>
      _serial(() async {
        if (rawItems.length > 250)
          throw const FormatException('History batch is too large.');
        final accepted = <Map<String, dynamic>>[];
        await Database.instance.writeTxn(() async {
          for (final raw in rawItems) {
            final item = Map<String, dynamic>.from(raw as Map);
            if (item['event_id'] is! String ||
                item['track_key'] is! String ||
                item['played_at'] is! int ||
                item['ms_played'] is! int ||
                (item['ms_played'] as int) < 0 ||
                (item['ms_played'] as int) > 86400000)
              throw const FormatException('Invalid history event.');
            final existing = await Database.instance.playEventEntitys
                .filter()
                .eventIdEqualTo(item['event_id'] as String)
                .findFirst();
            if (existing != null) {
              accepted.add({
                'event_id': existing.eventId,
                'device_id': existing.deviceId,
                'track_key': existing.trackKey,
                'file_hash': existing.fileHash,
                'played_at': existing.playedAt,
                'ms_played': existing.msPlayed,
                'source': existing.source,
                'track': jsonDecode(existing.trackJson),
              });
              continue;
            }
            final row = PlayEventEntity()
              ..eventId = item['event_id'] as String
              ..deviceId = item['device_id'] as String
              ..trackKey = item['track_key'] as String
              ..fileHash = (item['file_hash'] as String?)
              ..playedAt = item['played_at'] as int
              ..msPlayed = item['ms_played'] as int
              ..source = (item['source'] as String? ?? 'desktop')
              ..trackJson = jsonEncode(
                item['track'] ??
                    jsonDecode(item['track_json'] as String? ?? '{}'),
              );
            await Database.instance.playEventEntitys.put(row);
            accepted.add(item);
          }
        });
        if (accepted.isNotEmpty) changes.add(null);
        return accepted;
      });
}
