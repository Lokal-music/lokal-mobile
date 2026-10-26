import 'package:flick/features/flow/domain/flow_engine.dart';
import 'package:flick/features/flow/domain/flow_models.dart';
import 'package:flutter_test/flutter_test.dart';

FlowTrack track(int id, {String? genre, String? title, String? artist}) =>
    FlowTrack(
      id: '$id',
      title: title ?? 'Song $id',
      artist: artist ?? 'Artist ${id % 5}',
      genres: flowGenres(genre),
      durationMs: 180000,
    );

void main() {
  const engine = FlowEngine();
  final library = List.generate(
    80,
    (i) => track(i, genre: i.isEven ? 'Rock' : 'Jazz'),
  );
  final favorites = {for (var i = 0; i < 16; i++) '$i'};
  List<String> ids(List<FlowTrack> songs) => songs.map((s) => s.id).toList();
  List<FlowTrack> mix(
    FlowData data, {
    List<FlowTrack>? songs,
    int limit = 100,
  }) => engine.recommend(
    library: songs ?? library,
    favoriteIds: favorites,
    data: data,
    historyIds: ['20', '21'],
    limit: limit,
  );

  test(
    'unlock requires 16 real track favorites, including at engine boundary',
    () {
      expect(FlowRules.isUnlocked(15), isFalse);
      expect(FlowRules.isUnlocked(16), isTrue);
      expect(FlowRules.needed(-4), 16);
      expect(FlowRules.needed(16), 0);
      expect(
        engine.recommend(
          library: library,
          favoriteIds: {'missing', '0'},
          data: FlowData(),
        ),
        isEmpty,
      );
      expect(mix(FlowData()), isNotEmpty);
    },
  );

  test(
    'bans, three skips, genres, ids and duplicate recordings are hard filters',
    () {
      final songs = [
        ...library,
        library.first,
        track(900, title: 'Song 1', artist: 'Artist 1'),
        track(901, title: 'Song 3', artist: 'Artist 3'),
      ];
      final result = mix(
        FlowData(
          bannedIds: ['1'],
          skipCounts: {'5': 3},
          config: FlowConfig(excludedGenres: [' ROCK ']),
        ),
        songs: songs,
      );
      expect(ids(result), isNot(contains('1')));
      expect(ids(result), isNot(contains('900')));
      expect(ids(result), isNot(contains('5')));
      expect(result.every((s) => !s.genres.contains('rock')), isTrue);
      expect(result.map((s) => s.recordingKey).toSet().length, result.length);
      expect(ids(result).toSet().length, result.length);
    },
  );

  test(
    'discovery gates include exact .15/.85 boundaries with no fallback leak',
    () {
      for (final discovery in [0.0, .15]) {
        expect(
          ids(mix(FlowData(config: FlowConfig(discovery: discovery)))).toSet(),
          favorites.union({'20', '21'}),
        );
      }
      for (final discovery in [.85, 1.0]) {
        final result = ids(
          mix(FlowData(config: FlowConfig(discovery: discovery))),
        );
        expect(
          result.toSet().intersection(favorites.union({'20', '21'})),
          isEmpty,
        );
      }
      expect(
        mix(
          FlowData(config: FlowConfig(discovery: 1)),
          songs: library.take(16).toList(),
        ),
        isEmpty,
      );
      expect(mix(FlowData(config: FlowConfig(discovery: .151))).length, 80);
      expect(mix(FlowData(config: FlowConfig(discovery: .849))).length, 80);
    },
  );

  test(
    'same seed is repeatable and independent of library order; new seed varies',
    () {
      final data = FlowData(session: FlowSession(seed: 77));
      final result = ids(mix(data, limit: 24));
      expect(
        ids(mix(data, songs: library.reversed.toList(), limit: 24)),
        result,
      );
      expect(
        ids(mix(FlowData(session: FlowSession(seed: 78)), limit: 24)),
        isNot(result),
      );
    },
  );

  test(
    'memory, mood, affinity and skips change weights in meaningful directions',
    () {
      final jazz = track(0, genre: 'Jazz');
      double weight(
        FlowConfig c, {
        int? rank,
        int skips = 0,
        bool liked = false,
      }) => engine.score(
        jazz,
        config: c,
        historyRank: rank,
        skips: skips,
        favorite: liked,
        familiar: true,
      );
      expect(
        weight(FlowConfig(memory: 1), rank: 0),
        greaterThan(weight(FlowConfig(memory: 0), rank: 0)),
      );
      expect(
        weight(FlowConfig(memory: 1), rank: 0),
        greaterThan(weight(FlowConfig(memory: 1), rank: 30)),
      );
      expect(
        weight(FlowConfig(memory: 0), liked: true),
        greaterThan(weight(FlowConfig(memory: 1), liked: true)),
      );
      expect(
        weight(FlowConfig(mood: FlowMood.focus)),
        greaterThan(weight(FlowConfig())),
      );
      expect(weight(FlowConfig(), skips: 2), lessThan(weight(FlowConfig())));
    },
  );

  test('spaces artists by three tracks when alternatives are available', () {
    final songs = List.generate(
      36,
      (i) => track(i, artist: 'Artist ${i % 6}', genre: i.isEven ? 'Rock' : 'Jazz'),
    );
    final result = engine.recommend(
      library: songs,
      favoriteIds: {for (var i = 0; i < 16; i++) '$i'},
      data: FlowData(),
      limit: 30,
    );
    for (var i = 0; i < result.length; i++) {
      for (var back = 1; back <= 3 && i - back >= 0; back++) {
        expect(result[i].artistKey, isNot(result[i - back].artistKey));
      }
    }
  });

  test('top-up spacing respects artists already at the queue tail', () {
    final songs = List.generate(
      40,
      (i) => track(i, artist: 'Artist ${i % 8}'),
    );
    final tail = ['Artist 0', 'Artist 1', 'Artist 2'];
    final result = engine.recommend(
      library: songs,
      favoriteIds: {for (var i = 0; i < 16; i++) '$i'},
      data: FlowData(),
      previousArtists: tail,
      limit: 6,
    );
    expect(result.first.artistKey, isNot(isIn(tail.map(normalizeFlowText))));
  });

  test('top-ups exclude previous IDs and duplicate recordings', () {
    final initial = mix(FlowData(), limit: 24);
    final extra = engine.recommend(
      library: library,
      favoriteIds: favorites,
      data: FlowData(),
      excludeIds: ids(initial).toSet(),
      limit: 10,
    );
    expect(extra.length, 10);
    expect(ids(initial).toSet().intersection(ids(extra).toSet()), isEmpty);
  });

  test(
    'session restore drops missing/banned entries and expires after 24 hours',
    () {
      final now = DateTime.utc(2026, 10, 13);
      final data = FlowData(
        bannedIds: ['1'],
        session: FlowSession(
          trackIds: ['0', '1', 'missing'],
          builtAtMs: now.millisecondsSinceEpoch,
        ),
      );
      expect(ids(engine.restore(library: library, data: data, now: now)), [
        '0',
      ]);
      expect(
        engine.restore(
          library: library,
          data: data,
          now: now.add(const Duration(hours: 24)),
        ),
        isEmpty,
      );
      expect(
        engine.restore(
          library: library,
          data: data,
          now: now.subtract(const Duration(seconds: 1)),
        ),
        isEmpty,
      );
    },
  );

  test(
    'discovery snapshot retains its own plays but new mixes exclude them',
    () {
      final now = DateTime.utc(2026, 10, 13);
      final data = FlowData(
        config: FlowConfig(discovery: 1),
        recentIds: ['30'],
        session: FlowSession(
          trackIds: ['30', '31'],
          builtAtMs: now.millisecondsSinceEpoch,
        ),
      );
      expect(ids(engine.restore(library: library, data: data, now: now)), [
        '30',
        '31',
      ]);
      expect(ids(mix(data)), isNot(contains('30')));
    },
  );
}
