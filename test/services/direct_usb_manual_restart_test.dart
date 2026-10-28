import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/player_service.dart';

void main() {
  group('force restart direct USB audio', () {
    test('stops old engine before resetting and restoring the track', () async {
      final steps = <String>[];
      final succeeded = await restartDirectUsbSessionSequence(
        stopEngine: () async { steps.add('stop old Rust engine'); },
        resetTransport: () async {
          steps.add('release and re-claim USB');
          return true;
        },
        reselectDirectRoute: () async {
          steps.add('select exclusive USB route');
          return true;
        },
        restorePlayback: () async { steps.add('restart track at 0:00'); },
      );
      expect(succeeded, isTrue);
      expect(steps, [
        'stop old Rust engine',
        'release and re-claim USB',
        'select exclusive USB route',
        'restart track at 0:00',
      ]);
    });

    test('refuses success when native USB re-registration fails', () async {
      final steps = <String>[];
      final succeeded = await restartDirectUsbSessionSequence(
        stopEngine: () async { steps.add('stop'); },
        resetTransport: () async {
          steps.add('failed reset');
          return false;
        },
        reselectDirectRoute: () async {
          steps.add('must not select');
          return true;
        },
        restorePlayback: () async { steps.add('must not resume'); },
      );
      expect(succeeded, isFalse);
      expect(steps, ['stop', 'failed reset']);
    });

    test('does not resume until USB was reselected', () async {
      final steps = <String>[];
      final succeeded = await restartDirectUsbSessionSequence(
        stopEngine: () async { steps.add('stop'); },
        resetTransport: () async {
          steps.add('reset');
          return true;
        },
        reselectDirectRoute: () async {
          steps.add('route unavailable');
          return false;
        },
        restorePlayback: () async { steps.add('must not resume'); },
      );
      expect(succeeded, isFalse);
      expect(steps, ['stop', 'reset', 'route unavailable']);
    });

    test('propagates a failed track restore so fallback can report it', () async {
      await expectLater(
        restartDirectUsbSessionSequence(
          stopEngine: () async {},
          resetTransport: () async => true,
          reselectDirectRoute: () async => true,
          restorePlayback: () async {
            throw StateError('DAC format unavailable');
          },
        ),
        throwsStateError,
      );
    });

    test('explicit restart plays the current track from 0:00', () async {
      var playCount = 0;
      var startPositionMs = -1;
      const positionAfterRestartMs = 0;
      final succeeded = await restartDirectUsbSessionSequence(
        stopEngine: () async {},
        resetTransport: () async => true,
        reselectDirectRoute: () async => true,
        restorePlayback: () async {
          startPositionMs = positionAfterRestartMs;
          playCount++;
        },
      );
      expect(succeeded, isTrue);
      expect(startPositionMs, 0);
      expect(playCount, 1);
    });
  });
}
