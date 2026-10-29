// Actual host FFmpeg/FFprobe processes using the product's argument/parser
// contract. These generated fixtures are not bundled-iOS decoder acceptance.
import 'dart:convert';
import 'dart:io';

import 'package:flick/models/ios_transfer_import.dart';
import 'package:flick/services/ios_transfer_media.dart';

void require(bool value, String reason) {
  if (!value) throw StateError(reason);
}

Future<ProcessResult> command(String executable, List<String> args) async {
  final process = await Process.start(executable, args);
  try {
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    final exit = await process.exitCode.timeout(const Duration(seconds: 15));
    return ProcessResult(process.pid, exit, await output, await errors);
  } finally {
    process.kill();
  }
}

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('lokal-media-contracts-');
  HttpServer? server;
  try {
    Future<File> generate(String name, List<String> options) async {
      final file = File('${root.path}/$name');
      final result = await command('ffmpeg', [
        '-v',
        'error',
        '-nostdin',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:sample_rate=96000',
        '-t',
        '1.5',
        '-ac',
        '2',
        ...options,
        file.path,
      ]);
      require(
        result.exitCode == 0 && await file.length() > 0,
        'Generate actual audio fixture',
      );
      return file;
    }

    Future<IosTransferMediaInfo?> inspect(File file) async {
      final result = await command(
        'ffprobe',
        IosTransferMedia.arguments(file.path),
      );
      if (result.exitCode != 0) return null;
      try {
        return IosTransferMedia.parse(
          result.stdout as String,
          expectedBytes: await file.length(),
        );
      } on FormatException {
        return null;
      }
    }

    final wav = await generate("source '曲' .download", [
      '-c:a',
      'pcm_s24le',
      '-f',
      'wav',
    ]);
    final flac = await generate('lossless.download', [
      '-c:a',
      'flac',
      '-sample_fmt',
      's32',
      '-f',
      'flac',
    ]);
    final aac = await generate('lossy.download', [
      '-c:a',
      'aac',
      '-ar',
      '48000',
      '-f',
      'ipod',
    ]);
    final mp3 = await generate('mp3.download', [
      '-c:a',
      'libmp3lame',
      '-ar',
      '48000',
      '-f',
      'mp3',
    ]);
    final pcm = await inspect(wav),
        lossless = await inspect(flac),
        lossy = await inspect(aac),
        mpeg = await inspect(mp3);
    require(
      pcm?.codec == 'PCM_S24LE' &&
          pcm?.bitDepth == 24 &&
          pcm?.sampleRate == 96000 &&
          pcm?.channels == 2,
      'Real 24-bit PCM is recognized from bytes despite spaces, quotes, Unicode and .download suffix',
    );
    require(
      lossless?.codec == 'FLAC' && lossless?.bitDepth == 24,
      'Real lossless source depth survives',
    );
    require(
      lossy?.codec == 'AAC' &&
          lossy?.bitDepth == null &&
          lossy?.sampleRate == 48000,
      'Actual AAC decoded sample width is never encoded source bit depth',
    );
    require(
      mpeg?.codec == 'MP3' && mpeg?.bitDepth == null,
      'Actual MP3 has no invented source depth',
    );
    require(
      [pcm, lossless, lossy, mpeg].every(
        (m) => m != null && m.durationMs! >= 1400 && m.durationMs! < 1800,
      ),
      'Probe reports actual positive full-file duration after decoding a bounded first interval',
    );

    final multi = File('${root.path}/multiple-audio.download');
    final encoded = await command('ffmpeg', [
      '-v',
      'error',
      '-nostdin',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=220:sample_rate=32000',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=880:sample_rate=48000',
      '-map',
      '0:a',
      '-map',
      '1:a',
      '-t',
      '1.5',
      '-c:a',
      'aac',
      '-disposition:a:0',
      '0',
      '-disposition:a:1',
      'default',
      '-f',
      'ipod',
      multi.path,
    ]);
    require(
      encoded.exitCode == 0 && (await inspect(multi))?.sampleRate == 48000,
      'Actual default audio wins deterministically over the first alternate stream',
    );

    for (final entry in {
      'invalid.download': utf8.encode('These are not audio bytes.'),
      'header-only.download': (await wav.readAsBytes()).take(44).toList(),
      'empty.download': <int>[],
    }.entries) {
      final file = File('${root.path}/${entry.key}');
      await file.writeAsBytes(entry.value);
      require(
        await inspect(file) == null,
        'Invalid/empty/header-only media cannot become a playable receipt',
      );
    }
    final probe = await command(
      'ffprobe',
      IosTransferMedia.arguments(wav.path),
    );
    final bytes = await wav.length();
    try {
      IosTransferMedia.parse(probe.stdout as String, expectedBytes: bytes + 1);
      throw StateError('Changed source length was accepted');
    } on FormatException {
      /* Expected actual-byte mismatch. */
    }

    var requests = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      requests++;
      request.response.close();
    });
    final playlist = File('${root.path}/network-playlist.download');
    await playlist.writeAsString(
      '#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\n'
      'http://127.0.0.1:${server.port}/must-not-read.ts\n#EXT-X-ENDLIST\n',
    );
    require(
      await inspect(playlist) == null && requests == 0,
      'A retained playlist cannot make the local reader fetch its embedded URL',
    );
    for (final invalid in [
      'https://private.invalid/secret',
      '/private/../outside',
      '/private/secret\u0000',
    ]) {
      try {
        IosTransferMedia.arguments(invalid);
        throw StateError('Invalid source was accepted');
      } on FormatException {
        /* Expected fixed diagnostic. */
      }
    }
    try {
      IosTransferMedia.parse(
        '{"private":"sensitive-metadata",',
        expectedBytes: bytes,
      );
      throw StateError('Malformed probe output was accepted');
    } on FormatException catch (error) {
      require(
        !error.toString().contains('sensitive-metadata'),
        'Malformed output never leaks into diagnostics',
      );
    }
    // ignore: avoid_print
    print(
      'Actual host media contracts passed: PCM24, FLAC24, AAC, MP3, default audio selection, '
      'decoded frames, .download/Unicode paths, corrupt/header-only/empty media, '
      'changed byte length and zero embedded-playlist HTTP requests. Not bundled-iOS qualification.',
    );
  } finally {
    await server?.close(force: true);
    await root.delete(recursive: true);
  }
}
