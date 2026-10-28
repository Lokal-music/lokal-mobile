import 'dart:async';

import 'package:flick/models/song.dart';
import 'package:flick/features/discovery/discovery_progressive_streams.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/queue_pre_resolver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

Song _owned(String id) => Song(
  id: id,
  title: id,
  artist: 'A',
  duration: Duration.zero,
  fileType: 'FLAC',
  filePath: '/music/$id.flac',
);

Song _ready(String key) => Song(
  id: 'discovery:$key',
  title: key,
  artist: 'A',
  duration: Duration.zero,
  fileType: 'M4A',
  filePath: '/cache/$key.m4a',
  sourcePackage: 'konnekted.discovery',
  isExternal: true,
);

class _Host implements PreResolveHost {
  @override
  List<Song> playlist = [];
  @override
  int currentIndex = 0;
  @override
  bool repeatAll = false;
  final song = ValueNotifier(0);
  final queue = ValueNotifier(0);
  final swaps = <(String, Song)>[];

  @override
  Listenable get songChanges => song;
  @override
  Listenable get queueChanges => queue;

  @override
  void replacePending(String pendingId, Song resolved) {
    swaps.add((pendingId, resolved));
    playlist = [
      for (final entry in playlist) entry.id == pendingId ? resolved : entry,
    ];
  }

  /// Moves on to [index], as the player does when a song ends or is skipped.
  void playAt(int index) {
    currentIndex = index;
    song.value++;
  }

  /// Edits the queue, as adding, moving or shuffling does.
  void edit(List<Song> songs) {
    playlist = songs;
    queue.value++;
  }
}

/// A resolver whose lookups are answered by the test.
class _Lookups {
  final asked = <String>[];
  final pending = <String, Completer<Song?>>{};
  final cancelled = <String>[];

  PendingResolve resolver(String key) => ({onStatus, cancel}) {
    asked.add(key);
    onStatus?.call('Getting $key from Somewhere…');
    final completer = Completer<Song?>();
    pending[key] = completer;
    unawaited(cancel?.then((_) => cancelled.add(key)));
    return completer.future;
  };

  void answer(String key, [Song? song]) =>
      pending.remove(key)!.complete(song ?? _ready(key));
}

