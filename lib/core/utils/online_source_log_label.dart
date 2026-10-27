import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A source ID may contain an add-on URL or opaque account-scoped settings.
/// Keep public built-ins recognizable; correlate custom IDs without logging
/// their contents or allowing control characters into diagnostics.
String onlineSourceLogLabel(String id) {
  const publicIds = {
    'youtube',
    'youtube_audio',
    'ytmusic',
    'lastfm',
    'spotify',
    'monochrome',
    'soundcloud',
  };
  if (publicIds.contains(id)) return id;
  return 'custom:${sha256.convert(utf8.encode(id)).toString().substring(0, 12)}';
}
