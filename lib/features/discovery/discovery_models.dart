/// Discovery metadata is not a playable Song. In particular, a catalog URL is
/// never passed to the engine as a local file, and provider quality is not fact.
enum DiscoverySource { youtubeMusic, monochrome, soundCloud, addon, morneye }

class DiscoveryTrack {
  const DiscoveryTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.source,
    this.duration,
    this.album,
    this.sourceUrl,
    this.addonBase,
    this.addonId,
    this.sourceName,
    this.inlineStream,
    this.artwork,
    this.atmosAvailable = false,
    this.atmosRequested = false,
    this.atmosDownload = false,
    this.catalogueQuality,
    this.requestedQuality,
    this.catalogueCodec,
    this.catalogueBitDepth,
    this.catalogueSampleRate,
  });

  final String id;
  final String title;
  final String artist;
  final DiscoverySource source;
  final Duration? duration;
  final String? album;
  final Uri? sourceUrl;
  final Uri? addonBase;

  /// Local configuration identity, never taken from an addon response.
  final String? addonId;
  final String? sourceName;
  final Map<String, dynamic>? inlineStream;

  /// The cover's https address, when the source has one: downloaded next
  /// to the audio so Now Playing, the mini player and the notification
  /// show it.
  final String? artwork;

  /// Catalogue flag only. The decoded output might be stereo.
  final bool atmosAvailable;

  /// Explicit mobile 'Play Atmos' request; never inferred from a catalogue flag.
  final bool atmosRequested;
  /// A verified JOC download can be saved without an Atmos playback device.
  final bool atmosDownload;

  /// Provider-reported quality, not a verified active audio output.
  final String? catalogueQuality;

  /// Requested provider tier, distinct from per-track catalogue or decoded
  /// stream quality. Must never be presented as a verified file format.
  final String? requestedQuality;
  final String? catalogueCodec;
  final int? catalogueBitDepth;
  final int? catalogueSampleRate;

  DiscoveryTrack requestAtmos({bool downloadOnly = false}) => DiscoveryTrack(
    id: id, title: title, artist: artist, source: source,
    duration: duration, album: album, sourceUrl: sourceUrl, addonBase: addonBase,
    addonId: addonId, sourceName: sourceName, inlineStream: inlineStream,
    artwork: artwork, atmosAvailable: atmosAvailable, atmosRequested: true,
    atmosDownload: downloadOnly,
    catalogueQuality: catalogueQuality, requestedQuality: requestedQuality,
    catalogueCodec: catalogueCodec,
    catalogueBitDepth: catalogueBitDepth,
    catalogueSampleRate: catalogueSampleRate,
  );

  /// This track with [cover] as its artwork when it has none of its own.
  DiscoveryTrack withArtwork(String? cover) =>
      artwork != null || cover == null || cover.isEmpty
      ? this
      : DiscoveryTrack(
          id: id,
          title: title,
          artist: artist,
          source: source,
          duration: duration,
          album: album,
          sourceUrl: sourceUrl,
          addonBase: addonBase,
          addonId: addonId,
          sourceName: sourceName,
          inlineStream: inlineStream,
          artwork: cover,
          atmosAvailable: atmosAvailable,
          atmosRequested: atmosRequested,
          atmosDownload: atmosDownload,
          catalogueQuality: catalogueQuality,
          requestedQuality: requestedQuality,
          catalogueCodec: catalogueCodec,
          catalogueBitDepth: catalogueBitDepth,
          catalogueSampleRate: catalogueSampleRate,
        );

  String get key => '${source.name}:$addonId:$addonBase:$id${atmosRequested ? ':atmos' : ''}';
}

/// Safe to display: transport errors and remote response bodies never reach UI.
class DiscoveryException implements Exception {
  const DiscoveryException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A valid configured provider awaits its user verification. This is NOT
/// "track unavailable": autoplay must hold the current Mix item instead of
/// moving to the next recommendation.
class DiscoveryVerificationRequired extends DiscoveryException {
  const DiscoveryVerificationRequired(String provider)
      : super('$provider needs verification. Complete verification and retry this song.');
}

String discoveryError(Object error) => error is DiscoveryException
    ? error.message
    : 'The request could not be completed. Check your connection and try again.';

String? discoveryText(Object? value, {int maxLength = 500}) {
  if (value is! String || value.trim().isEmpty || value.length > maxLength) {
    return null;
  }
  return value.trim();
}

Uri requireHttps(String raw) {
  // Uri.parse normalizes dot segments, so reject them before that information
  // is lost. This also prevents surprising credential-bearing base rewrites.
  if (RegExp(
    r'/(?:\.|%2e){1,2}(?:/|$|[?#])',
    caseSensitive: false,
  ).hasMatch(raw)) {
    throw const DiscoveryException('The URL contains an unsafe path.');
  }
  final uri = Uri.tryParse(raw);
  if (raw.length > 8192 ||
      RegExp(r'[\x00-\x20\x7f\\]').hasMatch(raw) ||
      uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.port == 0) {
    throw const DiscoveryException(
      'Use an absolute HTTPS URL without user info or a fragment.',
    );
  }
  return uri;
}

Uri normalizeAddonEndpoint(String raw) {
  final uri = requireHttps(raw.trim());
  if (uri.hasQuery) {
    throw const DiscoveryException(
      'Put addon credentials in the token field, not URL query parameters.',
    );
  }
  final segments = uri.pathSegments.toList();
  while (segments.isNotEmpty && segments.last.isEmpty) {
    segments.removeLast();
  }
  if (segments.isNotEmpty && segments.last == 'manifest.json') {
    segments.removeLast();
  }
  if (segments.any((s) => s == '.' || s == '..' || s.contains('\\'))) {
    throw const DiscoveryException('The addon URL contains an unsafe path.');
  }
  return uri.replace(pathSegments: segments);
}

Duration? discoveryDuration(Object? seconds) {
  if (seconds is! num || !seconds.isFinite || seconds <= 0 || seconds > 86400) {
    return null;
  }
  return Duration(milliseconds: (seconds * 1000).round());
}
