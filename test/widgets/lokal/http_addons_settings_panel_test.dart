import 'dart:convert';

import 'package:flick/features/discovery/discovery_settings.dart';
import 'package:flick/features/settings/widgets/http_addons_settings_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _MemoryStore extends DiscoverySettingsStore {
  _MemoryStore(this.settings);

  DiscoverySettings settings;
  int saves = 0;

  @override
  Future<DiscoverySettings> load() async => settings;

  @override
  Future<void> save(DiscoverySettings value) async {
    saves++;
    settings = value.validated();
  }
}

Widget _host(HttpAddonsSettingsPanel panel) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: panel)),
);

void main() {
  testWidgets('adds a manifest URL inline after validating the manifest', (
    tester,
  ) async {
    final store = _MemoryStore(const DiscoverySettings(youtubeEnabled: true));
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      expect(request.method, 'GET');
      expect(
        request.url.toString(),
        'https://music.example/library/manifest.json',
      );
      return http.Response(
        jsonEncode({
          'id': 'private-id',
          'name': 'https://private.example/do-not-display-secret',
          'resources': ['search', 'stream'],
          'allowDownloads': true,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    addTearDown(client.close);

    await tester.pumpWidget(
      _host(HttpAddonsSettingsPanel(store: store, client: client)),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('http-addon-manifest-url')),
      findsOneWidget,
    );
    expect(find.text('HTTP music add-ons'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('http-addon-manifest-url')),
      'https://music.example/library/manifest.json',
    );
    await tester.tap(find.byKey(const ValueKey('http-addon-add')));
    // The mock HTTP stream crosses real and widget-test event queues. Drain
    // both, then require actual persistence rather than a spinner timeout.
    for (var frame = 0; frame < 40 && store.saves == 0; frame++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();

    expect(requests, 1);
    expect(
      store.saves,
      1,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data)
          .join(' | '),
    );
    expect(store.settings.youtubeEnabled, isTrue);
    expect(store.settings.addons, hasLength(1));
    expect(
      store.settings.addons.single.endpoint,
      'https://music.example/library',
    );
    expect(store.settings.addons.single.enabled, isTrue);
    expect(store.settings.addons.single.token, isEmpty);
    expect(find.text('music.example'), findsOneWidget);
    expect(find.textContaining('private.example'), findsNothing);
    expect(find.textContaining('do-not-display-secret'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'installs a streaming-only BitChord addon without enabling saves',
    (tester) async {
      final store = _MemoryStore(const DiscoverySettings());
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.url.toString(),
          'https://bppcaf.bot-keep.xyz/manifest.json',
        );
        return http.Response(
          jsonEncode({
            'id': 'com.bitchord.qobuz',
            'name': 'Qobuz',
            'version': '1.0.0',
            'resources': ['search', 'stream'],
            'allowDownloads': 0,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      addTearDown(client.close);

      await tester.pumpWidget(
        _host(HttpAddonsSettingsPanel(store: store, client: client)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('http-addon-manifest-url')),
        'https://bppcaf.bot-keep.xyz/',
      );
      await tester.tap(find.byKey(const ValueKey('http-addon-add')));
      // The mock HTTP stream crosses real and widget-test event queues. Drain
      // both, then require actual persistence rather than a spinner timeout.
      for (var frame = 0; frame < 40 && store.saves == 0; frame++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump();

      expect(
        store.saves,
        1,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data)
            .join(' | '),
      );
      expect(store.settings.addons, hasLength(1));
      expect(
        store.settings.addons.single.endpoint,
        'https://bppcaf.bot-keep.xyz',
      );
      expect(store.settings.addons.single.enabled, isTrue);
      expect(store.settings.addons.single.displayName, 'Qobuz');
      expect(find.text('Qobuz'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rejects an invalid URL without contacting the server', (
    tester,
  ) async {
    final store = _MemoryStore(const DiscoverySettings());
    final client = MockClient(
      (_) async => fail('Invalid URL must not be sent'),
    );
    addTearDown(client.close);

    await tester.pumpWidget(
      _host(HttpAddonsSettingsPanel(store: store, client: client)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('http-addon-manifest-url')),
      'http://music.example/manifest.json',
    );
    await tester.tap(find.byKey(const ValueKey('http-addon-add')));
    await tester.pumpAndSettle();

    expect(store.saves, 0);
    expect(store.settings.addons, isEmpty);
    expect(
      find.text('Use an absolute HTTPS URL without user info or a fragment.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('existing sources can be toggled and removed inline', (
    tester,
  ) async {
    const existing = DiscoveryAddonConfig(
      id: 'home',
      endpoint: 'https://music.example/library',
      label: 'Home music',
      enabled: true,
    );
    final store = _MemoryStore(
      const DiscoverySettings(youtubeEnabled: true, addons: [existing]),
    );
    final client = MockClient((_) async => fail('No network request expected'));
    addTearDown(client.close);

    await tester.pumpWidget(
      _host(
        HttpAddonsSettingsPanel(
          initial: store.settings,
          store: store,
          client: client,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Home music'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('http-addon-enabled-home')));
    await tester.pumpAndSettle();
    expect(store.settings.addons.single.enabled, isFalse);

    await tester.tap(find.byTooltip('Remove Home music'));
    await tester.pumpAndSettle();
    expect(store.settings.addons, isEmpty);
    expect(find.text('Home music'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manifest name and quality control are persisted and editable', (
    tester,
  ) async {
    final store = _MemoryStore(const DiscoverySettings());
    final client = MockClient((request) async {
      expect(request.url.path, '/private/manifest.json');
      return http.Response(
        jsonEncode({
          'id': 'qobuz',
          'name': 'Qobuz [Heisenbergg]',
          'resources': ['search', 'stream'],
          'settings': [
            {
              'key': 'quality',
              'default': 'LOSSLESS',
              'options': [
                {'value': 'LOSSLESS'},
                {'value': 'HI_RES'},
                {'value': 'HIGH'},
              ],
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    addTearDown(client.close);
    await tester.pumpWidget(
      _host(HttpAddonsSettingsPanel(store: store, client: client)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('http-addon-manifest-url')),
      'https://music.example/private/manifest.json',
    );
    await tester.tap(find.byKey(const ValueKey('http-addon-add')));
    // The mock HTTP stream crosses real and widget-test event queues. Drain
    // both, then require actual persistence rather than a spinner timeout.
    for (var frame = 0; frame < 40 && store.saves == 0; frame++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
    expect(store.settings.addons.single.displayName, 'Qobuz [Heisenbergg]');
    expect(store.settings.addons.single.settings['quality'], 'LOSSLESS');
    expect(find.text('Qobuz [Heisenbergg]'), findsOneWidget);
    final id = store.settings.addons.single.id;
    await tester.tap(find.byKey(ValueKey('http-addon-settings-$id')));
    for (var frame = 0; frame < 40 &&
        find.byKey(const ValueKey('http-addon-setting-quality')).evaluate().isEmpty; frame++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('http-addon-setting-quality')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('HI_RES').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();
    expect(store.settings.addons.single.settings['quality'], 'HI_RES');
    await tester.tap(find.byKey(ValueKey('http-addon-enabled-$id')));
    await tester.pumpAndSettle();
    expect(store.settings.addons.single.enabled, isFalse);
    expect(store.settings.addons.single.settings['quality'], 'HI_RES');
    expect(tester.takeException(), isNull);
  });
}
