import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 4),
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
    report['source_commit'] = Platform.environment['GITHUB_SHA'];
    report['simulator_runtime'] = Platform.environment['IOS_SIMULATOR_RUNTIME'];
    final screenshots = report.remove('screenshots') as List<dynamic>? ?? [];
    final images = <String>[];
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
    report['screenshots'] = images;
    await writeResponseData(
      report,
      testOutputFilename: 'ios-runtime-report',
      destinationDirectory: output.path,
    );
  },
);
