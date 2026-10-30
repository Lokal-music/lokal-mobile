import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/utils/app_log.dart';
import '../player/widgets/player_artwork_quality.dart';
import '../../services/tidal_atmos_metadata.dart';
import '../../services/atmos_playback_support.dart';
import '../../services/atmos_diagnostics.dart';

import 'morneye_host.dart';
import 'morneye_network.dart';
import 'morneye_runtime.dart';
import 'morneye_session.dart';
import 'morneye_storage.dart';
import 'morneye_ffmpeg.dart';
import 'morneye_playback_quality.dart';

/// Morneye add-on packages (.sflx), as desktop's
/// electron/morneye/packages.js: repositories to install from, installed
/// packages with their settings and logins, and searching and downloading
/// through them. The same packages run on desktop and phone.

const morneyeRegistry =
    'https://raw.githubusercontent.com/mornyeapp/Mornye-Extension/refs/heads/main/registry.json';
const morneyeAmazonNewRegistry =
    'https://raw.githubusercontent.com/CHEYCKIT/Mornye-Extension/refs/heads/feature/amazon-new-release-20261029/amazon-new-registry.json';
const morneyeCompatVersion = '5.1.0';
/// Mornye's documented .spotiflac-ext format and its legacy/newer archives.
bool morneyeIsPackageFileName(String filename) => RegExp(
  r'\.(?:sflx|morneye-ext|spotiflac-ext)$',
  caseSensitive: false,
).hasMatch(filename);

const morneyeFeatures = {
  'signedSession': 3,
  'sessionRefresh': 1,
  'sessionGrant': 1,
  'globalAction': 1,
  'webviewAuth': 1,
  'downloadSegments': 1,
  'patternedFileTransform': 1,
  'preparedContext': 1,
  'accountForms': 1,
  'accountDownloadMode': 1,
  'directMedia': 1,
};

String _sha256(List<int> value) => sha256.convert(value).toString();

/// Search metadata can replace an extra by-ID fetch when the exact
/// selected provider and track identity are known. The addon still performs
/// checkAvailability before downloading: this is never a playback ticket.
Map<String, Object?>? morneyeSelectedTrackHint({
  required String id,
  required String title,
  required String artist,
  required int? durationMs,
}) {
  if (id.trim().isEmpty || title.trim().isEmpty ||
      artist.trim().isEmpty) return null;
  return {
    'id': id,
    'name': title,
    'artists': artist,
    if (durationMs != null && durationMs > 0) 'duration_ms': durationMs,
  };
}

/// A negative first availability result can be retried once after
/// enrichment, for any provider. Tidal and other native catalogue matches
/// are not exempt. Authorization is still checked again on the retry.
bool morneyeShouldRetryEnrichment({
  required Object? available,
  required bool hasEnrichment,
}) => hasEnrichment && (available is! Map || available['available'] != true);

/// The installed package's stable key (also its storage namespace).
String morneyeKeyOf(String name) =>
    sha1.convert(utf8.encode('spotiflac:$name')).toString().substring(0, 10);

