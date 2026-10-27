import 'dart:async';

import 'package:flick/services/local_audio_lifecycle.dart';
import 'package:flick/services/rust_audio_polling.dart';
import 'package:flick/services/rust_playback_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'queued transport gets prompt observations until actual state settles',
    (tester) async {
      var state = RustPlaybackState.paused;
      var position = 0;
      var events = 0, progress = 0;
      final polling = RustAudioPolling(
        state: () => state,
        progress: () => progress++,
        events: () {
          if (++events == 3) position = 2000;
        },
      );
      try {
        polling.startEvents(until: () => position == 2000);
        await tester.pump(const Duration(milliseconds: 100));
        expect(events, 3);
        expect(position, 2000);
        expect(progress, 0);
        await tester.pump(const Duration(milliseconds: 499));
        expect(events, 3, reason: 'Settled seek returns to paused cadence');
        await tester.pump(const Duration(milliseconds: 1));
        expect(events, 4);
        state = RustPlaybackState.playing;
        polling.startEvents(until: () => state == RustPlaybackState.playing);
        await tester.pump(const Duration(milliseconds: 100));
        expect(progress, 2);
      } finally {
        polling.stop();
      }
    },
  );

  testWidgets(
    'an unsettled native command cannot keep paused fast polling indefinitely',
    (tester) async {
      var events = 0;
      final polling = RustAudioPolling(
        state: () => RustPlaybackState.paused,
        progress: () {},
        events: () => events++,
      );
      try {
        polling.startEvents(until: () => false);
        await tester.pump(const Duration(seconds: 2));
        final before = events;
        await tester.pump(const Duration(seconds: 2));
        expect(events - before, 4);
      } finally {
        polling.stop();
      }
    },
  );
  testWidgets(
    'late native pause acknowledgement cannot restart a retired poller',
    (tester) async {
      var epoch = BigInt.zero;
      var observations = 0;
      final nativePause = Completer<void>();
      final quiet = Completer<void>();
      final polling = RustAudioPolling(
        state: () => RustPlaybackState.playing,
        progress: () => observations++,
        events: () => observations++,
      );
      final lifecycle = LocalAudioLifecycle(
        nativeEpoch: () => epoch,
        destroyNativeOutput: () async {},
        restoreSession: () async {},
      );
      lifecycle.register(polling, () async {
        polling.stop();
        await quiet.future;
      });
      polling.startEvents();
      final oldPause = lifecycle.run(() async {
        await lifecycle.waitFor(nativePause.future);
        polling.startEvents();
      });
      final rejected = expectLater(
        oldPause,
        throwsA(isA<LocalAudioRequestRetired>()),
      );
      epoch = BigInt.one;
      final cleanup = lifecycle.accept(LocalAudioNativeEvent.reset, epoch);
      await tester.pump();
      await rejected;
      final before = observations;
      nativePause.complete();
      quiet.complete();
      await cleanup;
      polling.setForeground(false);
      polling.setForeground(true);
      await tester.pump(const Duration(seconds: 5));
      expect(observations, before);
      expect(polling.observingEvents, isFalse);
      lifecycle.unregister(polling);
    },
  );
  for (final foreground in [true, false]) {
    testWidgets(
      'active ${foreground ? 'foreground' : 'background'} observations retain the expected work budget',
      (tester) async {
        var progress = 0, events = 0;
        final polling = RustAudioPolling(
          state: () => RustPlaybackState.playing,
          progress: () => progress++,
          events: () => events++,
        );
        try {
          polling.setForeground(foreground);
          expect(progress, 0);
          expect(
            events,
            0,
            reason: 'Visibility changes never initialize an output',
          );
          polling.startEvents();
          await tester.pump(const Duration(seconds: 1));
          expect(progress, foreground ? 20 : 4);
          expect(
            events,
            foreground ? 21 : 5,
          ); // Includes the immediate state poll.
        } finally {
          polling.stop();
        }
      },
    );
  }

  testWidgets(
    'paused events remain observable without repeated progress reads',
    (tester) async {
      var state = RustPlaybackState.playing;
      var progress = 0, events = 0;
      final polling = RustAudioPolling(
        state: () => state,
        progress: () => progress++,
        events: () => events++,
      );
      try {
        polling.startEvents();
        await tester.pump(const Duration(milliseconds: 100));
        state = RustPlaybackState.paused;
        polling.stopProgress();
        polling.startEvents();
        final before = progress;
        final eventBaseline = events;
        await tester.pump(const Duration(seconds: 2));
        expect(progress, before);
        expect(events - eventBaseline, 4);
        polling.setForeground(false);
        final backgroundBaseline = events;
        await tester.pump(const Duration(seconds: 2));
        expect(progress, before);
        expect(events - backgroundBaseline, 2);
        // A later native transition is still delivered; it resumes observation,
        // not audio playback or a native output constructor.
        state = RustPlaybackState.playing;
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(milliseconds: 250));
        expect(progress, greaterThan(before));
      } finally {
        polling.stop();
      }
    },
  );

  testWidgets('idle engine does not poll at the active rate', (tester) async {
    var progress = 0, events = 0;
    final polling = RustAudioPolling(
      state: () => RustPlaybackState.idle,
      progress: () => progress++,
      events: () => events++,
    );
    try {
      polling.setForeground(false);
      polling.startEvents();
      await tester.pump(const Duration(seconds: 6));
      expect(progress, 0);
      expect(events, 4);
    } finally {
      polling.stop();
    }
  });

  testWidgets(
    'callback retirement cannot resurrect either timer on foreground',
    (tester) async {
      var events = 0, progress = 0;
      late RustAudioPolling polling;
      polling = RustAudioPolling(
        state: () => RustPlaybackState.playing,
        progress: () => progress++,
        events: () {
          events++;
          polling.stop();
        },
      );
      polling.startEvents();
      polling.setForeground(false);
      polling.setForeground(true);
      await tester.pump(const Duration(seconds: 30));
      expect(events, 1);
      expect(progress, 0);
      expect(polling.observingEvents, isFalse);
    },
  );

  testWidgets(
    'progress callback retirement prevents its finalizer from rescheduling',
    (tester) async {
      var events = 0, progress = 0;
      late RustAudioPolling polling;
      polling = RustAudioPolling(
        state: () => RustPlaybackState.playing,
        progress: () {
          progress++;
          polling.stop();
        },
        events: () => events++,
      );
      polling.startEvents();
      await tester.pump(const Duration(seconds: 30));
      expect(progress, 1);
      expect(events, 1);
    },
  );

  testWidgets(
    'synchronous session replacement keeps one event/progress schedule',
    (tester) async {
      var events = 0, progress = 0;
      late RustAudioPolling polling;
      polling = RustAudioPolling(
        state: () => RustPlaybackState.playing,
        progress: () => progress++,
        events: () {
          events++;
          if (events == 1) polling.startEvents();
        },
      );
      try {
        polling.startEvents();
        await tester.pump(const Duration(milliseconds: 100));
        expect(events, 4); // Two initial callbacks, then one per interval.
        expect(progress, 2);
      } finally {
        polling.stop();
      }
    },
  );

  testWidgets(
    'an event callback exception propagates and preserves future delivery',
    (tester) async {
      var events = 0;
      final polling = RustAudioPolling(
        state: () => RustPlaybackState.idle,
        progress: () {},
        events: () {
          if (++events == 1) throw StateError('Controlled consumer failure');
        },
      );
      try {
        expect(polling.startEvents, throwsStateError);
        await tester.pump(const Duration(seconds: 1));
        expect(events, 2);
      } finally {
        polling.stop();
      }
    },
  );

  testWidgets(
    'native reset retains unacknowledged cleanup without idle/foreground revival',
    (tester) async {
      var epoch = BigInt.zero;
      var progress = 0, events = 0;
      final quiet = Completer<void>();
      final polling = RustAudioPolling(
        state: () => RustPlaybackState.playing,
        progress: () => progress++,
        events: () => events++,
      );
      final lifecycle = LocalAudioLifecycle(
        nativeEpoch: () => epoch,
        destroyNativeOutput: () async {},
        restoreSession: () async {},
      );
      lifecycle.register(polling, () async {
        polling.stop();
        await quiet.future;
      });
      polling.startEvents();
      epoch = BigInt.one;
      final cleanup = lifecycle.accept(LocalAudioNativeEvent.reset, epoch);
      await tester.pump();
      final beforeEvents = events, beforeProgress = progress;
      polling.setForeground(false);
      polling.setForeground(true);
      await tester.pump(const Duration(seconds: 10));
      expect(events, beforeEvents);
      expect(progress, beforeProgress);
      expect(lifecycle.phase.value, LocalAudioPhase.recovering);
      quiet.complete();
      await cleanup;
      expect(lifecycle.phase.value, LocalAudioPhase.paused);
      expect(progress, beforeProgress);
      lifecycle.unregister(polling);
    },
  );
}
