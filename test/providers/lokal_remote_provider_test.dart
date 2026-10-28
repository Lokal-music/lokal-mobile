import 'package:flick/models/lokal_remote_state.dart';
import 'package:flick/providers/lokal_remote_provider.dart';
import 'package:flick/services/lokal_remote_credentials_store.dart';
import 'package:flick/services/lokal_remote_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:async';

import 'package:flick/services/link/lokal_link_service.dart';

class _DelayedPairing extends LokalLinkService {
  final started = Completer<void>();
  final response = Completer<LokalRemoteCredentials>();
  @override
  Future<LokalRemoteCredentials> pair({
    required Uri origin,
    required String code,
    String? expectedDesktopId,
    String deviceName = 'Lokal phone',
  }) {
    started.complete();
    return response.future;
  }
}

class _Store implements LokalRemoteCredentialsStore {
  LokalRemoteCredentials? value;

  @override
  Future<LokalRemoteCredentials?> read() async => value;

  @override
  Future<void> write(LokalRemoteCredentials credentials) async =>
      value = credentials;

  @override
  Future<void> clear() async => value = null;
}

class _Service extends LokalRemoteService {
  _Service(this.responses);

  final List<Object> responses;
  final commands = <(LokalRemoteAction, double?)>[];

  @override
  Future<LokalRemoteSnapshot> fetchState(
    LokalRemoteCredentials credentials,
  ) async {
    final response = responses.removeAt(0);
    if (response is! LokalRemoteSnapshot) throw response;
    return response;
  }

  @override
  Future<void> sendCommand(
    LokalRemoteCredentials credentials,
    LokalRemoteAction action, {
    double? value,
  }) async {
    commands.add((action, value));
  }
}

final _credentials = LokalRemoteCredentials(
  origin: Uri.parse('http://desktop'),
  remoteToken: 'token',
);

LokalRemoteSnapshot _snapshot({
  required int updatedAt,
  String title = 'Track',
}) => LokalRemoteSnapshot(
  connected: true,
  isPlaying: true,
  progress: 2,
  duration: 10,
  volume: .7,
  repeat: 'none',
  shuffle: false,
  currentTrack: LokalRemoteTrack(title: title, artist: 'Artist'),
  updatedAt: updatedAt,
);

ProviderContainer _container(_Store store, _Service service) =>
    ProviderContainer(
      overrides: [
        lokalRemoteCredentialsStoreProvider.overrideWithValue(store),
        lokalRemoteServiceProvider.overrideWithValue(service),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'forgetting a desktop retires a pairing reply still in flight',
    () async {
      final store = _Store();
      final link = _DelayedPairing();
      final container = ProviderContainer(
        overrides: [
          lokalRemoteCredentialsStoreProvider.overrideWithValue(store),
          lokalRemoteServiceProvider.overrideWithValue(_Service([])),
          lokalLinkServiceProvider.overrideWithValue(link),
        ],
      );
      addTearDown(link.close);
      addTearDown(container.dispose);
      final controller = container.read(lokalRemoteControllerProvider.notifier);
      final pairing = controller.pairDesktop(
        origin: 'http://desktop',
        code: '123456',
      );
      await link.started.future;
      await controller.forgetConfiguration();
      link.response.complete(
        LokalRemoteCredentials(
          origin: Uri.parse('http://desktop'),
          remoteToken: 'synthetic-retired-token',
          desktopId: 'retired-desktop',
        ),
      );
      await pairing;
      expect(store.value, isNull);
      expect(
        container.read(lokalRemoteControllerProvider).status,
        LokalRemoteConnectionStatus.unconfigured,
      );
    },
  );
  test(
    'reconnect keeps the last good state through a transient failure',
    () async {
      final store = _Store()..value = _credentials;
      final service = _Service([
        _snapshot(updatedAt: 1),
        const LokalRemoteNetworkException('fixture offline'),
        _snapshot(updatedAt: 2, title: 'Recovered'),
      ]);
      final container = _container(store, service);
      addTearDown(container.dispose);
      final controller = container.read(lokalRemoteControllerProvider.notifier);

      await controller.connect();
      expect(
        container.read(lokalRemoteControllerProvider).status,
        LokalRemoteConnectionStatus.connected,
      );
      expect(
        container
            .read(lokalRemoteControllerProvider)
            .snapshot!
            .currentTrack!
            .title,
        'Track',
      );

      await controller.refresh();
      final offline = container.read(lokalRemoteControllerProvider);
      expect(offline.status, LokalRemoteConnectionStatus.offline);
      expect(offline.snapshot!.currentTrack!.title, 'Track');

      await controller.connect();
      final recovered = container.read(lokalRemoteControllerProvider);
      expect(recovered.status, LokalRemoteConnectionStatus.connected);
      expect(recovered.snapshot!.currentTrack!.title, 'Recovered');
    },
  );

  test('older desktop timestamps cannot overwrite a newer snapshot', () async {
    final store = _Store();
    final service = _Service([
      _snapshot(updatedAt: 20, title: 'New'),
      _snapshot(updatedAt: 10, title: 'Old'),
    ]);
    final container = _container(store, service);
    addTearDown(container.dispose);
    final controller = container.read(lokalRemoteControllerProvider.notifier);
    await controller.saveConfiguration(
      origin: 'http://desktop:3421/remote',
      remoteToken: 'token',
      apiKey: '',
    );
    await controller.connect();
    await controller.refresh();

    expect(
      container
          .read(lokalRemoteControllerProvider)
          .snapshot!
          .currentTrack!
          .title,
      'New',
    );
  });

  test(
    'commands are delivered through the remote service, not local playback',
    () async {
      final store = _Store()..value = _credentials;
      final service = _Service([
        _snapshot(updatedAt: 1),
        _snapshot(updatedAt: 2),
      ]);
      final container = _container(store, service);
      addTearDown(container.dispose);
      final controller = container.read(lokalRemoteControllerProvider.notifier);
      await controller.connect();
      await controller.sendCommand(LokalRemoteAction.volume, value: .25);

      expect(service.commands, [(LokalRemoteAction.volume, .25)]);
    },
  );
}
