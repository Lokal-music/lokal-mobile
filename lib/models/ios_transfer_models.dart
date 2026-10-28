import 'dart:convert';

const iosTransferProtocolVersion = 1;
const iosTransferMaximumJobs = 10000;
const iosTransferMaximumBytes = 16 * 1024 * 1024;
const _maximumClock = 4102444800000;
const _maximumInt = 0x7fffffffffffffff;

Never _invalid() =>
    throw const FormatException('Invalid native transfer document.');

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.keys.any((key) => key is! String || !keys.contains(key))) {
    _invalid();
  }
  return Map<String, dynamic>.from(value);
}

String _text(Object? value, {int maximum = 4096, bool empty = true}) {
  if (value is! String ||
      (!empty && value.isEmpty) ||
      utf8.encode(value).length > maximum) {
    _invalid();
  }
  return value;
}

String? _optionalText(Object? value, {int maximum = 4096}) =>
    value == null ? null : _text(value, maximum: maximum);

int _integer(Object? value, {int minimum = 0, int maximum = _maximumInt}) {
  if (value is! int || value < minimum || value > maximum) _invalid();
  return value;
}

int? _optionalInteger(
  Object? value, {
  int minimum = 0,
  int maximum = _maximumInt,
}) =>
    value == null ? null : _integer(value, minimum: minimum, maximum: maximum);

String _uuid(Object? value) {
  final text = _text(value, maximum: 36, empty: false);
  if (!RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
      .hasMatch(text)) {
    _invalid();
  }
  return text;
}

String _stable(Object? value) {
  final text = _text(value, maximum: 512, empty: false);
  if (text.contains('://') ||
      text.contains('?') ||
      text.contains('#') ||
      RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(text)) {
    _invalid();
  }
  return text;
}

String? _hash(Object? value) {
  if (value == null) return null;
  final text = _text(value, maximum: 64);
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(text)) _invalid();
  return text;
}

class IosTransferScope {
  const IosTransferScope({
    required this.desktopId,
    required this.origin,
    this.pairingId,
  });
  final String desktopId, origin;
  final String? pairingId;

  factory IosTransferScope.fromJson(Object? value) {
    final json = _object(value, {'desktopID', 'origin', 'pairingID'});
    final scope = IosTransferScope(
      desktopId: _stable(json['desktopID']),
      origin: _text(json['origin'], empty: false),
      pairingId: json['pairingID'] == null ? null : _uuid(json['pairingID']),
    );
    scope.validate();
    return scope;
  }

  void validate() {
    _stable(desktopId);
    _text(origin, empty: false);
    if (pairingId != null) _uuid(pairingId);
    final uri = Uri.tryParse(origin);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.port < 1 ||
        uri.port > 65535) {
      _invalid();
    }
  }

  Map<String, Object?> toJson() => {
    'desktopID': desktopId,
    'origin': origin,
    if (pairingId != null) 'pairingID': pairingId,
  };
}

class IosTransferPairing {
  const IosTransferPairing({required this.scope, this.desktopUserId});
  final IosTransferScope scope;
  final String? desktopUserId;
  factory IosTransferPairing.fromJson(Object? value) {
    final json = _object(value, {'scope', 'desktopUserID'});
    return IosTransferPairing(
      scope: IosTransferScope.fromJson(json['scope']),
      desktopUserId: json['desktopUserID'] == null
          ? null
          : _stable(json['desktopUserID']),
    );
  }
}

class IosTransferIdentity {
  const IosTransferIdentity({
    required this.scope,
    required this.sourceId,
    this.localSongId,
    this.localServerId,
    this.desktopUserId,
  });
  final IosTransferScope scope;
  final String sourceId;
  final String? localSongId, desktopUserId;
  final int? localServerId;

  factory IosTransferIdentity.fromJson(Object? value) {
    final json = _object(value, {
      'desktopID',
      'origin',
      'pairingID',
      'sourceID',
      'localSongID',
      'localServerID',
      'desktopUserID',
    });
    return IosTransferIdentity(
      scope: IosTransferScope.fromJson({
        'desktopID': json['desktopID'],
        'origin': json['origin'],
        'pairingID': json['pairingID'],
      }),
      sourceId: _stable(json['sourceID']),
      localSongId: json['localSongID'] == null
          ? null
          : _stable(json['localSongID']),
      localServerId: _optionalInteger(json['localServerID'], minimum: 1),
      desktopUserId: json['desktopUserID'] == null
          ? null
          : _stable(json['desktopUserID']),
    );
  }

  void validate({bool submission = false}) {
    scope.validate();
    _stable(sourceId);
    if (localSongId != null) _stable(localSongId);
    if (desktopUserId != null) _stable(desktopUserId);
    _optionalInteger(localServerId, minimum: 1);
    if (submission && (scope.pairingId == null || localServerId == null)) {
      _invalid();
    }
  }

