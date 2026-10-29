/// Tidal catalogues Dolby Atmos as an audio *mode*, independently of the
/// stereo stream quality. Explicit metadata only: do not infer from FLAC,
/// sample rate, bitrate, multichannel PCM or an audio decoder's capabilities.
bool tidalAtmosAvailable(Map<dynamic, dynamic> track) {
  bool isMode(Object? value) {
    if (value is! String) return false;
    // Amazon's metadata sometimes combines modes in one comma-separated string.
    // AC-4 alone is a codec, not proof that the track advertises Atmos.
    return value.split(RegExp(r'[,;|]')).any((part) {
      final mode = part.trim().toUpperCase().replaceAll(RegExp(r'[ -]'), '_');
      return mode == 'DOLBY_ATMOS' || mode == 'ATMOS';
    });
  }

  for (final key in const [
    'audio_mode', 'audioMode', 'audio_quality', 'audioQuality',
    'spatial_audio', 'spatialAudio', 'audio_modes', 'audioModes',
  ]) {
    if (isMode(track[key])) return true;
  }
  for (final key in const ['audio_modes', 'audioModes']) {
    final modes = track[key];
    if (modes is List && modes.any(isMode)) return true;
  }
  // The official Amazon Music catalogue API returns an explicit
  // per-track audioQualities array (SD/HD/UHD/ATMOS/360RA). These are
  // authoritative *catalogue* modes, unlike the Mornye addon's global
  // qualityOptions, or a codec string ("ac4", "eac3").
  // Some adapters use snake_case; never derive availability from a
  // neighbouring song, matching ISRC in another catalogue, or the addon.
  for (final key in const ['audioQualities', 'audio_qualities']) {
    final qualities = track[key];
    if (qualities is List && qualities.any(isMode)) return true;
    if (isMode(qualities)) return true;
  }
  return false;
}
