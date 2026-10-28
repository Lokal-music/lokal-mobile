import 'dart:convert';

import 'package:flick/features/whats_new/data/lokal_minor_release_notes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('minor key ignores patch, build number, and optional v prefix', () {
    expect(lokalMinorVersion('4.2.7'), '4.2');
    expect(lokalMinorVersion('v4.2.0'), '4.2');
    expect(lokalMinorVersion('4.2.7+215476944'), '4.2');
    expect(lokalMinorVersion('4.3.0'), '4.3');
    expect(lokalMinorVersion('invalid'), isNull);
  });

  test('every patch and build within one minor is already seen', () {
    expect(lokalMinorHasChanged('4.2', '4.2.1+123'), isFalse);
    expect(lokalMinorHasChanged('4.2', '4.2.7+999'), isFalse);
    expect(lokalMinorHasChanged('4.2', '4.2'), isFalse);
    expect(lokalMinorHasChanged('4.3', '4.2.7+999'), isTrue);
    expect(lokalMinorHasChanged('4.3', '4.3.0+1'), isFalse);
    expect(lokalMinorHasChanged('4.3', null), isFalse);
  });

  test('parses only the current minor tagged release notes', () async {
    final client = MockClient((request) async {
      expect(request.url.pathSegments.last, 'v4.3.0');
      return http.Response(jsonEncode({
        'body': """Intro

## What's Changed
* Improve playback by @dev in https://github.com/lokal-music/lokal-mobile/pull/1
* Redesign queue by @dev in https://github.com/lokal-music/lokal-mobile/pull/2

**Full Changelog**: https://github.com/lokal-music/lokal-mobile/compare/v4.2.7...v4.3.0
""",
        'published_at': '2026-11-04T10:00:00Z',
      }), 200);
    });
    addTearDown(client.close);

    final notes = await loadLokalMinorRelease('4.3', client: client);
    expect(notes?.version, '4.3');
    expect(notes?.date, '2026-11-04');
    expect(notes?.sections.single.bullets,
        ['Improve playback', 'Redesign queue']);
  });

  test('an unavailable release never substitutes another minor notes', () async {
    final client = MockClient((_) async => http.Response('Not found', 404));
    addTearDown(client.close);
    expect(await loadLokalMinorRelease('4.3', client: client), isNull);
    expect((await loadLokalMinorRelease('4.2', client: client))?.version, '4.2');
  });
}
