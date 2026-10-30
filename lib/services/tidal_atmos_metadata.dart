/// Catalogue evidence is per recording. Bare AC-4/E-AC-3 codecs, globally
/// requestable addon tiers, and another track's metadata are not proof of
/// Dolby Atmos availability.
String? morneyeExplicitAtmosMode(Map<dynamic, dynamic> track) {
  final modes = <String>{};
  void collect(Object? value) {
    if (value is List) {
      for (final item in value) {
        collect(item);
      }
      return;
    }
    if (value is! String) return;
    for (final part in value.split(RegExp(r'[,;|]'))) {
      final mode = part.trim().toUpperCase()
          .replaceAll(RegExp(r'[ -]'), '_');
      if (const {'DOLBY_ATMOS', 'ATMOS', 'EAC3_JOC', 'E_AC_3_JOC',
        'AC4_ATMOS', 'AC_4_ATMOS'}.contains(mode)) {
        modes.add(mode);
      }
    }
  }

  for (final key in const [
    'audio_mode', 'audioMode', 'audio_quality', 'audioQuality',
    'spatial_audio', 'spatialAudio', 'audio_modes', 'audioModes',
    'audioQualities', 'audio_qualities',
  ]) {
    collect(track[key]);
  }
  // Prefer an explicitly named rendition when multiple catalogue modes
  // exist, so playback can request the matching format rather than guessing.
  if (modes.contains('AC4_ATMOS') || modes.contains('AC_4_ATMOS')) {
    return 'AC4_ATMOS';
  }
  if (modes.contains('EAC3_JOC') || modes.contains('E_AC_3_JOC')) {
    return 'EAC3_JOC';
  }
  if (modes.contains('DOLBY_ATMOS') || modes.contains('ATMOS')) {
    return 'DOLBY_ATMOS';
  }
  return null;
}

/// Explicit track-level catalogue availability; not active playback status.
bool tidalAtmosAvailable(Map<dynamic, dynamic> track) =>
    morneyeExplicitAtmosMode(track) != null;

/// An explicit Amazon-specific presentation is needed to select a matching
/// codec. Generic ATMOS flags do not establish which codec is available.
String? morneyeAmazonAtmosCodec(Map<dynamic, dynamic> track) =>
    switch (morneyeExplicitAtmosMode(track)) {
      'AC4_ATMOS' => 'ac4',
      'EAC3_JOC' => 'eac3-joc',
      _ => null,
    };