int morneyeCompareVersions(Object? a, Object? b) {
  List<int> parts(Object? v) =>
      '${v ?? '0'}'.split('.').map((x) => int.tryParse(x) ?? 0).toList();
  final left = parts(a), right = parts(b);
  for (
    var i = 0;
    i < (left.length > right.length ? left.length : right.length);
    i++
  ) {
    final d =
        (i < left.length ? left[i] : 0) - (i < right.length ? right[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

class MorneyePackageError implements Exception {
  const MorneyePackageError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The downloaded bytes did not match the requested encoded source.
/// Distinct from an addon's tier, authorization or transport failure.
class MorneyeSourceVerificationError extends MorneyePackageError {
  const MorneyeSourceVerificationError(String codec)
      : super('The requested $codec source could not be verified. '
            'No stereo substitute was used.');
}

Map<String, Object?> morneyeValidateManifest(Object? json) {
  if (json is! Map ||
      !RegExp(r'^[a-z0-9][a-z0-9_-]{0,99}$')
          .hasMatch('${json['name'] ?? ''}') ||
      json['displayName'] is! String ||
      !RegExp(r'^\d+\.\d+\.\d+(?:[-+][\w.-]+)?$')
          .hasMatch('${json['version'] ?? ''}')) {
    throw const MorneyePackageError('Invalid Morneye package manifest');
  }
  final manifest = json.cast<String, Object?>();
  final type = manifest['type'];
  final urlHandler = manifest['urlHandler'];
  final linkReader = urlHandler is Map && urlHandler['enabled'] == true;
  if (type is! List ||
      !(type.contains('download_provider') ||
          (type.contains('metadata_provider') && linkReader))) {
    throw const MorneyePackageError(
      'Only download-capable or playlist-link Morneye addons can be installed',
    );
  }
  if (morneyeCompareVersions(manifest['minAppVersion'], morneyeCompatVersion) >
      0) {
    throw MorneyePackageError(
      'This addon requires Morneye compatibility ${manifest['minAppVersion']}',
    );
  }
  for (final required
      in manifest['requiredRuntimeFeatures'] is List
          ? manifest['requiredRuntimeFeatures'] as List
          : const []) {
    final match = RegExp(r'^([A-Za-z]+)@(\d+)$').firstMatch('$required');
    final have = match == null ? null : morneyeFeatures[match.group(1)];
    if (have == null || have < int.parse(match!.group(2)!)) {
      throw MorneyePackageError('Unsupported runtime feature: $required');
    }
  }
  final permissions = manifest['permissions'];
  final network = permissions is Map ? permissions['network'] : null;
  if (network is! List ||
      network.length > 100 ||
      network.any(
        (d) =>
            d is! String ||
            !RegExp(
              r'^(?:\*\.)?[a-z0-9.-]+$',
              caseSensitive: false,
            ).hasMatch(d),
      )) {
    throw const MorneyePackageError('Invalid addon network permissions');
  }
  final signed = manifest['signedSession'];
  if (signed is Map) {
    morneyeValidateUrl(
      '${signed['baseUrl']}',
      MorneyePermissions.fromJson(permissions),
    );
    if ((permissions as Map)['storage'] != true) {
      throw const MorneyePackageError(
        'Signed sessions require storage permission',
      );
    }
  }
  if ((manifest['settings'] is List &&
          (manifest['settings'] as List).length > 100) ||
      (manifest['qualityOptions'] is List &&
          (manifest['qualityOptions'] as List).length > 30)) {
    throw const MorneyePackageError('Addon manifest is too large');
  }
  return manifest;
}

class MorneyeArchive {
  const MorneyeArchive(this.files, this.manifest, this.code);
  final Map<String, Uint8List> files;
  final Map<String, Object?> manifest;
  final String code;
}

/// Opens and checks a package's zip.
MorneyeArchive morneyeReadArchive(Uint8List bytes) {
  if (bytes.length > 32 * 1024 * 1024) {
    throw const MorneyePackageError('Addon package exceeds 32 MB');
  }
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw const MorneyePackageError('This isn’t a Morneye package');
  }
  if (zip.files.length > 100) {
    throw const MorneyePackageError('Addon package contains too many files');
  }
  final files = <String, Uint8List>{};
  var total = 0;
  for (final entry in zip.files) {
    final name = entry.name;
    if (files.containsKey(name) ||
        name.isEmpty ||
        name.contains('\\') ||
        name.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(name) ||
        name.split('/').any((part) => part == '..' || part == '.') ||
        entry.isSymbolicLink) {
      throw const MorneyePackageError(
        'Addon package contains an unsafe archive path',
      );
    }
    total += entry.size;
    if (total > 64 * 1024 * 1024) {
      throw const MorneyePackageError('Unpacked addon package exceeds 64 MB');
    }
    if (entry.isFile) files[name] = entry.content;
  }
  final manifestBytes = files['manifest.json'];
  final codeBytes = files['index.js'];
  if (manifestBytes == null || codeBytes == null) {
    throw const MorneyePackageError(
      'A Morneye package needs manifest.json and index.js at its root',
    );
  }
  final manifest = morneyeValidateManifest(
    jsonDecode(utf8.decode(manifestBytes)),
  );
  if (codeBytes.length > 8 * 1024 * 1024) {
    throw const MorneyePackageError('Addon script exceeds 8 MB');
  }
  return MorneyeArchive(files, manifest, utf8.decode(codeBytes));
}

bool _placeholderAlbum(Object? value) {
  final album = value is String ? value.trim() : '';
  return album.isEmpty ||
      RegExp(
        r'^(?:unknown(?:\s+album)?|untitled(?:\s+album)?|n/?a|none|null|undefined)$',
        caseSensitive: false,
      ).hasMatch(album);
}

String? morneyeAlbumName(Map track) {
  final album = track['album'];
  final candidates = [
    track['album_name'],
    track['albumName'],
    track['album_title'],
    track['albumTitle'],
    if (album is String) album,
    if (album is Map)
      album['name'] ??
          album['title'] ??
          album['album_name'] ??
          album['albumName'],
  ];
  for (final value in candidates) {
    if (value is String && !_placeholderAlbum(value)) return value.trim();
  }
  return null;
}

/// Request the original resolution of the *same* Amazon image, rather
/// than upscaling the small 120/300px variant. Unsized Amazon media images
/// retain their content hash. Other providers are not rewritten.
bool providerIdentityIsAmazon(String addonName, Map track) {
  if (!addonName.toLowerCase().startsWith('amazon')) return false;
  if (track['provider_id']?.toString().toLowerCase() != 'amazon') {
    return false;
  }
  return RegExp(r'^[A-Z0-9]{10}$')
      .hasMatch((track['id'] ?? '').toString().toUpperCase());
}

/// An installed Deezer source's own Search row contains the canonical
/// numeric Deezer track ID. Repeating enrichTrack() issues another API call
/// before the actual signed download ticket can even be requested.
bool providerIdentityIsDeezer(String addonName, Map track) {
  if (!addonName.toLowerCase().startsWith('deezer') ||
      track['provider_id']?.toString().toLowerCase() != 'deezer') {
    return false;
  }
  final id = track['id']?.toString() ?? '';
  return RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(id);
}

String morneyeAlbumArtworkUrl(String original) {
  final uri = Uri.tryParse(original);
  if (uri == null || uri.scheme != 'https') return original;
  final host = uri.host.toLowerCase();
  if (!PlayerArtworkQuality.isAmazonArtworkHost(host)) return original;
  final upgraded = uri.path.replaceFirst(
    RegExp(r'\._[^/.]+_\.(?=(?:jpg|jpeg|png|webp)$)', caseSensitive: false),
    '.',
  );
  return upgraded == uri.path ? original : uri.replace(path: upgraded).toString();
}
/// A song an add-on found.
class MorneyeTrack {
  const MorneyeTrack({
    required this.provider,
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    this.duration,
    this.isrc,
    this.thumbnail,
    this.trackNumber,
    this.discNumber,
    this.year,
    this.quality,
    this.codec,
    this.bitDepth,
    this.sampleRate,
    this.atmosAvailable = false,
    this.atmosCodec,
  });

  /// `a-<package key>`.
  final String provider;
  final String id;
  final String title;
  final String artist;
  final String? album;
  final Duration? duration;
  final String? isrc;
  final String? thumbnail;
  final int? trackNumber;
  final int? discNumber;
  final int? year;
  final String? quality;
  final String? codec;
  final int? bitDepth;
  final int? sampleRate;
  final bool atmosAvailable;
  /// Per-track confirmed Amazon Atmos presentation, if the codec is known.
  final String? atmosCodec;
  String get key => provider.substring(2);

  static int? _positiveInt(Object? value) {
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    return parsed != null && parsed > 0 ? parsed : null;
  }

  static int? _sampleRate(Map track) {
    final raw = track['sample_rate'] ?? track['sampleRate'] ??
        track['sampling_rate'] ?? track['samplingRate'] ??
        track['maximum_sampling_rate'] ?? track['maxSampleRate'];
    final value = raw is num
        ? raw.toDouble()
        : double.tryParse('$raw'.replaceAll(RegExp(r'\s*k(?:hz)?', caseSensitive: false), '').trim());
    if (value == null || !value.isFinite || value <= 0) return null;
    // Preserve 44.1 / 88.2 kHz exactly; don't truncate to 44 / 88.
    final hz = (value <= 384 ? value * 1000 : value).round();
    return hz >= 8000 && hz <= 768000 ? hz : null;
  }

  static int? _bitDepth(Map track) {
    final bits = _positiveInt(track['bit_depth'] ?? track['bitDepth'] ??
        track['bits_per_sample'] ?? track['bitsPerSample'] ??
        track['maximum_bit_depth'] ?? track['maxBitDepth']);
    return bits != null && bits <= 64 ? bits : null;
  }

  static String? _codec(Map track) {
    final raw = track['codec'] ?? track['audio_codec'] ??
        track['audioCodec'] ?? track['audio_format'] ??
        track['audioFormat'] ?? track['format'];
    final text = raw?.toString().toLowerCase() ?? '';
    if (text.contains('flac')) return 'FLAC';
    if (text.contains('alac')) return 'ALAC';
    if (text.contains('opus')) return 'OPUS';
    if (text.contains('vorbis')) return 'VORBIS';
    if (text.contains('eac3') || text.contains('ec-3')) return 'E-AC-3';
    if (text.contains('aac') || text.contains('mp4a')) return 'AAC';
    if (text.contains('mp3') || text.contains('mpeg')) return 'MP3';
    return null;
  }

  /// Provider search results can put covers in album artwork, a flat image
  /// URL, or an array of image sizes. Prefer the largest exact-track image,
  /// and promote Amazon CDN thumbnails to their unsized original asset.
  static String? _artwork(Map track) {
    double sizeOf(Map value) {
      double dimension(Object? raw) => raw is num ? raw.toDouble() :
          double.tryParse(raw?.toString() ?? '') ?? 0;
      final width = dimension(value['width']);
      final height = dimension(value['height']);
      return width > 0 && height > 0 ? width * height : width * width + height * height;
    }
    double urlSize(String url) {
      final uri = Uri.tryParse(url);
      if (uri == null || !PlayerArtworkQuality.isAmazonArtworkHost(uri.host)) return 0;
      final sizes = RegExp(r'_(?:SX|SY|SL|UX|UY)(\d+)').allMatches(uri.path)
          .map((m) => double.parse(m[1]!));
      if (sizes.isEmpty) return 0;
      final largest = sizes.reduce((a, b) => a > b ? a : b);
      return largest * largest;
    }
    ({String url, double size})? getImage(Object? value) {
      if (value is String && Uri.tryParse(value)?.hasScheme == true) {
        return (url: value, size: urlSize(value));
      }
      if (value is Map) {
        for (final field in ['url', 'src', 'cover_url', 'coverUrl', 'original',
            'large', 'medium', 'small']) {
          final found = getImage(value[field]);
          if (found != null) {
            final explicit = sizeOf(value);
            return (url: found.url, size: explicit > 0 ? explicit : found.size);
          }
        }
      }
      if (value is List) {
        ({String url, double size})? best;
        for (final image in value) {
          final found = getImage(image);
          if (found != null && (best == null || found.size >= best.size)) best = found;
        }
        return best;
      }
      return null;
    }

    final album = track['album'];
    ({String url, double size})? best;
    for (final value in [
      // Providers frequently expose a tiny convenience thumbnail alongside
      // a separate album images array with much larger artwork.
      track['images'], track['image'],
      if (album is Map) ...[
        album['images'], album['image'], album['cover_art'],
        album['cover_url'],
      ],
      track['artwork_url'], track['artworkUrl'],
      track['album_art'], track['albumArt'],
      track['cover_art'], track['coverArt'],
      track['cover_url'], track['coverUrl'], track['thumbnail'],
    ]) {
      final found = getImage(value);
      if (found != null && (best == null || found.size > best.size)) best = found;
    }
    // Keep the provider URL, so every renderer/downloader can try the master
    // and still fall back to this known working variant.
    return best?.url;
  }

  static MorneyeTrack of(Map track, String provider) {
    final rawArtists = track['artists'];
    final artists = rawArtists is List
        ? [
            for (final a in rawArtists)
              if ((a is String ? a : (a is Map ? a['name'] : null))
                  case final String n when n.isNotEmpty)
                n,
          ]
        : ['${rawArtists ?? track['artist'] ?? ''}']
              .where((a) => a.isNotEmpty)
              .toList();
    final title = '${track['name'] ?? track['title'] ?? ''}';
    final ms = (track['duration_ms'] ?? track['durationMs']) as num?;
    return MorneyeTrack(
      provider: provider,
      id: '${track['id']}',
      title: title.length > 500 ? title.substring(0, 500) : title,
      artist: artists.join(', '),
      album: morneyeAlbumName(track),
      duration: ms != null && ms > 0
          ? Duration(milliseconds: ms.toInt())
          : null,
      isrc: track['isrc'] as String?,
      thumbnail: _artwork(track),
      trackNumber: (track['track_number'] ?? track['trackNumber']) is num
          ? ((track['track_number'] ?? track['trackNumber']) as num).toInt()
          : null,
      discNumber: (track['disc_number'] ?? track['discNumber']) is num
          ? ((track['disc_number'] ?? track['discNumber']) as num).toInt()
          : null,
      year: int.tryParse(
        '${track['release_date'] ?? ''}'.padRight(4).substring(0, 4).trim(),
      ),
      quality: (track['audio_quality'] ?? track['audioQuality'] ?? track['quality'])?.toString(),
      codec: _codec(track),
      bitDepth: _bitDepth(track),
      sampleRate: _sampleRate(track),
      // Tidal audio_modes or Amazon's per-track audioQualities=ATMOS,
      // never addon-wide AC-4 qualityOptions, may certify catalogue Atmos.
      atmosAvailable: tidalAtmosAvailable(track),
      atmosCodec: morneyeAmazonAtmosCodec(track),
    );
  }
}

/// An installed package.
class MorneyeAddon {
  MorneyeAddon({
    required this.key,
    required this.name,
    required this.manifest,
    required this.digest,
    required this.installedAt,
    required this.methods,
    this.repositoryId,
    this.enabled = true,
  });

  final String key;
  final String name;
  Map<String, Object?> manifest;
  String digest;
  final int installedAt;
  List<String> methods;
  String? repositoryId;
  bool enabled;

  String get displayName => '${manifest['displayName'] ?? name}';
  String get version => '${manifest['version'] ?? ''}';
  String get description => '${manifest['description'] ?? ''}';
  List get settingsSchema =>
      manifest['settings'] is List ? manifest['settings'] as List : const [];
  List get qualityOptions => manifest['qualityOptions'] is List
      ? manifest['qualityOptions'] as List
      : const [];
  List get globalActions => manifest['globalActions'] is List
      ? manifest['globalActions'] as List
      : const [];
  Map? get signedSession => manifest['signedSession'] is Map
      ? manifest['signedSession'] as Map
      : null;
  bool get downloads =>
      (manifest['type'] as List).contains('download_provider');
  bool get searches =>
      methods.contains('searchTracks') || methods.contains('customSearch');

  MorneyeAddonInfo get info =>
      MorneyeAddonInfo(key: key, name: name, manifest: manifest);

  Map<String, Object?> toJson() => {
    'key': key,
    'name': name,
    'manifest': manifest,
    'digest': digest,
    'installed_at': installedAt,
    'methods': methods,
    'repository_id': repositoryId,
    'enabled': enabled,
  };

  static MorneyeAddon? fromJson(Object? json) {
    if (json is! Map || json['key'] is! String || json['manifest'] is! Map) {
      return null;
    }
    return MorneyeAddon(
      key: json['key'] as String,
      name: '${json['name']}',
      manifest: (json['manifest'] as Map).cast<String, Object?>(),
      digest: '${json['digest'] ?? ''}',
      installedAt: (json['installed_at'] as num?)?.toInt() ?? 0,
      methods: [
        for (final m
            in json['methods'] is List ? json['methods'] as List : const [])
          '$m',
      ],
      repositoryId: json['repository_id'] as String?,
      enabled: json['enabled'] != false,
    );
  }
}

class MorneyeRepository {
  MorneyeRepository({
    required this.id,
    required this.url,
    required this.name,
    this.refreshedAt,
    this.entries = const [],
    this.error,
  });

  final String id;
  final String url;
  String name;
  int? refreshedAt;
  List<Map<String, Object?>> entries;
  String? error;

  bool get official => url == morneyeRegistry;

  Map<String, Object?> toJson() => {
    'id': id,
    'url': url,
    'name': name,
    'refreshed_at': refreshedAt,
    'entries': entries,
    'error': error,
  };

  static MorneyeRepository? fromJson(Object? json) {
    if (json is! Map || json['id'] is! String || json['url'] is! String) {
      return null;
    }
    return MorneyeRepository(
      id: json['id'] as String,
      url: json['url'] as String,
      name: '${json['name'] ?? ''}',
      refreshedAt: (json['refreshed_at'] as num?)?.toInt(),
      entries: [
        for (final e
            in json['entries'] is List ? json['entries'] as List : const [])
          if (e is Map) e.cast<String, Object?>(),
      ],
      error: json['error'] as String?,
    );
  }
}

/// A repository package as offered, with how it relates to what's installed.
class MorneyeCatalogueEntry {
  const MorneyeCatalogueEntry(
    this.entry,
    this.repositoryId, {
    this.installed,
    required this.compatible,
  });

  final Map<String, Object?> entry;
  final String repositoryId;
  final MorneyeAddon? installed;
  final bool compatible;

  String get id => '${entry['id']}';
  String get name =>
      '${entry['display_name'] ?? entry['displayName'] ?? entry['name'] ?? id}';
  String get version => '${entry['version']}';
  String get description => '${entry['description'] ?? ''}';
  String get category => '${entry['category'] ?? ''}';
  bool get updateAvailable =>
      installed != null &&
      morneyeCompareVersions(version, installed!.version) > 0;
}

/// What an add-on still needs before it can download.
class MorneyeAccess {
  const MorneyeAccess(
    this.kind, {
    required this.ready,
    required this.verified,
    this.missing = const [],
  });

  /// `verification`, `login`, `settings` or `none`.
  final String kind;
  final bool ready;
  final bool verified;
  final List<String> missing;
}

/// The finished download.
class MorneyeDownload {
  MorneyeDownload(this.file, this.metadata, this.info, this._staging, {this.atmosEncoded = false, this.atmosCodec});

  final File file;
  final Map<String, Object?> metadata;
  final Map<String, Object?> info;
  final Directory _staging;
  /// True only after native/FFprobe identified an original AC-4 or JOC stream.
  /// This does not imply that AC-4's immersive presentation was verified.
  final bool atmosEncoded;
  final String? atmosCodec; // Verified encoded source, AC-4 or E-AC-3 JOC.

  Future<void> cleanup() async {
    if (_staging.existsSync()) await _staging.delete(recursive: true);
  }
}

/// Fetches a document from a repository host (and only that host).
typedef MorneyeDocumentFetch = Future<Uint8List> Function(
  String url,
  int maxBytes,
);

typedef MorneyeAudioConverter = Future<void> Function(
  String inputPath,
  String outputPath,
  String codec,
);

class MorneyePackages {
  MorneyePackages(
    this.root, {
    required this.storage,
    this._native = const NativeMorneye(),
    this._starter = startNativeMorneyeGuest,
    this._fetch,
    this.isrcLookup,
    this.audioConverter,
    this.audioDecryptor,
    this.appVersion = '1.0.0',
  });

  final Directory root;
  final MorneyeStorage storage;
  final MorneyeNative _native;
  final MorneyeGuestStarter _starter;
  final MorneyeDocumentFetch? _fetch;
  final MorneyeIsrcLookup? isrcLookup;
  final MorneyeAudioConverter? audioConverter;
  final MorneyeAudioConverter? audioDecryptor;
  final String appVersion;

  final _repos = <MorneyeRepository>[];
  final _addons = <String, MorneyeAddon>{};
  final _runtimes = <String, MorneyeRuntime>{};
  final _networks = <String, MorneyeNetwork>{};
  final _sessions = <String, MorneyeSignedSession>{};
  final _tracks = <String, Map>{};
  final _locks = <String, Future<void>>{};
  final _forms =
      <String, ({String key, String action, int steps, DateTime expires})>{};
  bool _loaded = false;

  File get _index => File(p.join(root.path, 'index.json'));

  /// Reads what's installed; safe to call more than once.
  Future<void> load() async {
    if (_loaded) return;
    await storage.open();
    if (_index.existsSync()) {
      try {
        final json = jsonDecode(await _index.readAsString()) as Map;
        _repos.addAll([
          for (final r in json['repositories'] as List? ?? const [])
            ?MorneyeRepository.fromJson(r),
        ]);
        for (final a in json['packages'] as List? ?? const []) {
          final addon = MorneyeAddon.fromJson(a);
          if (addon != null) _addons[addon.key] = addon;
        }
      } catch (_) {
        // An unreadable index starts empty rather than failing every screen.
      }
    }
    const legacyRegistryUrl =
        'https://raw.githubusercontent.com/spotiflacapp/SpotiFLAC-Extension/main/registry.json';
    String? oldDefaultId;
    String? currentDefaultId;
    for (final repository in _repos) {
      if (repository.url == legacyRegistryUrl) oldDefaultId = repository.id;
      if (repository.url == morneyeRegistry) currentDefaultId = repository.id;
    }
    if (oldDefaultId != null) {
      _repos.removeWhere((r) => r.url == legacyRegistryUrl);
    }
    if (currentDefaultId == null) {
      currentDefaultId = _sha256(utf8.encode(morneyeRegistry)).substring(0, 16);
      _repos.insert(
        0,
        MorneyeRepository(
          id: currentDefaultId,
          url: morneyeRegistry,
          name: 'Morneye official',
        ),
      );
    }
    var migratedAddonRepositoryIds = false;
    if (oldDefaultId != null) {
      for (final addon in _addons.values) {
        if (addon.repositoryId == oldDefaultId) {
          addon.repositoryId = currentDefaultId;
          migratedAddonRepositoryIds = true;
        }
      }
    }
    // The bundled Amazon (New) package has a separate update feed; official
    // Morneye sources remain on their original registry.
    final needsAmazonNewRepo =
        !_repos.any((repository) => repository.url == morneyeAmazonNewRegistry);
    if (needsAmazonNewRepo) {
      _repos.add(MorneyeRepository(
        id: _sha256(utf8.encode(morneyeAmazonNewRegistry)).substring(0, 16),
        url: morneyeAmazonNewRegistry,
        name: 'Amazon (New) updates',
      ));
    }
    _loaded = true;
    if (oldDefaultId != null || migratedAddonRepositoryIds ||
        currentDefaultId != null && needsAmazonNewRepo) _save();
  }

  void _save() => morneyeAtomicWrite(
    _index,
    utf8.encode(
      jsonEncode({
        'repositories': [for (final r in _repos) r.toJson()],
        'packages': [for (final a in _addons.values) a.toJson()],
      }),
    ),
  );

  List<MorneyeAddon> get addons =>
      _addons.values.toList()
        ..sort((a, b) => a.installedAt.compareTo(b.installedAt));
  List<MorneyeRepository> get repositories => List.unmodifiable(_repos);
  MorneyeAddon? find(String key) => _addons[key];

  // ---------------------------------------------------------------- settings

  Map<String, Object?> settings(MorneyeAddon addon) {
    Map<String, Object?> values = {};
    try {
      values = storage.read(addon.key, 'settings');
    } catch (_) {
      // Unreadable (a reset key): the add-on shows its defaults.
    }
    final defaults = <String, Object?>{
      for (final field in addon.settingsSchema)
        if (field is Map && field.containsKey('default'))
          '${field['key']}': field['default'],
    };
    final quality = <String, Object?>{
      for (final option in addon.qualityOptions)
        if (option is Map)
          '${option['id']}': {
            for (final field
                in option['settings'] is List
                    ? option['settings'] as List
                    : const [])
              if (field is Map && field.containsKey('default'))
                '${field['key']}': field['default'],
          },
    };
    return {...defaults, 'qualitySettings': quality, ...values};
  }

  /// Saves [values] the add-on's schema allows; secrets left empty keep theirs.
  void setSettings(String key, Map<String, Object?> values) {
    final addon = _addons[key];
    if (addon == null) throw const MorneyePackageError('Addon not found');
    final current = storage.read(key, 'settings');
    void assign(List schema, Map? input, Map<String, Object?> target) {
      if (input == null) return;
      for (final field in schema) {
        if (field is! Map ||
            field['type'] == 'button' ||
            !input.containsKey(field['key'])) {
          continue;
        }
        final name = '${field['key']}';
        final value = input[name];
        if (field['secret'] == true && value == '') continue;
        final type = field['type'];
        final options = [
          for (final o
              in field['options'] is List ? field['options'] as List : const [])
            o is Map ? o['value'] : o,
        ];
        if ((type == 'boolean' && value is! bool) ||
            (type == 'number' && num.tryParse('$value') == null) ||
            (type == 'select' && !options.contains(value))) {
          throw MorneyePackageError('Invalid setting: $name');
        }
        final text = '${value ?? ''}';
        target[name] = type == 'number'
            ? num.parse('$value')
            : type == 'boolean'
            ? value
            : (text.length > 8000 ? text.substring(0, 8000) : text);
      }
    }

    assign(addon.settingsSchema, values, current);
    final quality = values['qualitySettings'];
    if (quality is Map) {
      final saved =
          (current['qualitySettings'] as Map?)?.cast<String, Object?>() ?? {};
      for (final option in addon.qualityOptions) {
        if (option is! Map) continue;
        final id = '${option['id']}';
        final target = (saved[id] as Map?)?.cast<String, Object?>() ?? {};
        assign(
          option['settings'] is List ? option['settings'] as List : const [],
          quality[id] as Map?,
          target,
        );
        saved[id] = target;
      }
      current['qualitySettings'] = saved;
    }
    final downloadQuality = values['downloadQuality'];
    if (downloadQuality != null &&
        addon.qualityOptions.any(
          (q) => q is Map && q['id'] == downloadQuality,
        )) {
      current['downloadQuality'] = downloadQuality;
    }
    storage.write(key, 'settings', current);
    _retire(key);
  }

  MorneyeAccess access(MorneyeAddon addon) {
    final values = settings(addon);
    final missing = [
      for (final field in addon.settingsSchema)
        if (field is Map &&
            field['required'] == true &&
            field['type'] != 'button' &&
            (values[field['key']] == null || values[field['key']] == ''))
          '${field['label'] ?? field['key']}',
    ];
    final signed = addon.signedSession;
    if (signed != null) {
      var verified = false;
      try {
        verified = _sessionFor(addon, null).status()['authenticated'] == true;
      } catch (_) {}
      return MorneyeAccess(
        'verification',
        ready: verified && missing.isEmpty,
        verified: verified,
        missing: missing,
      );
    }
    final login = addon.globalActions.any(
      (item) =>
          item is Map &&
          RegExp(
            r'log\s*in|sign\s*in|connect|auth|account',
            caseSensitive: false,
          ).hasMatch('${item['action']} ${item['label'] ?? ''}'),
    );
    if (login) {
      var auth = _networks[addon.key]?.auth;
      if (auth == null) {
        try {
          auth = (storage.read(addon.key, 'connection')['auth'] as Map?)
              ?.cast<String, Object?>();
        } catch (_) {}
      }
      final tokens =
          auth != null &&
          (auth['access_token'] != null ||
              auth['refresh_token'] != null ||
              auth['code'] != null);
      var account = false;
      try {
        account = storage.read(addon.key, 'credentials').isNotEmpty;
      } catch (_) {}
      final verified = tokens || account;
      return MorneyeAccess(
        'login',
        ready: verified && missing.isEmpty,
        verified: verified,
        missing: missing,
      );
    }
    return MorneyeAccess(
      missing.isEmpty ? 'none' : 'settings',
      ready: missing.isEmpty,
      verified: true,
      missing: missing,
    );
  }

  // ------------------------------------------------------------ repositories

  Future<Uint8List> _document(String url, int maxBytes) async {
    final fetch = _fetch;
    if (fetch != null) return fetch(url, maxBytes);
    final uri = Uri.parse(url);
    final network = MorneyeNetwork(
      MorneyePermissions(network: [uri.host]),
      userAgent: 'Lokal/$appVersion',
    );
    try {
      final response = await network.request(url);
      try {
        if (response.status != 200) {
          throw MorneyePackageError(
            'Repository returned HTTP ${response.status}',
          );
        }
        return await morneyeReadAll(
          response.body,
          maxBytes,
        ).timeout(const Duration(seconds: 60));
      } finally {
        await response.close();
      }
    } finally {
      network.close();
    }
  }

  /// Refreshes repositories not refreshed within [maxAge].
  Future<void> refreshDue({Duration maxAge = const Duration(hours: 6)}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await Future.wait([
      for (final repo in _repos)
        if (repo.refreshedAt == null ||
            now - repo.refreshedAt! > maxAge.inMilliseconds)
          refreshRepo(repo.id).then((_) {}, onError: (_) {}),
    ]);
  }

  Future<MorneyeRepository> addRepo(String raw) async {
    var url = Uri.tryParse(raw.trim());
    if (url == null ||
        url.scheme != 'https' ||
        url.userInfo.isNotEmpty ||
        url.host.isEmpty) {
      throw const MorneyePackageError('Repository URLs must use HTTPS');
    }
    if (!url.path.toLowerCase().endsWith('.json')) {
      url = url.replace(
        path: '${url.path.replaceFirst(RegExp(r'/$'), '')}/registry.json',
      );
    }
    url = url.removeFragment();
    final href = url.toString();
    final id = _sha256(utf8.encode(href)).substring(0, 16);
    if (!_repos.any((r) => r.id == id)) {
      _repos.add(MorneyeRepository(id: id, url: href, name: url.host));
      _save();
    }
    await refreshRepo(id);
    return _repos.firstWhere((r) => r.id == id);
  }

  Future<List<MorneyeCatalogueEntry>> refreshRepo(String id) async {
    final repo = _repos.where((r) => r.id == id).firstOrNull;
    if (repo == null) throw const MorneyePackageError('Repository not found');
    try {
      final index = jsonDecode(
        utf8.decode(await _document(repo.url, 2 * 1024 * 1024)),
      );
      if (index is! Map ||
          index['version'] != 1 ||
          index['extensions'] is! List ||
          (index['extensions'] as List).length > 2000) {
        throw const MorneyePackageError('Invalid Morneye registry');
      }
      bool valid(Map e) {
        try {
          return RegExp(r'^[a-z0-9][a-z0-9_-]{0,99}$')
                  .hasMatch('${e['id'] ?? e['name'] ?? ''}') &&
              e['version'] is String &&
              RegExp(
                r'^[a-f0-9]{64}$',
                caseSensitive: false,
              ).hasMatch('${e['sha256'] ?? ''}') &&
              Uri.parse('${e['download_url']}').scheme == 'https';
        } catch (_) {
          return false;
        }
      }

      final entries = <Map<String, Object?>>[];
      for (final e in index['extensions'] as List) {
        if (e is! Map) continue;
        if (e['category'] != 'download' &&
            !(e['category'] == 'integration' && valid(e))) {
          continue;
        }
        if (!valid(e)) {
          throw const MorneyePackageError('Invalid registry package entry');
        }
        entries.add({...e.cast<String, Object?>(), 'id': e['id'] ?? e['name']});
      }
      if (entries.map((e) => e['id']).toSet().length != entries.length) {
        throw const MorneyePackageError('Duplicate registry package IDs');
      }
      repo
        ..entries = entries
        ..refreshedAt = DateTime.now().millisecondsSinceEpoch
        ..error = null;
      final title = index['name'] is String
          ? (index['name'] as String)
                .replaceAll(RegExp(r'[\u0000-\u001f]'), '')
                .trim()
          : '';
      if (title.isNotEmpty && !repo.official) {
        repo.name = title.length > 80 ? title.substring(0, 80) : title;
      }
      _save();
    } catch (error) {
      repo.error = '$error';
      _save();
      rethrow;
    }
    return catalogue(id);
  }

  List<MorneyeCatalogueEntry> catalogue([String? id]) => [
    for (final repo in _repos)
      if (id == null || repo.id == id)
        for (final entry in repo.entries)
          MorneyeCatalogueEntry(
            entry,
            repo.id,
            installed: _addons[morneyeKeyOf('${entry['id']}')],
            compatible:
                morneyeCompareVersions(
                  entry['min_app_version'],
                  morneyeCompatVersion,
                ) <=
                0,
          ),
  ];

  void removeRepo(String id) {
    _repos.removeWhere((r) => r.id == id && !r.official);
    _save();
  }

  // ---------------------------------------------------------------- packages

  Future<T> _locked<T>(String key, Future<T> Function() action) async {
    final previous = _locks[key] ?? Future.value();
    final result = previous.then((_) => action());
    final done = result.then((_) {}, onError: (_) {});
    _locks[key] = done;
    try {
      return await result;
    } finally {
      if (identical(_locks[key], done)) _locks.remove(key);
    }
  }

  Directory _packageDir(String key) =>
      Directory(p.join(root.path, 'packages', key));

  /// Installs or updates from a repository entry, a URL, or package [bytes].
  Future<MorneyeAddon> install({
    String? repositoryId,
    String? id,
    String? url,
    Uint8List? bytes,
  }) async {
    Map<String, Object?>? entry;
    if (repositoryId != null) {
      entry = catalogue(repositoryId)
          .where((e) => e.id == id)
          .firstOrNull
          ?.entry;
      if (entry == null) {
        throw const MorneyePackageError('Package not found in this repository');
      }
      url = '${entry['download_url']}';
    }
    if (bytes == null) {
      final path = url == null ? '' : Uri.parse(url).path;
      if (!morneyeIsPackageFileName(path)) {
        throw const MorneyePackageError(
          'Choose a .sflx, .spotiflac-ext or .morneye-ext package',
        );
      }
      bytes = await _document(url!, 32 * 1024 * 1024);
    }
    final digest = _sha256(bytes);
    if (entry != null && digest != '${entry['sha256']}'.toLowerCase()) {
      throw const MorneyePackageError(
        'Package SHA-256 does not match its repository',
      );
    }
    final archive = morneyeReadArchive(bytes);
    final manifest = archive.manifest;
    final name = manifest['name'] as String;
    if (entry != null &&
        (name != entry['id'] || manifest['version'] != entry['version'])) {
      throw const MorneyePackageError(
        'Package identity/version does not match its registry entry',
      );
    }
    final key = morneyeKeyOf(name);
    return _locked(key, () async {
      final existing = _addons[key];
      if (existing != null && existing.name != name) {
        throw const MorneyePackageError('Addon identity collision');
      }
      if (existing != null &&
          morneyeCompareVersions(manifest['version'], existing.version) < 0) {
        throw const MorneyePackageError('Cannot downgrade an installed addon');
      }
      final staged = Directory(
        p.join(
          root.path,
          'staging',
          '${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      MorneyeRuntime? runtime;
      try {
        for (final file in archive.files.entries) {
          final target = File(p.join(staged.path, file.key));
          if (!p.isWithin(staged.path, target.path)) {
            throw const MorneyePackageError(
              'Addon package contains an unsafe archive path',
            );
          }
          await target.parent.create(recursive: true);
          await target.writeAsBytes(file.value);
        }
        final candidate = MorneyeAddon(
          key: key,
          name: name,
          manifest: manifest,
          digest: digest,
          installedAt: 0,
          methods: const [],
        );
        runtime = await _createRuntime(
          candidate,
          archive.code,
          root: p.join(staged.path, 'validation-data'),
        );
        final methods = runtime.methods;
        final types = manifest['type'] as List;
        final urlHandler = manifest['urlHandler'];
        if (types.contains('download_provider') &&
            !methods.contains('download')) {
          throw const MorneyePackageError(
            'Download provider has no registered download() method',
          );
        }
        if (((urlHandler is Map && urlHandler['enabled'] == true) ||
                !types.contains('download_provider')) &&
            !methods.contains('handleUrl')) {
          throw const MorneyePackageError(
            'Playlist-link addon has no registered handleUrl() method',
          );
        }
        runtime.close();
        runtime = null;
        final validation = Directory(p.join(staged.path, 'validation-data'));
        if (validation.existsSync()) await validation.delete(recursive: true);
        _retire(key);
        final target = _packageDir(key);
        final backup = Directory('${target.path}.previous');
        await target.parent.create(recursive: true);
        if (backup.existsSync()) await backup.delete(recursive: true);
        if (target.existsSync()) await target.rename(backup.path);
        try {
          await staged.rename(target.path);
          final addon =
              existing ??
              MorneyeAddon(
                key: key,
                name: name,
                manifest: manifest,
                digest: digest,
                installedAt: DateTime.now().millisecondsSinceEpoch,
                methods: methods,
              );
          addon
            ..manifest = manifest
            ..digest = digest
            ..methods = methods
            ..repositoryId = repositoryId;
          _addons[key] = addon;
          _save();
        } catch (error) {
          if (target.existsSync()) await target.delete(recursive: true);
          if (backup.existsSync()) await backup.rename(target.path);
          rethrow;
        }
        if (backup.existsSync()) await backup.delete(recursive: true);
        return _addons[key]!;
      } finally {
        runtime?.close();
        if (staged.existsSync()) await staged.delete(recursive: true);
      }
    });
  }

  Future<void> remove(String key) => _locked(key, () async {
    _retire(key);
    _addons.remove(key);
    _save();
    final dir = _packageDir(key);
    if (dir.existsSync()) await dir.delete(recursive: true);
    storage.forget(key);
  });

  void setEnabled(String key, bool enabled) {
    _retire(key);
    _addons[key]?.enabled = enabled;
    _save();
  }

  // ---------------------------------------------------------------- runtimes

  MorneyeNetwork _networkFor(MorneyeAddon addon) {
    final existing = _networks[addon.key];
    if (existing != null) return existing;
    final network = MorneyeNetwork(
      MorneyePermissions.fromJson(addon.manifest['permissions']),
      userAgent: 'Lokal/$appVersion',
      requestTimeout: addon.name.toLowerCase().contains('tidal')
          ? const Duration(seconds: 75)
          : const Duration(seconds: 30),
    );
    try {
      final saved = storage.read(addon.key, 'connection');
      if (saved['auth'] is Map) {
        network.auth = (saved['auth'] as Map).cast<String, Object?>();
      }
      if (saved['cookies'] != null) {
        network.cookies = MorneyeCookieJar.fromJson(saved['cookies']);
      }
    } catch (_) {}
    Timer? timer;
    network.persist = () {
      timer?.cancel();
      timer = Timer(
        const Duration(milliseconds: 250),
        () => _saveConnection(addon.key, network),
      );
    };
    return _networks[addon.key] = network;
  }

  void _saveConnection(String key, MorneyeNetwork network) {
    if (!_addons.containsKey(key)) return;
    try {
      final auth = Map<String, Object?>.of(network.auth)..remove('pending');
      storage.write(key, 'connection', {
        'auth': auth,
        'cookies': network.cookies.toJson(),
      });
    } catch (_) {}
  }

  MorneyeSignedSession _sessionFor(
    MorneyeAddon addon,
    MorneyeNetwork? network,
  ) {
    final config = addon.signedSession!.cast<String, Object?>();
    final scope = _sha256(utf8.encode(jsonEncode(config)));
    final existing = _sessions[scope];
    if (existing != null &&
        (network == null || identical(existing.network, network))) {
      return existing;
    }
    final session = MorneyeSignedSession(config, storage, network, addon.key);
    if (network != null) _sessions[scope] = session;
    return session;
  }

  Future<MorneyeRuntime> _createRuntime(
    MorneyeAddon addon,
    String code, {
    String? root,
    List<String> grants = const [],
    void Function({double? percent, String? message})? onProgress,
    void Function(MorneyeTransfer)? onTransfer,
    int heapMb = 64,
  }) {
    final network = _networkFor(addon);
    final session = addon.signedSession != null
        ? _sessionFor(addon, network)
        : null;
    final host = MorneyeHost(
      addon: addon.info,
      storage: storage,
      network: network,
      session: session,
      native: _native,
      root: root ?? p.join(this.root.path, 'data', addon.key, 'files'),
      grants: grants,
      isrcLookup: isrcLookup,
      onProgress: onProgress,
      onTransfer: onTransfer,
      appVersion: appVersion,
    );
    return MorneyeRuntime.start(
      code,
      {
        'permissions': addon.manifest['permissions'],
        'signedSession': addon.manifest['signedSession'],
        'settings': settings(addon),
        'rawFfmpeg': (addon.manifest['capabilities'] as Map?)?['rawFfmpeg'],
        // Host-only resource limit; not exposed as a user setting.
        'heapMb': heapMb,
      },
      host,
      starter: _starter,
    );
  }

  String _code(String key) =>
      File(p.join(_packageDir(key).path, 'index.js')).readAsStringSync();

  /// The add-on's shared runtime (for browsing, logins and actions).
  Future<MorneyeRuntime> runtime(String key) async {
    final addon = _addons[key];
    if (addon == null || !addon.enabled) {
      throw const MorneyePackageError(
        'This addon is not installed or is turned off',
      );
    }
    var runtime = _runtimes[key];
    if (runtime == null || runtime.closed) {
      runtime = await _createRuntime(addon, _code(key));
      _runtimes[key] = runtime;
      final started = runtime;
      started.initialized = started
          .invoke('initialize', [settings(addon)])
          .then((_) {});
    }
    await runtime.initialized;
    return runtime;
  }

  void _retire(String key) {
    final network = _networks.remove(key);
    if (network != null) _saveConnection(key, network);
    _runtimes.remove(key)?.close();
  }

  /// Stops every add-on (the app is closing or the service is replaced).
  void shutdown() {
    for (final key in [..._runtimes.keys, ..._networks.keys]) {
      _retire(key);
    }
  }

  // --------------------------------------------------------------- browsing

  void _remember(String key, Iterable tracks) {
    for (final track in tracks) {
      if (track is Map && track['id'] != null) {
        _tracks['$key:${track['id']}'] = track;
      }
    }
    if (_tracks.length > 2000) {
      for (final stale in _tracks.keys.take(_tracks.length - 2000).toList()) {
        _tracks.remove(stale);
      }
    }
  }

  /// Songs matching [query] (or a link, for add-ons that read links).
  Future<List<MorneyeTrack>> search(
    String key,
    String query, {
    int limit = 20,
  }) async {
    final runtime = await this.runtime(key);
    final addon = _addons[key]!;
    final urlHandler = addon.manifest['urlHandler'];
    Object? results;
    if (urlHandler is Map &&
        urlHandler['enabled'] == true &&
        RegExp(r'^(https?:|[a-z]+:)', caseSensitive: false).hasMatch(query)) {
      results = await runtime.invoke('handleUrl', [query]);
    } else if (runtime.methods.contains('searchTracks')) {
      results = await runtime.invoke('searchTracks', [query, limit]);
    } else {
      final behavior = addon.manifest['searchBehavior'];
      final filters = behavior is Map && behavior['filters'] is List
          ? behavior['filters'] as List
          : const [];
      final filter = filters
          .where(
            (f) =>
                f is Map &&
                RegExp(r'^(songs?|tracks?)$').hasMatch('${f['id']}'),
          )
          .firstOrNull;
      results = await runtime.invoke('customSearch', [
        query,
        {'limit': limit, 'filter': filter is Map ? filter['id'] : 'tracks'},
      ]);
    }
    List tracks;
    if (results is List) {
      tracks = results;
    } else if (results is Map) {
      final album = results['album'], artist = results['artist'];
      tracks =
          (results['tracks'] ??
                  (album is Map ? album['tracks'] : null) ??
                  (artist is Map ? artist['top_tracks'] : null) ??
                  (results['track'] != null ? [results['track']] : const []))
              as List? ??
          const [];
    } else {
      tracks = const [];
    }
    // Amazon search can repeat the exact ASIN in multiple widgets. Keep
    // distinct release ASINs, and retain confirmed Atmos metadata if it
    // appears only on a later duplicate of the same recording.
    final amazon = addon.name.toLowerCase().startsWith('amazon');
    final amazonIndex = <String, int>{};
    final songs = <Map>[];
    for (final entry in tracks) {
      if (entry is! Map ||
          entry['id'] == null ||
          (entry['name'] ?? entry['title']) == null ||
          (entry['item_type'] != null && entry['item_type'] != 'track')) {
        continue;
      }
      if (amazon) {
        final id = '${entry['id']}';
        final previous = amazonIndex[id];
        if (previous != null) {
          if (tidalAtmosAvailable(entry) &&
              !tidalAtmosAvailable(songs[previous])) {
            // Copy only the confirmed mode. A later widget often has empty
            // artist/title fields which must not destroy the first track's
            // playback metadata and cached availability context.
            songs[previous] = {
              ...songs[previous],
              'audio_modes': morneyeExplicitAtmosMode(entry),
            };
          }
          continue;
        }
        amazonIndex[id] = songs.length;
      }
      songs.add(entry);
    }
    _remember(key, songs);
    return [for (final t in songs.take(limit)) MorneyeTrack.of(t, 'a-$key')];
  }

  // ----------------------------------------------------------------- logins

  Future<Map<String, Object?>> authStatus(String key) async {
    final runtime = await this.runtime(key);
    final addon = _addons[key]!;
    final access = this.access(addon);
    final session = runtime.host.session;
    final status = session?.status();
    final pending = runtime.host.network.auth['pending'];
    return {
      ...?status,
      'authenticated': status != null
          ? status['authenticated']
          : access.verified,
      'open_auth_url':
          session?.pending?.url ??
          (pending is Map ? pending['url'] : null) ??
          '',
    };
  }

  /// Starts verification or login; the page to open, or null when none is needed.
  Future<String?> verify(String key) async {
    final runtime = await this.runtime(key);
    final session = runtime.host.session;
    if (session != null) await session.bootstrap();
    final status = await authStatus(key);
    if (status['authenticated'] == true) return null;
    final url = '${status['open_auth_url'] ?? ''}';
    return url.isEmpty ? null : url;
  }

  /// Whether [url] is where the open login page hands back to the add-on.
  Future<bool> isAuthCallback(String key, String url) async {
    final runtime = await this.runtime(key);
    final session = runtime.host.session;
    if (session?.pending != null) return session!.isCallback(url);
    final pending = runtime.host.network.auth['pending'];
    final callback = pending is Map ? '${pending['callback'] ?? ''}' : '';
    if (callback.isEmpty) return false;
    final expected = Uri.tryParse(callback), actual = Uri.tryParse(url);
    return expected != null &&
        actual != null &&
        actual.scheme == expected.scheme &&
        actual.authority == expected.authority &&
        actual.path == expected.path;
  }

  Future<Map<String, Object?>> authCallback(String key, String raw) async {
    final runtime = await this.runtime(key);
    final session = runtime.host.session;
    if (session?.pending != null) return session!.callback(raw);
    final network = runtime.host.network;
    final pending = network.auth['pending'];
    final url = Uri.parse(raw);
    if (pending is! Map ||
        DateTime.now().millisecondsSinceEpoch - (pending['createdAt'] as num) >
            180000 ||
        url.queryParameters['state'] != pending['state']) {
      throw const MorneyePackageError('Invalid or expired OAuth callback');
    }
    network.auth['code'] = url.queryParameters['code'] ?? '';
    network.auth['pending'] = null;
    network.persist?.call();
    return {'success': true};
  }

  Future<void> logout(String key) async {
    final runtime = await this.runtime(key);
    runtime.host.session?.clear();
    try {
      await runtime.invoke('clearAuth');
    } catch (_) {
      // Few add-ons define it.
    }
    final network = _networks[key];
    if (network != null) {
      network.generation++;
      network.auth.clear();
      network.cookies = MorneyeCookieJar();
    }
    try {
      storage.write(key, 'connection', {});
      storage.write(key, 'credentials', {});
    } catch (_) {}
  }

  /// Runs a button or global action the add-on declared.
  Future<Map<String, Object?>> invokeAction(
    String key,
    String action, {
    Object? input,
    String? token,
  }) async {
    final runtime = await this.runtime(key);
    final addon = _addons[key]!;
    final form = token == null ? null : _forms[token];
    final declared = [
      for (final s in addon.settingsSchema)
        if (s is Map && s['type'] == 'button') '${s['action']}',
      for (final a in addon.globalActions)
        if (a is Map) '${a['action']}',
    ];
    if (form != null) {
      if (form.key != key ||
          form.action != action ||
          form.expires.isBefore(DateTime.now()) ||
          form.steps >= 8) {
        throw const MorneyePackageError('Invalid or expired addon form');
      }
      _forms.remove(token);
    } else if (!declared.contains(action) &&
        !(action == 'completeGrant' && addon.signedSession != null)) {
      throw const MorneyePackageError(
        'This action is not declared by the addon',
      );
    }
    final seconds =
        (((addon.manifest['capabilities'] as Map?)?['actionTimeoutSeconds']
                    as num?) ??
                30)
            .clamp(1, 120);
    final result = await runtime.invoke(
      action,
      input != null ? [input] : const [],
      Duration(seconds: seconds.toInt()),
    );
    final payload = <String, Object?>{
      ...(((result is Map ? result['result'] ?? result : null) as Map?)
              ?.cast<String, Object?>() ??
          {}),
    };
    final schema = payload['action_form'] ?? payload['byoa_form'];
    if (schema is Map) {
      if (schema['version'] != 1 ||
          !runtime.methods.contains(schema['submit_action']) ||
          schema['fields'] is! List ||
          (schema['fields'] as List).length > 12) {
        throw const MorneyePackageError('Invalid addon account form');
      }
      final next = _sha256(morneyeRandomBytes(16));
      _forms[next] = (
        key: key,
        action: '${schema['submit_action']}',
        steps: (form?.steps ?? 0) + 1,
        expires: DateTime.now().add(const Duration(minutes: 5)),
      );
      payload['formToken'] = next;
    }
    return payload;
  }

  // -------------------------------------------------------------- downloads

  static const _playable = {
    'flac',
    'alac',
    'aac',
    'mp3',
    'opus',
    'vorbis',
    'wavpack',
    'pcm_s16le',
    'pcm_s24le',
    'pcm_s32le',
    'pcm_f32le',
  };
  static const _extensions = {
    'flac': 'flac',
    'mp3': 'mp3',
    'isomp4': 'm4a',
    'ogg': 'ogg',
    'wave': 'wav',
    'adts': 'aac',
    'mkv': 'webm',
    'webm': 'webm',
    'wv': 'wv',
    'wavpack': 'wv',
  };

  /// Downloads song [id] through add-on [key] into a staging folder; call
  /// [MorneyeDownload.cleanup] once its file has been moved or copied.
  Future<MorneyeDownload> download(
    String key,
    String id, {
    String? quality,
    bool forPlayback = false,
    /// Exact user-selected catalogue metadata; never replaces authorization.
    Map<String, Object?>? trackHint,
    /// Host-side phase callback, distinct from guest-reported download percent.
    void Function(String stage)? onResolutionStage,
    void Function({double? percent, String? message})? onProgress,
    void Function(MorneyeTransfer)? onTransfer,
    Future<void>? cancel,
  }) async {
    final addon = _addons[key];
    if (addon == null || !addon.enabled) {
      throw const MorneyePackageError('Addon is not available');
    }
    final staged = Directory(
      p.join(root.path, 'work', '${DateTime.now().microsecondsSinceEpoch}'),
    );
    await staged.create(recursive: true);
    final hooks =
        addon.manifest['postProcessing'] is Map &&
        (addon.manifest['postProcessing'] as Map)['enabled'] == true &&
        ((addon.manifest['postProcessing'] as Map)['hooks'] as List? ??
                const [])
            .any((h) => h is Map && h['defaultEnabled'] == true);
    final preparation = Stopwatch()..start();
    var sawFirstByte = false;
    MorneyeRuntime? activeRuntime;
    Timer? inactivityTimer;
    var monitoringTransfer = false;
    var transferStalled = false;
    double lastPercent = -1;
    String? lastPart;
    var lastWritten = 0;
    void recordActivity() {
      if (!monitoringTransfer) return;
      inactivityTimer?.cancel();
      inactivityTimer = Timer(const Duration(seconds: 90), () {
        transferStalled = true;
        // End only an inactive *download*, never an interactive account or
        // verification step. Closing the guest rejects its pending invoke.
        activeRuntime?.close();
      });
    }
    void phase(String stage) {
      onResolutionStage?.call(stage);
      // Private IDs, signed URLs, tokens and track names are never logged.
      AppLog.instance.add('[Morneye] resolve stage=$stage '
          'elapsedMs=${preparation.elapsedMilliseconds}');
    }
    phase('worker_start');
    final runtime = await _createRuntime(
      addon,
      _code(key),
      grants: [staged.path],
      onProgress: ({double? percent, String? message}) {
        // Percent can restart from zero on a failed segment retry.
        // Compare with the preceding callback, not the highest old value.
        if (percent != null) {
          if (percent > lastPercent) recordActivity();
          lastPercent = percent;
        }
        onProgress?.call(percent: percent, message: message);
      },
      onTransfer: hooks ? null : (transfer) {
        // A header-only transfer restart isn't progress. Once real bytes
        // resume, even below the previous attempt's total, reset watchdog.
        if (transfer.written > 0 &&
            (transfer.part != lastPart || transfer.written > lastWritten)) {
          recordActivity();
        }
        lastPart = transfer.part;
        lastWritten = transfer.written;
        if (!sawFirstByte && transfer.written > 0) {
          sawFirstByte = true;
          phase('first_byte');
        }
        onTransfer?.call(transfer);
      },
      // Isolated download workers need headroom for segments/decryption.
      // Browsing stays at 64 MiB. Native code caps this at 256 MiB.
      heapMb: 256,
    );
    activeRuntime = runtime;
    unawaited(cancel?.then((_) => runtime.close()));
    try {
      phase('initializing');
      await runtime.invoke('initialize', [settings(addon)]);
      phase('metadata');
      Map track = _tracks['$key:$id'] ?? const {};
      if (track.isEmpty &&
          runtime.methods.contains('checkAvailability') &&
          trackHint != null &&
          '${trackHint['id'] ?? ''}' == id &&
          morneyeSelectedTrackHint(
            id: id, title: '${trackHint['name'] ?? ''}',
            artist: '${trackHint['artists'] ?? ''}',
            durationMs: (trackHint['duration_ms'] as num?)?.toInt(),
          ) != null) {
        // A verified selection avoids getTrack when the saved search cache
        // was evicted. checkAvailability is still mandatory.
        track = Map.of(trackHint);
      }
      if (track.isEmpty && runtime.methods.contains('getTrack')) {
        final found = await runtime.invoke('getTrack', [id]);
        if (found is Map) track = found;
      }
      if (track.isEmpty) {
        track = {
          'id': id,
          'name': '',
          'artists': '',
          'duration_ms': 0,
          'provider_id': addon.name,
        };
      }
      track = Map.of(track);
      final provider = addon.name.replaceFirst(RegExp(r'-web$'), '');
      final amazonProvider = provider == 'amazon' || provider == 'amazon-new';
      // First request is always the provider's own availability/download
      // ticket, regardless of Play vs Save or Tidal/Deezer/Qobuz identity.
      // This removes redundant enrichment before a source can transfer bytes.
      Future<dynamic> checkAvailability() {
        final options = <String, Object?>{
          'track': track,
          'duration_ms': track['duration_ms'] ?? 0,
        };
        const directFields = {
          'qobuz': 'qobuz_id',
          'tidal': 'tidal_id',
          'deezer': 'deezer_id',
          'soundcloud': 'spotify_id',
          'amazon': 'spotify_id',
          'amazon-new': 'spotify_id',
        };
        final directField = directFields[provider];
        if (directField != null) {
          options[directField] =
              '${track[directField] ?? (amazonProvider || provider == 'soundcloud' ? track['id'] : id)}';
        }
        return runtime.methods.contains('checkAvailability')
            ? runtime.invoke('checkAvailability', [
                track['isrc'] ?? '',
                track['name'] ?? '',
                track['artists'] ?? '',
                options,
              ], const Duration(seconds: 25))
            : Future.value({'available': true, 'track_id': id});
      }
      phase('availability');
      var available = await checkAvailability();
      if (morneyeShouldRetryEnrichment(
        available: available,
        hasEnrichment: runtime.methods.contains('enrichTrack'),
      )) {
        phase('cross_provider_enrichment');
        final enriched = await runtime.invoke('enrichTrack', [
          track,
        ], const Duration(seconds: 20));
        if (enriched is Map) {
          enriched.forEach((field, value) {
            if (value != null && value != '' && value != 0 &&
                !(value is String && value.trim().isEmpty) &&
                !(value is List && value.isEmpty)) {
              track[field] = value;
            }
          });
        }
        phase('availability_retry');
        available = await checkAvailability();
      }
      if (available is! Map || available['available'] != true) {
        throw MorneyePackageError(
          available is Map && available['reason'] != null
              ? '${available['reason']}'
              : 'The addon cannot download this track',
        );
      }
      final prepared = {
        ...((available['prepared_context'] ?? available['preparedContext'])
                as Map? ??
            const {}),
        'host_track': track,
        if (amazonProvider) 'web_metadata': track,
      };
      final values = settings(addon);
      // Preserve Settings > Addons download preferences for actual saves.
      // Only streaming playback must reject an implicit Atmos-only tier.
      final configuredQuality = values['downloadQuality'] as String?;
      final chosen = resolveMorneyeRequestQuality(
        forPlayback: forPlayback,
        requested: quality,
        configured: configuredQuality,
        options: addon.qualityOptions,
        provider: provider,
      );
      final explicitAmazonJoc = amazonProvider &&
          quality?.trim().toLowerCase() == 'eac3' &&
          chosen.trim().toLowerCase() == 'eac3';
      if (forPlayback && !isMorneyeAtmosQuality(quality) &&
          !explicitAmazonJoc &&
          (morneyeSpatialOption({'id': chosen}, provider: provider) ||
              addon.qualityOptions.any((o) => o is Map && o['id'] == chosen &&
                  morneyeSpatialOption(o, provider: provider)))) {
        throw const MorneyePackageError(
          'Normal playback unexpectedly selected a Dolby Atmos download tier.',
        );
      }
      // Saves retain the user's Amazon AC-4 setting even without an explicit
      // per-track tier. Playback's resolved tier has already excluded it.
      final amazonAc4 = amazonProvider &&
          chosen.trim().toLowerCase() == 'ac4';
      // An explicit E-AC-3 selection is Atmos only when initiated by a
      // confirmed JOC action. The decoded file must then pass the JOC probe.
      final explicitAtmos = isMorneyeAtmosQuality(quality) ||
          explicitAmazonJoc || (!forPlayback && amazonAc4);
      if (explicitAtmos) AtmosDiagnostics.record('addon_download_start', {
        'source': provider == 'tidal' ? 'tidal' : 'other',
        'quality': chosen,
      });
      phase('preparing_media');
      monitoringTransfer = true;
      recordActivity();
      dynamic result;
      try {
        result = await runtime.invoke('download', [
          '${available['track_id'] ?? available['trackId'] ?? id}',
          chosen,
          p.join(staged.path, 'audio.flac'),
          {'preparedContext': prepared, 'resolutionTimeoutMs': 60000},
        ], const Duration(hours: 24));
      } catch (error) {
        if (transferStalled) {
          throw const MorneyePackageError(
            'The provider stopped delivering audio for 90 seconds. Retry the track.',
          );
        }
        rethrow;
      } finally {
        monitoringTransfer = false;
        inactivityTimer?.cancel();
      }
      phase('download_complete');
      if (result is! Map || result['success'] != true) {
        if (explicitAtmos) AtmosDiagnostics.record('addon_download_failed', {
          'reason': 'addon_returned_failure',
        });
        final message = result is Map
            ? (result['error_message'] ?? result['error'])
            : null;
        throw MorneyePackageError('${message ?? 'Addon download failed'}');
      }
      final host = runtime.host;
      var file = host.file(
        '${result['file_path'] ?? result['filePath'] ?? result['path']}',
      );
      if (explicitAtmos) {
        // Diagnose provider tier negotiation without logging track IDs,
        // filesystem paths, signed URLs, manifest credentials or raw results.
        final claimed = '${result['audio_quality'] ?? result['audioQuality'] ?? result['quality'] ?? ''}'
            .trim().toUpperCase().replaceAll(RegExp(r'[ -]'), '_');
        final extension = p.extension(file).toLowerCase();
        AtmosDiagnostics.record('addon_response', {
          'quality': chosen,
          'reason': claimed == 'DOLBY_ATMOS'
              ? 'provider_claimed_atmos'
              : claimed == 'HI_RES_LOSSLESS' || claimed == 'LOSSLESS' || claimed == 'HIGH'
                  ? 'provider_claimed_stereo'
                  : 'provider_quality_unspecified',
          'container': {'.flac', '.m4a', '.mp4', '.ec3', '.eac3'}
                  .contains(extension)
              ? extension.replaceFirst('.', '')
              : 'other',
        });
      }
      if (!File(file).existsSync() || File(file).lengthSync() == 0) {
        if (explicitAtmos) AtmosDiagnostics.record('addon_download_failed', {
          'reason': 'empty_file',
        });
        throw const MorneyePackageError('Addon produced an empty file');
      }
      final decryption =
          result['decryption'] ??
          (result['decryption_key'] != null &&
                  '${result['decryption_key']}'.trim().isNotEmpty
              ? {'strategy': 'ffmpeg.mov_key', 'key': result['decryption_key']}
              : null);
      if (decryption != null) {
        if (explicitAtmos) AtmosDiagnostics.record('postprocess_start', {
          'stage': 'decrypt',
        });
        if (decryption is! Map ||
            decryption['strategy'] != 'ffmpeg.mov_key' ||
            !RegExp(r'^[a-fA-F0-9]{32}$')
                .hasMatch('${decryption['key'] ?? ''}')) {
          throw const MorneyePackageError(
            'Unsupported audio decryption descriptor',
          );
        }
        // Amazon uses an empty string for FLAC: desktop's JS `||`
        // treats that as unspecified, whereas Dart `??` does not.
        var ext = '.flac';
        for (final value in [
          result['output_extension'],
          decryption['output_extension'],
        ]) {
          if (value == null || (value is String && value.trim().isEmpty))
            continue;
          if (value is! String)
            throw const MorneyePackageError(
              'Invalid decrypted audio container',
            );
          ext = value.trim().toLowerCase();
          if (!ext.startsWith('.')) ext = '.$ext';
          break;
        }
        if (!{'.flac', '.m4a', '.mp4', '.ogg', '.opus'}.contains(ext))
          throw const MorneyePackageError('Invalid decrypted audio container');
        final target = p.join(staged.path, 'decrypted$ext');
        onProgress?.call(message: 'Decrypting audio…');
        if (audioDecryptor case final decrypt?) {
          await decrypt(file, target, '${decryption['key']}');
        } else {
          await morneyeConvertAudio(
            inputPath: file,
            outputPath: target,
            decryptionKey: '${decryption['key']}',
            cancel: cancel,
          );
        }
        file = target;
      }
      // Preserve the original compressed stream, including Atmos objects.
      // Amazon exposes 'ac4'; Tidal exposes 'DOLBY_ATMOS' (E-AC-3 JOC).
      // AC-4 verifies the codec, not independently its immersive presentation.
      final verifiedAtmos = explicitAtmos && (amazonAc4
          ? await AtmosPlaybackSupport.isAc4File(file)
          : await AtmosPlaybackSupport.isJocFile(file));
      if (explicitAtmos) AtmosDiagnostics.record('source_validation', {
        'codec': amazonAc4 ? 'ac4' : 'eac3_joc',
        'encoded': verifiedAtmos,
        'outcome': verifiedAtmos ? 'confirmed' : 'rejected',
      });
      if (explicitAtmos && !verifiedAtmos) {
        throw MorneyeSourceVerificationError(amazonAc4 ? 'AC-4' : 'E-AC-3 JOC');
      }
      if (verifiedAtmos) {
        // Media3, not Rust/FFmpeg PCM, retains the original encoded data.
        return MorneyeDownload(
          File(file),
          {...track.cast<String, Object?>(), ...result.cast<String, Object?>()},
          {'codec': amazonAc4 ? 'ac4' : 'eac3-joc', 'format': 'isomp4'},
          staged,
          atmosEncoded: true,
          atmosCodec: amazonAc4 ? 'ac4' : 'eac3-joc',
        );
      }

      final requiresContainerConversion =
          result['requires_container_conversion'] == true ||
          result['requiresContainerConversion'] == true;
      final postProcessing = addon.manifest['postProcessing'];
      if (postProcessing is Map && postProcessing['enabled'] == true) {
        for (final hook in postProcessing['hooks'] as List? ?? const []) {
          if (hook is! Map || hook['defaultEnabled'] != true) continue;
          final formats =
              (hook['supportedFormats'] ?? hook['formats']) as List?;
          if (formats != null &&
              formats.isNotEmpty &&
              !formats.contains(p.extension(file).replaceFirst('.', ''))) {
            continue;
          }
          final processed = await runtime.invoke('postProcessV2', [
            {'path': file},
            track,
            hook['id'],
          ], const Duration(minutes: 2));
          if (processed is! Map || processed['success'] != true) {
            throw MorneyePackageError(
              '${(processed is Map ? processed['error'] : null) ?? 'Addon post-processing failed'}',
            );
          }
          if (processed['new_file_uri'] != null ||
              processed['newFileUri'] != null) {
            throw const MorneyePackageError(
              'Addon post-processing cannot replace destination URIs',
            );
          }
          final moved = processed['new_file_path'] ?? processed['newFilePath'];
          if (moved != null) file = host.file('$moved');
        }
      }
      Map<String, Object?> info;
      if (requiresContainerConversion) {
        // Symphonia may not probe a FLAC bitstream wrapped in an MP4/DASH
        // container. Try the probe first; if it is readable, ALAC-in-M4A can
        // stay untouched and a FLAC bitstream can be remuxed without re-encoding.
        try {
          info = await _native.mediaInfo(file);
        } catch (_) {
          info = const {};
        }
        final sourceCodec = '${info['codec']}'.toLowerCase();
        final alreadyPlayableAlac =
            sourceCodec == 'alac' && p.extension(file).toLowerCase() == '.m4a';
        if (!alreadyPlayableAlac) {
          final output = p.join(staged.path, 'playable.flac');
          final conversionCodec = sourceCodec == 'flac' ? 'copy' : 'flac';
          final convert = audioConverter;
          if (convert != null) {
            await convert(file, output, conversionCodec);
          } else {
            await morneyeConvertAudio(
              inputPath: file,
              outputPath: output,
              codec: conversionCodec,
            );
          }
          file = output;
          info = await _native.mediaInfo(file);
        }
      } else {
        info = await _native.mediaInfo(file);
      }
      final codec = '${info['codec']}';
      final expected = (track['duration_ms'] as num?)?.toInt() ?? 0;
      final actual = (info['duration_ms'] as num?)?.toInt() ?? 0;
      if (expected > 0 && actual > 0 && (actual - expected).abs() > 12000) {
        throw const MorneyePackageError(
          'Downloaded audio does not match the track duration',
        );
      }
      if (!_playable.contains(codec)) {
        throw MorneyePackageError('The phone can’t play $codec audio');
      }
      // The player goes by the file name: give it the extension its container needs.
      final extension = _extensions['${info['format']}'.toLowerCase()];
      if (extension != null &&
          p.extension(file).toLowerCase() != '.$extension') {
        final renamed = p.join(staged.path, 'playable.$extension');
        await File(file).rename(renamed);
        file = renamed;
        info = {...info};
      }
      return MorneyeDownload(
        File(file),
        {...track.cast<String, Object?>(), ...result.cast<String, Object?>()},
        info,
        staged,
      );
    } catch (error) {
      if (staged.existsSync()) await staged.delete(recursive: true);
      rethrow;
    } finally {
      inactivityTimer?.cancel();
      runtime.close();
    }
  }
}
