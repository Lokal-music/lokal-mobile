import 'dart:async';
import 'dart:typed_data';

import 'package:flick/models/ios_widget_snapshot.dart';
import 'package:flick/services/ios_widget_publication_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

final alias = List.filled(64, 'a').join();
final otherAlias = List.filled(64, 'b').join();
final imageName = '${List.filled(64, 'c').join()}.png';

IosWidgetSnapshot snapshot(String title, {int timestamp = 1793059200000}) =>
    IosWidgetSnapshot.fromJson({
      'schemaVersion': 1,
      'revision': 1,
      'updatedAtMs': timestamp,
      'current': {'id': alias, 'title': title, 'artist': 'Fixture'},
      'positionMs': 1250,
      'durationMs': 12000,
      'isPlaying': false,
    });

class Transport implements IosWidgetPublicationTransport {
  IosWidgetPublicationCapability available =
      const IosWidgetPublicationCapability(available: true);
  int capabilityCalls = 0, active = 0, maximumActive = 0;
  final publications = <IosWidgetSnapshot>[];
  final images = <Map<String, Uint8List>>[];
  final reloads = <bool>[];
  Future<IosWidgetPublicationReceipt> Function(IosWidgetSnapshot)? handler;
  Future<IosWidgetPublicationCapability> Function()? capabilityHandler;

  @override
  Future<IosWidgetPublicationCapability> capability() async {
    capabilityCalls++;
    return await (capabilityHandler?.call() ?? Future.value(available));
  }

  @override
  Future<IosWidgetPublicationReceipt> publish(
    IosWidgetSnapshot metadata,
    Map<String, Uint8List> artworkByAlias, {
    required bool reloadTimelines,
  }) async {
    publications.add(metadata);
    images.add(artworkByAlias);
    reloads.add(reloadTimelines);
    active++;
    if (active > maximumActive) maximumActive = active;
    try {
      return await (handler?.call(metadata) ??
          Future.value(
            IosWidgetPublicationReceipt(
              revision: metadata.toJson()['revision']! as int,
            ),
          ));
    } finally {
      active--;
    }
  }
}

