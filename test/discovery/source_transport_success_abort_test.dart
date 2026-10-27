import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:flick/features/discovery/discovery_http.dart';
import 'package:flick/features/spotify/spotify_http.dart';

/// Models a normally completed HTTP response, while recording when the
/// application's AbortableRequest trigger is completed.
class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.responseBytes);
  final List<int> responseBytes;
  final List<Future<void>> aborts = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    expect(request, isA<http.AbortableRequest>());
    aborts.add((request as http.AbortableRequest).abortTrigger!);
    return http.StreamedResponse(
      Stream<List<int>>.value(responseBytes),
      200,
      contentLength: responseBytes.length,
    );
  }
}

void main() {
  test('successful Discovery JSON fetch does not abort its socket', () async {
    final client = _RecordingClient(utf8.encode('{"ok":true}'));
    final transport = DiscoveryHttp(client);

    expect(await transport.json(Uri.https('example.org', '/source')), {
      'ok': true,
    });
    expect(client.aborts, hasLength(1));

    var aborted = false;
    client.aborts.single.then((_) => aborted = true);
    await Future<void>.delayed(Duration.zero);
    expect(aborted, isFalse,
        reason: 'Completing abort after success races with socket pooling');
  });

  test('successful Spotify response does not abort its socket', () async {
    final client = _RecordingClient(utf8.encode('{"data":{}}'));
    final transport = SpotifyHttp(client);
    final response = await transport.send(
      Uri.https('api-partner.spotify.com', '/pathfinder/v2/query'),
    );

    expect(response.statusCode, 200);
    expect(client.aborts, hasLength(1));
    var aborted = false;
    client.aborts.single.then((_) => aborted = true);
    await Future<void>.delayed(Duration.zero);
    expect(aborted, isFalse);
  });

  test('Discovery explicit cancellation still aborts a blocked request', () async {
    final cancelling = Completer<void>();
    final client = _NeverReplyClient();
    final operation = DiscoveryHttp(client).json(
      Uri.https('example.org', '/blocked'),
      cancel: cancelling.future,
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    cancelling.complete();
    await expectLater(operation, throwsA(isA<Exception>()));
    expect(client.aborted, isTrue);
  });
}

class _NeverReplyClient extends http.BaseClient {
  bool aborted = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final abort = (request as http.AbortableRequest).abortTrigger!;
    final reply = Completer<http.StreamedResponse>();
    abort.then((_) {
      aborted = true;
      if (!reply.isCompleted) reply.completeError(StateError('cancelled'));
    });
    return reply.future;
  }
}
