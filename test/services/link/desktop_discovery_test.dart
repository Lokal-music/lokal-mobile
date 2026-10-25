import 'package:flick/services/link/lokal_link_service.dart';
import 'package:flick/services/lokal_remote_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(
    () => messenger.setMockMethodCallHandler(LokalLinkService.channel, null),
  );

  test(
    'OS-owned permission flow still discovers through the native adapter',
    () async {
      messenger.setMockMethodCallHandler(LokalLinkService.channel, (
        call,
      ) async {
        if (call.method == 'requestLocalNetwork') {
          throw MissingPluginException();
        }
        return [
          {
            'id': 'desktop-fixture',
            'name': 'Desktop',
            'host': '192.168.1.8',
            'port': 3814,
          },
          {'id': 'unresolved', 'name': 'No address'},
        ];
      });
      final service = LokalLinkService();
      addTearDown(service.close);
      final found = await service.discover();
      expect(found, hasLength(1));
      expect(found.single.id, 'desktop-fixture');
      expect(found.single.origin.toString(), 'http://192.168.1.8:3814');
    },
  );

  test('native discovery failure exposes its actionable message', () async {
    messenger.setMockMethodCallHandler(LokalLinkService.channel, (call) async {
      if (call.method == 'requestLocalNetwork') return null;
      throw PlatformException(
        code: 'LOCAL_DISCOVERY',
        message: 'Allow Local Network or enter the desktop address.',
      );
    });
    final service = LokalLinkService();
    addTearDown(service.close);
    await expectLater(
      service.discover(),
      throwsA(
        isA<LokalRemoteConfigurationException>().having(
          (error) => error.message,
          'message',
          'Allow Local Network or enter the desktop address.',
        ),
      ),
    );
  });
}
