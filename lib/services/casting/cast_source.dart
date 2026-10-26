import 'dart:io';

/// The default receiver cannot inherit the sender's Authorization/Cookie
/// headers. Such sources must use an authorized app-owned copy instead.
String? receiverDirectUrl(
  String? value, {
  Map<String, String> headers = const {},
}) {
  if (value == null || headers.isNotEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.host.toLowerCase() == 'localhost') {
    return null;
  }
  final address = InternetAddress.tryParse(uri.host);
  if (address?.isLoopback == true ||
      (address != null && address.rawAddress.every((byte) => byte == 0))) {
    return null;
  }
  return value;
}

String castAudioContentType(String url, String fileType) {
  const types = {
    'mp3': 'audio/mpeg',
    'flac': 'audio/flac',
    'wav': 'audio/wav',
    'ogg': 'audio/ogg',
    'oga': 'audio/ogg',
    'opus': 'audio/ogg',
    'm4a': 'audio/mp4',
    'mp4': 'audio/mp4',
    'alac': 'audio/mp4',
    'aac': 'audio/aac',
    'aiff': 'audio/aiff',
    'aif': 'audio/aiff',
    'wv': 'audio/x-wavpack',
    'm3u8': 'application/vnd.apple.mpegurl',
    'mpd': 'application/dash+xml',
  };
  final path = Uri.tryParse(url)?.path ?? '';
  final extension = path.contains('.')
      ? path.split('.').last.toLowerCase()
      : '';
  return types[extension] ?? types[fileType.toLowerCase()] ?? 'audio/*';
}
