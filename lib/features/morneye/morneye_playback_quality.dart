/// Playback capability checks must not block a file-only Save operation.
/// A valid encoded source may be preserved on disk even on an iPhone which
/// cannot decode it for native playback.
bool morneyeNeedsSpatialPlaybackOutput({
  required bool spatialRequested,
  required bool forDownload,
  required bool atmosDownload,
}) => spatialRequested && !forDownload && !atmosDownload;

/// A codec/quality identifier is not catalogue evidence of Dolby Atmos.
/// Selecting an encoded Atmos tier in an add-on's settings is a playback
/// preference, not evidence that a particular song has an Atmos edition.
bool isMorneyeAtmosQuality(String? value) => RegExp(
  r'^(?:DOLBY[_ -]?ATMOS|ATMOS|AC-?4)$',
  caseSensitive: false,
).hasMatch(value?.trim() ?? '');

/// The Amazon extension also exposes E-AC-3 as a spatial tier, but E-AC-3
/// alone is NOT Atmos. Do not invent catalogue tags from either option.
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

  // The add-on's selected quality is the playback preference, not just a
  // download preference. Always request its exact manifest tier first,
  // including AC-4/JOC when selected. Selection is not proof of availability.
  if (configured != null && configured.isNotEmpty) {
    for (final option in options) {
      if (option is Map && option['id']?.toString() == configured) {
        return configured;
      }
    }
  }

  final candidates = <String>[];
  for (final option in options) {
    if (option is! Map || morneyeSpatialOption(option, provider: provider)) {
      continue;
    }
    final id = option['id']?.toString() ?? '';
    if (id.isNotEmpty) candidates.add(id);
  }

  // Without an explicit selection, prefer the highest documented stereo
  // quality. Never infer an Atmos capability from the add-on manifest alone.
  for (final tier in const ['HI_RES_LOSSLESS', 'LOSSLESS']) {
    for (final id in candidates) {
      if (id.toUpperCase() == tier) return id;
    }
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
  if (candidates.isNotEmpty) return candidates.first;
  // Preserve Tidal's stereo fallback when an absent Atmos tier was saved.
  if (isMorneyeAtmosQuality(configured) &&
      provider.toLowerCase().startsWith('tidal')) {
    return 'HI_RES_LOSSLESS';
  }
  return 'default';
}

/// Play and Save both honor the selected add-on tier. Neither a manifest
/// option nor a configured quality proves that a particular track has it.
String resolveMorneyeRequestQuality({
  required bool forPlayback,
  required String? requested,
  required String? configured,
  required List<dynamic> options,
  required String provider,
}) {
  // The user's explicitly chosen tier is authoritative for playback and
  // downloads; an explicit one-off request overrides that preference.
  return chooseMorneyeDownloadQuality(
    requested: requested,
    configured: configured,
    options: options,
    provider: provider,
  );
}

/// An explicit per-song Atmos action overrides the configured quality.
String? explicitMorneyePlaybackTier({
  required bool atmosRequested,
  String? provider,
  String? atmosCodec,
}) => !atmosRequested
    ? null
    : (provider?.toLowerCase().startsWith('amazon') == true
          // A track explicitly advertised as E-AC-3 JOC must never
          // accidentally request the unrelated AC-4 presentation.
          ? (atmosCodec == 'eac3-joc' ? 'eac3' : 'ac4')
          : 'DOLBY_ATMOS');

/// Amazon's search rows usually omit per-track codec and available audio
/// modes. Show the *normal playback tier we will request*, never a fabricated
/// per-track FLAC/AC-4 guarantee. A spatial selection is not a search tag.
String? amazonRequestedPlaybackQualityLabel({
  required String? configured,
  required List<dynamic> options,
}) {
  if (options.isEmpty) return null;
  final selected = chooseMorneyeDownloadQuality(
    requested: null,
    configured: configured,
    options: options,
    provider: 'amazon',
  );
  for (final option in options) {
    if (option is! Map ||
        option['id']?.toString().toLowerCase() != selected.toLowerCase() ||
        morneyeSpatialOption(option, provider: 'amazon')) continue;
    final label = option['label']?.toString().trim() ?? '';
    if (selected.toLowerCase() == 'best') return 'FLAC best (requested)';
    if (label.isNotEmpty) return '$label (requested)';
    return '$selected (requested)';
  }
  return null;
}

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
