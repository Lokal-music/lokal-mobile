import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the explicit-only sync wiring. A regression in the connection,
/// journal or periodic timer paths can silently trigger a full library walk
/// against thousands of desktop tracks before the user can use the app.
void main() {
  final controller = File('lib/providers/lokal_remote_provider.dart')
      .readAsStringSync();
  final screen = File('lib/features/link/lokal_desktop_link_screen.dart')
      .readAsStringSync();

  String section(String start, String end) {
    final begin = controller.indexOf(start);
    final finish = controller.indexOf(end, begin + start.length);
    expect(begin, greaterThanOrEqualTo(0), reason: 'Missing $start');
    expect(finish, greaterThan(begin), reason: 'Missing $end');
    return controller.substring(begin, finish);
  }

  test('startup, reconnect, refresh and timer never start full sync', () {
    final startup = section(
      'LokalRemoteControllerState build()', 'Future<void> _ensureRestored()',
    );
    final refresh = section('Future<void> refresh()', 'Future<void> sendCommand(');
    final socket = section(
      'Future<void> _connectSocket()', 'void _socketConnectionChanged(',
    );
    final timer = section('void _tickLink()', 'Future<void> _syncLink()');

    for (final path in [startup, refresh, socket, timer]) {
      expect(path, isNot(contains('_syncLink(')));
      expect(path, isNot(contains('.synchronize(')));
    }
    expect(controller, isNot(contains('_syncDebounce')));
    expect(controller, isNot(contains('_lastLibrarySyncAt')));
    expect(controller, isNot(contains('LinkJournal.instance.changes.stream.listen')));
  });

  test('only an explicit Sync now invokes the full library coordinator', () {
    final manual = section('Future<void> syncNow()', 'LinkFileCopy _fileCopier()');
    expect(manual, contains('state.mergeApproved'));
    expect(manual, contains('state.socketConnected'));
    expect(manual, contains('await _syncLink();'));
    expect(RegExp(r'_syncLink\(').allMatches(controller).length, 2,
        reason: 'Only the user action and its method definition may reference _syncLink');
    expect(RegExp(r'\.synchronize\(').allMatches(controller).length, 1);
    expect(screen, contains('Future<void> _syncNow()'));
    expect(screen, contains(': _syncNow,'));
    expect(screen, contains('Full desktop-library, metadata, likes and playlist sync is manual'));
  });
  test('automatic stats path is bounded and excludes catalog operations', () {
    final coordinator = File('lib/services/link/link_sync_coordinator.dart')
        .readAsStringSync();
    final journal = File('lib/services/link/link_journal.dart')
        .readAsStringSync();
    final statsStart = coordinator.indexOf('Future<void> _syncStatsBatch()');
    final statsEnd = coordinator.indexOf('Future<void> _synchronize(');
    expect(statsStart, greaterThanOrEqualTo(0));
    expect(statsEnd, greaterThan(statsStart));
    final stats = coordinator.substring(statsStart, statsEnd);

    expect(stats, contains('const pageSize = 50;'));
    expect(stats, contains("socket.request('history.push'"));
    expect(stats, contains("socket.request('history.pull'"));
    expect(stats, contains('getHistoryMatchCandidates'));
    expect(stats, isNot(contains('syncLibrary(')));
    expect(stats, isNot(contains('repairDesktopCopies(')));
    expect(stats, isNot(contains('syncCopiedLyrics(')));
    expect(stats, isNot(contains('_reconcileDesktopPlaylists(')));
    expect(coordinator, contains('fullSync: false'));
    expect(journal, contains('final historyChanges = StreamController<void>.broadcast();'));
    expect(journal, contains('historyChanges.add(null);'));
    expect(journal, contains('int limit = 250'));
  });

  test('stats are scheduled separately on connection, play and polling', () {
    final socket = section(
      'Future<void> _connectSocket()', 'void _socketConnectionChanged(',
    );
    final timer = section('void _tickLink()', 'Future<void> _syncLink()');
    final manual = section('Future<void> syncNow()', 'LinkFileCopy _fileCopier()');
    expect(socket, contains('_scheduleStatsSync(const Duration(seconds: 8))'));
    expect(socket, contains('_lastStatsSyncAt = DateTime.now()'));
    expect(timer, contains('unawaited(_syncStats())'));
    expect(controller, contains('LinkJournal.instance.historyChanges.stream.listen'));
    expect(controller, contains('await coordinator.synchronizeStats();'));
    expect(manual, isNot(contains('synchronizeStats')));
  });

  test('unmatched remote events still count toward listening minutes', () {
    final recaps = File('lib/data/repositories/recently_played_repository.dart')
        .readAsStringSync();
    expect(recaps, contains('displayedEventIds.contains(event.eventId)'));
    expect(recaps, contains('.playEventEntitys'));
    expect(recaps, contains('listenedMs: event.msPlayed'));
    expect(recaps, contains('recordLinkPlays('));
    expect(recaps, contains('displayedEventIds.add(entry.eventId!)'));
    expect(recaps, contains(r"id: 'history:${event.trackKey}'"));
  });

}
