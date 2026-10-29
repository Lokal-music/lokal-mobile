import 'dart:convert';

import '../models/ios_transfer_import.dart';

enum IosTransferMediaFailure { invalid, retired, timeout, unavailable }

class IosTransferMediaException implements Exception {
  const IosTransferMediaException(this.reason);
  final IosTransferMediaFailure reason;
  @override
  String toString() => 'iPhone media verification ${reason.name}.';
}

/// Shared by the bundled FFprobe adapter and actual-process host contracts.
/// A staged .download suffix and desktop quality claims are never media proof.
class IosTransferMedia {
  IosTransferMedia._();
  static const maximumOutputBytes = 128 * 1024;
  static const formats = <String>{
    'wav',
    'flac',
    'mp3',
    'aac',
    'mov',
    'ogg',
    'aiff',
    'ape',
    'wv',
    'tta',
    'asf',
    'amr',
    'ac3',
    'eac3',
    'dts',
    'dsf',
    'dsdiff',
    'loas',
    'mpc',
    'mpc8',
  };

  static List<String> arguments(String path) {
    if (!path.startsWith('/') ||
        path.contains('\u0000') ||
        path.split('/').any((part) => part == '.' || part == '..') ||
        utf8.encode(path).length > 4096) {
      throw const FormatException('Invalid native media source.');
    }
    return [
      '-v', 'quiet', '-hide_banner',
      '-protocol_whitelist', 'file',
      '-format_whitelist', formats.join(','),
      '-probesize', '8388608', '-analyzeduration', '10000000',
      '-max_probe_packets', '2500', '-max_streams', '32',
      // MOV external references stay disabled, including local absolute paths.
      '-enable_drefs', '0', '-use_absolute_path', '0',
      '-select_streams', 'a', '-count_frames', '-read_intervals', '%+1',
      '-show_entries',
      'format=format_name,duration,size,bit_rate:'
          'stream=index,codec_type,codec_name,duration,sample_rate,channels,'
          'bits_per_sample,bits_per_raw_sample,bit_rate,nb_read_frames:'
          'stream_disposition=default',
      '-of', 'json', '-i', path,
    ];
  }

  static Never _invalid() => throw const FormatException(
    'The transferred audio could not be verified.',
  );

  static int? _integer(Object? value) {
    if (value is int) return value;
    if (value is String && RegExp(r'^\d{1,19}$').hasMatch(value)) {
      return int.tryParse(value);
    }
    return null;
  }

  static int? _duration(Object? value) {
    if (value is! String && value is! num) return null;
    final seconds = double.tryParse('$value');
    if (seconds == null ||
        !seconds.isFinite ||
        seconds <= 0 ||
        seconds > 365 * 24 * 60 * 60) {
      return null;
    }
    return (seconds * 1000).round();
  }

  static IosTransferMediaInfo parse(
    String output, {
    required int expectedBytes,
  }) {
    if (expectedBytes < 1 ||
        expectedBytes > 8 * 1024 * 1024 * 1024 ||
        output.length > maximumOutputBytes ||
        utf8.encode(output).length > maximumOutputBytes) {
      _invalid();
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(output);
    } on FormatException {
      // Do not quote sandbox paths, tags or native output in error messages.
      _invalid();
    }
    if (decoded is! Map) _invalid();
    final format = decoded['format'];
    final streams = decoded['streams'];
    if (format is! Map ||
        streams is! List ||
        streams.isEmpty ||
        streams.length > 32 ||
        format['format_name'] is! String ||
        !(format['format_name'] as String).split(',').any(formats.contains) ||
        _integer(format['size']) != expectedBytes) {
      _invalid();
    }
    final audio = <Map>[];
    final indexes = <int>{};
    for (final stream in streams) {
      if (stream is! Map || stream['codec_type'] != 'audio') _invalid();
      final index = _integer(stream['index']);
      if (index == null || index < 0 || index > 31 || !indexes.add(index)) {
        _invalid();
      }
      audio.add(stream);
    }
    int priority(Map stream) =>
        stream['disposition'] is Map &&
            (stream['disposition'] as Map)['default'] == 1
        ? 0
        : 1;
    audio.sort((left, right) {
      final defaultOrder = priority(left).compareTo(priority(right));
      return defaultOrder != 0
          ? defaultOrder
          : _integer(left['index'])!.compareTo(_integer(right['index'])!);
    });
    final stream = audio.first;
    final codec = stream['codec_name'];
    final duration =
        _duration(stream['duration']) ?? _duration(format['duration']);
    final rate = _integer(stream['sample_rate']);
    final channels = _integer(stream['channels']);
    if (codec is! String ||
        !RegExp(r'^[a-z0-9_]{1,16}$').hasMatch(codec) ||
        codec == 'unknown' ||
        duration == null ||
        rate == null ||
        channels == null ||
        (_integer(stream['nb_read_frames']) ?? 0) < 1) {
      _invalid();
    }
    // A lossy decoder's float/s32 sample width is not the encoded source depth.
    final lossless =
        codec.startsWith('pcm_') ||
        {'flac', 'alac', 'wavpack', 'ape', 'tta'}.contains(codec);
    int? depth;
    if (codec.startsWith('dsd_')) {
      depth = 1;
    } else if (lossless) {
      final raw = _integer(stream['bits_per_raw_sample']);
      final stored = _integer(stream['bits_per_sample']);
      depth = raw != null && raw > 0
          ? raw
          : stored != null && stored > 0
          ? stored
          : null;
    }
    final bitsPerSecond =
        _integer(stream['bit_rate']) ?? _integer(format['bit_rate']);
    final demuxer = (format['format_name'] as String)
        .split(',')
        .firstWhere(formats.contains);
    final fileType = switch (demuxer) {
      'mov' => 'M4A',
      'ogg' when codec == 'opus' => 'OPUS',
      'dsdiff' => 'DFF',
      'loas' => 'AAC',
      'mpc8' => 'MPC',
      _ => demuxer.toUpperCase(),
    };
    final media = IosTransferMediaInfo(
      recognized: true,
      codec: codec.toUpperCase(),
      format: fileType,
      durationMs: duration,
      sampleRate: rate,
      channels: channels,
      bitDepth: depth,
      bitrate: bitsPerSecond != null && bitsPerSecond >= 1000
          ? (bitsPerSecond / 1000).round()
          : null,
    );
    media.validate();
    return media;
  }
}
