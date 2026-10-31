import 'dart:async';

import 'package:flick/models/ios_transfer_models.dart';
import 'package:flick/services/ios_transfer_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ios_transfer_transport_test.dart'
    show encoded, request, intentDocument, summary;

const contextId = '11111111-1111-4111-8111-111111111111';
const grantId = '22222222-2222-4222-8222-222222222222';
Map<String, Object?> context() => {
  'contextID': contextId,
  'rootPath': '/var/Music',
  'canonicalRootPath': '/private/var/Music',
  'pairing': {
    'scope':
        (intentDocument()['identity'] as Map).map(
          (key, value) => MapEntry(key.toString(), value),
        )..removeWhere(
          (key, _) => !{'desktopID', 'origin', 'pairingID'}.contains(key),
        ),
  },
};
IosTransferIntent intent() {
  final row = intentDocument();
  (row['identity'] as Map)['localSongID'] = '42';
  row['expectedBytes'] = 4;
  row['expectedSHA256'] = 'a' * 64;
  return IosTransferIntent.fromJson(row);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  test(
    'source grants and immutable upload intent use the active root client',
    () async {
      const channel = MethodChannel('test/upload-source');
      final observed = Completer<String>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'observe') {
          observed.complete((request(call) as Map)['clientID'] as String);
          return null;
        }
        if (call.method == 'unobserve') return null;
        final row = request(call) as Map;
        expect(row['clientID'], await observed.future);
        switch (call.method) {
          case 'uploadSourceContext':
            return encoded(context());
          case 'authorizeUploadSource':
            expect(row['relativePath'], 'Café/track.wav');
            expect(row['songID'], '42');
            return encoded({
              'grantID': grantId,
              'songID': '42',
              'bytes': 4,
              'sha256': 'a' * 64,
            });
          case 'enqueueUpload':
            expect(row['intent'], intent().toJson());
            expect(row['grantID'], grantId);
            return encoded(summary());
          default:
            return encoded(true);
        }
      });
      final transport = IosTransferTransport(channel: channel, supported: true);
      final subscription = transport.changes.listen((_) {});
      try {
        await observed.future;
        final source = await transport.uploadSourceContext();
        expect(source.canonicalRootPath, '/private/var/Music');
        final grant = await transport.authorizeUploadSource(
          contextId: source.id,
          relativePath: 'Café/track.wav',
          songId: '42',
        );
        await transport.enqueueUpload(intent(), grantId: grant.id);
        final before = calls.length;
        await expectLater(
          transport.authorizeUploadSource(
            contextId: source.id,
            relativePath: '../outside',
            songId: '42',
          ),
          throwsFormatException,
        );
        expect(calls.length, before);
        await transport.pauseSubmissions();
        await expectLater(transport.uploadSourceContext(), throwsStateError);
        await transport.releaseUploadSource(grant.id);
      } finally {
        await subscription.cancel();
        await transport.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
  );

  test('mutation fence drains a dispatched upload reply and rejects stale admission', () async {
    const channel = MethodChannel('test/upload-source-fence');
    final observed = Completer<void>(),
        dispatched = Completer<void>(),
        release = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'observe') {
        observed.complete();
        return null;
      }
      if (call.method == 'enqueueUpload') {
        dispatched.complete();
        await release.future;
        return encoded(summary());
      }
      return encoded(true);
    });
    final transport = IosTransferTransport(channel: channel, supported: true);
    final subscription = transport.changes.listen((_) {});
    try {
      await observed.future;
      final pending = transport.enqueueUpload(intent(), grantId: grantId);
      final rejected = expectLater(pending, throwsStateError);
      await dispatched.future;
      bool drained = false;
      final fence = transport.pauseSubmissions().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, false);
      release.complete();
      await rejected;
      await fence;
      expect(drained, true);
    } finally {
      if (!release.isCompleted) release.complete();
      await subscription.cancel();
      await transport.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}
