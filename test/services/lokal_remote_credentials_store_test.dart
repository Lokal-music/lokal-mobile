import 'dart:convert';
import 'dart:io';

import 'package:flick/models/lokal_remote_state.dart';
import 'package:flick/services/lokal_remote_credentials_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RejectWrites extends FlutterSecureStorage {
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      throw const FileSystemException('Synthetic Keychain write failure');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = FlutterSecureStorage();
  final fixture = File('test/fixtures/ios_transfer_credentials_v2.json')
      .readAsStringSync();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test(
    'forgetting during a pending write leaves no revived endpoint',
    () async {
      final store = SecureLokalRemoteCredentialsStore(secureStorage: secure);
      final writing = store.write(
        LokalRemoteCredentials(
          origin: Uri.parse('http://192.0.2.20:5443'),
          remoteToken: 'synthetic-pending-token',
          desktopId: 'contract-desktop',
        ),
      );
      final forgetting = store.clear();
      await Future.wait([writing, forgetting]);
      expect(await store.read(), isNull);
      expect(
        await secure.read(key: SecureLokalRemoteCredentialsStore.secureKey),
        isNull,
      );
    },
  );

  test('shared native contract reads a coherent origin and pairing without preferences', () async {
    FlutterSecureStorage.setMockInitialValues({
      SecureLokalRemoteCredentialsStore.secureKey: fixture,
    });
    final value = await SecureLokalRemoteCredentialsStore(secureStorage: secure)
        .read();
    expect(value!.origin.toString(), 'http://192.0.2.20:5443');
    expect(value.desktopId, 'contract-desktop');
    expect(value.pairingID, '14093104-64d4-44f7-8c8b-8b4b14399067');
    expect(value.remoteToken, 'synthetic-transfer-contract-token');
  });

  test('stale Forget cannot clear credentials from a replacement pairing', () async {
    final store = SecureLokalRemoteCredentialsStore(secureStorage: secure);
    final first = LokalRemoteCredentials(
      origin: Uri.parse('http://192.0.2.20:5443'),
      desktopId: 'contract-desktop',
      remoteToken: 'synthetic-old',
    );
    await store.write(first);
    final captured = (await store.read())!;
    await store.write(LokalRemoteCredentials(
      origin: Uri.parse('http://192.0.2.20:5443'),
      desktopId: 'contract-desktop',
      remoteToken: 'synthetic-repaired',
    ));
    await expectLater(store.clearIfMatching(captured), throwsStateError);
    expect((await store.read())!.remoteToken, 'synthetic-repaired');
    final fresh = await store.read();
    await store.clearIfMatching(fresh);
    expect(await store.read(), isNull);
  });

  test('conditional forget is serialized with an already-dispatched write', () async {
    final store = SecureLokalRemoteCredentialsStore(secureStorage: secure);
    await store.write(LokalRemoteCredentials(
      origin: Uri.parse('http://192.0.2.20:5443'),
      desktopId: 'contract-desktop',
      remoteToken: 'synthetic-initial',
    ));
    final captured = await store.read();
    final replacing = store.write(LokalRemoteCredentials(
      origin: Uri.parse('https://new-device.invalid'),
      desktopId: 'new-desktop',
      remoteToken: 'synthetic-new',
    ));
    final staleClear = store.clearIfMatching(captured);
    await replacing;
    await expectLater(staleClear, throwsStateError);
    expect((await store.read())!.desktopId, 'new-desktop');
  });

  test(
    'a partial preferences write cannot redirect a stored bearer token',
    () async {
      SharedPreferences.setMockInitialValues({
        SecureLokalRemoteCredentialsStore.originKey:
            'https://different.invalid',
      });
      FlutterSecureStorage.setMockInitialValues({
        SecureLokalRemoteCredentialsStore.secureKey: fixture,
      });
      final value = await SecureLokalRemoteCredentialsStore(
        secureStorage: secure,
      ).read();
      expect(value!.origin.toString(), 'http://192.0.2.20:5443');
    },
  );

  test('fresh pairing renews public authority and keeps secrets out of preferences', () async {
    final store = SecureLokalRemoteCredentialsStore(secureStorage: secure);
    final input = LokalRemoteCredentials(
      origin: Uri.parse('http://192.0.2.20:5443'),
      remoteToken: 'synthetic-pairing-token',
      desktopId: 'contract-desktop',
    );
    await store.write(input);
    final first = await store.read();
    await store.write(input);
    final next = await store.read();
    expect(first!.pairingID, isNotNull);
    expect(next!.pairingID, isNot(first.pairingID));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), {SecureLokalRemoteCredentialsStore.originKey});
    expect(
      prefs.getString(SecureLokalRemoteCredentialsStore.originKey),
      input.origin.toString(),
    );
    await store.clear();
    expect(
      await secure.read(key: SecureLokalRemoteCredentialsStore.secureKey),
      isNull,
    );
    expect(await store.read(), isNull);
  });

  test(
    'failed Keychain write leaves the previous endpoint authoritative',
    () async {
      SharedPreferences.setMockInitialValues({
        SecureLokalRemoteCredentialsStore.originKey: 'http://192.0.2.20:5443',
      });
      FlutterSecureStorage.setMockInitialValues({
        SecureLokalRemoteCredentialsStore.secureKey: fixture,
      });
      await expectLater(
        SecureLokalRemoteCredentialsStore(secureStorage: _RejectWrites()).write(
          LokalRemoteCredentials(
            origin: Uri.parse('https://different.invalid'),
          ),
        ),
        throwsA(isA<FileSystemException>()),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(SecureLokalRemoteCredentialsStore.originKey),
        'http://192.0.2.20:5443',
      );
      expect(
        await secure.read(key: SecureLokalRemoteCredentialsStore.secureKey),
        fixture,
      );
    },
  );

  test(
    'legacy settings stay readable without silently granting background work',
    () async {
      SharedPreferences.setMockInitialValues({
        SecureLokalRemoteCredentialsStore.originKey: 'http://192.0.2.20:5443',
      });
      FlutterSecureStorage.setMockInitialValues({
        SecureLokalRemoteCredentialsStore.secureKey: jsonEncode({
          'version': 1,
          'remoteToken': 'synthetic-legacy-token',
          'desktopId': 'contract-desktop',
        }),
      });
      final value = await SecureLokalRemoteCredentialsStore(
        secureStorage: secure,
      ).read();
      expect(value!.remoteToken, 'synthetic-legacy-token');
      expect(value.pairingID, isNull);
    },
  );

  test(
    'corrupt and future records cannot fall back to another endpoint',
    () async {
      SharedPreferences.setMockInitialValues({
        SecureLokalRemoteCredentialsStore.originKey:
            'https://different.invalid',
      });
      for (final raw in [
        '{broken',
        '{"version":3}',
        '{"version":2,"origin":"https://different.invalid"}',
      ]) {
        FlutterSecureStorage.setMockInitialValues({
          SecureLokalRemoteCredentialsStore.secureKey: raw,
        });
        expect(
          await SecureLokalRemoteCredentialsStore(secureStorage: secure).read(),
          isNull,
        );
        expect(
          await secure.read(key: SecureLokalRemoteCredentialsStore.secureKey),
          raw,
        );
      }
    },
  );
}
