import 'dart:async';

import 'package:flick/services/notification_artwork_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NotificationArtworkResolver', () {
    test('keeps local artwork immediately and ignores missing artwork', () {
      final resolver = NotificationArtworkResolver(
        fetcher: (_) => throw StateError('Remote fetch not expected'),
      );
      final updates = <String>[];

      expect(
        resolver.pathFor(
          identity: 'local',
          artwork: '/storage/emulated/0/Music/cover.jpg',
          onResolved: updates.add,
        ),
        '/storage/emulated/0/Music/cover.jpg',
      );
      expect(
        resolver.pathFor(
          identity: 'no-art',
          artwork: null,
          onResolved: updates.add,
        ),
        isNull,
      );
      expect(updates, isEmpty);
    });

    test('caches a remote cover without blocking or repeated requests', () async {
      final pending = Completer<String?>();
      var requests = 0;
      final updates = <String>[];
      final resolver = NotificationArtworkResolver(fetcher: (url) {
        expect(url, 'https://covers.example/album.jpg');
        requests++;
        return pending.future;
      });

      String? read() => resolver.pathFor(
        identity: 'addon:track-1',
        artwork: 'https://covers.example/album.jpg',
        onResolved: updates.add,
      );

      expect(read(), isNull);
      expect(read(), isNull);
      expect(requests, 1);
      pending.complete('/cache/album.jpg');
      await Future<void>.delayed(Duration.zero);
      expect(updates, ['/cache/album.jpg']);
      expect(read(), '/cache/album.jpg');
      expect(requests, 1);
    });

    test('late completion never overwrites the next track', () async {
      final oldRequest = Completer<String?>();
      final newRequest = Completer<String?>();
      final updates = <String>[];
      final resolver = NotificationArtworkResolver(fetcher: (url) =>
          url.contains('old') ? oldRequest.future : newRequest.future);

      expect(
        resolver.pathFor(
          identity: 'song-1',
          artwork: 'https://covers.example/old.jpg',
          onResolved: updates.add,
        ),
        isNull,
      );
      expect(
        resolver.pathFor(
          identity: 'song-2',
          artwork: 'https://covers.example/new.jpg',
          onResolved: updates.add,
        ),
        isNull,
      );
      oldRequest.complete('/cache/old.jpg');
      await Future<void>.delayed(Duration.zero);
      expect(updates, isEmpty);
      newRequest.complete('/cache/new.jpg');
      await Future<void>.delayed(Duration.zero);
      expect(updates, ['/cache/new.jpg']);
    });

    test('invalidates downloads after the notification is hidden', () async {
      final pending = Completer<String?>();
      final updates = <String>[];
      final resolver = NotificationArtworkResolver(fetcher: (_) => pending.future);
      resolver.pathFor(
        identity: 'song-1',
        artwork: 'https://covers.example/cover.jpg',
        onResolved: updates.add,
      );
      resolver.invalidate();
      pending.complete('/cache/cover.jpg');
      await Future<void>.delayed(Duration.zero);
      expect(updates, isEmpty);
    });

    test('failed and unsupported remote covers do not disrupt playback', () async {
      final updates = <String>[];
      final resolver = NotificationArtworkResolver(
        fetcher: (_) async => throw StateError('offline'),
      );
      expect(
        resolver.pathFor(
          identity: 'bad-url',
          artwork: 'javascript:alert(1)',
          onResolved: updates.add,
        ),
        isNull,
      );
      expect(
        resolver.pathFor(
          identity: 'offline',
          artwork: 'https://covers.example/missing.jpg',
          onResolved: updates.add,
        ),
        isNull,
      );
      await Future<void>.delayed(Duration.zero);
      expect(updates, isEmpty);
    });
  });
}
