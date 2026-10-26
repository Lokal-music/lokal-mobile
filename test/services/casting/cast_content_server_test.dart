import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/casting/cast_content_server.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final bytes = List<int>.generate(100, (i) => i);

  Future<void> withServer(
    Future<void> Function(HttpClient client, Uri uri) check, {
    String filename = 'track.m4a',
    bool empty = false,
  }) async {
    await binding.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('cast_server');
      final server = CastContentServer.instance;
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      try {
        final file = File('${dir.path}/$filename');
        await file.writeAsBytes(empty ? <int>[] : bytes);
        final url = await server.serve(file.path, filename: filename);
        await check(client, Uri.parse(url).replace(host: '127.0.0.1'));
      } finally {
        client.close(force: true);
        await server.stop();
        await dir.delete(recursive: true);
      }
    });
  }

  Future<HttpClientResponse> request(
    HttpClient client,
    Uri uri, {
    String method = 'GET',
    String? range,
  }) async {
    final req = await client.openUrl(method, uri);
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    return req.close();
  }

  Future<List<int>> body(HttpClientResponse response) =>
      response.fold<List<int>>([], (all, chunk) => all..addAll(chunk));

  test('full GET has accurate framing and unknown tokens return 404', () async {
    await withServer((client, uri) async {
      final full = await request(client, uri);
      expect(full.statusCode, 200);
      expect(full.contentLength, 100);
      expect(full.headers.contentType?.mimeType, 'audio/mp4');
      expect(full.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
      expect(await body(full), bytes);
      final missing = await request(
        client,
        uri.replace(path: '/deadbeef/x.m4a'),
      );
      expect(missing.statusCode, 404);
      await body(missing);
    });
  });

  test(
    'closed, open, suffix and clamped ranges return their exact bytes',
    () async {
      await withServer((client, uri) async {
        for (final (range, start, end) in [
          ('bytes=10-19', 10, 19),
          ('bytes=90-', 90, 99),
          ('bytes=-10', 90, 99),
          ('bytes=-100', 0, 99),
          ('bytes=-1000', 0, 99),
          ('bytes=90-500', 90, 99),
          ('bytes=0-0', 0, 0),
          ('bytes=99-', 99, 99),
          ('bytes=5-999999999999999999999999999999', 5, 99),
          ('bytes=-999999999999999999999999999999', 0, 99),
        ]) {
          final part = await request(client, uri, range: range);
          expect(part.statusCode, 206, reason: range);
          expect(part.contentLength, end - start + 1, reason: range);
          expect(
            part.headers.value(HttpHeaders.contentRangeHeader),
            'bytes $start-$end/100',
            reason: range,
          );
          expect(
            await body(part),
            bytes.sublist(start, end + 1),
            reason: range,
          );
        }
      });
    },
  );

  test(
    'unsatisfiable ranges are empty 416 responses with the file size',
    () async {
      await withServer((client, uri) async {
        for (final range in [
          'bytes=100-',
          'bytes=500-',
          'bytes=20-10',
          'bytes=-0',
          'bytes=999999999999999999999999999999-',
        ]) {
          final response = await request(client, uri, range: range);
          expect(response.statusCode, 416, reason: range);
          expect(response.contentLength, 0, reason: range);
          expect(
            response.headers.value(HttpHeaders.contentRangeHeader),
            'bytes */100',
            reason: range,
          );
          expect(await body(response), isEmpty, reason: range);
        }
      });
    },
  );

  test(
    'malformed, unsupported and multipart ranges fall back to full GET',
    () async {
      await withServer((client, uri) async {
        for (final range in [
          'bytes=-',
          'bytes=abc-def',
          'items=10-19',
          'bytes=0-9,20-29',
          'prefixbytes=10-19',
          'bytes=10-19suffix',
        ]) {
          final response = await request(client, uri, range: range);
          expect(response.statusCode, 200, reason: range);
          expect(response.contentLength, 100, reason: range);
          expect(
            response.headers.value(HttpHeaders.contentRangeHeader),
            isNull,
          );
          expect(await body(response), bytes, reason: range);
        }
      });
    },
  );

  test(
    'HEAD returns full GET metadata with no body and ignores Range',
    () async {
      await withServer((client, uri) async {
        final head = await request(
          client,
          uri,
          method: 'HEAD',
          range: 'bytes=10-19',
        );
        expect(head.statusCode, 200);
        expect(head.contentLength, 100);
        expect(head.headers.contentType?.mimeType, 'audio/mp4');
        expect(head.headers.value(HttpHeaders.contentRangeHeader), isNull);
        expect(await body(head), isEmpty);
        final get = await request(client, uri);
        expect(await body(get), bytes);
      });
    },
  );

  test('other methods are rejected without serving file bytes', () async {
    await withServer((client, uri) async {
      final response = await request(client, uri, method: 'POST');
      expect(response.statusCode, 405);
      expect(response.headers.value(HttpHeaders.allowHeader), 'GET, HEAD');
      expect(await body(response), isEmpty);
    });
  });

  test(
    'empty files have an empty full response and no satisfiable range',
    () async {
      await withServer((client, uri) async {
        final full = await request(client, uri);
        expect(full.statusCode, 200);
        expect(full.contentLength, 0);
        expect(await body(full), isEmpty);
        for (final range in ['bytes=0-', 'bytes=-1']) {
          final response = await request(client, uri, range: range);
          expect(response.statusCode, 416);
          expect(
            response.headers.value(HttpHeaders.contentRangeHeader),
            'bytes */0',
          );
          expect(await body(response), isEmpty);
        }
      }, empty: true);
    },
  );

  test('raw AAC uses its real MIME type', () async {
    await withServer((client, uri) async {
      final response = await request(client, uri);
      expect(response.headers.contentType?.mimeType, 'audio/aac');
      expect(await body(response), bytes);
    }, filename: 'track.aac');
  });
}
