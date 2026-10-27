import 'package:flick/services/motion_art/shared_motion_playback.dart';
import 'package:flutter_test/flutter_test.dart';

class Clip {
  int frame = 42;
  bool playing = false;
  bool disposed = false;
}

void main() {
  test('expansion can take an existing frame synchronously without a second decode', () async {
    var created = 0;
    final pool = SharedMotionPlayback<Clip>(
      create: (_) async {
        created++;
        return Clip();
      },
      activate: (clip, active) async => clip.playing = active,
      dispose: (clip) async => clip.disposed = true,
    );
    expect(pool.acquireExisting('not-loaded'), isNull);
    final mini = await pool.acquire('song', 'https://video.test/canvas.mp4');
    await mini.setActive(true);
    mini.resource.frame = 321;
    final preview = pool.acquireExisting('song')!;
    expect(preview.resource, same(mini.resource));
    expect(preview.resource.frame, 321);
    await preview.setActive(
      false,
    ); // TickerMode is disabled in the pull preview.
    expect(mini.resource.playing, isTrue);
    expect(created, 1);
    await preview.release(immediate: true);
    await mini.release(immediate: true);
  });

  test('full player and thumbnail share one decoder and the same frame across handoff', () async {
    var created = 0, disposed = 0;
    final pool = SharedMotionPlayback<Clip>(
      create: (_) async {
        created++;
        return Clip();
      },
      activate: (clip, active) async => clip.playing = active,
      dispose: (clip) async {
        clip.disposed = true;
        disposed++;
      },
    );
    final full = await pool.acquire('player:42', 'https://video.test/loop.mp4');
    await full.setActive(true);
    full.resource.frame = 128;
    await full.release();
    final mini = await pool.acquire('player:42', 'https://video.test/loop.mp4');
    await mini.setActive(true);
    expect(created, 1);
    expect(mini.resource, same(full.resource));
    expect(mini.resource.frame, 128);
    expect(mini.resource.playing, isTrue);
    await mini.release(immediate: true);
    expect(disposed, 1);
  });
  test('a hidden view cannot pause a visible view and suppression disposes the shared decoder', () async {
    final pool = SharedMotionPlayback<Clip>(
      create: (_) async => Clip(),
      activate: (clip, active) async => clip.playing = active,
      dispose: (clip) async => clip.disposed = true,
    );
    final mini = await pool.acquire('song', 'https://video.test/canvas.mp4');
    final full = await pool.acquire('song', 'https://video.test/canvas.mp4');
    await full.setActive(true);
    await mini.setActive(false);
    expect(full.resource.playing, isTrue);
    await full.setActive(false);
    expect(full.resource.playing, isFalse);
    await mini.release(immediate: true);
    expect(full.resource.disposed, isFalse);
    await full.release(immediate: true);
    expect(full.resource.disposed, isTrue);
  });
  test('last lease pauses during handoff and resumes without decoding again', () async {
    var created = 0;
    var disposed = 0;
    final transitions = <bool>[];
    final pool = SharedMotionPlayback<Clip>(
      create: (_) async {
        created++;
        return Clip();
      },
      activate: (clip, active) async {
        clip.playing = active;
        transitions.add(active);
      },
      dispose: (clip) async {
        clip.disposed = true;
        disposed++;
      },
    );

    final first = await pool.acquire('song', 'https://video.test/loop.mp4');
    await first.setActive(true);
    await first.release();
    expect(first.resource.playing, isFalse);
    expect(disposed, 0, reason: 'retain the decoder for a short handoff');

    final next = await pool.acquire('song', 'https://video.test/loop.mp4');
    expect(next.resource, same(first.resource));
    await next.setActive(true);
    expect(next.resource.playing, isTrue);
    expect(created, 1);
    await next.release(immediate: true);
    expect(disposed, 1);
    expect(transitions, [true, false, true, false]);
  });

}