void main() {
  late Transport transport;
  late IosWidgetPublicationCoordinator coordinator;
  setUp(() {
    transport = Transport();
    coordinator = IosWidgetPublicationCoordinator(
      transport: transport,
      debounce: const Duration(days: 1),
    );
  });
  tearDown(() => coordinator.dispose());

  test(
    'pending updates coalesce and resume from the real committed revision',
    () async {
      transport.available = const IosWidgetPublicationCapability(
        available: true,
        committedRevision: 500,
      );
      coordinator.submit(snapshot('Older'));
      coordinator.submit(snapshot('Latest'), reloadTimelines: false);
      await coordinator.flush();
      expect(transport.publications.single.toJson()['revision'], 501);
      expect(
        (transport.publications.single.toJson()['current']! as Map)['title'],
        'Latest',
      );
      expect(transport.reloads, [false]);
      expect(coordinator.lastReceipt?.revision, 501);
      expect(transport.capabilityCalls, 1);
    },
  );

  test('missing shared-container capability performs no artwork or publication work', () async {
    transport.available = const IosWidgetPublicationCapability(
      available: false,
    );
    var loads = 0;
    coordinator.submit(
      snapshot('Selected'),
      loadArtwork: () async {
        loads++;
        return {};
      },
    );
    await coordinator.flush();
    expect(loads, 0);
    expect(transport.publications, isEmpty);
    expect(coordinator.phase.value, IosWidgetPublicationPhase.unavailable);
    transport.available = const IosWidgetPublicationCapability(
      available: true,
      committedRevision: 8,
    );
    await coordinator.retry();
    expect(loads, 1);
    expect(coordinator.lastReceipt?.revision, 9);
  });

  test('obsolete artwork cannot publish its former selection', () async {
    final started = Completer<void>();
    final artwork = Completer<Map<String, Uint8List>>();
    coordinator.submit(
      snapshot('Old song'),
      loadArtwork: () {
        started.complete();
        return artwork.future;
      },
    );
    final work = coordinator.flush();
    await started.future;
    coordinator.submit(snapshot('New song'));
    artwork.complete({
      alias: Uint8List.fromList([1, 2, 3]),
    });
    await work;
    expect(transport.publications, hasLength(1));
    expect(
      (transport.publications.single.toJson()['current']! as Map)['title'],
      'New song',
    );
    expect(transport.images.single, isEmpty);
  });

  test('in-flight native writes stay ordered and obsolete receipts are not exposed', () async {
    final started = Completer<void>();
    final first = Completer<IosWidgetPublicationReceipt>();
    transport.handler = (metadata) {
      if (transport.publications.length == 1) {
        started.complete();
        return first.future;
      }
      return Future.value(
        IosWidgetPublicationReceipt(
          revision: metadata.toJson()['revision']! as int,
        ),
      );
    };
    final exposed = <int?>[];
    coordinator.phase.addListener(() {
      if (coordinator.phase.value == IosWidgetPublicationPhase.idle) {
        exposed.add(coordinator.lastReceipt?.revision);
      }
    });
    coordinator.submit(snapshot('First'));
    final work = coordinator.flush();
    await started.future;
    var skippedLoads = 0;
    coordinator.submit(
      snapshot('Skipped'),
      loadArtwork: () async {
        skippedLoads++;
        return {};
      },
    );
    coordinator.submit(snapshot('Newest'));
    first.complete(IosWidgetPublicationReceipt(revision: 1));
    await work;
    expect(transport.maximumActive, 1);
    expect(
      transport.publications.map(
        (s) => (s.toJson()['current']! as Map)['title'],
      ),
      ['First', 'Newest'],
    );
    expect(skippedLoads, 0);
    expect(exposed, [2]);
  });

  test('actual sampled source timestamp and position survive asynchronous preparation', () async {
    coordinator.submit(
      snapshot('Paused', timestamp: 1000),
      loadArtwork: () async => {},
    );
    await coordinator.flush();
    final fields = transport.publications.single.toJson();
    expect(fields['updatedAtMs'], 1000);
    expect(fields['positionMs'], 1250);
    expect(fields['isPlaying'], false);
  });

  test(
    'invalid images are bounded and unrelated aliases never cross the bridge',
    () async {
      coordinator.submit(
        snapshot('Metadata'),
        loadArtwork: () async => {
          alias: Uint8List(
            IosWidgetPublicationCoordinator.maximumArtworkBytes + 1,
          ),
          'https://fixture.invalid/private?token=never-export': Uint8List(1),
        },
      );
      await coordinator.flush();
      expect(transport.images.single, isEmpty);
      expect(coordinator.lastArtworkDegraded, true);
      expect(coordinator.lastReceipt?.revision, 1);
    },
  );

  test('accepted artwork is copied and cannot be changed by the original loader buffer', () async {
    final original = Uint8List.fromList([1, 2, 3]);
    coordinator.submit(
      snapshot('Owned'),
      loadArtwork: () async => {alias: original},
    );
    await coordinator.flush();
    original[0] = 99;
    expect(transport.images.single[alias], [1, 2, 3]);
    expect(
      () => transport.images.single[alias]![0] = 4,
      throwsUnsupportedError,
    );
  });

  test('wrong native acknowledgement fails without caching it or reusing its revision', () async {
    transport.handler = (_) async => IosWidgetPublicationReceipt(revision: 0);
    coordinator.submit(snapshot('Pending'));
    await coordinator.flush();
    expect(coordinator.lastReceipt, isNull);
    expect(coordinator.phase.value, IosWidgetPublicationPhase.failed);
    expect(transport.publications, hasLength(1));
    transport.handler = null;
    await coordinator.retry();
    expect(coordinator.lastReceipt?.revision, 2);
  });

  test(
    'receipt source URLs and unreferenced artwork aliases are rejected',
    () async {
      for (final receipt in [
        IosWidgetPublicationReceipt(
          revision: 1,
          lastArtwork: 'https://fixture.invalid/private.png',
        ),
        IosWidgetPublicationReceipt(
          revision: 2,
          artworkByAlias: {otherAlias: imageName},
        ),
      ]) {
        transport.handler = (_) async => receipt;
        coordinator.submit(snapshot('Pending'));
        await coordinator.flush();
        expect(coordinator.lastReceipt, isNull);
        expect(coordinator.phase.value, IosWidgetPublicationPhase.failed);
      }
    },
  );

  test('native artwork-degraded acknowledgement remains a successful metadata commit', () async {
    transport.handler = (_) async =>
        IosWidgetPublicationReceipt(revision: 1, artworkDegraded: true);
    coordinator.submit(snapshot('Fresh metadata'));
    await coordinator.flush();
    expect(coordinator.phase.value, IosWidgetPublicationPhase.idle);
    expect(coordinator.lastReceipt?.revision, 1);
    expect(coordinator.lastArtworkDegraded, true);
  });

  test(
    'missing sample timestamp and exhausted revisions cannot publish',
    () async {
      coordinator.submit(snapshot('Invalid sample', timestamp: 0));
      await coordinator.flush();
      expect(transport.publications, isEmpty);
      expect(coordinator.phase.value, IosWidgetPublicationPhase.failed);
      transport.available = const IosWidgetPublicationCapability(
        available: true,
        committedRevision: IosWidgetPublicationCoordinator.maximumRevision,
      );
      coordinator.submit(snapshot('Counter exhausted'));
      await coordinator.retry();
      expect(transport.publications, isEmpty);
      expect(coordinator.phase.value, IosWidgetPublicationPhase.failed);
    },
  );

  test(
    'a timed-out artwork job stays owned while new metadata continues',
    () async {
      coordinator.dispose();
      coordinator = IosWidgetPublicationCoordinator(
        transport: transport,
        debounce: const Duration(days: 1),
        artworkTimeout: const Duration(milliseconds: 5),
      );
      final blocked = Completer<Map<String, Uint8List>>();
      var loads = 0;
      coordinator.submit(
        snapshot('First'),
        loadArtwork: () {
          loads++;
          return blocked.future;
        },
      );
      await coordinator.flush();
      coordinator.submit(
        snapshot('Second'),
        loadArtwork: () async {
          loads++;
          return {};
        },
      );
      await coordinator.flush();
      expect(loads, 1, reason: 'a native read timeout must not lose ownership');
      expect(transport.publications, hasLength(2));
      blocked.complete({alias: Uint8List(1)});
      await blocked.future;
      coordinator.submit(
        snapshot('Third'),
        loadArtwork: () async {
          loads++;
          return {};
        },
      );
      await coordinator.flush();
      expect(loads, 2);
      expect(
        transport.publications,
        hasLength(3),
        reason: 'late artwork never publishes an old selection',
      );
    },
  );

  test(
    'fresh state submitted during failure notification is scheduled once',
    () async {
      coordinator.dispose();
      coordinator = IosWidgetPublicationCoordinator(
        transport: transport,
        debounce: Duration.zero,
      );
      final latestStarted = Completer<void>();
      var submitted = false;
      coordinator.phase.addListener(() {
        if (coordinator.phase.value == IosWidgetPublicationPhase.failed &&
            !submitted) {
          submitted = true;
          coordinator.submit(snapshot('Latest'));
        }
      });
      transport.handler = (metadata) async {
        if ((metadata.toJson()['current']! as Map)['title'] == 'First') {
          throw StateError('Controlled write failure');
        }
        latestStarted.complete();
        return IosWidgetPublicationReceipt(
          revision: metadata.toJson()['revision']! as int,
        );
      };
      coordinator.submit(snapshot('First'));
      await coordinator.flush();
      await latestStarted.future.timeout(const Duration(seconds: 1));
      await coordinator.flush();
      expect(transport.publications, hasLength(2));
      expect(coordinator.lastReceipt?.revision, 2);
      expect(coordinator.phase.value, IosWidgetPublicationPhase.idle);
    },
  );

  test(
    'dispose during preparation cannot publish after the host is gone',
    () async {
      final started = Completer<void>();
      final artwork = Completer<Map<String, Uint8List>>();
      coordinator.submit(
        snapshot('Selected'),
        loadArtwork: () {
          started.complete();
          return artwork.future;
        },
      );
      final work = coordinator.flush();
      await started.future;
      coordinator.dispose();
      artwork.complete({});
      await work;
      expect(transport.publications, isEmpty);
    },
  );
  test('timed-out native writes stay owned and block further work until completion', () async {
    coordinator.dispose();
    coordinator = IosWidgetPublicationCoordinator(
      transport: transport,
      debounce: const Duration(days: 1),
      operationTimeout: const Duration(milliseconds: 5),
    );
    final blocked = Completer<IosWidgetPublicationReceipt>();
    transport.handler = (_) => blocked.future;
    coordinator.submit(snapshot('First'));
    await coordinator.flush();
    expect(coordinator.phase.value, IosWidgetPublicationPhase.failed);
    var loads = 0;
    for (var i = 0; i < 4; i++) {
      coordinator.submit(
        snapshot('Latest $i'),
        loadArtwork: () async {
          loads++;
          return {};
        },
      );
      await coordinator.flush();
      await coordinator.retry();
    }
    expect(transport.publications, hasLength(1));
    expect(transport.capabilityCalls, 1);
    expect(loads, 0);
    expect(transport.maximumActive, 1);
    blocked.complete(IosWidgetPublicationReceipt(revision: 1));
    await blocked.future;
    await Future<void>.delayed(Duration.zero);
    expect(
      coordinator.lastReceipt,
      isNull,
      reason: 'late acknowledgements cannot escape',
    );
    expect(
      transport.publications,
      hasLength(1),
      reason: 'completion does not retry automatically',
    );
    transport.handler = null;
    await coordinator.retry();
    expect(transport.publications, hasLength(2));
    expect(transport.maximumActive, 1);
    expect(coordinator.lastReceipt?.revision, 2);
    expect(
      (transport.publications.last.toJson()['current']! as Map)['title'],
      'Latest 3',
    );
  });

  test(
    'a timed-out capability check stays owned across fresh states and retries',
    () async {
      coordinator.dispose();
      coordinator = IosWidgetPublicationCoordinator(
        transport: transport,
        debounce: const Duration(days: 1),
        operationTimeout: const Duration(milliseconds: 5),
      );
      final blocked = Completer<IosWidgetPublicationCapability>();
      transport.capabilityHandler = () => blocked.future;
      coordinator.submit(snapshot('First'));
      await coordinator.flush();
      for (var i = 0; i < 3; i++) {
        coordinator.submit(snapshot('Latest $i'));
        await coordinator.flush();
        await coordinator.retry();
      }
      expect(transport.capabilityCalls, 1);
      expect(transport.publications, isEmpty);
      blocked.complete(
        const IosWidgetPublicationCapability(
          available: true,
          committedRevision: 40,
        ),
      );
      await blocked.future;
      await Future<void>.delayed(Duration.zero);
      transport.capabilityHandler = null;
      transport.available = const IosWidgetPublicationCapability(
        available: true,
        committedRevision: 40,
      );
      await coordinator.retry();
      expect(coordinator.lastReceipt?.revision, 41);
      expect(
        (transport.publications.single.toJson()['current']! as Map)['title'],
        'Latest 2',
      );
    },
  );

  test(
    'late failed native publication clears ownership without automatic retries',
    () async {
      coordinator.dispose();
      coordinator = IosWidgetPublicationCoordinator(
        transport: transport,
        debounce: const Duration(days: 1),
        operationTimeout: const Duration(milliseconds: 5),
      );
      final blocked = Completer<IosWidgetPublicationReceipt>();
      transport.handler = (_) => blocked.future;
      coordinator.submit(snapshot('First'));
      await coordinator.flush();
      blocked.completeError(StateError('Late native failure'));
      await Future<void>.delayed(Duration.zero);
      expect(transport.publications, hasLength(1));
      expect(coordinator.phase.value, IosWidgetPublicationPhase.failed);
      transport.handler = null;
      await coordinator.retry();
      expect(coordinator.lastReceipt?.revision, 2);
      expect(transport.maximumActive, 1);
    },
  );
}
