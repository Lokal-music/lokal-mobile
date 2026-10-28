import 'dart:async';

import 'package:flick/services/link/copy_check_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'cancel returns promptly even if the current I/O never answers',
    () async {
      final guard = CopyCheckGuard();
      final blocked = Completer<int>();
      final result = guard.run(() => blocked.future);
      final expectation = expectLater(result, throwsStateError);
      guard.cancel();
      await expectation;
      expect(guard.check, throwsStateError);
      blocked.complete(1);
    },
  );
  test(
    'active file checks may exceed the idle limit without timing out',
    () async {
      final guard = CopyCheckGuard(limit: const Duration(milliseconds: 100));
      final result = guard.run(() async {
        for (var index = 0; index < 8; index++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          guard.pulse();
        }
        return 42;
      });
      expect(await result, 42);
    },
  );

  test(
    'timeout stops late work from publishing further preview progress',
    () async {
      final guard = CopyCheckGuard(limit: const Duration(milliseconds: 5));
      final blocked = Completer<void>();
      var published = false;
      final result = guard.run(() async {
        await blocked.future;
        guard.check();
        published = true;
      });
      await expectLater(result, throwsStateError);
      blocked.complete();
      await Future<void>.delayed(Duration.zero);
      expect(published, isFalse);
    },
  );
}
