import 'package:flick/features/discovery/youtube_music_account.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> shelf(String title, List<Object?> cards) => {
  'musicCarouselShelfRenderer': {
    'header': {
      'musicCarouselShelfBasicHeaderRenderer': {
        'title': {'simpleText': title},
      },
    },
    'contents': cards,
  },
};

Map<String, Object?> track(String title, String id) => {
  'musicResponsiveListItemRenderer': {
    'playlistItemData': {'videoId': id},
    'flexColumns': [
      {
        'musicResponsiveListItemFlexColumnRenderer': {
          'text': {'runs': [
            {
              'text': title,
              'navigationEndpoint': {
                'watchEndpoint': {'videoId': id},
              },
            },
          ]},
        },
      },
      {
        'musicResponsiveListItemFlexColumnRenderer': {
          'text': {'runs': [
            {'text': 'Example Artist'},
          ]},
        },
      },
    ],
  },
};

void main() {
  test('five YouTube Home categories map to native named shelves', () {
    const names = [
      'From the community',
      'New releases',
      'Trending songs for you',
      'Featured playlists for you',
      'Your daily discover',
    ];
    const ids = [
      'community', 'newReleases', 'trending', 'featuredPlaylists',
      'dailyDiscover',
    ];
    final root = {
      'contents': [
        for (var i = 0; i < names.length; i++)
          shelf(names[i], [track('Song $i', 'abcdefghi0$i')]),
        shelf('Unrelated shelf', [track('Wrong', 'abcdefghiz0')]),
      ],
    };
    final categories = parseYoutubeMusicHomeCategories(root);
    expect(categories.map((c) => c.id), ids);
    for (var i = 0; i < ids.length; i++) {
      expect(categories[i].tracks.single.title, 'Song $i');
    }
    expect(categories.any((c) => c.tracks.any((t) => t.title == 'Wrong')),
        isFalse);
  });

  test('new releases can show actual albums rather than fake track groups', () {
    final root = shelf('New releases', [
      {
        'musicTwoRowItemRenderer': {
          'title': {'simpleText': 'New Album'},
          'subtitle': {'simpleText': 'Some Artist'},
          'navigationEndpoint': {
            'browseEndpoint': {'browseId': 'MPREb1234'},
          },
        },
      },
    ]);
    final categories = parseYoutubeMusicHomeCategories(root);
    expect(categories.single.id, 'newReleases');
    expect(categories.single.albums.single.title, 'New Album');
    expect(categories.single.tracks, isEmpty);
  });

  test('unnamed/unsupported provider shelves are not fabricated', () {
    final parsed = parseYoutubeMusicHomeCategories(
      shelf('Welcome back', [track('Some Song', 'abcdefghijk')]),
    );
    expect(parsed, isEmpty);
  });
}
