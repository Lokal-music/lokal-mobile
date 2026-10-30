import 'dart:convert';

import 'package:flick/features/settings/screens/lokal_remote_settings_screen.dart';
import 'package:flick/models/lokal_remote_state.dart';
import 'package:flick/providers/lokal_remote_provider.dart';
import 'package:flick/services/lokal_remote_credentials_store.dart';
import 'package:flick/services/lokal_remote_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Store implements LokalRemoteCredentialsStore {
  _Store(this.value);

  final LokalRemoteCredentials value;

  @override
  Future<LokalRemoteCredentials?> read() async => value;

  @override
  Future<void> write(LokalRemoteCredentials credentials) async {}

  @override
  Future<void> clearIfMatching(LokalRemoteCredentials? expected) async {
    if (!SecureLokalRemoteCredentialsStore.sameAuthority(value, expected)) {
      throw StateError('Pairing changed.');
    }
  }

  @override
  Future<void> clear() async {}
}

void main() {
  testWidgets('restores only the desktop address, never the bearer values', (
    tester,
  ) async {
    final store = _Store(
      LokalRemoteCredentials(
        origin: Uri.parse('http://192.168.1.20:3421'),
        remoteToken: 'remote-secret',
        apiKey: 'api-secret',
      ),
    );
    final service = LokalRemoteService(
      client: MockClient(
        (_) async => http.Response(jsonEncode({'connected': false}), 200),
      ),
    );
    addTearDown(service.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          lokalRemoteCredentialsStoreProvider.overrideWithValue(store),
          lokalRemoteServiceProvider.overrideWithValue(service),
        ],
        child: const MaterialApp(home: LokalRemoteSettingsScreen()),
      ),
    );
    await tester.pump();

    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('lokal-remote-origin')))
          .controller!
          .text,
      'http://192.168.1.20:3421',
    );
    expect(find.text('remote-secret'), findsNothing);
    expect(find.text('api-secret'), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
  });
}
