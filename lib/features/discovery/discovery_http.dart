import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'discovery_models.dart';

/// Bounded transport. Only media redirects within HTTPS googlevideo are allowed.
/// The client is owned by the caller.
class DiscoveryHttp {
  DiscoveryHttp(this.client, {this.timeout = const Duration(seconds: 15)});

  final http.Client client;
  final Duration timeout;
  static const jsonLimit = 2 * 1024 * 1024;

  Future<Map<String, dynamic>> json(
    Uri url, {
    Map<String, String> headers = const {},
    Map<String, Object?>? body,
    Future<void>? cancel,
  }) async {
    final bytes = BytesBuilder(copy: false);
    await transfer(
      url,
      headers: {'Accept': 'application/json', ...headers},
      body: body,
      maxBytes: jsonLimit,
      isMetadata: true,
      deadline: timeout,
      onChunk: bytes.add,
      cancel: cancel,
    );
    try {
      final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // Do not expose response content, URLs or credentials in parse errors.
    }
    throw const DiscoveryException('The source returned invalid JSON.');
  }

  Future<int> transfer(
    Uri url, {
    Map<String, String> headers = const {},
    Map<String, Object?>? body,
    required int maxBytes,
    bool isMetadata = false,
    required Duration deadline,
    required FutureOr<void> Function(List<int>) onChunk,
    Future<void>? cancel,
    bool allowPartial = false,
    bool followMediaRedirects = false,
    int? rangeStart,
  }) async {
    requireHttps(url.toString());
    final abort = Completer<void>();
    var timedOut = false;
    var cancelled = false;
    var finished = false;
    var succeeded = false;
    final timer = Timer(deadline, () {
      if (finished) return;
      timedOut = true;
      if (!abort.isCompleted) abort.complete();
    });
    if (cancel != null) {
      unawaited(
        cancel.then((_) {
          if (finished) return;
          cancelled = true;
          if (!abort.isCompleted) abort.complete();
        }),
      );
    }
    final request = http.AbortableRequest(
      body == null ? 'GET' : 'POST',
      url,
      abortTrigger: abort.future,
    )..followRedirects = false;
    request.headers.addAll(headers);
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    StreamIterator<List<int>>? chunks;
    try {
      // Observe an already-completed cancellation before initiating another
      // request in a manifest -> resolve -> download chain.
      await Future<void>.value();
      if (abort.isCompleted) {
        throw const DiscoveryException('Request cancelled.');
      }
      // Future.any also bounds injected clients that do not implement abort.
      Future<http.StreamedResponse> send() async {
        var next = request;
        for (var redirects = 0; ; redirects++) {
          final response = await client.send(next);
          if (abort.isCompleted) {
            unawaited(response.stream.listen(null).cancel());
            throw const DiscoveryException('Request cancelled.');
          }
          final location = response.headers['location'];
          if (!followMediaRedirects ||
              location == null ||
              !{301, 302, 303, 307, 308}.contains(response.statusCode))
            return response;
          final target = next.url.resolve(location);
          await response.stream.listen(null).cancel();
          // Only the selected CDN may redirect its own signed media URL:
          // do not forward bearer headers to a different site or private IP.
          final googleVideo = url.host.endsWith('.googlevideo.com');
          final soundCloudCdn = url.host.endsWith('.sndcdn.com');
          final sameTrustedCdn = (googleVideo &&
                  target.host.endsWith('.googlevideo.com')) ||
              (soundCloudCdn && target.host.endsWith('.sndcdn.com'));
          if (redirects >= 3 ||
              body != null ||
              target.scheme != 'https' ||
              target.userInfo.isNotEmpty ||
              !sameTrustedCdn) {
            throw const DiscoveryException(
              'The source returned an unsupported media redirect.',
            );
          }
          next =
              http.AbortableRequest('GET', target, abortTrigger: abort.future)
                ..followRedirects = false
                ..headers.addAll(headers);
        }
      }

      final pending = send();
      final response = await Future.any([
        pending,
        abort.future.then<http.StreamedResponse>(
          (_) => throw const DiscoveryException('Request cancelled.'),
        ),
      ]);
      chunks = StreamIterator(response.stream);
      if (rangeStart != null &&
          (response.statusCode == 200 || response.statusCode == 206)) {
        final contentRange = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$')
            .firstMatch(response.headers['content-range'] ?? '');
        if (contentRange == null || int.parse(contentRange[1]!) != rangeStart) {
          throw const DiscoveryException(
            'The source returned an invalid media range.',
          );
        }
      }
      if (response.statusCode != 200 &&
          !(allowPartial && response.statusCode == 206)) {
        throw DiscoveryException(switch (response.statusCode) {
          401 || 403 =>
            'The source refused access (HTTP ${response.statusCode}). Check its configuration or token.',
          404 => 'This source or recording is unavailable (HTTP 404).',
          429 => 'The source is rate limiting requests. Try again later.',
          >= 300 && < 400 => 'The source redirected the request. Configure its final HTTPS address.',
          _ =>
            'The source returned HTTP ${response.statusCode}. Try again later.',
        });
      }
      if ((response.contentLength ?? 0) > maxBytes) {
        throw DiscoveryException(
          isMetadata
              ? 'The source returned too much JSON metadata (2 MiB limit).'
              : 'The audio response exceeds the per-track download limit.',
        );
      }
      var received = 0;
      while (await Future.any([
        chunks.moveNext(),
        abort.future.then<bool>(
          (_) => throw const DiscoveryException('Request cancelled.'),
        ),
      ])) {
        final chunk = chunks.current;
        received += chunk.length;
        if (received > maxBytes) {
          throw DiscoveryException(
            isMetadata
                ? 'The source returned too much JSON metadata (2 MiB limit).'
                : 'The audio response exceeds the per-track download limit.',
          );
        }
        await onChunk(chunk);
      }
      if (received == 0 ||
          (response.contentLength != null &&
              received != response.contentLength)) {
        throw const DiscoveryException(
          'The source returned an empty or incomplete response.',
        );
      }
      succeeded = true;
      return received;
    } catch (error) {
      if (timedOut) {
        throw const DiscoveryException('The source timed out. Try again.');
      }
      if (cancelled) throw const DiscoveryException('Request cancelled.');
      if (error is DiscoveryException) rethrow;
      throw const DiscoveryException(
        'Could not reach the source securely. Check your connection.',
      );
    } finally {
      timer.cancel();
      finished = true;
      // The same abort trigger belongs to the underlying IOClient. Completing
      // it after a fully consumed successful response races with Dart's
      // asynchronous keep-alive connection handoff (_returnConnection).
      // Abort only failed/incomplete requests, never a completed transfer.
      if (!succeeded && !abort.isCompleted) abort.complete();
      await chunks?.cancel();
    }
  }
}
