/// A codec/quality identifier is not catalogue evidence of Dolby Atmos.
/// Atmos playback requires an explicit user action; ordinary playback must
/// always choose a stereo or lossless tier from the installed addon manifest.
bool isMorneyeAtmosQuality(String? value) => RegExp(
  r'^(?:DOLBY[_ -]?ATMOS|ATMOS|AC-?4)$',
  caseSensitive: false,
).hasMatch(value?.trim() ?? '');

/// The Amazon extension also exposes E-AC-3 as a spatial tier, but E-AC-3
/// alone is NOT Atmos. Never inherit either spatial option for normal play.
bool morneyeSpatialOption(Map option, {String? provider}) =>
    option['kind']?.toString().toLowerCase() == 'spatial' ||
    (provider?.toLowerCase().startsWith('amazon') == true &&
        option['id']?.toString().trim().toLowerCase() == 'eac3') ||
    isMorneyeAtmosQuality(option['id']?.toString()) ||
    isMorneyeAtmosQuality(option['name']?.toString()) ||
    isMorneyeAtmosQuality(option['label']?.toString());

String chooseMorneyeDownloadQuality({
  required String? requested,
  required String? configured,
  required List<dynamic> options,
  required String provider,
}) {
  // Explicit user choice is validated against the installed manifest by the
  // download call. In particular, the Amazon Atmos action requests 'ac4'.
  if (requested != null && requested.isNotEmpty) return requested;

  final configuredSpatial =
      morneyeSpatialOption({'id': configured}, provider: provider) ||
      options.any(
        (option) =>
            option is Map &&
            option['id']?.toString().toLowerCase() ==
                configured?.toLowerCase() &&
            morneyeSpatialOption(option, provider: provider),
      );
  if (configured != null && configured.isNotEmpty && !configuredSpatial) {
    return configured;
  }

  final candidates = <String>[];
  for (final option in options) {
    if (option is! Map || morneyeSpatialOption(option, provider: provider)) {
      continue;
    }
    final id = option['id']?.toString() ?? '';
    if (id.isNotEmpty) candidates.add(id);
  }

  // A configured spatial tier should prefer the best offered stereo option.
  if (configuredSpatial) {
    for (final tier in ['HI_RES_LOSSLESS', 'LOSSLESS', 'HIGH', 'BEST']) {
      for (final id in candidates) {
        if (id.toUpperCase() == tier) return id;
      }
    }
    if (candidates.isNotEmpty) return candidates.first;
    return provider.toLowerCase().startsWith('tidal')
        ? 'HI_RES_LOSSLESS'
        : 'default';
  }

  for (final option in options) {
    if (option is! Map || morneyeSpatialOption(option, provider: provider)) {
      continue;
    }
    if (option['kind'] == 'lossless') {
      final id = option['id']?.toString() ?? '';
      if (id.isNotEmpty) return id;
    }
  }
  return candidates.isNotEmpty ? candidates.first : 'default';
}

/// Saving can intentionally keep an addon-specific user setting. Regular
/// playback never inherits an Atmos-only download preference.
String resolveMorneyeRequestQuality({
  required bool forPlayback,
  required String? requested,
  required String? configured,
  required List<dynamic> options,
  required String provider,
}) {
  if (!forPlayback &&
      requested == null &&
      configured != null &&
      configured.isNotEmpty) {
    return configured;
  }
  return chooseMorneyeDownloadQuality(
    requested: requested,
    configured: configured,
    options: options,
    provider: provider,
  );
}

/// Only an explicit Atmos action changes the ordinary requested quality.
String? explicitMorneyePlaybackTier({
  required bool atmosRequested,
  String? provider,
}) => !atmosRequested
    ? null
    : (provider?.toLowerCase().startsWith('amazon') == true
          ? 'ac4'
          : 'DOLBY_ATMOS');

/// The catalogue can advertise a different maximum tier from the requested
/// stereo playback quality. Do not misrepresent either as verified audio.
String? tidalRequestedQualityLabel({
  required String? configured,
  required List<dynamic> options,
}) {
  if (options.isEmpty) return null;
  final chosen = chooseMorneyeDownloadQuality(
    requested: null,
    configured: configured,
    options: options,
    provider: 'tidal',
  );
  for (final option in options) {
    if (option is! Map ||
        option['id']?.toString().toLowerCase() != chosen.toLowerCase()) {
      continue;
    }
    final label = option['label']?.toString().trim() ?? '';
    final name = option['name']?.toString().trim() ?? '';
    final title = label.isNotEmpty ? label : (name.isNotEmpty ? name : chosen);
    return '$title (requested)';
  }
  return null;
}