  Map<String, Object?> toJson() => {
    ...scope.toJson(),
    'sourceID': sourceId,
    if (localSongId != null) 'localSongID': localSongId,
    if (localServerId != null) 'localServerID': localServerId,
    if (desktopUserId != null) 'desktopUserID': desktopUserId,
  };
}

class IosTransferMetadata {
  const IosTransferMetadata({
    required this.title,
    required this.artist,
    required this.fileExtension,
    this.album,
    this.albumArtist,
    this.genre,
    this.durationMs,
    this.sampleRate,
    this.bitDepth,
    this.bitrate,
    this.trackNumber,
    this.discNumber,
    this.year,
  });
  final String title, artist, fileExtension;
  final String? album, albumArtist, genre;
  final int? durationMs,
      sampleRate,
      bitDepth,
      bitrate,
      trackNumber,
      discNumber,
      year;

  factory IosTransferMetadata.fromJson(Object? value) {
    final json = _object(value, {
      'title',
      'artist',
      'fileExtension',
      'album',
      'albumArtist',
      'genre',
      'durationMs',
      'sampleRate',
      'bitDepth',
      'bitrate',
      'trackNumber',
      'discNumber',
      'year',
    });
    final metadata = IosTransferMetadata(
      title: _text(json['title']),
      artist: _text(json['artist']),
      fileExtension: _text(json['fileExtension'], maximum: 8, empty: false),
      album: _optionalText(json['album']),
      albumArtist: _optionalText(json['albumArtist']),
      genre: _optionalText(json['genre']),
      durationMs: _optionalInteger(json['durationMs'], maximum: 31622400000),
      sampleRate: _optionalInteger(json['sampleRate'], maximum: 1000000000),
      bitDepth: _optionalInteger(json['bitDepth'], maximum: 1024),
      bitrate: _optionalInteger(json['bitrate'], maximum: 1000000000000),
      trackNumber: _optionalInteger(json['trackNumber'], maximum: 1000000),
      discNumber: _optionalInteger(json['discNumber'], maximum: 1000000),
      year: _optionalInteger(json['year'], maximum: 9999),
    );
    if (!RegExp(r'^[a-z0-9]{1,8}$').hasMatch(metadata.fileExtension)) {
      _invalid();
    }
    return metadata;
  }

  void validate() => IosTransferMetadata.fromJson(toJson());
  Map<String, Object?> toJson() => {
    'title': title,
    'artist': artist,
    'fileExtension': fileExtension,
    if (album != null) 'album': album,
    if (albumArtist != null) 'albumArtist': albumArtist,
    if (genre != null) 'genre': genre,
    if (durationMs != null) 'durationMs': durationMs,
    if (sampleRate != null) 'sampleRate': sampleRate,
    if (bitDepth != null) 'bitDepth': bitDepth,
    if (bitrate != null) 'bitrate': bitrate,
    if (trackNumber != null) 'trackNumber': trackNumber,
    if (discNumber != null) 'discNumber': discNumber,
    if (year != null) 'year': year,
  };
}

class IosTransferIntent {
  const IosTransferIntent({
    required this.id,
    required this.identity,
    required this.metadata,
    required this.createdMs,
    this.expectedBytes,
    this.expectedSha256,
  });
  final String id;
  final IosTransferIdentity identity;
  final IosTransferMetadata metadata;
  final int createdMs;
  final int? expectedBytes;
  final String? expectedSha256;

  factory IosTransferIntent.fromJson(Object? value) => _intent(
    _object(value, {
      'id',
      'identity',
      'metadata',
      'createdMs',
      'expectedBytes',
      'expectedSHA256',
    }),
  );

  void validate({bool submission = false}) {
    _uuid(id);
    identity.validate(submission: submission);
    metadata.validate();
    _integer(createdMs, maximum: _maximumClock);
    _optionalInteger(expectedBytes, minimum: 1);
    _hash(expectedSha256);
    if (utf8.encode(jsonEncode(toJson())).length > 32 * 1024) _invalid();
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'identity': identity.toJson(),
    'metadata': metadata.toJson(),
    'createdMs': createdMs,
    if (expectedBytes != null) 'expectedBytes': expectedBytes,
    if (expectedSha256 != null) 'expectedSHA256': expectedSha256,
  };
}

IosTransferIntent _intent(Map<String, dynamic> json) {
  final intent = IosTransferIntent(
    id: _uuid(json['id']),
    identity: IosTransferIdentity.fromJson(json['identity']),
    metadata: IosTransferMetadata.fromJson(json['metadata']),
    createdMs: _integer(json['createdMs'], maximum: _maximumClock),
    expectedBytes: _optionalInteger(json['expectedBytes'], minimum: 1),
    expectedSha256: _hash(json['expectedSHA256']),
  );
  intent.validate();
  return intent;
}

