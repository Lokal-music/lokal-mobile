import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/sources/local_network_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('identifies NAS private addresses and names, not internet servers', () {
    for (final host in ['192.168.8.1', '10.0.0.2', '172.16.2.3',
      'nas', 'nas.local', 'home.arpa', 'fd00::1']) {
      expect(NetworkLocalAccess.isPrivateHost(host), isTrue, reason: host);
    }
    for (final host in ['example.com', '8.8.8.8', 'localhost', '127.0.0.1']) {
      expect(NetworkLocalAccess.isPrivateHost(host), isFalse, reason: host);
    }
  });

  test('asks Android for local-network permission before NAS access', () async {
    const channel = MethodChannel('test/lokal-lan');
    final messages = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      messages.add(call.method);
      return true;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    await NetworkLocalAccess.ensure(Uri.parse('smb://192.168.8.1/Music'),
        bridge: channel, isAndroid: true);
    await NetworkLocalAccess.ensure(Uri.parse('https://example.com/files'),
        bridge: channel, isAndroid: true);
    expect(messages, ['requestLocalNetwork']);
  });

  test('denied permission surfaces a meaningful error', () async {
    const channel = MethodChannel('test/lokal-lan-denied');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => false);
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    await expectLater(
      NetworkLocalAccess.ensure(Uri.parse('smb://nas/music'),
          bridge: channel, isAndroid: true),
      throwsA(isA<NetworkAccessDenied>()),
    );
  });
}
