import 'dart:convert';
import 'dart:io';

import 'package:flick/models/ios_widget_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final corpus = jsonDecode(
    File('test/fixtures/ios_widget/snapshot_contract.json').readAsStringSync(),
  ) as Map;
  for (final raw in corpus['cases'] as List) {
    final row = raw as Map;
    test('WidgetKit wire: ${row['name']}', () {
      final document = row['document'] as String? ?? jsonEncode(row['input']);
      final snapshot = IosWidgetSnapshot.decode(document);
      expect(snapshot.toJson(), row['expected']);
      expect(snapshot.isStaleAt(row['nowMs'] as int), row['stale']);
      expect(
        snapshot.projectedPositionAt(row['nowMs'] as int),
        row['projectedPositionMs'],
      );
      expect(
        IosWidgetSnapshot.decode(snapshot.encode()).toJson(),
        snapshot.toJson(),
        reason: 'Every normalized snapshot must round-trip without widening',
      );
      expect(utf8.encode(snapshot.encode()).length, lessThanOrEqualTo(65536));
    });
  }

  Map<String, Object?> input() => {
    'schemaVersion': 1,
    'current': {'id': 'a' * 64, 'title': 'Generated song', 'artist': 'Artist'},
    'recommendations': [
      {'id': 'b' * 64, 'title': 'Recommendation'},
    ],
  };

  test('exports cannot mutate the saved current/recommendation snapshot', () {
    final raw = input();
    final snapshot = IosWidgetSnapshot.fromJson(raw);
    (raw['current'] as Map)['title'] = 'Changed input';
    final exported = snapshot.toJson();
    (exported['current'] as Map)['title'] = 'Changed output';
    ((exported['recommendations'] as List).single as Map)['title'] = 'Changed';
    (exported['recommendations'] as List).clear();
    expect((snapshot.toJson()['current'] as Map)['title'], 'Generated song');
    expect(snapshot.toJson()['recommendations'], hasLength(1));
    expect(
      ((snapshot.toJson()['recommendations'] as List).single as Map)['title'],
      'Recommendation',
    );
  });

  test('non-JSON native numbers cannot trap a field conversion', () {
    for (final invalid in [
      double.nan,
      double.infinity,
      -double.infinity,
      1e100,
    ]) {
      final snapshot = IosWidgetSnapshot.fromJson({
        ...input(),
        'updatedAtMs': invalid,
        'accentArgb': invalid,
        'positionMs': invalid,
        'queueCount': invalid,
        'playbackRate': invalid,
      });
      expect(snapshot.toJson()['updatedAtMs'], 0);
      expect(snapshot.toJson()['accentArgb'], 0);
      expect(snapshot.toJson()['positionMs'], 0);
      expect(snapshot.toJson()['queueCount'], 0);
      expect(snapshot.toJson()['playbackRate'], 1.0);
    }
  });

  test('the largest permitted metadata snapshot fits the wire byte budget', () {
    final snapshot = IosWidgetSnapshot.fromJson({
      ...input(),
      'current': {
        'id': 'a' * 64,
        'title': '😀' * 1000,
        'artist': '😀' * 1000,
        'album': '😀' * 1000,
        'artwork': '${'b' * 64}.png',
      },
      'flowStatus': '😀' * 1000,
      'recommendations': [
        for (var i = 0; i < 12; i++)
          {
            'id': i.toRadixString(16).padLeft(64, '0'),
            'title': '😀' * 1000,
            'artist': '😀' * 1000,
            'album': '😀' * 1000,
            'artwork': '${'b' * 64}.jpg',
          },
      ],
    });
    expect(utf8.encode(snapshot.encode()).length, lessThanOrEqualTo(65536));
    expect(
      IosWidgetSnapshot.decode(snapshot.encode()).toJson(),
      snapshot.toJson(),
    );
  });

  test('controls and projection never infer playback from invalid values', () {
    final snapshot = IosWidgetSnapshot.fromJson({
      ...input(),
      'isPlaying': 'true',
      'updatedAtMs': 1793059200000,
      'positionMs': 500,
      'durationMs': 1000,
    });
    expect(snapshot.toJson()['isPlaying'], isFalse);
    expect(snapshot.projectedPositionAt(-9223372036854775808), 500);
    expect(snapshot.projectedPositionAt(9223372036854775807), 500);
  });
}