enum IosTransferPhase {
  queued,
  waiting,
  transferring,
  received,
  downloaded,
  staged,
  validating,
  importing,
  complete,
  interrupted,
  cancelled,
  failed;

  bool get canRetry => this == interrupted || this == failed;
  bool get canCancel =>
      this != complete && this != cancelled && this != importing;
}

class IosTransferJob {
  const IosTransferJob._({
    required this.intent,
    required this.revision,
    required this.phase,
    required this.updatedMs,
    required this.direction,
    this.receivedBytes,
    this.receivedSha256,
    this.resultOriginalId,
    this.lastFailure,
  });
  final IosTransferIntent intent;
  final int revision, updatedMs;
  final IosTransferPhase phase;
  final String direction;
  final int? receivedBytes;
  final String? receivedSha256, resultOriginalId, lastFailure;
  String get id => intent.id;

  factory IosTransferJob.fromJson(Object? value) {
    final json = _object(value, {
      'id',
      'revision',
      'direction',
      'identity',
      'metadata',
      'createdMs',
      'updatedMs',
      'phase',
      'taskID',
      'expectedBytes',
      'expectedSHA256',
      'receivedBytes',
      'receivedSHA256',
      'resultOriginalID',
      'responseBytes',
      'responseSHA256',
      'lastFailure',
    });
    final intent = _intent(json);
    final phase = IosTransferPhase.values
        .where((value) => value.name == json['phase'])
        .firstOrNull;
    if (phase == null || !{'download', 'upload'}.contains(json['direction'])) {
      _invalid();
    }
    final revision = _integer(
      json['revision'],
      minimum: 1,
      maximum: _maximumInt - 1,
    );
    final updated = _integer(
      json['updatedMs'],
      minimum: intent.createdMs,
      maximum: _maximumClock,
    );
    final task = _optionalInteger(json['taskID'], minimum: 1);
    final bound =
        phase == IosTransferPhase.transferring ||
        phase == IosTransferPhase.received;
    if (bound != (task != null)) _invalid();
    final bytes = _optionalInteger(json['receivedBytes'], minimum: 1),
        hash = _hash(json['receivedSHA256']);
    if ((bytes == null) != (hash == null)) _invalid();
    if ({
          IosTransferPhase.queued,
          IosTransferPhase.waiting,
          IosTransferPhase.transferring,
          IosTransferPhase.received,
          IosTransferPhase.downloaded,
        }.contains(phase) &&
        bytes != null) {
      _invalid();
    }
    final responseBytes = _optionalInteger(json['responseBytes'], minimum: 1);
    final responseHash = _hash(json['responseSHA256']);
    if (bytes != null &&
        (responseBytes != null && responseBytes != bytes ||
            responseHash != null && responseHash != hash)) {
      _invalid();
    }
    if (json['direction'] == 'download' &&
        {
          IosTransferPhase.staged,
          IosTransferPhase.validating,
          IosTransferPhase.importing,
          IosTransferPhase.complete,
        }.contains(phase) &&
        bytes == null) {
      _invalid();
    }
    if (bytes != null &&
        (intent.expectedBytes != null && intent.expectedBytes != bytes ||
            intent.expectedSha256 != null && intent.expectedSha256 != hash)) {
      _invalid();
    }
    final failure = _optionalText(json['lastFailure'], maximum: 64);
    if (failure != null &&
        !{
          'network',
          'unauthorized',
          'invalidResponse',
          'checksum',
          'storage',
          'pairingChanged',
        }.contains(failure)) {
      _invalid();
    }
    if (failure != null &&
        !{
          IosTransferPhase.waiting,
          IosTransferPhase.failed,
          IosTransferPhase.interrupted,
          IosTransferPhase.cancelled,
        }.contains(phase)) {
      _invalid();
    }
    final originalId = json['resultOriginalID'] == null
        ? null
        : _stable(json['resultOriginalID']);
    if (originalId != null &&
        (json['direction'] != 'upload' || phase != IosTransferPhase.complete)) {
      _invalid();
    }
    if (json['direction'] == 'upload' &&
        (bytes != null ||
            intent.expectedBytes == null ||
            intent.expectedSha256 == null ||
            (phase == IosTransferPhase.complete && originalId == null) ||
            {
              IosTransferPhase.received,
              IosTransferPhase.downloaded,
              IosTransferPhase.staged,
              IosTransferPhase.validating,
              IosTransferPhase.importing,
            }.contains(phase))) {
      _invalid();
    }
    return IosTransferJob._(
      intent: intent,
      revision: revision,
      phase: phase,
      updatedMs: updated,
      direction: json['direction'] as String,
      receivedBytes: bytes,
      receivedSha256: hash,
      resultOriginalId: originalId,
      lastFailure: failure,
    );
  }
}

