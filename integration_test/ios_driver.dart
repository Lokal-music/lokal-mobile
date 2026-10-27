import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  timeout: Duration(
    minutes: Platform.environment['LOKAL_IOS_VIDEO_PROBE'] == 'true' ? 6 : 4,
  ),
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    final output = Directory(
      Platform.environment['LOKAL_IOS_RUNTIME_EVIDENCE_DIR'] ??
          Platform.environment['RUNNER_TEMP'] ??
          'build/ios/runtime-evidence',
    );
    await output.create(recursive: true);
    final report = Map<String, dynamic>.from(data ?? {});
    report['workflow_run_id'] = Platform.environment['GITHUB_RUN_ID'];
    report['workflow_run_attempt'] = Platform.environment['GITHUB_RUN_ATTEMPT'];
    report['source_commit'] = Platform.environment['GITHUB_SHA'];
    report['simulator_runtime'] = Platform.environment['IOS_SIMULATOR_RUNTIME'];
    final screenshots = report.remove('screenshots') as List<dynamic>? ?? [];
    final images = <String>[];
    try {
      for (final image in screenshots) {
        final snapshot = image as Map<String, dynamic>;
        final name = snapshot['screenshotName'] as String;
        if (!RegExp(r'^ios-[a-z-]+$').hasMatch(name)) {
          throw StateError('Invalid screenshot artifact name');
        }
        final bytes = (snapshot['bytes'] as List<dynamic>).cast<int>();
        if (bytes.length < 8 ||
            bytes.take(8).join(',') != '137,80,78,71,13,10,26,10') {
          throw StateError('The native screenshot is not a PNG');
        }
        await File('${output.path}/$name.png').writeAsBytes(bytes, flush: true);
        images.add('$name.png');
      }
    } catch (error) {
      report['evidence_export_error'] = error.toString();
      rethrow;
    } finally {
      report['screenshots'] = images;
      await writeResponseData(
        report,
        testOutputFilename: 'ios-runtime-report',
        destinationDirectory: output.path,
      );
    }
  },
);
