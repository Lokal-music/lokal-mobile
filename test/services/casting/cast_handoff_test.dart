import 'package:flutter_test/flutter_test.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/playback_output_transition.dart';
import 'package:flick/services/casting/cast_handoff.dart';

const _song = Song(
  id: 'one',
  title: 'One',
  artist: 'Fixture',
  duration: Duration(minutes: 3),
  fileType: 'WAV',
);

class _Handoff {
  final calls = <String>[];
  bool current = true;
  bool localPlaying = true;
  bool remotePlaying = false;
  bool claimed = false;
  bool wasPlaying = true;
  Song? song = _song;
  String? failAt;
  String? invalidateAt;
  bool failShutdown = false;

  Future<void> step(String name) async {
    calls.add(name);
    if (invalidateAt == name) current = false;
    if (failAt == name || (failShutdown && name == 'disconnect')) {
      throw StateError(name);
    }
  }

  Future<void> run() => handoffToCast(
    local: PlaybackOutputTransition(
      song: song,
      position: const Duration(seconds: 17),
      wasPlaying: wasPlaying,
      isCurrent: () => current,
      pauseLocal: () async {
        await step('pauseLocal');
        localPlaying = false;
      },
      resumeLocal: () async {
        expect(
          remotePlaying,
          isFalse,
          reason: 'receiver must stop before local resume',
        );
        await step('resumeLocal');
        localPlaying = true;
      },
    ),
    connect: () => step('connect'),
    preparePaused: () async {
      await step('preparePaused');
      remotePlaying = false;
    },
    play: () async {
      expect(
        localPlaying,
        isFalse,
        reason: 'phone must yield before remote play',
      );
      // Model an unknown outcome: receiver may start before a lost reply.
      remotePlaying = true;
      await step('play');
    },
    disconnect: () async {
      await step('disconnect');
      remotePlaying = false;
    },
    claimRemote: () {
      calls.add('claim');
      claimed = true;
    },
    releaseRemote: () {
      calls.add('release');
      claimed = false;
    },
  );
}

void main() {
  test(
    'confirmed transfer prepares paused then yields local audio before play',
    () async {
      final h = _Handoff();
      await h.run();
      expect(h.calls, [
        'connect',
        'preparePaused',
        'pauseLocal',
        'claim',
        'play',
      ]);
      expect(h.localPlaying, isFalse);
      expect(h.remotePlaying, isTrue);
      expect(h.claimed, isTrue);
    },
  );

  test('paused source stays paused on both outputs', () async {
    final h = _Handoff()
      ..wasPlaying = false
      ..localPlaying = false;
    await h.run();
    expect(h.calls, ['connect', 'preparePaused', 'claim']);
    expect(h.remotePlaying, isFalse);
    expect(h.localPlaying, isFalse);
  });

  test('empty queue connects without starting or pausing audio', () async {
    final h = _Handoff()
      ..song = null
      ..wasPlaying = false
      ..localPlaying = false;
    await h.run();
    expect(h.calls, ['connect', 'claim']);
  });

  for (final step in ['connect', 'preparePaused']) {
    test(
      '$step failure leaves local playback untouched after confirmed cleanup',
      () async {
        final h = _Handoff()..failAt = step;
        await expectLater(h.run(), throwsStateError);
        expect(h.localPlaying, isTrue);
        expect(h.claimed, isFalse);
        expect(h.calls, isNot(contains('pauseLocal')));
        expect(h.calls.last, 'disconnect');
      },
    );
  }

  test(
    'lost play acknowledgement stops receiver before releasing and resuming',
    () async {
      final h = _Handoff()..failAt = 'play';
      await expectLater(h.run(), throwsStateError);
      expect(h.calls.sublist(5), ['disconnect', 'release', 'resumeLocal']);
      expect(h.localPlaying, isTrue);
      expect(h.remotePlaying, isFalse);
      expect(h.claimed, isFalse);
    },
  );

  for (final step in ['connect', 'preparePaused', 'pauseLocal', 'play']) {
    test(
      'new selection during $step cancels stale handoff without resuming old song',
      () async {
        final h = _Handoff()..invalidateAt = step;
        await expectLater(h.run(), throwsA(isA<CastHandoffCancelled>()));
        expect(h.remotePlaying, isFalse);
        expect(h.claimed, isFalse);
        expect(h.calls, isNot(contains('resumeLocal')));
      },
    );
  }

  test(
    'unconfirmed remote shutdown keeps ownership and local audio paused',
    () async {
      final h = _Handoff()
        ..failAt = 'play'
        ..failShutdown = true;
      await expectLater(h.run(), throwsA(isA<CastHandoffUncertain>()));
      expect(h.claimed, isTrue);
      expect(h.localPlaying, isFalse);
      expect(h.calls, isNot(contains('resumeLocal')));
      expect(h.calls, isNot(contains('release')));
    },
  );

  test('failed early cleanup also yields local engine before quarantining ownership', () async {
    final h = _Handoff()
      ..failAt = 'connect'
      ..failShutdown = true;
    await expectLater(h.run(), throwsA(isA<CastHandoffUncertain>()));
    expect(h.calls, ['connect', 'disconnect', 'pauseLocal', 'claim']);
    expect(h.localPlaying, isFalse);
    expect(h.claimed, isTrue);
  });
}
