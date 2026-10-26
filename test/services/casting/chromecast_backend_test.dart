import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/casting/chromecast_backend.dart';
import 'package:flick/services/casting/cast_device.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.mossapps.flick/cast');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const device = CastDevice(
    id: 'receiver',
    name: 'Fixture',
    backend: CastBackend.chromecast,
  );
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'confirmed bridge preserves paused load and millisecond start position',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      final backend = ChromecastBackend(propagateErrors: true);
      await backend.connect(device);
      await backend.load(
        'https://example.invalid/track.flac',
        title: 'Fixture',
        autoplay: false,
        position: const Duration(milliseconds: 17250),
        contentType: 'audio/flac',
      );
      expect(calls.map((c) => c.method), ['connect', 'load']);
      expect(calls.last.arguments, containsPair('autoplay', false));
      expect(calls.last.arguments, containsPair('position', 17250));
      expect(calls.last.arguments, containsPair('contentType', 'audio/flac'));
    },
  );

  test(
    'strict bridge exposes receiver errors for all ownership commands',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'CAST_TIMEOUT', message: 'Fixture');
      });
      final backend = ChromecastBackend(propagateErrors: true);
      for (final operation in <Future<dynamic> Function()>[
        () => backend.connect(device),
        () => backend.load('https://example.invalid/audio'),
        backend.play,
        backend.pause,
        backend.stop,
        backend.disconnect,
        () => backend.seek(const Duration(seconds: 8)),
        () => backend.setVolume(.4),
        backend.getVolume,
        backend.discover,
      ]) {
        await expectLater(
          operation(),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'CAST_TIMEOUT',
            ),
          ),
        );
      }
    },
  );

  test(
    'missing native sender is an error when strict and optional otherwise',
    () async {
      await expectLater(
        ChromecastBackend(propagateErrors: true).connect(device),
        throwsA(isA<MissingPluginException>()),
      );
      await ChromecastBackend(propagateErrors: false).connect(device);
      expect(
        await ChromecastBackend(propagateErrors: false).discover(),
        isEmpty,
      );
    },
  );

  test('discovery excludes malformed devices without IDs', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => [
        {'id': 'one', 'name': 'Kitchen'},
        {'name': 'Invalid'},
      ],
    );
    final devices = await ChromecastBackend(propagateErrors: true).discover();
    expect(devices.map((d) => d.id), ['one']);
  });
}
