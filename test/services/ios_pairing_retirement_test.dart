import 'package:flick/models/ios_transfer_models.dart';
import 'package:flick/models/lokal_remote_state.dart';
import 'package:flick/services/ios_pairing_retirement.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const id = '14093104-64d4-44f7-8c8b-8b4b14399067';
  const other = 'a7d96b93-6526-4f1f-a1af-688ffb5c799d';
  const nativeScope = IosTransferScope(
    desktopId: 'contract-desktop',
    origin: 'http://192.0.2.20:5443',
    pairingId: id,
  );
  final credentials = LokalRemoteCredentials(
    origin: Uri.parse('http://192.0.2.20:5443'),
    desktopId: nativeScope.desktopId,
    pairingID: id,
    remoteToken: 'synthetic-bearer-never-sent-to-native',
  );
  IosTransferSummary summary({
    int total = 0,
    String? phase,
    IosTransferScope? pauseScope,
    bool persistenceFailed = false,
  }) => IosTransferSummary.fromJson({
    'generation': 3,
    'total': total,
    'counts': phase == null ? <String, int>{} : {phase: total},
    'progress': <Object>[],
    'pauses': [
      if (pauseScope != null)
        {'scope': pauseScope.toJson(), 'reason': 'pairingChanged'},
    ],
    'persistenceFailed': persistenceFailed,
  });
  final pairing = IosTransferPairing.fromJson({'scope': nativeScope.toJson()});

  test(
    'matching Keychain pairing retires before allowing credential deletion',
    () async {
      final events = <String>[];
      await IosPairingRetirement.retireBeforeForget(
        reconcileImports: (_) async {
          events.add('isar-before');
        },
        reconcileReservations: (_) async {
          events.add('isar-after');
        },
        expected: credentials,
        recover: () async {
          events.add('recover');
          return summary(total: 2, phase: 'queued');
        },
        currentPairing: () async {
          events.add('keychain');
          return pairing;
        },
        retire: (scope) async {
          events.add('retire');
          expect(IosPairingRetirement.sameScope(scope, nativeScope), isTrue);
          return summary(total: 2, phase: 'cancelled', pauseScope: scope);
        },
      );
      expect(events, [
        'recover',
        'keychain',
        'isar-before',
        'retire',
        'isar-after',
      ]);
    },
  );

  test(
    'failed import reconciliation prevents native retirement and Forget',
    () async {
      final events = <String>[];
      await expectLater(
        IosPairingRetirement.retireBeforeForget(
          expected: credentials,
          recover: () async => summary(),
          currentPairing: () async => pairing,
          reconcileImports: (_) async {
            events.add('before');
            throw StateError('missing Isar proof');
          },
          retire: (_) async {
            events.add('retire');
            return summary(pauseScope: nativeScope);
          },
          reconcileReservations: (_) async {
            events.add('after');
          },
        ),
        throwsStateError,
      );
      expect(events, ['before']);
    },
  );

  test(
    'failed reservation reconciliation blocks Forget after durable retirement',
    () async {
      final events = <String>[];
      await expectLater(
        IosPairingRetirement.retireBeforeForget(
          expected: credentials,
          recover: () async => summary(),
          currentPairing: () async => pairing,
          reconcileImports: (_) async {
            events.add('before');
          },
          retire: (_) async {
            events.add('retire');
            return summary(pauseScope: nativeScope);
          },
          reconcileReservations: (_) async {
            events.add('after');
            throw StateError('retiring Isar receipt');
          },
        ),
        throwsStateError,
      );
      expect(events, ['before', 'retire', 'after']);
    },
  );

  test('mismatch never retires and blocks credential clear', () async {
    var attempted = false;
    final changed = IosTransferPairing.fromJson({
      'scope': nativeScope.toJson()..['pairingID'] = other,
    });
    await expectLater(
      IosPairingRetirement.retireBeforeForget(
        reconcileImports: (_) async {},
        reconcileReservations: (_) async {},
        expected: credentials,
        recover: () async => summary(total: 1, phase: 'queued'),
        currentPairing: () async => changed,
        retire: (_) async {
          attempted = true;
          return summary();
        },
      ),
      throwsStateError,
    );
    expect(attempted, isFalse);
  });

  test(
    'legacy/no Keychain pairing is safe only with empty native journal',
    () async {
      final legacy = LokalRemoteCredentials(
        origin: credentials.origin,
        desktopId: credentials.desktopId,
        remoteToken: credentials.remoteToken,
      );
      var retirementCalled = false;
      Future<void> attempt(int total) =>
          IosPairingRetirement.retireBeforeForget(
            reconcileImports: (_) async {},
            reconcileReservations: (_) async {},
            expected: legacy,
            recover: () async => summary(
              total: total,
              phase: total == 0 ? null : 'transferring',
            ),
            currentPairing: () async => null,
            retire: (_) async {
              retirementCalled = true;
              return summary();
            },
          );
      await attempt(0);
      await expectLater(attempt(1), throwsStateError);
      expect(retirementCalled, isFalse);
    },
  );

  test('native Keychain missing for a v2 pairing fails closed', () async {
    await expectLater(
      IosPairingRetirement.retireBeforeForget(
        reconcileImports: (_) async {},
        reconcileReservations: (_) async {},
        expected: credentials,
        recover: () async => summary(),
        currentPairing: () async => null,
        retire: (_) async => summary(),
      ),
      throwsStateError,
    );
  });

  test(
    'invalid native receipt, journal failure and transport errors block Forget',
    () async {
      for (final scenario in [
        'failedRecovery',
        'missingTombstone',
        'throwingCancel',
      ]) {
        await expectLater(
          IosPairingRetirement.retireBeforeForget(
            reconcileImports: (_) async {},
            reconcileReservations: (_) async {},
            expected: credentials,
            recover: () async =>
                summary(persistenceFailed: scenario == 'failedRecovery'),
            currentPairing: () async => pairing,
            retire: (_) async {
              if (scenario == 'throwingCancel')
                throw StateError('native failed');
              return summary(total: 1, phase: 'cancelled');
            },
          ),
          throwsStateError,
        );
      }
    },
  );

  test('origin normalization accepts only the same exact desktop endpoint', () {
    expect(
      IosPairingRetirement.sameScope(
        const IosTransferScope(
          desktopId: 'contract-desktop',
          origin: 'http://192.0.2.20:5443/',
          pairingId: id,
        ),
        nativeScope,
      ),
      isTrue,
    );
    expect(
      IosPairingRetirement.sameScope(
        const IosTransferScope(
          desktopId: 'contract-desktop',
          origin: 'http://192.0.2.21:5443',
          pairingId: id,
        ),
        nativeScope,
      ),
      isFalse,
    );
  });
}
