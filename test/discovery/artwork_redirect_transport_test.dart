import 'package:flick/features/discovery/discovery_http.dart';
import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  for (final destination in [
    'https://ia800000.us.archive.org/cover.jpg',
    'https://coverartarchive.org/release/next',
    'http://archive.org/cover.jpg',
    'https://other.example/cover.jpg',
    'https://coverartarchive.org.evil.example/cover.jpg',
  ]) {
    final allowed =
        destination.startsWith('https://ia800000.') ||
        destination.startsWith('https://coverartarchive.org/');
    test(
      'bounded artwork redirect ${allowed ? 'accepts' : 'rejects'} $destination',
      () async {
        final requests = <http.BaseRequest>[];
        final client = MockClient.streaming((request, _) async {
          requests.add(request);
          return requests.length == 1
              ? http.StreamedResponse(
                  const Stream.empty(),
                  307,
                  headers: {'location': destination},
                )
              : http.StreamedResponse(
                  Stream.value([1, 2, 3]),
                  200,
                  contentLength: 3,
                );
        });
        final chunks = <int>[];
        final operation = DiscoveryHttp(client).transfer(
          Uri.https('coverartarchive.org', '/release/id/front-1200'),
          headers: const {
            'Accept': 'image/*',
            'Authorization': 'fixture-only',
            'Cookie': 'fixture-only',
          },
          maxBytes: 1024,
          deadline: const Duration(seconds: 1),
          followArtworkRedirects: true,
          onChunk: chunks.addAll,
        );
        if (allowed) {
          expect(await operation, 3);
          expect(chunks, [1, 2, 3]);
          expect(requests, hasLength(2));
          final sameOrigin =
              Uri.parse(destination).origin == 'https://coverartarchive.org';
          expect(
            requests.last.headers['authorization'],
            sameOrigin ? 'fixture-only' : isNull,
          );
          expect(
            requests.last.headers['cookie'],
            sameOrigin ? 'fixture-only' : isNull,
          );
        } else {
          await expectLater(operation, throwsA(isA<DiscoveryException>()));
          expect(requests, hasLength(1));
        }
        client.close();
      },
    );
  }

  test(
    'ordinary source requests retain their existing redirect rejection',
    () async {
      var sends = 0;
      final client = MockClient.streaming((_, __) async {
        sends++;
        return http.StreamedResponse(
          const Stream.empty(),
          307,
          headers: {'location': 'https://ia800000.us.archive.org/cover.jpg'},
        );
      });
      await expectLater(
        DiscoveryHttp(client).transfer(
          Uri.https('coverartarchive.org', '/release/id/front-1200'),
          maxBytes: 1024,
          deadline: const Duration(seconds: 1),
          onChunk: (_) {},
        ),
        throwsA(isA<DiscoveryException>()),
      );
      expect(sends, 1);
      client.close();
    },
  );
}
