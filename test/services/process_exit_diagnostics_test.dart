import 'package:flick/services/process_exit_diagnostics_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ambiguous SIGKILL is not labeled as a confirmed crash', () {
    expect(
      ProcessExitDiagnosticsService.isLikelyCrash(reason: 2, status: 9),
      isFalse,
    );
    expect(
      ProcessExitDiagnosticsService.isLikelyCrash(reason: 2, status: 15),
      isFalse,
    );
  });

  test('native fatal signals and known Android failure reasons remain crashes', () {
    for (final signal in [4, 5, 6, 7, 8, 11]) {
      expect(
        ProcessExitDiagnosticsService.isLikelyCrash(reason: 2, status: signal),
        isTrue,
      );
    }
    for (final reason in [3, 4, 5, 6, 7, 9, 12]) {
      expect(
        ProcessExitDiagnosticsService.isLikelyCrash(reason: reason, status: 0),
        isTrue,
      );
    }
    expect(
      ProcessExitDiagnosticsService.isLikelyCrash(reason: 16, status: 0),
      isFalse,
    );
  });
}
