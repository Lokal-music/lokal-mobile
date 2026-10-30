/// Normal Morneye playback must never inherit a native Atmos-only download
/// preference. Only an explicit Play/Download Atmos request may ask an add-on
/// for `DOLBY_ATMOS`. Keep the other configured quality tiers unchanged.
bool isMorneyeAtmosQuality(String? value) => RegExp(
  r'^(?:DOLBY[_ -]?ATMOS|ATMOS)$',
  caseSensitive: false,
).hasMatch(value?.trim() ?? '');

/// Amazon's AC-4 and plain E-AC-3 download tiers must not leak into ordinary
/// stereo playback. This classification does not advertise an iPhone decoder
/// or infer Atmos from a codec. Explicit native AC-4 actions remain excluded.
bool morneyeSpatialOption(Map option, {required String provider}) =>
    option['kind']?.toString().toLowerCase() == 'spatial' ||
    (provider.toLowerCase().startsWith('amazon') &&
        {
          'ac4',
          'ac-4',
          'eac3',
        }.contains(option['id']?.toString().trim().toLowerCase())) ||
    isMorneyeAtmosQuality(option['id']?.toString()) ||
    isMorneyeAtmosQuality(option['kind']?.toString()) ||
    isMorneyeAtmosQuality(option['name']?.toString()) ||
    isMorneyeAtmosQuality(option['label']?.toString());

String chooseMorneyeDownloadQuality({
  required String? requested,
  required String? configured,
  required List<dynamic> options,
  required String provider,
}) {
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
    if (option is! Map) continue;
    final id = option['id']?.toString() ?? '';
    if (id.isEmpty || morneyeSpatialOption(option, provider: provider)) {
      continue;
    }
    candidates.add(id);
  }
  if (configuredSpatial) {
    for (final tier in ['HI_RES_LOSSLESS', 'LOSSLESS', 'BEST', 'HIGH']) {
      for (final id in candidates) {
        if (id.toUpperCase() == tier) return id;
      }
    }
    if (candidates.isNotEmpty) return candidates.first;
    // Tidal normally supports HI_RES_LOSSLESS; do not substitute Atmos
    // merely because an extension did not publish qualityOptions.
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
      if (id.isNotEmpty && !isMorneyeAtmosQuality(id)) return id;
    }
  }
  return candidates.isNotEmpty ? candidates.first : 'default';
}

/// Saving a file may intentionally use the configured Atmos tier; playback
/// must not inherit it. Keeping this distinction explicit also prevents
/// quality leakage to another track from the same add-on.
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

/// Requesting the best catalogue edition because Atmos happens to be
/// advertised overrides the user's HIGH/LOW setting. Only an explicit Atmos
/// play command may force a tier. Normal playback passes null so the addon
/// receives its configured downloadQuality.
String? explicitMorneyePlaybackTier({required bool atmosRequested}) =>
    atmosRequested ? 'DOLBY_ATMOS' : null;

/// The quality tier sent to a Tidal add-on for normal stereo playback.
/// Unlike the catalogue maximum, this is a request, not proof of the bytes
/// delivered. Search can show it even when individual tracks omit quality.
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
  // Never invent a label for a tier missing from the installed manifest.
  return null;
}
