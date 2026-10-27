import 'dart:async';

import 'package:flick/services/external_playback_owner.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../integration_test/native_probe_cleanup.dart';

void main() {
  test(
    'decoder failure survives native release and unmount failures',
    () async {
      final report = <String, dynamic>{};
      final decoderFailure = StateError('Local decoder never became ready');
      final primaryStack = StackTrace.fromString('original decoder gate');
      final attempted = <String>[];
      StackTrace? observedStack;
      try {
        await runNativeProbeWithCleanup(
          name: 'video',
          report: report,
          body: () async =>
              Error.throwWithStackTrace(decoderFailure, primaryStack),
          cleanup: {
            'native_release': () async {
              attempted.add('native_release');
              throw TimeoutException('Native suspension did not acknowledge');
            },
            'unmount': () async {
              attempted.add('unmount');
              throw StateError('Platform view teardown failed');
            },
            'observers': () async => attempted.add('observers'),
          },
        );
        fail('The decoder failure must propagate');
      } catch (error, stack) {
        expect(error, same(decoderFailure));
        observedStack = stack;
      }
      expect(observedStack.toString(), primaryStack.toString());
      expect(attempted, ['native_release', 'unmount', 'observers']);
      expect(report['video_primary_failure']['error'], contains('decoder'));
      expect(
        (report['video_cleanup_failures'] as List).map((item) => item['stage']),
        ['native_release', 'unmount'],
      );
    },
  );

  test(
    'unconfirmed release fails a successful body and retains ownership',
    () async {
      final report = <String, dynamic>{};
      final owner = ExternalPlaybackOwner();
      final nativeQuiet = Completer<void>();
      final lease = owner.claim(() => nativeQuiet.future);
      var observersRemoved = false;
      await expectLater(
        runNativeProbeWithCleanup(
          name: 'video',
          report: report,
          body: () async {},
          cleanup: {
            'native_release': () => lease.release().timeout(Duration.zero),
            'observers': () async => observersRemoved = true,
          },
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(observersRemoved, isTrue);
      expect(report.containsKey('video_primary_failure'), isFalse);
      expect(report['video_cleanup_failures'], hasLength(1));
      expect(lease.isReleased, isFalse);
      expect(() => owner.claim(() async {}), throwsStateError);
      // The bounded diagnostic wait does not cancel or acknowledge native work.
      nativeQuiet.complete();
      await lease.release();
      expect(lease.isReleased, isTrue);
      await owner.releaseCurrent();
      owner.claim(() async {});
    },
  );

  test(
    'successful body and native cleanup leave no failure evidence',
    () async {
      final report = <String, dynamic>{};
      final owner = ExternalPlaybackOwner();
      final lease = owner.claim(() async {});
      await runNativeProbeWithCleanup(
        name: 'video',
        report: report,
        body: () async {},
        cleanup: {'native_release': lease.release},
      );
      expect(lease.isReleased, isTrue);
      expect(report, isEmpty);
    },
  );
}
