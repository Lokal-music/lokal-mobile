/// Preserve the first acceptance failure while still attempting every cleanup.
/// A cleanup failure also fails an otherwise successful probe. Bounding a wait
/// here never acknowledges, cancels or replaces the underlying native output.
Future<void> runNativeProbeWithCleanup({
  required String name,
  required Map<String, dynamic> report,
  required Future<void> Function() body,
  required Map<String, Future<void> Function()> cleanup,
}) async {
  Object? primaryError;
  try {
    await body();
  } catch (error, stack) {
    primaryError = error;
    report['${name}_primary_failure'] = {
      'error': error.toString(),
      'stack': stack.toString(),
    };
    rethrow;
  } finally {
    Object? cleanupError;
    StackTrace? cleanupStack;
    final failures = <Map<String, String>>[];
    for (final stage in cleanup.entries) {
      try {
        await stage.value();
      } catch (error, stack) {
        failures.add({
          'stage': stage.key,
          'error': error.toString(),
          'stack': stack.toString(),
        });
        cleanupError ??= error;
        cleanupStack ??= stack;
      }
    }
    if (failures.isNotEmpty) report['${name}_cleanup_failures'] = failures;
    if (primaryError == null && cleanupError != null) {
      Error.throwWithStackTrace(cleanupError, cleanupStack!);
    }
  }
}
