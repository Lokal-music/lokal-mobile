import 'dart:io';

import 'package:flick/models/ios_widget_snapshot.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/player_provider.dart';
import 'package:flick/services/ios_widget_owned_artwork.dart';
import 'package:flick/services/ios_widget_publication_coordinator.dart';
import 'package:flick/services/ios_widget_runtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements IosWidgetPublicationTransport {
  bool available = false;
  int checks = 0;
  final writes = <IosWidgetSnapshot>[];
  final images = <Map<String, Uint8List>>[];
  @override
  Future<IosWidgetPublicationCapability> capability() async {
    checks++;
    return IosWidgetPublicationCapability(
      available: available,
      committedRevision: 7,
      unavailableReason: available
          ? null
          : IosWidgetUnavailableReason.notConfigured,
    );
  }

  @override
  Future<IosWidgetPublicationReceipt> publish(
    IosWidgetSnapshot metadata,
    Map<String, Uint8List> artworkByAlias, {
    required bool reloadTimelines,
  }) async {
    writes.add(metadata);
    images.add(artworkByAlias);
    return IosWidgetPublicationReceipt(
      revision: metadata.toJson()['revision']! as int,
    );
  }
}

void main() {
  late Directory root;
  late _Transport transport;
  late IosWidgetRuntime runtime;
  late ValueNotifier<({String source, String path})?> artworkEvents;
  var roots = 0, lookups = 0;
  String? materialized;
  const source = '/music/track.flac';
  const song = Song(
    id: 'track',
    title: 'Track',
    artist: 'Artist',
    duration: Duration(minutes: 3),
    fileType: 'FLAC',
    filePath: source,
  );
  PlayerState state(int ms) => PlayerState(
    currentSong: song,
    isPlaying: true,
    duration: const Duration(minutes: 3),
    position: Duration(milliseconds: ms),
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lokal-widget-runtime-');
    transport = _Transport();
    artworkEvents = ValueNotifier(null);
    roots = lookups = 0;
    materialized = null;
    runtime = IosWidgetRuntime(
      accentArgb: 0xff112233,
      clock: () => DateTime.utc(2026, 10, 27),
      coordinator: IosWidgetPublicationCoordinator(
        transport: transport,
        debounce: const Duration(days: 1),
      ),
      artwork: IosWidgetOwnedArtworkLoader(
        ownedRoots: () async {
          roots++;
          return [root];
        },
        materializedPathFor: (_) async {
          lookups++;
          return materialized;
        },
      ),
      materializedArtwork: artworkEvents,
    );
  });
  tearDown(() async {
    runtime.dispose();
    artworkEvents.dispose();
    await root.delete(recursive: true);
  });

  test('an unconfigured installation does no artwork I/O and can explicitly retry a new profile', () async {
    runtime.observe(state(1000));
    await runtime.flush();
    runtime.setAccent(0xffaabbcc);
    await runtime.flush();
    expect(transport.checks, 1);
    expect(transport.writes, isEmpty);
    expect(roots, 0);
    expect(lookups, 0);
    expect(
      runtime.coordinator.unavailableReason,
      IosWidgetUnavailableReason.notConfigured,
    );
    materialized = (await File('${root.path}/cover').writeAsBytes([1, 2, 3]))
        .path;
    transport.available = true;
    await runtime.retry();
    expect(transport.writes, hasLength(1));
    expect(transport.writes.single.toJson()['revision'], 8);
    expect(transport.writes.single.toJson()['positionMs'], 1000);
    expect(transport.writes.single.toJson()['isPlaying'], true);
    expect(
      transport.writes.single.toJson()['accentArgb'],
      0xffaabbcc.toSigned(32),
    );
    expect(roots, 1);
    expect(lookups, 1);
  });

  test('completed relevant artwork updates refresh metadata without requesting new art extraction', () async {
    transport.available = true;
    materialized = (await File('${root.path}/first').writeAsBytes([1])).path;
    runtime.observe(state(1000));
    await runtime.flush();
    artworkEvents.value = (
      source: '/music/unrelated.flac',
      path: '${root.path}/other',
    );
    await runtime.flush();
    expect(transport.writes, hasLength(1));
    materialized = (await File('${root.path}/second').writeAsBytes([2])).path;
    artworkEvents.value = (source: source, path: materialized!);
    await runtime.flush();
    expect(transport.writes, hasLength(2));
    expect(transport.images.last.values.single, [2]);
    expect(
      transport.writes.last.toJson()['updatedAtMs'],
      transport.writes.first.toJson()['updatedAtMs'],
    );
    expect(transport.writes.last.toJson()['positionMs'], 1000);
  });

  test('detaching runtime removes materialized-art listeners and all pending publication', () async {
    transport.available = true;
    runtime.observe(state(1000));
    runtime.dispose();
    artworkEvents.value = (source: source, path: '${root.path}/cover');
    runtime.observe(state(2000));
    runtime.setAccent(0);
    await runtime.flush();
    expect(transport.checks, 0);
    expect(transport.writes, isEmpty);
    expect(roots, 0);
  });
}