void main() {
  test('pre-resolved HTTP streams are reusable without a local cache file', () {
    final registry = DiscoveryProgressiveStreams.instance;
    registry.clear();
    addTearDown(registry.clear);
    final handle = registry.register(Uri.parse('https://cdn.example.com/audio.flac'));
    final song = Song(
      id: 'remote', title: 'Song', artist: 'Artist',
      duration: Duration.zero, fileType: 'FLAC', filePath: handle,
      sourcePackage: 'konnekted.progressive',
    );
    expect(QueuePreResolver.isPlayableResolvedSource(song), isTrue);
    registry.clear();
    expect(QueuePreResolver.isPlayableResolvedSource(song), isFalse);
  });

  testWidgets('a stalled lookup cancels and ignores its late answer', (
    tester,
  ) async {
    final resolver = QueuePreResolver(
      lookupIdleTimeout: const Duration(seconds: 1),
    );
    final host = _Host();
    resolver.attach(host);
    addTearDown(() {
      resolver.reset();
      resolver.detach();
    });
    final answer = Completer<Song?>();
    var cancelled = false;
    final pending = resolver.pending(
      key: 'stalled',
      title: 'Stalled',
      artist: 'A',
      resolve: ({onStatus, cancel}) {
        unawaited(cancel?.then((_) => cancelled = true));
        onStatus?.call('Resolving');
        return answer.future;
      },
    );
    host.playlist = [pending];
    final result = expectLater(
      resolver.resolveNow(pending),
      throwsA(isA<TimeoutException>()),
    );
    await tester.pump(const Duration(seconds: 2));
    await result;
    expect(cancelled, isTrue);
    expect(resolver.status.value, isNull);
    expect(resolver.running, isEmpty);
    answer.complete(_ready('stalled'));
    await tester.pump();
    expect(host.swaps, isEmpty);
  });

  group('upcomingSongs', () {
    final songs = [for (var i = 0; i < 6; i++) _owned('s$i')];

    test('the next four after the one playing', () {
      expect(upcomingSongs(songs, 0, repeatAll: false).map((s) => s.id), [
        's1',
        's2',
        's3',
        's4',
      ]);
    });

    test('stops at the end unless repeating all, then goes round', () {
      expect(upcomingSongs(songs, 4, repeatAll: false).map((s) => s.id), [
        's5',
      ]);
      expect(upcomingSongs(songs, 4, repeatAll: true).map((s) => s.id), [
        's5',
        's0',
        's1',
        's2',
      ]);
    });

    test('a short queue on repeat-all never lists the current song', () {
      final two = songs.take(2).toList();
      expect(upcomingSongs(two, 1, repeatAll: true).map((s) => s.id), ['s0']);
      expect(upcomingSongs(two.take(1).toList(), 0, repeatAll: true), isEmpty);
      expect(upcomingSongs(const [], 0, repeatAll: true), isEmpty);
      expect(upcomingSongs(songs, -1, repeatAll: true), isEmpty);
    });

    test('follows the shuffle order the player plays in', () {
      // The player keeps its playlist in play order, shuffled when shuffled.
      final shuffled = [songs[3], songs[0], songs[5], songs[1], songs[4]];
      expect(upcomingSongs(shuffled, 1, repeatAll: true).map((s) => s.id), [
        's5',
        's1',
        's4',
        's3',
      ]);
    });
  });

  test('the player swaps a found song in place, wherever it is queued', () {
    final placeholder = QueuePreResolver().pending(
      key: 'k1',
      title: 'k1',
      artist: 'A',
      resolve: ({onStatus, cancel}) async => null,
    );
    final songs = [_owned('a'), placeholder, _owned('b'), placeholder];
    final changed = replacePendingInPlace(songs, placeholder.id, _ready('k1'));
    expect(changed, [1, 3]);
    expect(songs.map((s) => s.id), ['a', 'discovery:k1', 'b', 'discovery:k1']);
    expect(replacePendingInPlace(songs, placeholder.id, _ready('k1')), isEmpty);
  });

  group('QueuePreResolver', () {
    late _Host host;
    late _Lookups lookups;
    late QueuePreResolver resolver;
    var now = DateTime(2026, 10, 20);

    Song pending(String key) => resolver.pending(
      key: key,
      title: key,
      artist: 'A',
      resolve: lookups.resolver(key),
    );

    setUp(() {
      now = DateTime(2026, 10, 20);
      host = _Host();
      lookups = _Lookups();
      resolver = QueuePreResolver(now: () => now, stillUsable: (_) => true)
        ..attach(host);
    });

    tearDown(() => resolver.reset());

    void testResolver(String name, WidgetTesterCallback body) {
      testWidgets(name, (tester) async {
        try {
          await body(tester);
        } finally {
          // Dispose watchdogs before the widget binding checks pending timers.
          resolver.reset();
        }
      });
    }

    test('placeholders are marked pending and carry no file', () {
      final song = pending('k1');
      expect(song.isPending, isTrue);
      expect(song.id, 'pending:k1');
      expect(song.filePath, isNull);
      expect(song.isExternal, isTrue);
      expect(_owned('x').isPending, isFalse);
    });

    testResolver('playlist starts its first pending track before any prefetch', (
      tester,
    ) async {
      final first = pending('first');
      host.playlist = [first, pending('second'), pending('third')];
      // The player publishes a new pending Song before stopping the old
      // engine. That change must not start downloads for tracks 2 and 3.
      host.playAt(0);
      expect(resolver.schedule(), isEmpty);
      host.queue.value++;
      await tester.pump(const Duration(milliseconds: 600));
      expect(lookups.asked, isEmpty);

      // Its foreground resolution is now the only add-on request.
      final started = resolver.resolveNow(first);
      expect(lookups.asked, ['first']);
      resolver.schedule();
      await tester.pump(const Duration(seconds: 3));
      expect(lookups.asked, ['first']);

      lookups.answer('first');
      expect((await started)?.id, 'discovery:first');
      // After the foreground handoff the next-four window opens normally.
      await tester.pump(const Duration(milliseconds: 600));
      expect(lookups.asked, ['first', 'second']);
      await tester.pump(const Duration(seconds: 2));
      expect(lookups.asked, ['first', 'second', 'third']);
    });

    testResolver('new playlist first track cancels stale add-on lookups', (
      tester,
    ) async {
      host.playlist = [
        _owned('old'),
        pending('old-next'),
        pending('old-later'),
      ];
      resolver.schedule();
      expect(lookups.asked, ['old-next']);
      final first = pending('new-first');
      host.playlist = [first, pending('new-second')];
      host.playAt(0);
      await tester.pump();
      expect(lookups.cancelled, contains('old-next'));
      expect(resolver.running, isEmpty);
      // A slow answer from the previous queue cannot replace the new one.
      lookups.answer('old-next');
      await tester.pump();
      expect(host.swaps, isEmpty);
      final started = resolver.resolveNow(first);
      expect(lookups.asked, ['old-next', 'new-first']);
      lookups.answer('new-first');
      expect((await started)?.id, 'discovery:new-first');
      await tester.pump(const Duration(milliseconds: 600));
      expect(lookups.asked, ['old-next', 'new-first', 'new-second']);
    });

    testResolver('pending selection defers existing stagger without losing work', (
      tester,
    ) async {
      final first = pending('first');
      host.playlist = [_owned('old'), first, pending('second')];
      resolver.schedule();
      expect(lookups.asked, ['first']);
      // Existing background work for the selected track is retained.
      host.playAt(1);
      await tester.pump(const Duration(seconds: 2));
      expect(lookups.asked, ['first']);
      final started = resolver.resolveNow(first);
      expect(lookups.asked, ['first']);
      lookups.answer('first');
      expect((await started)?.id, 'discovery:first');
      // A next track that was deferred during the handoff is still resolved.
      await tester.pump(const Duration(milliseconds: 600));
      expect(lookups.asked, ['first', 'second']);
    });

    testResolver('the first lookup runs at once, the rest 2 s apart', (
      tester,
    ) async {
      host.playlist = [
        _owned('now'),
        for (var i = 1; i <= 6; i++) pending('k$i'),
      ];
      expect(resolver.schedule(), [
        'pending:k1',
        'pending:k2',
        'pending:k3',
        'pending:k4',
      ]);
      expect(lookups.asked, ['k1']);
      await tester.pump(const Duration(milliseconds: 1999));
      expect(lookups.asked, ['k1']);
      await tester.pump(const Duration(milliseconds: 1));
      expect(lookups.asked, ['k1', 'k2']);
      await tester.pump(const Duration(seconds: 2));
      expect(lookups.asked, ['k1', 'k2', 'k3']);
      await tester.pump(const Duration(seconds: 2));
      expect(lookups.asked, ['k1', 'k2', 'k3', 'k4']);
      await tester.pump(const Duration(seconds: 10));
      expect(lookups.asked, hasLength(4), reason: 'only four ahead');
    });

    testResolver('repeated queue updates do not postpone the two-second stagger', (tester) async {
      host.playlist = [
        _owned('now'),
        for (var i = 1; i <= 5; i++) pending('k$i'),
      ];
      resolver.schedule();
      expect(lookups.asked, ['k1']);
      await tester.pump(const Duration(seconds: 1));
      resolver.schedule(); // e.g. Discovery refreshed the upcoming queue.
      await tester.pump(const Duration(seconds: 1));
      expect(lookups.asked, ['k1', 'k2']);
      resolver.schedule();
      await tester.pump(const Duration(seconds: 2));
      expect(lookups.asked, ['k1', 'k2', 'k3']);
      await tester.pump(const Duration(seconds: 2));
      expect(lookups.asked, ['k1', 'k2', 'k3', 'k4']);
    });

    testResolver('skipping to a pending song retains other preloading work', (tester) async {
      host.playlist = [
        _owned('now'),
        for (var i = 1; i <= 6; i++) pending('k$i'),
      ];
      resolver.schedule();
      await tester.pump(const Duration(seconds: 2));
      expect(lookups.asked, ['k1', 'k2']);
      host.playAt(1);
      final selected = host.playlist[1];
      final ready = resolver.resolveNow(selected);
      expect(lookups.asked.where((key) => key == 'k1'), hasLength(1));
      expect(lookups.cancelled, isNot(contains('k2')));
      lookups.answer('k1');
      expect((await ready)?.id, 'discovery:k1');
      await tester.pump(const Duration(seconds: 2));
      expect(lookups.asked, contains('k3'));
      expect(lookups.cancelled, isNot(contains('k2')));
    });

    testResolver('only placeholders are looked up, owned songs are skipped', (
      tester,
    ) async {
      host.playlist = [_owned('now'), _owned('a'), pending('k1'), _owned('b')];
      expect(resolver.schedule(), ['pending:k1']);
      expect(lookups.asked, ['k1']);
    });

    testResolver('a found song is swapped in place without a new lookup', (
      tester,
    ) async {
      host.playlist = [_owned('now'), pending('k1'), _owned('b')];
      resolver.schedule();
      lookups.answer('k1');
      await tester.pump();
      expect(host.swaps.single.$1, 'pending:k1');
      expect(host.playlist.map((s) => s.id), ['now', 'discovery:k1', 'b']);
      expect(resolver.resolvedPaths, {'/cache/k1.m4a'});
      expect(resolver.running, isEmpty);
    });

    testResolver('songs looked up lately are not asked for again', (
      tester,
    ) async {
      host.playlist = [_owned('now'), pending('k1')];
      resolver.schedule();
      lookups.answer('k1');
      await tester.pump();

      // Queued again later (a new placeholder for the same song).
      host.playlist = [_owned('now'), pending('k1')];
      expect(resolver.schedule(), isEmpty);
      expect(lookups.asked, ['k1']);
      expect(host.playlist[1].id, 'discovery:k1');

      // Past the time a lookup stays good, it's asked for afresh.
      now = now.add(const Duration(minutes: 21));
      host.playlist = [_owned('now'), pending('k1')];
      expect(resolver.schedule(), ['pending:k1']);
      expect(lookups.asked, ['k1', 'k1']);
    });

    testResolver('a song already being looked up is not asked for twice', (
      tester,
    ) async {
      host.playlist = [_owned('now'), pending('k1'), pending('k1')];
      resolver.schedule();
      resolver.schedule();
      expect(lookups.asked, ['k1']);
    });

    testResolver('a lookup for a song no longer coming up is cancelled', (
      tester,
    ) async {
      host.playlist = [_owned('now'), pending('k1'), pending('k2')];
      resolver.schedule();
      expect(lookups.asked, ['k1']);

      // The queue changes before k2's turn: k1 drops out, k2 never starts.
      host.playlist = [_owned('now'), _owned('other')];
      resolver.schedule();
      await tester.pump();
      expect(lookups.cancelled, ['k1']);
      await tester.pump(const Duration(seconds: 5));
      expect(lookups.asked, ['k1']);

      // Its late answer is dropped, not swapped in.
      lookups.answer('k1');
      await tester.pump();
      expect(host.swaps, isEmpty);
      expect(resolver.resolvedPaths, isEmpty);
    });

    testResolver('a staggered lookup checks it is still coming up', (
      tester,
    ) async {
      host.playlist = [_owned('now'), pending('k1'), pending('k2')];
      resolver.schedule();
      host.playlist = [_owned('now'), pending('k1')];
      await tester.pump(const Duration(seconds: 3));
      expect(lookups.asked, ['k1']);
    });

    testResolver('a song change looks ahead at once, a queue change shortly', (
      tester,
    ) async {
      final a = _owned('a'), b = _owned('b'), c = _owned('c');
      final d = _owned('d'), e = _owned('e');
      final k1 = pending('k1');
      host.playlist = [a, b, c, d, e, k1];
      // A skip or a crossfade moves the current song: looked up at once.
      host.playAt(1);
      expect(lookups.asked, ['k1']);

      // A song added next: looked up once the queue settles, and k1, no
      // longer among the next four, is cancelled.
      host.edit([a, b, pending('k2'), c, d, e, k1]);
      expect(lookups.asked, ['k1']);
      await tester.pump(const Duration(milliseconds: 599));
      expect(lookups.asked, ['k1']);
      await tester.pump(const Duration(milliseconds: 1));
      expect(lookups.asked, ['k1', 'k2']);
      expect(lookups.cancelled, ['k1']);
    });

    testResolver('wraps round on repeat-all', (tester) async {
      host
        ..playlist = [pending('k1'), _owned('a'), _owned('b')]
        ..currentIndex = 2;
      expect(resolver.schedule(), isEmpty);
      host.repeatAll = true;
      expect(resolver.schedule(), ['pending:k1']);
    });

    testResolver('playing a placeholder reuses the lookup under way', (
      tester,
    ) async {
      host.playlist = [_owned('now'), pending('k1'), _owned('b')];
      resolver.schedule();
      // Skipped to it: it's now the current song, so it isn't cancelled.
      host.playAt(1);
      final ready = resolver.resolveNow(host.playlist[1]);
      expect(lookups.asked, ['k1']);
      expect(lookups.cancelled, isEmpty);
      lookups.answer('k1');
      expect((await ready)?.id, 'discovery:k1');
      expect(host.playlist[1].id, 'discovery:k1');
      expect(lookups.cancelled, isEmpty);
    });

    testResolver('playing a placeholder looks it up on demand with status', (
      tester,
    ) async {
      final song = pending('k9');
      host.playlist = [song];
      final statuses = <String?>[];
      resolver.status.addListener(() => statuses.add(resolver.status.value));
      final ready = resolver.resolveNow(song);
      expect(lookups.asked, ['k9']);
      lookups.answer('k9');
      expect((await ready)?.filePath, '/cache/k9.m4a');
      expect(statuses, ['Preparing k9…', 'Getting k9 from Somewhere…', null]);
      // Asked again soon after: answered from what was found.
      expect((await resolver.resolveNow(song))?.id, 'discovery:k9');
      expect(lookups.asked, ['k9']);
    });

    testResolver('a song that can’t be found resolves to null', (tester) async {
      final song = pending('gone');
      host.playlist = [song];
      final ready = resolver.resolveNow(song);
      lookups.pending.remove('gone')!.complete(null);
      expect(await ready, isNull);
      expect(host.swaps, isEmpty);
      final unknown = Song(
        id: 'pending:unregistered',
        title: 'x',
        artist: 'y',
        duration: Duration.zero,
        fileType: 'ONLINE',
        sourcePackage: Song.pendingSourcePackage,
      );
      expect(await resolver.resolveNow(unknown), isNull);
    });
  });
}
