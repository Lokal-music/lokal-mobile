import 'package:flick/services/link/desktop_genre_reconciliation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads the desktop primary and all additional real genres', () {
    expect(
      desktopLinkGenres({
        'genre': 'House',
        'genres': '["House", "Deep House", "Electronic"]',
      }),
      'House; Deep House; Electronic',
    );
    expect(
      desktopLinkGenres({'genre': 'Music', 'genres': 'Jazz, Funk'}),
      'Jazz; Funk',
    );
    expect(desktopLinkGenres({'genre': 'Music'}), isNull);
    expect(desktopLinkGenres({'genre': null, 'genres': ['No genre', 'Rock']}),
        'Rock');
  });

  test('only fills missing or placeholder genres', () {
    for (final value in [null, '', '  ', 'Music', 'unknown genre', 'No Genre']) {
      expect(isUnclassifiedLinkGenre(value), isTrue, reason: '$value');
    }
    for (final value in ['Jazz', 'Deep House', 'World', 'Alternative']) {
      expect(isUnclassifiedLinkGenre(value), isFalse, reason: value);
    }
  });

  final records = [
    const DesktopGenreIdentity(
      id: 1, remoteServerId: 22, remoteId: 'desktop-123',
      title: 'Phone-renamed song', artist: 'Artist', album: 'Album',
      durationMs: 200000,
    ),
    const DesktopGenreIdentity(
      id: 2, title: 'Song', artist: 'Artist', album: 'Original',
      durationMs: 212000,
    ),
    const DesktopGenreIdentity(
      id: 3, title: 'Song', artist: 'Artist', album: 'Live',
      durationMs: 212000,
    ),
    const DesktopGenreIdentity(
      id: 4, title: 'Single', artist: 'Another', album: 'EP',
      durationMs: 183500,
    ),
  ];

  test('stable desktop IDs match copied originals even after renames', () {
    final matcher = DesktopGenreMatcher(records);
    expect(
      matcher.matchingIds(22, {
        'id': 'desktop-123',
        'title': 'Original desktop title',
        'artist': 'Different tag',
        'duration': 200,
      }),
      [1],
    );
    expect(
      matcher.matchingIds(23, {
        'id': 'desktop-123',
        'title': 'Original desktop title',
        'artist': 'Different tag',
        'duration': 200,
      }),
      isEmpty,
    );
  });

  test('matches a unique local recording with duration tolerance', () {
    final matcher = DesktopGenreMatcher(records);
    expect(
      matcher.matchingIds(22, {
        'id': 'not-in-remote-index',
        'title': '  SINGLE  ',
        'artist': 'ANOTHER',
        'album': 'EP',
        'duration': 184,
      }),
      [4],
    );
  });

  test('disambiguates album editions and refuses unsafe matches', () {
    final matcher = DesktopGenreMatcher(records);
    expect(
      matcher.matchingIds(22, {
        'title': 'Song', 'artist': 'Artist',
        'album': 'Live', 'duration': 212,
      }),
      [3],
    );
    expect(
      matcher.matchingIds(22, {
        'title': 'Song', 'artist': 'Artist', 'duration': 212,
      }),
      isEmpty,
    );
    expect(
      matcher.matchingIds(22, {
        'title': 'Single', 'artist': 'Another', 'duration': 188,
      }),
      isEmpty,
    );
  });
}
