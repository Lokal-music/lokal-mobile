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

  test('startup, reconnect, refresh and timer must never start a sync', () {
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
    expect(RegExp(r'_syncLink\\(').allMatches(controller).length, 2,
        reason: 'Only the user action and its method definition may reference _syncLink');
    expect(RegExp(r'\\.synchronize\\(').allMatches(controller).length, 1);
    expect(screen, contains('Future<void> _syncNow()'));
    expect(screen, contains(': _syncNow,'));
    expect(screen, contains('Desktop library sync is manual.'));
  });
}
