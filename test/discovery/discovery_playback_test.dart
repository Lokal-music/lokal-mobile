import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flick/features/discovery/discovery_http.dart';
import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flick/features/discovery/discovery_playback.dart';
import 'package:flick/features/discovery/discovery_sources.dart';
import 'package:flick/src/rust/api/audio_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;

// Header fixtures exercise staging; native probing is injected here, not faked
// in production. Hardware/decoder integration is explicitly a separate check.
final flacHeader = [...ascii.encode('fLaC'), ...List.filled(48, 0)];
final fixtureTrack = DiscoveryTrack(
  id: 'recording-1',
  title: 'Fixture recording',
  artist: 'Fixture artist',
  duration: const Duration(seconds: 60),
  source: DiscoverySource.addon,
  addonBase: Uri.parse('https://addon.example'),
  sourceUrl: Uri.parse('https://catalog.example/recording-1'),
);
final fixtureAudio = ResolvedDiscoveryAudio(
  Uri.parse('https://media.example/file.mp3?secret=signed'),
);

void main() {
  late Directory directory;
  setUp(
    () async =>
        directory = await Directory.systemTemp.createTemp('discovery_test_'),
  );
  tearDown(() async => directory.delete(recursive: true));

  test(
    'downloads without credentials, probes bytes and builds a real local Song',
    () async {
      final client = MockClient((request) async {
        expect(request.url, fixtureAudio.url);
        expect(
          request.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('authorization')),
        );
        expect(request.followRedirects, isFalse);
        return http.Response.bytes(flacHeader, 200);
      });
      addTearDown(client.close);
      var probes = 0;
      final cache = DiscoveryPlaybackCache(
        http: DiscoveryHttp(client),
        directory: () async => directory,
        probe: (path) async {
          probes++;
          expect(
            p.extension(path),
            '.flac',
          ); // URL's MP3 suffix is not trusted.
          expect(await File(path).readAsBytes(), flacHeader);
          return const AudioProbeFormat(
            sampleRate: 44100,
            channels: 2,
            bitsPerSample: 16,
          );
        },
      );
      final song = await cache.prepare(fixtureTrack, fixtureAudio);
      expect(probes, 1);
      expect(song.fileType, 'FLAC');
      expect(song.sampleRate, 44100);
      expect(song.bitDepth, 16);
      expect(song.resolution, isNull);
      expect(song.filePath, startsWith(directory.path));
      expect(song.filePath, isNot(contains('secret')));
      expect(song.remoteId, fixtureTrack.sourceUrl.toString());
      expect(
        song.isNetworkSource,
        isFalse,
      ); // No unsupported RemoteSourceService route.
      expect(await File(song.filePath!).exists(), isTrue);
    },
  );

  test(
    'an add-on\'s finished file moves into the cache and is probed',
    () async {
      final source = File(p.join(directory.path, 'work', 'audio.flac'));
      await source.create(recursive: true);
      await source.writeAsBytes(flacHeader);
      final cacheDir = Directory(p.join(directory.path, 'cache'));
      final cache = DiscoveryPlaybackCache(
        http: DiscoveryHttp(MockClient((_) async => fail('no network'))),
        directory: () async => cacheDir,
        probe: (path) async => const AudioProbeFormat(
          sampleRate: 96000,
          channels: 2,
          bitsPerSample: 24,
        ),
      );
      final song = await cache.adopt(fixtureTrack, source);
      expect(song.fileType, 'FLAC');
      expect(song.bitDepth, 24);
      expect(song.filePath, startsWith(cacheDir.path));
      expect(await source.exists(), isFalse);
    },
  );

  test('fast Morneye playback reuses verified download metadata without waiting for artwork', () async {
    final source = File(p.join(directory.path, 'work', 'audio.flac'));
    await source.create(recursive: true);
    await source.writeAsBytes(flacHeader);
    final coverReply = Completer<http.Response>();
    var probes = 0;
    final cache = DiscoveryPlaybackCache(
      http: DiscoveryHttp(MockClient((_) => coverReply.future)),
      directory: () async => Directory(p.join(directory.path, 'cache')),
      probe: (_) async {
        probes++;
        throw StateError('the already-verified Morneye file was reprobed');
      },
    );
    final song = await cache
        .adopt(
          fixtureTrack.withArtwork('https://img.example/cover.jpg'),
          source,
          fastPlayback: true,
          sourceInfo: const {
            'codec': 'flac',
            'format': 'flac',
            'sample_rate': 44100,
            'channels': 2,
            'bit_depth': 16,
          },
        )
        .timeout(const Duration(seconds: 1));
    expect(probes, 0);
    expect(song.sampleRate, 44100);
    expect(song.bitDepth, 16);
    expect(song.albumArt, 'https://img.example/cover.jpg');
    coverReply.complete(http.Response('', 404));
  });

  test('the cover is kept next to the song and played with it', () async {
    final source = File(p.join(directory.path, 'work', 'audio.flac'));
    await source.create(recursive: true);
    await source.writeAsBytes(flacHeader);
    final cacheDir = Directory(p.join(directory.path, 'cache'));
    final cover = image.encodeJpg(image.Image(width: 512, height: 512));
    final cache = DiscoveryPlaybackCache(
      http: DiscoveryHttp(
        MockClient((request) async {
          expect(request.url.toString(), 'https://img.example/cover.jpg');
          return http.Response.bytes(cover, 200);
        }),
      ),
      directory: () async => cacheDir,
      probe: (_) async =>
          const AudioProbeFormat(sampleRate: 44100, channels: 2),
    );
    final song = await cache.adopt(
      fixtureTrack.withArtwork('https://img.example/cover.jpg'),
      source,
    );
    expect(song.albumArt, DiscoveryPlaybackCache.coverPath(song.filePath!));
    expect(await File(song.albumArt!).readAsBytes(), cover);
  });

  test('missing high-res rendition returning HTTP 200 does not defeat a better original', () async {
    final source = File(p.join(directory.path, 'audio.flac'))
      ..writeAsBytesSync(flacHeader);
    final cacheDir = Directory(p.join(directory.path, 'cache'));
    final tiny = image.encodeJpg(image.Image(width: 120, height: 120));
    final larger = image.encodeJpg(image.Image(width: 640, height: 640));
    final requests = <String>[];
    final cache = DiscoveryPlaybackCache(
      http: DiscoveryHttp(
        MockClient((request) async {
          requests.add(request.url.toString());
          return http.Response.bytes(
            request.url.toString().contains('w1200-h1200') ? tiny : larger,
            200,
          );
        }),
      ),
      directory: () async => cacheDir,
      probe: (_) async =>
          const AudioProbeFormat(sampleRate: 44100, channels: 2),
    );
    final song = await cache.adopt(
      fixtureTrack.withArtwork(
        'https://lh3.googleusercontent.com/album=w120-h120',
      ),
      source,
    );
    expect(requests.length, 2);
    expect(song.albumArt, isNotNull);
    final result = image.decodeImage(await File(song.albumArt!).readAsBytes());
    expect(result!.width, 640);
    expect(result.height, 640);
  });

  test('an invalid cover response is not embedded or cached', () async {
    final source = File(p.join(directory.path, 'invalid-audio.flac'))
      ..writeAsBytesSync(flacHeader);
    final cache = DiscoveryPlaybackCache(
      http: DiscoveryHttp(
        MockClient(
          (_) async => http.Response.bytes([0xff, 0xd8, 0xff, 0x00], 200),
        ),
      ),
      directory: () async => Directory(p.join(directory.path, 'cache')),
      probe: (_) async =>
          const AudioProbeFormat(sampleRate: 44100, channels: 2),
    );
    final song = await cache.adopt(
      fixtureTrack.withArtwork('https://img.example/invalid.jpg'),
      source,
    );
    expect(song.albumArt, isNull);
  });

  test('a cover that won\'t load leaves the song playable', () async {
    final source = File(p.join(directory.path, 'audio.flac'))
      ..writeAsBytesSync(flacHeader);
    final cacheDir = Directory(p.join(directory.path, 'cache'));
    final cache = DiscoveryPlaybackCache(
      http: DiscoveryHttp(MockClient((_) async => http.Response('', 404))),
      directory: () async => cacheDir,
      probe: (_) async =>
          const AudioProbeFormat(sampleRate: 44100, channels: 2),
    );
    final song = await cache.adopt(
      fixtureTrack.withArtwork('https://img.example/cover.jpg'),
      source,
    );
    expect(song.albumArt, isNull);
    expect(cacheDir.listSync().map((e) => e.path), [song.filePath]);
  });

  test('an add-on file the engine refuses is not left in the cache', () async {
    final source = File(p.join(directory.path, 'audio.flac'))
      ..writeAsBytesSync(flacHeader);
    final cacheDir = Directory(p.join(directory.path, 'cache'));
    final cache = DiscoveryPlaybackCache(
      http: DiscoveryHttp(MockClient((_) async => fail('no network'))),
      directory: () async => cacheDir,
      probe: (_) async => throw StateError('unsupported'),
    );
    await expectLater(
      cache.adopt(fixtureTrack, source),
      throwsA(isA<DiscoveryException>()),
    );
    expect(cacheDir.listSync(), isEmpty);
  });

  test('a recording with a known size downloads in ranged parts', () async {
    final file = [
      ...ascii.encode('\x00\x00\x00\x18ftypM4A '),
      ...List.filled(40, 7),
    ];
    final asked = <String>[];
    final client = MockClient((request) async {
      expect(request.headers['User-Agent'], 'Fixture agent');
      expect(request.url.queryParameters['secret'], 'signed');
      final range = request.url.queryParameters['range']!;
      asked.add(range);
      final [start, end] = range.split('-').map(int.parse).toList();
      return http.Response.bytes(file.sublist(start, end + 1), 200);
    });
    addTearDown(client.close);
    final cache = DiscoveryPlaybackCache(
      http: DiscoveryHttp(client),
      directory: () async => directory,
      rangeBytes: 20,
      probe: (path) async {
        expect(await File(path).readAsBytes(), file);
        return const AudioProbeFormat(sampleRate: 44100, channels: 2);
      },
    );
    final song = await cache.prepare(
      fixtureTrack,
      ResolvedDiscoveryAudio(
        fixtureAudio.url,
        length: file.length,
        headers: const {'User-Agent': 'Fixture agent'},
      ),
    );
    expect(asked, ['0-19', '20-39', '40-${file.length - 1}']);
    // Container bytes are known; this fixture supplies no verified codec.
    expect(song.fileType, 'ONLINE');
  });

  test(
    'lossy decoder bit width never becomes a lossless quality claim',
    () async {
      final client = MockClient(
        (_) async => http.Response.bytes([
          ...ascii.encode('ID3'),
          ...List.filled(40, 0),
        ], 200),
      );
      addTearDown(client.close);
      final cache = DiscoveryPlaybackCache(
        http: DiscoveryHttp(client),
        directory: () async => directory,
        probe: (_) async => const AudioProbeFormat(
          sampleRate: 48000,
          channels: 2,
          bitsPerSample: 32,
        ),
      );
      final song = await cache.prepare(fixtureTrack, fixtureAudio);
      expect(song.fileType, 'MP3');
      expect(song.sampleRate, 48000);
      expect(song.bitDepth, isNull);
      expect(song.resolution, isNull);
    },
  );

  test(
    'HTML named FLAC and playlist payloads never reach native probe',
    () async {
      for (final bytes in [
        ascii.encode('<html>not audio</html>'),
        ascii.encode('#EXTM3U\nhttps://media.example/file'),
      ]) {
        final client = MockClient((_) async => http.Response.bytes(bytes, 200));
        addTearDown(client.close);
        final cache = DiscoveryPlaybackCache(
          http: DiscoveryHttp(client),
          directory: () async => directory,
          probe: (_) async => fail('Probe must not be called'),
        );
        await expectLater(
          cache.prepare(fixtureTrack, fixtureAudio),
          throwsA(isA<DiscoveryException>()),
        );
        expect(await directory.list().toList(), isEmpty);
      }
    },
  );

  test('native probe failure removes the staged file and is not treated as playable', () async {
    final client = MockClient(
      (_) async => http.Response.bytes(flacHeader, 200),
    );
    addTearDown(client.close);
    final cache = DiscoveryPlaybackCache(
      http: DiscoveryHttp(client),
      directory: () async => directory,
      probe: (_) async => throw StateError('decoder failure with private path'),
    );
    await expectLater(
      cache.prepare(fixtureTrack, fixtureAudio),
      throwsA(
        isA<DiscoveryException>().having(
          (e) => e.message,
          'sanitized',
          isNot(contains('private path')),
        ),
      ),
    );
    expect(await directory.list().toList(), isEmpty);
  });

  test('hi-res add-ons have a 512 MiB bounded file limit', () async {
    final cache = DiscoveryPlaybackCache(
      http: DiscoveryHttp(MockClient((_) async => fail('No request'))),
      directory: () async => directory,
    );
    expect(cache.maxFileBytes, 512 * 1024 * 1024);
    expect(cache.maxCacheBytes, 1024 * 1024 * 1024);
    expect(cache.downloadTimeout, const Duration(minutes: 6));
  });

  test(
    'a declared 200 MiB recording passes the old 128 MiB preflight',
    () async {
      final client = MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          Stream.value(flacHeader),
          200,
          contentLength: 200 * 1024 * 1024,
        ),
      );
      addTearDown(client.close);
      final cache = DiscoveryPlaybackCache(
        http: DiscoveryHttp(client),
        directory: () async => directory,
        probe: (_) async => fail('Incomplete audio must never be probed'),
      );
      await expectLater(
        cache.prepare(fixtureTrack, fixtureAudio),
        throwsA(
          isA<DiscoveryException>().having(
            (e) => e.message,
            'must reject incomplete transfer, not the old size cap',
            contains('incomplete'),
          ),
        ),
      );
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test('a declared file above the new cap stays rejected', () async {
    final client = MockClient.streaming(
      (_, _) async => http.StreamedResponse(
        const Stream<List<int>>.empty(),
        200,
        contentLength: 513 * 1024 * 1024,
      ),
    );
    addTearDown(client.close);
    final cache = DiscoveryPlaybackCache(
      http: DiscoveryHttp(client),
      directory: () async => directory,
      probe: (_) async => fail('Oversized audio must never be probed'),
    );
    await expectLater(
      cache.prepare(fixtureTrack, fixtureAudio),
      throwsA(
        isA<DiscoveryException>().having(
          (e) => e.message,
          'bounded audio file',
          contains('audio response exceeds'),
        ),
      ),
    );
    expect(await directory.list().toList(), isEmpty);
  });

  test('oversized add-on JSON has a distinct metadata error', () async {
    final client = MockClient.streaming(
      (_, _) async => http.StreamedResponse(
        const Stream<List<int>>.empty(),
        200,
        contentLength: DiscoveryHttp.jsonLimit + 1,
      ),
    );
    addTearDown(client.close);
    await expectLater(
      DiscoveryHttp(client).json(Uri.parse('https://addon.example/stream/id')),
      throwsA(
        isA<DiscoveryException>().having(
          (e) => e.message,
          'metadata rather than audio',
          contains('JSON metadata'),
        ),
      ),
    );
  });

  test('oversized declared or chunked download is bounded and partial file removed', () async {
    for (final declared in [true, false]) {
      final client = MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          Stream.fromIterable([flacHeader, List.filled(100, 0)]),
          200,
          contentLength: declared ? 152 : null,
        ),
      );
      addTearDown(client.close);
      final cache = DiscoveryPlaybackCache(
        http: DiscoveryHttp(client),
        directory: () async => directory,
        maxFileBytes: 80,
        maxCacheBytes: 160,
        probe: (_) async => fail('Oversized file must not be probed'),
      );
      await expectLater(
        cache.prepare(fixtureTrack, fixtureAudio),
        throwsA(isA<DiscoveryException>()),
      );
      expect(await directory.list().toList(), isEmpty);
    }
  });

  test('download timeout cancels stream and removes partial file', () async {
    final stream = StreamController<List<int>>();
    final client = MockClient.streaming((_, _) async {
      stream.add(flacHeader);
      return http.StreamedResponse(stream.stream, 200);
    });
    addTearDown(client.close);
    final cache = DiscoveryPlaybackCache(
      http: DiscoveryHttp(client),
      directory: () async => directory,
      downloadTimeout: const Duration(milliseconds: 20),
      probe: (_) async => fail('Timeout must not be probed'),
    );
    await expectLater(
      cache.prepare(fixtureTrack, fixtureAudio),
      throwsA(isA<DiscoveryException>()),
    );
    expect(await directory.list().toList(), isEmpty);
    await stream.close();
  });

  test(
    'cancellation after native probe prevents handoff and cleans up',
    () async {
      final cancel = Completer<void>();
      final client = MockClient(
        (_) async => http.Response.bytes(flacHeader, 200),
      );
      addTearDown(client.close);
      final cache = DiscoveryPlaybackCache(
        http: DiscoveryHttp(client),
        directory: () async => directory,
        probe: (_) async {
          cancel.complete();
          await Future<void>.delayed(Duration.zero);
          return const AudioProbeFormat(sampleRate: 44100, channels: 2);
        },
      );
      await expectLater(
        cache.prepare(fixtureTrack, fixtureAudio, cancel: cancel.future),
        throwsA(isA<DiscoveryException>()),
      );
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test(
    'LRU reservation preserves queued file and bounds total storage',
    () async {
      final old = File(p.join(directory.path, 'old.flac'));
      final protected = File(p.join(directory.path, 'queued.flac'));
      await old.writeAsBytes(List.filled(80, 0));
      await protected.writeAsBytes(List.filled(80, 0));
      final client = MockClient(
        (_) async => http.Response.bytes(flacHeader, 200),
      );
      addTearDown(client.close);
      final cache = DiscoveryPlaybackCache(
        http: DiscoveryHttp(client),
        directory: () async => directory,
        maxFileBytes: 100,
        maxCacheBytes: 200,
        protectedPaths: () => {protected.path},
        probe: (_) async =>
            const AudioProbeFormat(sampleRate: 44100, channels: 2),
      );
      await cache.prepare(fixtureTrack, fixtureAudio);
      expect(await old.exists(), isFalse);
      expect(await protected.exists(), isTrue);
      var bytes = 0;
      await for (final entry in directory.list()) {
        bytes += await (entry as File).length();
      }
      expect(bytes, lessThanOrEqualTo(200));
    },
  );

  test(
    'small stream fits despite protected queue near the cache cap',
    () async {
      // Before the fix, every song reserved maxFileBytes (100) although the
      // streamed fixture occupies only 52 bytes: 120 + 100 exceeded 200.
      final queued = File(p.join(directory.path, 'queued.flac'));
      await queued.writeAsBytes(List.filled(120, 0));
      final client = MockClient(
        (_) async => http.Response.bytes(flacHeader, 200),
      );
      addTearDown(client.close);
      final cache = DiscoveryPlaybackCache(
        http: DiscoveryHttp(client),
        directory: () async => directory,
        maxFileBytes: 100,
        maxCacheBytes: 200,
        protectedPaths: () => {queued.path},
        probe: (_) async =>
            const AudioProbeFormat(sampleRate: 44100, channels: 2),
      );
      final song = await cache.prepare(fixtureTrack, fixtureAudio);
      expect(await queued.exists(), isTrue);
      expect(await File(song.filePath!).length(), flacHeader.length);
      final files = await directory
          .list()
          .where((entry) => entry is File)
          .toList();
      var total = 0;
      for (final file in files) {
        total += await (file as File).length();
      }
      expect(total, lessThanOrEqualTo(200));
    },
  );

  test('full protected cache fails before media request', () async {
    final protected = File(p.join(directory.path, 'queued.flac'));
    await protected.writeAsBytes(List.filled(150, 0));
    final client = MockClient((_) async => fail('No space must not download'));
    addTearDown(client.close);
    final cache = DiscoveryPlaybackCache(
      http: DiscoveryHttp(client),
      directory: () async => directory,
      maxFileBytes: 100,
      maxCacheBytes: 200,
      protectedPaths: () => {protected.path},
    );
    await expectLater(
      cache.prepare(fixtureTrack, fixtureAudio),
      throwsA(isA<DiscoveryException>()),
    );
    expect(await protected.length(), 150);
  });
  test('googlevideo cache downloads use the actual Range header and accept 206', () async {
    final bytes = [
      ...ascii.encode('\x00\x00\x00\x18ftypM4A '),
      ...List.filled(40, 7),
    ];
    final requested = <String>[];
    final client = MockClient((request) async {
      expect(request.url.queryParameters, isNot(contains('range')));
      final range = request.headers['range'];
      expect(range, isNotNull);
      requested.add(range!);
      final parts = range
          .replaceFirst('bytes=', '')
          .split('-')
          .map(int.parse)
          .toList();
      return http.Response.bytes(
        bytes.sublist(parts[0], parts[1] + 1),
        206,
        headers: {
          'content-type': 'audio/mp4',
          'content-range': 'bytes ${parts[0]}-${parts[1]}/${bytes.length}',
        },
      );
    });
    addTearDown(client.close);
    final cache = DiscoveryPlaybackCache(
      http: DiscoveryHttp(client),
      directory: () async => directory,
      rangeBytes: 20,
      probe: (_) async =>
          const AudioProbeFormat(sampleRate: 44100, channels: 2),
    );
    final stream = ResolvedDiscoveryAudio(
      Uri.parse(
        'https://rr1---sn-abc.googlevideo.com/videoplayback?clen=${bytes.length}',
      ),
      length: bytes.length,
      headers: const {'User-Agent': 'YouTube client'},
    );
    final song = await cache.prepare(fixtureTrack, stream);
    expect(requested, [
      'bytes=0-19',
      'bytes=20-39',
      'bytes=40-${bytes.length - 1}',
    ]);
    expect(song.fileType, 'ONLINE');
  });
}
