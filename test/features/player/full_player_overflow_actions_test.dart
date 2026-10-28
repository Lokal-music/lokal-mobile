import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/player/widgets/full_player_usb_restart_menu.dart';
import 'package:flick/features/songs/widgets/song_actions_bottom_sheet.dart';
import 'package:flick/models/song.dart';

Song _song(String id) => Song(
  id: id,
  title: 'Song $id',
  artist: 'Artist',
  duration: const Duration(minutes: 3),
  fileType: 'FLAC',
);

void main() {
  group('full-player overflow visibility', () {
    test('USB restart is offered for physically connected DACs on Android', () {
      expect(showUsbRestartMenuAction(
        android: true, connectedDac: true,
      ), isTrue);
      expect(showUsbRestartMenuAction(
        android: true, connectedDac: false,
      ), isFalse);
      expect(showUsbRestartMenuAction(
        android: false, connectedDac: true,
      ), isFalse);
    });

    test('motion cover and Watch video do not duplicate player footer', () {
      expect(showMovingCoverMenuAction(nowPlaying: true), isFalse);
      expect(showWatchVideoMenuAction(
        nowPlaying: true, videosEnabled: true,
      ), isFalse);
      // The library/queue song menu retains its separate capabilities.
      expect(showMovingCoverMenuAction(nowPlaying: false), isTrue);
      expect(showWatchVideoMenuAction(
        nowPlaying: false, videosEnabled: true,
      ), isTrue);
      expect(showWatchVideoMenuAction(
        nowPlaying: false, videosEnabled: false,
      ), isFalse);
    });

    test('Now Playing menu follows a new track while it is open', () {
      final original = _song('original');
      final next = _song('next');
      expect(songForOpenMenu(
        nowPlaying: true,
        openedSong: original,
        currentSong: next,
      ), same(next));
      expect(songForOpenMenu(
        nowPlaying: false,
        openedSong: original,
        currentSong: next,
      ), same(original));
      expect(songForOpenMenu(
        nowPlaying: true,
        openedSong: original,
        currentSong: null,
      ), isNull);
    });
  });

  test('Pitch footer is positioned between Speed up and Equalizer in both players', () {
    final modern = File(
      'lib/features/player/screens/full_player_screen.dart',
    ).readAsStringSync();
    final speedModern = modern.lastIndexOf(
      'valueListenable: _player.playbackSpeedNotifier',
    );
    final pitchModern = modern.lastIndexOf(
      'valueListenable: _player.pitchSemitonesNotifier',
    );
    final eqModern = modern.lastIndexOf(
      'chip(LucideIcons.slidersHorizontal, l10n.equalizer',
    );
    expect(speedModern, greaterThan(0));
    expect(pitchModern, greaterThan(speedModern));
    expect(eqModern, greaterThan(pitchModern));

    final classic = File(
      'lib/features/player/widgets/full_player_action_chip_row.dart',
    ).readAsStringSync();
    final speedClassic = classic.indexOf('label: l10n.speedUp');
    final pitchClassic = classic.indexOf(
      'valueListenable: playerService.pitchSemitonesNotifier',
    );
    final eqClassic = classic.indexOf('label: l10n.equalizer');
    expect(speedClassic, greaterThan(0));
    expect(pitchClassic, greaterThan(speedClassic));
    expect(eqClassic, greaterThan(pitchClassic));
  });
}
