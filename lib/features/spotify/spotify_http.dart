import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class SpotifyFailure implements Exception {
  const SpotifyFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class SpotifyCancelled extends SpotifyFailure {
  const SpotifyCancelled()
    : super('Cancelled. Completed local additions are kept; retrying is safe.');
}

class SpotifyCancellation {
  final _done = Completer<void>();
  bool get isCancelled => _done.isCompleted;
  Future<void> get whenCancelled => _done.future;
  void cancel() {
    if (!_done.isCompleted) _done.complete();
  }

  void check() {
    if (isCancelled) throw const SpotifyCancelled();
  }
}

/// Bounded transport shared by API and token calls. Redirects are disabled so
/// neither Authorization nor form-body credentials follow a different URL.
class SpotifyHttp {
  SpotifyHttp(this.client, {this.timeout = const Duration(seconds: 25)});
  final http.Client client;
  final Duration timeout;
  static const maxBytes = 4 * 1024 * 1024;

  Future<http.Response> send(
    Uri uri, {
    Map<String, String> headers = const {},
    Map<String, String>? form,
    String? jsonBody,
    SpotifyCancellation? cancellation,
  }) async {
    cancellation?.check();
    final abort = Completer<void>();
    var finished = false;
    var succeeded = false;
    void stop() {
      if (!finished && !abort.isCompleted) abort.complete();
    }

    final timer = Timer(timeout, stop);
    unawaited(cancellation?.whenCancelled.then((_) => stop()));
    final request = http.AbortableRequest(
      form == null && jsonBody == null ? 'GET' : 'POST',
      uri,
      abortTrigger: abort.future,
    )..followRedirects = false;
    request.headers.addAll(headers);
    if (form != null) request.bodyFields = form;
    if (jsonBody != null) request.body = jsonBody;
    StreamIterator<List<int>>? chunks;
    Future<T> bounded<T>(Future<T> future) => Future.any([
      future,
      abort.future.then<T>((_) {
        cancellation?.check();
        throw const SpotifyFailure('Spotify request timed out. Try again.');
      }),
    ]);
    try {
      final response = await bounded(
        client.send(request).then((response) {
          if (abort.isCompleted) {
            unawaited(response.stream.listen(null).cancel());
            throw const SpotifyFailure('Spotify request ended.');
          }
          return response;
        }),
      );
      chunks = StreamIterator(response.stream);
      final bytes = BytesBuilder(copy: false);
      while (await bounded(chunks.moveNext())) {
        cancellation?.check();
        bytes.add(chunks.current);
        if (bytes.length > maxBytes) {
          throw const SpotifyFailure('Spotify response is too large.');
        }
      }
      cancellation?.check();
      final completed = http.Response.bytes(
        bytes.takeBytes(),
        response.statusCode,
        headers: response.headers,
      );
      succeeded = true;
      return completed;
    } catch (error) {
      cancellation?.check();
      if (error is SpotifyFailure) rethrow;
      throw const SpotifyFailure(
        'Could not reach Spotify securely. Check your connection and retry.',
      );
    } finally {
      timer.cancel();
      finished = true;
      // AbortableRequest shares this signal with dart:io's active socket.
      // Cancelling after a successful response can race with the connection
      // returning to the pool and produce _HttpClient._returnConnection errors.
      if (!succeeded && !abort.isCompleted) abort.complete();
      await chunks?.cancel();
    }
  }

  static Map<String, dynamic> decode(http.Response response) {
    try {
      final value = jsonDecode(utf8.decode(response.bodyBytes));
      if (value is Map<String, dynamic>) return value;
    } catch (_) {
      /* Never expose a response body in an error. */
    }
    throw const SpotifyFailure('Spotify returned invalid JSON.');
  }
}
