import 'dart:convert';

import 'package:flick/models/ios_widget_snapshot.dart';
import 'package:flick/services/ios_widget_method_channel_transport.dart';
import 'package:flick/services/ios_widget_publication_coordinator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final alias = List.filled(64, 'a').join();
final cover = '${List.filled(64, 'b').join()}.png';
IosWidgetSnapshot snapshot() => IosWidgetSnapshot.fromJson({
  'schemaVersion': 1,
  'revision': 12,
  'updatedAtMs': 1793059200000,
  'current': {'id': alias, 'title': 'Fixture', 'artist': 'Artist'},
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('lokal/widgets');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late IosWidgetMethodChannelTransport transport;
  setUp(() => transport = IosWidgetMethodChannelTransport(supported: true));
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('unsupported hosts perform no native calls', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => fail('Unexpected native request'),
    );
    final unsupported = IosWidgetMethodChannelTransport(supported: false);
    final status = await unsupported.capability();
    expect(status.available, false);
    expect(
      status.unavailableReason,
      IosWidgetUnavailableReason.unsupportedPlatform,
    );
    await expectLater(
      unsupported.publish(snapshot(), {}, reloadTimelines: false),
      throwsUnsupportedError,
    );
  });

  test(
    'unconfigured installation is explicit and does not assume a group',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'capability');
        expect(call.arguments, isNull);
        return {'available': false, 'reason': 'notConfigured'};
      });
      final value = await transport.capability();
      expect(value.available, false);
      expect(value.unavailableReason, IosWidgetUnavailableReason.notConfigured);
    },
  );

  test(
    'actual committed capability revision is required to be a safe integer',
    () async {
      for (final invalid in [null, true, -1, 1.5, '12', 9007199254740992]) {
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => {'available': true, 'committedRevision': invalid},
        );
        await expectLater(transport.capability(), throwsFormatException);
      }
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {'available': true, 'committedRevision': 123},
      );
      expect((await transport.capability()).committedRevision, 123);
    },
  );

  test('publication transmits canonical UTF-8 and binary images without paths or group arguments', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'publish');
      final args = call.arguments as Map;
      expect(
        args.keys,
        unorderedEquals(['metadata', 'artwork', 'reloadTimelines']),
      );
      expect(args['metadata'], isA<Uint8List>());
      final metadata =
          jsonDecode(utf8.decode(args['metadata'] as Uint8List)) as Map;
      expect(metadata['revision'], 12);
      expect((metadata['current'] as Map)['id'], alias);
      expect((args['artwork'] as Map)[alias], [1, 2, 3]);
      expect(args['reloadTimelines'], false);
      return {
        'revision': 12,
        'artworkByAlias': {alias: cover},
        'lastArtwork': cover,
        'artworkDegraded': false,
      };
    });
    final ack = await transport.publish(snapshot(), {
      alias: Uint8List.fromList([1, 2, 3]),
    }, reloadTimelines: false);
    expect(ack.revision, 12);
    expect(ack.artworkByAlias[alias], cover);
    expect(ack.lastArtwork, cover);
  });

  test('oversized or unrelated image inputs are rejected before calling native code', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => fail('Invalid input crossed bridge'),
    );
    for (final images in [
      {'https://fixture.invalid/private?token=never-export': Uint8List(1)},
      {
        alias: Uint8List(
          IosWidgetPublicationCoordinator.maximumArtworkBytes + 1,
        ),
      },
    ]) {
      await expectLater(
        transport.publish(snapshot(), images, reloadTimelines: true),
        throwsFormatException,
      );
    }
  });

  test(
    'malformed native receipts are rejected rather than treated as success',
    () async {
      for (final raw in [
        null,
        {'revision': '12', 'artworkByAlias': {}, 'artworkDegraded': false},
        {
          'revision': 12,
          'artworkByAlias': {'bad': 1},
          'artworkDegraded': false,
        },
        {'revision': 12, 'artworkByAlias': {}, 'artworkDegraded': 'false'},
        {
          'revision': 12,
          'artworkByAlias': {},
          'artworkDegraded': false,
          'lastArtwork': 5,
        },
      ]) {
        messenger.setMockMethodCallHandler(channel, (_) async => raw);
        await expectLater(
          transport.publish(snapshot(), {}, reloadTimelines: true),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'native missing-container errors propagate without a success receipt',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'WIDGETS_UNAVAILABLE');
      });
      await expectLater(
        transport.publish(snapshot(), {}, reloadTimelines: false),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'WIDGETS_UNAVAILABLE',
          ),
        ),
      );
    },
  );
}
