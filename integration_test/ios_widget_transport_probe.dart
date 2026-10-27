import 'package:flick/models/ios_widget_snapshot.dart';
import 'package:flick/services/ios_widget_method_channel_transport.dart';
import 'package:flick/services/ios_widget_publication_coordinator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// The standalone simulator bundle deliberately has no configured App Group.
/// Exercise the actual registered bridge; never invent a container to make an
/// unsigned simulator installation appear to support provisioned widgets.
Future<void> probeIosWidgetTransport(
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  final transport = IosWidgetMethodChannelTransport();
  final capability = await transport.capability().timeout(
    const Duration(seconds: 5),
  );
  expect(capability.available, false);
  expect(
    capability.unavailableReason,
    IosWidgetUnavailableReason.notConfigured,
  );
  await expectLater(
    transport
        .publish(
          IosWidgetSnapshot.fromJson({
            'schemaVersion': 1,
            'revision': 1,
            'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
          }),
          const {},
          reloadTimelines: false,
        )
        .timeout(const Duration(seconds: 5)),
    throwsA(
      isA<PlatformException>().having(
        (error) => error.code,
        'code',
        'WIDGETS_UNAVAILABLE',
      ),
    ),
  );
  await expectLater(
    const MethodChannel('lokal/widgets')
        .invokeMethod<void>('unsupported-operation'),
    throwsA(
      isA<PlatformException>().having(
        (error) => error.code,
        'code',
        'UNSUPPORTED_WIDGET_METHOD',
      ),
    ),
  );
  binding.reportData!['widget_unconfigured_installation'] = {
    'scope':
        'Actual native bridge in standalone unprovisioned simulator bundle',
    'capability': 'notConfigured',
    'publication_rejected_explicitly': true,
    'unsupported_operation_rejected_explicitly': true,
    'signed_group_or_extension_acceptance': false,
  };
}
