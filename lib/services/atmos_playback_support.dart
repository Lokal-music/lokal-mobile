import 'package:flutter/services.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:flick/services/atmos_diagnostics.dart';
import 'package:flick/services/atmos_dec3_probe.dart';

/// Android's MediaExtractor can report the generic audio/eac3 MIME for an
/// E-AC-3 JOC track. In that case, independently inspect the *file* with
/// FFprobe (already bundled for Mornye) before deciding the provider sent
/// stereo. Never rely on the catalogue, filename or advertised quality.
class AtmosPlaybackSupport {
  AtmosPlaybackSupport._();

  static const _channel = MethodChannel('lokal/atmos');

  static Future<bool> get available async {
    try {
      final caps = await _channel.invokeMapMethod<String, dynamic>('capabilities');
      final available = caps?['available'] == true;
      AtmosDiagnostics.record('capability', {
        'available': available,
        'jocDecoder': caps?['jocDecoder'] == true,
        'passthrough': caps?['passthrough'] == true,
        if (caps?['sdk'] is int) 'sdk': caps!['sdk'] as int,
        'reason': available ? 'native_route_available' : 'native_route_unavailable',
      });
      return available;
    } on PlatformException catch (error) {
      AtmosDiagnostics.record('capability_error', {
        'errorClass': 'PlatformException',
        'errorCode': error.code,
      });
      return false;
    } on MissingPluginException {
      AtmosDiagnostics.record('capability_error', {
        'reason': 'missing_plugin',
      });
      return false;
    }
  }

  /// Only an E-AC-3 stream with an explicit JOC/Dolby Atmos profile counts.
  /// Plain E-AC-3, AAC, FLAC, marketing metadata and file extensions do not.
  static bool isJocProfile(Map<dynamic, dynamic> stream) {
    final codec = '${stream['codec_name'] ?? stream['codec'] ?? ''}'
        .trim().toLowerCase();
    if (codec != 'eac3' && codec != 'e-ac-3' && codec != 'ec-3' &&
        codec != 'eac3-joc') return false;
    final profile = '${stream['profile'] ?? ''}'.trim();
    return RegExp(r'(?:dolby[^\r\n]*atmos|\bjoc\b)', caseSensitive: false)
        .hasMatch(profile);
  }

  static String _codecCategory(List<Map<String, dynamic>> streams) {
    if (streams.isEmpty) return 'none';
    final audio = streams.where((entry) =>
        '${entry['codec_type'] ?? 'audio'}'.toLowerCase() == 'audio');
    if (audio.isEmpty) return 'none';
    final raw = '${audio.first['codec_name'] ?? ''}'.toLowerCase();
    if ({'eac3', 'e-ac-3', 'ec-3', 'eac3-joc'}.contains(raw)) return 'eac3';
    if (raw == 'flac') return 'flac';
    if (raw == 'aac') return 'aac';
    if (raw == 'alac') return 'alac';
    return 'other';
  }

  static Future<List<Map<String, dynamic>>> _probeStreams(String path) async {
    // No transcoding or bitstream rewrite: only metadata inspection.
    final session = await FFprobeKit.getMediaInformation(path, 12000);
    final info = await session.getMediaInformation();
    return [
      for (final stream in info?.getStreams() ?? const [])
        if (stream.getAllProperties() case final props?)
          Map<String, dynamic>.from(props),
    ];
  }

  /// Confirm an AC-4 *codec* from the delivered file. This is not proof of
  /// Dolby Atmos presentation and does not establish native iPhone decoding.
  static Future<bool> isAc4File(
    String path, {
    Future<List<Map<String, dynamic>>> Function(String path)? probeStreams,
  }) async {
    try {
      final streams = await (probeStreams ?? _probeStreams)(path);
      final encoded = streams.any((entry) =>
          '${entry['codec_type'] ?? 'audio'}'.toLowerCase() == 'audio' &&
          '${entry['codec_name'] ?? entry['codec'] ?? ''}'
                  .trim().toLowerCase().replaceAll('-', '') == 'ac4');
      AtmosDiagnostics.record('source_probe', {
        'encoded': encoded,
        'codec': encoded ? 'ac4' : 'unverified',
        'source': 'ffprobe',
        'outcome': encoded ? 'codec_confirmed' : 'not_confirmed',
      });
      return encoded;
    } catch (error) {
      AtmosDiagnostics.record('ffprobe_error', {
        'errorClass': error.runtimeType.toString(),
        'reason': 'ac4_probe_unavailable',
      });
      return false;
    }
  }