class IosTransferProgress {
  const IosTransferProgress._(
    this.id,
    this.revision,
    this.bytes,
    this.expectedBytes,
    this.waitingForConnectivity,
  );
  final String id;
  final int revision, bytes;
  final int? expectedBytes;
  final bool waitingForConnectivity;
  factory IosTransferProgress.fromJson(Object? value) {
    final json = _object(value, {
      'id',
      'revision',
      'bytes',
      'expectedBytes',
      'waitingForConnectivity',
    });
    if (json['waitingForConnectivity'] is! bool) _invalid();
    return IosTransferProgress._(
      _uuid(json['id']),
      _integer(json['revision'], minimum: 1),
      _integer(json['bytes']),
      _optionalInteger(json['expectedBytes'], minimum: 1),
      json['waitingForConnectivity'] as bool,
    );
  }
}

class IosTransferPause {
  const IosTransferPause._(this.scope, this.reason);
  final IosTransferScope scope;
  final String reason;
  factory IosTransferPause.fromJson(Object? value) {
    final json = _object(value, {'scope', 'reason'});
    final reason = _text(json['reason'], maximum: 64, empty: false);
    if (!{
      'network',
      'unauthorized',
      'invalidResponse',
      'checksum',
      'storage',
      'pairingChanged',
    }.contains(reason)) {
      _invalid();
    }
    return IosTransferPause._(IosTransferScope.fromJson(json['scope']), reason);
  }
}

class IosTransferSummary {
  const IosTransferSummary._({
    required this.generation,
    required this.total,
    required this.counts,
    required this.progress,
    required this.pauses,
    required this.persistenceFailed,
  });
  final int generation, total;
  final Map<IosTransferPhase, int> counts;
  final List<IosTransferProgress> progress;
  final List<IosTransferPause> pauses;
  final bool persistenceFailed;
  factory IosTransferSummary.fromJson(Object? value) {
    final json = _object(value, {
      'generation',
      'total',
      'counts',
      'progress',
      'pauses',
      'persistenceFailed',
    });
    final total = _integer(json['total'], maximum: iosTransferMaximumJobs);
    final rawCounts = _object(
      json['counts'],
      IosTransferPhase.values.map((phase) => phase.name).toSet(),
    );
    final counts = {
      for (final entry in rawCounts.entries)
        IosTransferPhase.values.byName(entry.key): _integer(
          entry.value,
          maximum: iosTransferMaximumJobs,
        ),
    };
    if (counts.values.fold(0, (sum, count) => sum + count) != total ||
        json['persistenceFailed'] is! bool ||
        json['progress'] is! List ||
        (json['progress'] as List).length > 2 ||
        json['pauses'] is! List ||
        (json['pauses'] as List).length > 64) {
      _invalid();
    }
    return IosTransferSummary._(
      generation: _integer(json['generation']),
      total: total,
      counts: Map.unmodifiable(counts),
      progress: List.unmodifiable(
        (json['progress'] as List).map(IosTransferProgress.fromJson),
      ),
      pauses: List.unmodifiable(
        (json['pauses'] as List).map(IosTransferPause.fromJson),
      ),
      persistenceFailed: json['persistenceFailed'] as bool,
    );
  }
}

class IosTransferCapability {
  const IosTransferCapability({
    required this.available,
    this.download = false,
    this.libraryImport = false,
    this.upload = false,
  });
  final bool available, download, libraryImport, upload;
  bool get canCopyToLibrary => available && download && libraryImport;
  factory IosTransferCapability.fromJson(Object? value) {
    final json = _object(value, {
      'available',
      'protocolVersion',
      'download',
      'libraryImport',
      'upload',
      'maximumIntents',
      'maximumIntentBytes',
    });
    if (json['protocolVersion'] != iosTransferProtocolVersion ||
        [
          'available',
          'download',
          'libraryImport',
          'upload',
        ].any((key) => json[key] is! bool)) {
      _invalid();
    }
    _integer(
      json['maximumIntents'],
      minimum: 1,
      maximum: iosTransferMaximumJobs,
    );
    _integer(
      json['maximumIntentBytes'],
      minimum: 1,
      maximum: iosTransferMaximumBytes,
    );
    return IosTransferCapability(
      available: json['available'] as bool,
      download: json['download'] as bool,
      libraryImport: json['libraryImport'] as bool,
      upload: json['upload'] as bool,
    );
  }
}
