import 'dart:io';

import 'package:flick/features/discovery/lastfm_discovery.dart';
import 'package:flick/features/konnekted/discovery_snapshot_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';

/// Actual native path-provider and filesystem acceptance, in a fresh owned
/// test directory. Never use or prune the installation's real Discovery cache.
Future<Map<String, Object>> probeIosDiscoveryCache() async {
  final support = await getApplicationSupportDirectory();
  final directory = await support.createTemp('ios-discovery-acceptance-');
  try {
    final first = DiscoverySnapshotCache(directory: directory);
    const account = 'synthetic-ios-discovery-account';
    const data = LokalDiscovery(
      account: 'Fixture listener',
      page: 2,
      quickPicks: [
        LokalDiscoveryTrack(title: 'First', artist: 'Fixture'),
        LokalDiscoveryTrack(title: 'Second', artist: 'Fixture'),
      ],
      mixes: [LokalDiscoveryMix(id: 'fixture-mix', title: 'Fixture mix')],
    );
    await first.writeLokal('youtube', account, data);
    final second = DiscoverySnapshotCache(directory: directory);
    final saved = await second.readLokal('youtube', account);
    expect(saved, isNotNull);
    expect(saved!.data.quickPicks!.map((track) => track.title), [
      'First',
      'Second',
    ]);
    expect(saved.data.page, 2);
    expect(saved.data.mixes!.single.id, 'fixture-mix');
    expect(saved.isFresh(DiscoverySnapshotCache.youtubeTtl), isTrue);
    expect(await second.readLokal('youtube', 'other-fixture-account'), isNull);
    expect(await second.readLokal('lastfm', account), isNull);
    final files = await directory.list(followLinks: false).toList();
    expect(files.length, 1);
    final document = await (files.single as File).readAsString();
    expect(document, isNot(contains(account)));
    await Future.wait([
      first.writeLokal('youtube', account, data),
      second.invalidate('youtube', account),
    ]);
    expect(await first.readLokal('youtube', account), isNull);
    expect(await directory.list().isEmpty, isTrue);
    return {
      'scope': 'Actual native app-support path and isolated filesystem; not live account/provider acceptance',
      'restored_order_and_mix_identity': true,
      'account_and_source_isolated': true,
      'invalidation_drains_pending_write': true,
      'real_user_cache_touched': false,
    };
  } finally {
    await directory.delete(recursive: true);
  }
}