  /// Verify staged audio, not the catalogue. Android can expose generic
  /// audio/eac3, while FFprobe can omit the JOC extension in its profile.
  /// Read the EC3SpecificBox as a final source-level verification.
  static Future<bool> isJocFile(
    String path, {
    Future<List<Map<String, dynamic>>> Function(String path)? probeStreams,
    Future<AtmosBoxProbe> Function(String path)? probeDec3,
  }) async {
    var native = false;
    try {
      native = await _channel.invokeMethod<bool>('inspect', {'path': path}) == true;
    } on PlatformException catch (error) {
      AtmosDiagnostics.record('native_probe_error', {
        'errorClass': 'PlatformException', 'errorCode': error.code,
      });
    } on MissingPluginException {
      AtmosDiagnostics.record('native_probe_error', {'reason': 'missing_plugin'});
    }
    AtmosDiagnostics.record('native_probe', {
      'encoded': native,
      'outcome': native ? 'confirmed' : 'not_confirmed',
    });
    if (native) {
      AtmosDiagnostics.record('source_probe', {
        'encoded': true, 'codec': 'eac3_joc', 'source': 'android',
        'outcome': 'confirmed',
      });
      return true;
    }

    var ffprobeVerified = false;
    var ffprobeCodec = 'unverified';
    try {
      final streams = await (probeStreams ?? _probeStreams)(path);
      final audio = streams.where((entry) =>
          '${entry['codec_type'] ?? 'audio'}'.toLowerCase() == 'audio');
      ffprobeVerified = audio.any(isJocProfile);
      ffprobeCodec = _codecCategory(streams);
      AtmosDiagnostics.record('ffprobe_result', {
        'codec': ffprobeCodec,
        'trackCount': streams.length,
        'encoded': ffprobeVerified,
        'outcome': ffprobeVerified ? 'confirmed' : 'not_confirmed',
      });
    } catch (error) {
      AtmosDiagnostics.record('ffprobe_error', {
        'errorClass': error.runtimeType.toString(),
        'reason': 'probe_unavailable',
      });
    }
    if (ffprobeVerified) {
      AtmosDiagnostics.record('source_probe', {
        'encoded': true, 'codec': 'eac3_joc', 'source': 'ffprobe',
        'outcome': 'confirmed',
      });
      return true;
    }

    // FFprobe codec_name=eac3 without a JOC profile is inconclusive.
    // Dolby's MP4 EC3SpecificBox carries an independent object-extension flag.
    AtmosBoxProbe dec3;
    try {
      dec3 = await (probeDec3 ?? inspectAtmosDec3)(path);
    } catch (error) {
      dec3 = const AtmosBoxProbe(verified: false, reason: 'probe_unavailable');
      AtmosDiagnostics.record('dec3_probe_error', {
        'errorClass': error.runtimeType.toString(),
      });
    }
    AtmosDiagnostics.record('dec3_probe', {
      'encoded': dec3.verified,
      'codec': dec3.ec3SampleEntry ? 'eac3' : ffprobeCodec,
      'reason': dec3.reason,
      'outcome': dec3.verified ? 'confirmed' : 'not_confirmed',
    });
    AtmosDiagnostics.record('source_probe', {
      'encoded': dec3.verified,
      'codec': dec3.verified ? 'eac3_joc' : ffprobeCodec,
      'source': 'dec3',
      'outcome': dec3.verified ? 'confirmed' : 'not_confirmed',
    });
    return dec3.verified;
  }
}
