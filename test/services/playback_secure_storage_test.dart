import 'dart:async';

import 'package:flick/services/playback_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a new account never joins an older unrelated migration', () async {
    final migrations = <String?, Completer<void>>{};
    final preparation = PlaybackCredentialPreparation((key) {
      final pending = Completer<void>();
      migrations[key] = pending;
      return pending.future;
    });
    final older = preparation.prepare(key: 'existing-vault');
    // A plugin legacy write finishes while the older migration is in flight.
    var newReadReady = false;
    final newer = preparation.prepare(key: 'just-written').then((_) {
      newReadReady = true;
    });
    expect(migrations.keys, containsAll(['existing-vault', 'just-written']));
    migrations['existing-vault']!.complete();
    await older;
    expect(newReadReady, false);
    migrations['just-written']!.complete();
    await newer;
    expect(newReadReady, true);
  });

  test('same-account callers share only their in-flight preparation', () async {
    var calls = 0;
    var pending = Completer<void>();
    final preparation = PlaybackCredentialPreparation((_) {
      calls++;
      return pending.future;
    });
    final first = preparation.prepare(key: 'same');
    final second = preparation.prepare(key: 'same');
    expect(calls, 1);
    pending.complete();
    await Future.wait([first, second]);
    pending = Completer<void>();
    final later = preparation.prepare(key: 'same');
    expect(calls, 2);
    pending.complete();
    await later;
  });

  test('global enumeration cannot satisfy a newer keyed preparation', () async {
    final pending = <String?, Completer<void>>{};
    final preparation = PlaybackCredentialPreparation((key) {
      return (pending[key] = Completer<void>()).future;
    });
    final global = preparation.prepare();
    final keyed = preparation.prepare(key: 'new-legacy-item');
    expect(pending.keys, containsAll([null, 'new-legacy-item']));
    pending[null]!.complete();
    await global;
    pending['new-legacy-item']!.complete();
    await keyed;
  });

  test(
    'failed preparation is observable and a later attempt can retry',
    () async {
      var calls = 0;
      final preparation = PlaybackCredentialPreparation((_) async {
        if (++calls == 1) throw StateError('locked');
      });
      await expectLater(preparation.prepare(key: 'vault'), throwsStateError);
      await preparation.prepare(key: 'vault');
      expect(calls, 2);
    },
  );
}
