import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/services/network_cache_service.dart';
import 'package:flick/services/sources/webdav_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

const _multistatus = '<?xml version="1.0"?>'
    '<D:multistatus xmlns:D="DAV:">'
    '<D:response>'
    '<D:href>/music/</D:href>'
    '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>'
    '</D:response>'
    '<D:response>'
    '<D:href>/music/Album%20One/</D:href>'
    '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>'
    '</D:response>'
    '<D:response>'
    '<D:href>/music/song.flac</D:href>'
    '<D:propstat><D:prop><D:resourcetype/><D:getcontentlength>9876</D:getcontentlength></D:prop></D:propstat>'
    '</D:response>'
    '</D:multistatus>';

class _StreamResponseClient extends http.BaseClient {
  _StreamResponseClient(this.respond);
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      respond(request);
}

NetworkServerEntity _server({String? token}) {
  final entity = NetworkServerEntity()
    ..id = 5
    ..label = 'Dav'
    ..protocol = 'webdav'
    ..baseUrl = 'https://dav.example.com/music'
    ..username = 'alice'
    ..token = token;
  return entity;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('NAS href interoperability', () {
    test('encoded share roots use decoded segments without double escaping', () {
      const base = 'https://dav.example.com/Music%20%25%20%C3%89t%C3%A9';
      final absolute = WebdavService.requestUriForTest(
        base,
        '$base/Album%20%231/100%25%20Real.flac',
      );
      expect(
        absolute.toString(),
        '$base/Album%20%231/100%25%20Real.flac',
      );

      final decoded = WebdavService.requestUriForTest(
        base,
        '/Music % Été/Album #1/100% Real.flac',
      );
      expect(decoded, absolute);
      expect(
        () => WebdavService.requestUriForTest(
          base, '/Music % Another/cover.jpg',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('encoded share root and nested cover hrefs compare by decoded name', () {
      const body = '<D:multistatus xmlns:D="DAV:">'
          '<D:response><D:href>/Music%20%25/</D:href></D:response>'
          '<D:response><D:href>/Music%20%25/Album%20%231/</D:href>'
          '<D:propstat><D:prop><D:resourcetype><D:collection/>'
          '</D:resourcetype></D:prop></D:propstat></D:response>'
          '<D:response><D:href>/Music%20%25/Album%20%231/cover.jpg</D:href>'
          '</D:response>'
          '</D:multistatus>';
      final entries = WebdavService.parseMultistatusForTest(
        body,
        '/Music %/',
        requestUrl: 'https://dav.example.com/Music%20%25/',
        shareRoot: '/Music %/',
      );
      expect(entries.map((entry) => entry.href).toList(), [
        '/Music %/Album #1/',
        '/Music %/Album #1/cover.jpg',
      ]);
    });

    test('sync encodes the server root and nested URL exactly once', () async {
      final seen = <Uri>[];
      final server = _server()
        ..baseUrl = 'https://dav.example.com/Music%20%25';
      final service = WebdavService.create(
        client: MockClient((request) async {
          seen.add(request.url);
          if (seen.length == 1) {
            return http.Response(
              '<D:multistatus xmlns:D="DAV:">'
              '<D:response><D:href>/Music%20%25/</D:href></D:response>'
              '<D:response><D:href>Album%20%231/</D:href>'
              '<D:propstat><D:prop><D:resourcetype><D:collection/>'
              '</D:resourcetype></D:prop></D:propstat></D:response>'
              '</D:multistatus>', 207,
            );
          }
          // Deliberately abort the walk before database purge; this test
          // validates URL construction, not a successful sync transaction.
          return http.Response('NAS unavailable', 503);
        }),
      );
      await expectLater(
        service.syncLibrary(server).toList(),
        throwsA(isA<WebdavNetworkException>()),
      );
      expect(seen.map((uri) => uri.toString()).toList(), [
        'https://dav.example.com/Music%20%25',
        'https://dav.example.com/Music%20%25/Album%20%231/',
      ]);
    });

    test('legacy absolute NAS cover and audio paths never duplicate the origin', () {
      final cover = WebdavService.requestUriForTest(
        'https://192.168.8.1:6008/disk1_part1',
        'https://192.168.8.1:6008/disk1_part1/Album%20One/cover.jpg',
      );
      expect(
        cover.toString(),
        'https://192.168.8.1:6008/disk1_part1/Album%20One/cover.jpg',
      );
      final song = WebdavService.requestUriForTest(
        'https://192.168.8.1:6008/disk1_part1',
        '/disk1_part1/100% Real.flac',
      );
      expect(song.toString(), contains('100%25%20Real.flac'));
    });

    test('legacy WebDAV paths may not escape the share or switch origins', () {
      const root = 'https://192.168.8.1:6008/disk1_part1';
      for (final invalid in [
        'https://evil.example/disk1_part1/cover.jpg',
        'https://192.168.8.1:6009/disk1_part1/cover.jpg',
        'https://admin:secret@192.168.8.1:6008/disk1_part1/cover.jpg',
        '/other_share/cover.jpg',
        '/disk1_part1/../private/cover.jpg',
      ]) {
        expect(() => WebdavService.requestUriForTest(root, invalid),
            throwsA(isA<FormatException>()));
      }
    });

    test('absolute same-origin WebDAV hrefs resolve as share-relative paths', () {
      const body = '<D:multistatus xmlns:D="DAV:">'
          '<D:response><D:href>https://192.168.8.1:6008/disk1_part1/</D:href>'
          '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>'
          '</D:prop></D:propstat></D:response>'
          '<D:response><D:href>https://192.168.8.1:6008/disk1_part1/Album%20One/</D:href>'
          '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>'
          '</D:prop></D:propstat></D:response>'
          '<D:response><D:href>https://192.168.8.1:6008/disk1_part1/100%25%20Real.flac</D:href>'
          '<D:propstat><D:prop><D:getcontentlength>128</D:getcontentlength>'
          '</D:prop></D:propstat></D:response>'
          '</D:multistatus>';
      final entries = WebdavService.parseMultistatusForTest(
        body, '/disk1_part1',
        requestUrl: 'https://192.168.8.1:6008/disk1_part1/',
        shareRoot: '/disk1_part1',
      );
      expect(entries.map((entry) => entry.href).toList(), [
        '/disk1_part1/Album One/',
        '/disk1_part1/100% Real.flac',
      ]);
      expect(entries.first.isCollection, isTrue);
      expect(entries.last.size, 128);
    });

    test('root share accepts children and skips its self href', () {
      const body = '<D:multistatus xmlns:D="DAV:">'
          '<D:response><D:href>/</D:href></D:response>'
          '<D:response><D:href>/Album/</D:href>'
          '<D:propstat><D:prop><D:resourcetype><D:collection/>'
          '</D:resourcetype></D:prop></D:propstat></D:response>'
          '</D:multistatus>';
      final entries = WebdavService.parseMultistatusForTest(
        body, '/', requestUrl: 'https://nas.example/',
        shareRoot: '/',
      );
      expect(entries, hasLength(1));
      expect(entries.single.href, '/Album/');
      expect(entries.single.isCollection, isTrue);
    });

    test('collection href ends with exactly one slash', () {
      const body = '<D:multistatus xmlns:D="DAV:">'
          '<D:response><D:href>/disk1_part1/</D:href></D:response>'
          '<D:response><D:href>/disk1_part1/Album/</D:href>'
          '<D:propstat><D:prop><D:resourcetype><D:collection/>'
          '</D:resourcetype></D:prop></D:propstat></D:response>'
          '</D:multistatus>';
      final entries = WebdavService.parseMultistatusForTest(
        body, '/disk1_part1/',
        requestUrl: 'https://nas.example/disk1_part1/',
        shareRoot: '/disk1_part1/',
      );
      expect(entries, hasLength(1));
      expect(entries.single.href, '/disk1_part1/Album/');
    });

    test('invalid HTTP 200 body is reported as XML failure during sync', () async {
      final service = WebdavService.create(
        client: MockClient((_) async =>
            http.Response('<html>Router files, not WebDAV</html>', 200)),
      );
      await expectLater(
        service.syncLibrary(_server()).toList(),
        throwsA(isA<WebdavNetworkException>().having(
          (error) => error.toString(), 'message',
          allOf(contains('invalid multistatus XML'), isNot(contains('HTTP 200'))),
        )),
      );
    });

    test('relative child href is resolved under an unslashed WebDAV collection', () {
      const body = '<D:multistatus xmlns:D="DAV:">'
          '<D:response><D:href>Album%20One/</D:href>'
          '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>'
          '</D:prop></D:propstat></D:response>'
          '</D:multistatus>';
      final entries = WebdavService.parseMultistatusForTest(
        body, '/disk1_part1',
        requestUrl: 'https://192.168.8.1:6008/disk1_part1',
        shareRoot: '/disk1_part1',
      );
      expect(entries.single.href, '/disk1_part1/Album One/');
    });

    test('encoded slash is rejected rather than crossing a folder boundary', () {
      const body = '<D:multistatus xmlns:D="DAV:">'
          '<D:response><D:href>/disk1_part1/Album%2FPrivate.flac</D:href>'
          '</D:response></D:multistatus>';
      expect(() => WebdavService.parseMultistatusForTest(
        body, '/disk1_part1',
        requestUrl: 'https://192.168.8.1:6008/disk1_part1',
        shareRoot: '/disk1_part1',
      ), throwsA(isA<FormatException>()));
    });

    test('blocks cross-origin and outside-share hrefs before indexing', () {
      for (final href in [
        'https://other.example/disk1_part1/song.flac',
        '/another_share/song.flac',
      ]) {
        final body = '<D:multistatus xmlns:D="DAV:">'
            '<D:response><D:href>$href</D:href></D:response>'
            '</D:multistatus>';
        expect(
          () => WebdavService.parseMultistatusForTest(
            body, '/disk1_part1',
            requestUrl: 'https://192.168.8.1:6008/disk1_part1/',
            shareRoot: '/disk1_part1',
          ),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('real WebDAV XML in HTTP 200 can pass connection probe', () async {
      final service = WebdavService.create(
        client: MockClient((_) async => http.Response(_multistatus, 200)),
      );
      expect(await service.ping(_server()), isTrue);
    });
  });

  group('auth', () {
    test('resolveToken stores base64(password)', () async {
      final client = MockClient((request) async => http.Response('', 200));
      final service = WebdavService.create(client: client);

      final token = await service.resolveToken(_server(), 'secret');

      expect(token, base64Encode(utf8.encode('secret')));
      expect(utf8.decode(base64Decode(token!)), 'secret');
    });

    test('cannot approve an unseen certificate fingerprint', () async {
      final service = WebdavService.create(
        client: MockClient((request) async => http.Response(_multistatus, 207)),
      );
      expect(await service.trustPresentedCertificate(_server(), approvedFingerprint: 'a' * 64), isFalse);
      expect(service.untrustedCertificateFingerprint, isNull);
    });

    test('certificate approval persists only after successful PROPFIND', () async {
      final server = _server(token: base64Encode(utf8.encode('secret')));
      final origin = Uri.parse(server.baseUrl).origin;
      const fingerprint = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      var requests = 0;
      final service = WebdavService.create(
        client: MockClient((request) async {
          requests++;
          expect(request.method, 'PROPFIND');
          return http.Response(_multistatus, 207);
        }),
      );
      service.recordRejectedCertificateForTest(origin, fingerprint);
      expect(
        await service.trustPresentedCertificate(
          server, approvedFingerprint: fingerprint,
        ),
        isTrue,
      );
      expect(requests, 1);
      final independentlyLoaded = WebdavService.create(
        client: MockClient((_) async => http.Response('', 500)),
      );
      expect(await independentlyLoaded.hasTrustedCertificate(server), isTrue);
    });

    test('certificate approval is not persisted on failed PROPFIND', () async {
      final server = _server();
      const fingerprint = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      var requests = 0;
      final service = WebdavService.create(
        client: MockClient((_) async {
          requests++;
          return http.Response('Forbidden', 403);
        }),
      );
      service.recordRejectedCertificateForTest(
        Uri.parse(server.baseUrl).origin, fingerprint,
      );
      expect(
        await service.trustPresentedCertificate(
          server, approvedFingerprint: fingerprint,
        ),
        isFalse,
      );
      expect(requests, 1);
      final other = WebdavService.create(
        client: MockClient((_) async => http.Response('', 500)),
      );
      expect(await other.hasTrustedCertificate(server), isFalse);
    });

    test('certificate approval rejects a swapped fingerprint before credentials',
        () async {
      final server = _server();
      const seen = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      const swapped = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
      final service = WebdavService.create(
        client: MockClient((_) async {
          fail('No authorization request is allowed for a swapped certificate');
        }),
      );
      service.recordRejectedCertificateForTest(
        Uri.parse(server.baseUrl).origin, swapped,
      );
      expect(
        await service.trustPresentedCertificate(
          server, approvedFingerprint: seen,
        ),
        isFalse,
      );
    });

    test('follows only same-origin trailing slash WebDAV redirects', () async {
      final visited = <Uri>[];
      final client = MockClient((request) async {
        visited.add(request.url);
        expect(request.followRedirects, isFalse);
        if (visited.length == 1) {
          return http.Response('', 301, headers: {
            'location': '/music/',
          });
        }
        return http.Response(_multistatus, 207);
      });
      final service = WebdavService.create(client: client);
      expect(await service.ping(_server()), isTrue);
      expect(visited.map((uri) => uri.path), ['/music', '/music/']);
    });

    test('never sends authentication on a cross-origin PROPFIND redirect', () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        return http.Response('', 302, headers: {
          'location': 'https://attacker.example/steal',
        });
      });
      final service = WebdavService.create(client: client);
      expect(await service.ping(_server()), isFalse);
      expect(service.lastPingError, contains('redirected outside'));
      expect(requests, 1);
    });

    test('ordinary HTTP 200 does not pretend to be WebDAV', () async {
      final client = MockClient((request) async =>
          http.Response('<html>Router files</html>', 200));
      final service = WebdavService.create(client: client);
      expect(await service.ping(_server()), isFalse);
      expect(service.lastPingError, contains('no WebDAV multistatus'));
    });

    test('HTTP authentication, missing folders and unsupported methods explain failures', () async {
      for (final (code, expected) in [
        (401, 'username or password'),
        (403, 'cannot access'),
        (404, 'not found'),
        (405, 'does not offer WebDAV'),
      ]) {
        final service = WebdavService.create(
          client: MockClient((_) async => http.Response('', code)),
        );
        expect(await service.ping(_server()), isFalse);
        expect(service.lastPingError, contains(expected));
      }
    });

    test('ping sends HTTP Basic over PROPFIND and accepts 207', () async {
      late String capturedAuth;
      late String capturedDepth;
      late String capturedMethod;
      late String capturedConnection;
      final client = MockClient((request) async {
        capturedAuth = request.headers['Authorization'] ?? '';
        capturedDepth = request.headers['Depth'] ?? '';
        capturedMethod = request.method;
        capturedConnection = request.headers['Connection'] ?? '';
        return http.Response(_multistatus, 207);
      });
      final service = WebdavService.create(client: client);

      // token = base64('secret'); expected Basic = base64('alice:secret')
      final server = _server(token: base64Encode(utf8.encode('secret')));
      final ok = await service.ping(server);

      expect(ok, isTrue);
      expect(capturedMethod, 'PROPFIND');
      expect(capturedDepth, '0');
      expect(capturedConnection, 'close');
      expect(
        capturedAuth,
        'Basic ${base64Encode(utf8.encode('alice:secret'))}',
      );
    });
  });

  group('multistatus schema', () {
    test('allows one RFC 4918 top-level DAV responsedescription after responses', () {
      const body = '<D:multistatus xmlns:D="DAV:">'
          '<D:response><D:href>/music/</D:href></D:response>'
          '<D:responsedescription>Directory listing</D:responsedescription>'
          '</D:multistatus>';
      expect(WebdavService.isValidMultistatusForTest(body), isTrue);
    });

    test('rejects nested, unnamespaced or wrongly ordered responses', () {
      expect(WebdavService.isValidMultistatusForTest(
        '<html><multistatus><response><href>/music/</href></response></multistatus></html>',
      ), isFalse);
      expect(WebdavService.isValidMultistatusForTest(
        '<multistatus><response><href>/music/</href></response></multistatus>',
      ), isFalse);
      expect(WebdavService.isValidMultistatusForTest(
        '<D:multistatus xmlns:D="DAV:">'
        '<D:responsedescription>First</D:responsedescription>'
        '<D:response><D:href>/music/</D:href></D:response>'
        '</D:multistatus>',
      ), isFalse);
    });
  });

  group('parse', () {
    test('multistatus splits collections from files and skips self', () {
      final entries =
          WebdavService.parseMultistatusForTest(_multistatus, '/music/');

      expect(entries, hasLength(2));
      expect(entries[0].href, '/music/Album One/');
      expect(entries[0].isCollection, isTrue);
      expect(entries[1].href, '/music/song.flac');
      expect(entries[1].isCollection, isFalse);
      expect(entries[1].size, 9876);
    });

    test('isAudioPath detects audio extensions', () {
      expect(WebdavService.isAudioPath('/a/b.flac'), isTrue);
      expect(WebdavService.isAudioPath('/a/b.mp3'), isTrue);
      expect(WebdavService.isAudioPath('/a/b.M4A'), isTrue);
      expect(WebdavService.isAudioPath('/a/cover.jpg'), isFalse);
      expect(WebdavService.isAudioPath('/a/notes.txt'), isFalse);
    });

    test('isCoverPath matches known cover stems with image extensions', () {
      expect(WebdavService.isCoverPath('/a/cover.jpg'), isTrue);
      expect(WebdavService.isCoverPath('/a/folder.png'), isTrue);
      expect(WebdavService.isCoverPath('/a/album.large.jpeg'), isTrue);
      // Image ext but not a cover stem.
      expect(WebdavService.isCoverPath('/a/track.jpg'), isFalse);
      // Cover stem but not an image ext.
      expect(WebdavService.isCoverPath('/a/cover.flac'), isFalse);
    });
  });

  // Regression for issue #255: hrefs were decoded twice. The second decode ran
  // during classification (outside the per-dir try/catch) and threw
  // `Invalid argument(s): Illegal percent encoding in URL` on the first
  // non-ASCII or literal-`%` file, aborting the whole sync.
  group('parse special characters (regression #255)', () {
    test('decodes non-ASCII, percent, hash and question mark hrefs', () {
      const body = '<?xml version="1.0"?>'
          '<D:multistatus xmlns:D="DAV:">'
          '<D:response><D:href>/music/</D:href>'
          '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>'
          '<D:response><D:href>/music/%E7%85%A7%E4%BA%95%E9%A0%86%E6%94%BF%20-%20Delirious.flac</D:href>'
          '<D:propstat><D:prop><D:resourcetype/><D:getcontentlength>11</D:getcontentlength></D:prop></D:propstat></D:response>'
          '<D:response><D:href>/music/100%25%20Real.flac</D:href>'
          '<D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat></D:response>'
          '<D:response><D:href>/music/Album%20%231/</D:href>'
          '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>'
          '<D:response><D:href>/music/What%3F.flac</D:href>'
          '<D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat></D:response>'
          '</D:multistatus>';

      final entries = WebdavService.parseMultistatusForTest(body, '/music/');

      expect(entries.map((e) => e.href), [
        '/music/照井順政 - Delirious.flac',
        '/music/100% Real.flac',
        '/music/Album #1/',
        '/music/What?.flac',
      ]);
    });

    test('tolerates raw non-conformant UTF-8 hrefs', () {
      const body = '<D:multistatus xmlns:D="DAV:">'
          '<D:response><D:href>/music/照井順政 - Delirious.flac</D:href>'
          '<D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat></D:response>'
          '</D:multistatus>';

      final entries = WebdavService.parseMultistatusForTest(body, '/music/');

      expect(entries.single.href, '/music/照井順政 - Delirious.flac');
    });

    test('classification accepts already-decoded special names', () {
      expect(WebdavService.isAudioPath('/music/照井順政 - Delirious.flac'),
          isTrue);
      expect(WebdavService.isAudioPath('/music/100% Real.flac'), isTrue);
      expect(WebdavService.isAudioPath('/music/What?.flac'), isTrue);
      expect(WebdavService.isCoverPath('/music/Album #1/cover.jpg'), isTrue);
    });
  });

  group('request URLs', () {
    NetworkServerEntity server() => _server();

    test('direct playback requests local-network access before returning URL',
        () async {
      final requests = <Uri>[];
      final service = WebdavService.create(
        client: MockClient((request) async => http.Response('', 200)),
        ensureLocalAccess: (uri) async {
          requests.add(uri);
        },
      );
      final descriptor = await service.streamDescriptor(
        server(), Uri.encodeComponent('/music/song.flac'),
      );
      expect(requests, hasLength(1));
      expect(requests.single.host, 'dav.example.com');
      expect(descriptor?.url, contains('/music/song.flac'));
    });

    test('direct playback does not return credentials if LAN access is denied',
        () async {
      final service = WebdavService.create(
        client: MockClient((request) async => http.Response('', 200)),
        ensureLocalAccess: (uri) async => throw StateError('LAN permission denied'),
      );
      await expectLater(
        service.streamDescriptor(
          server(), Uri.encodeComponent('/music/song.flac'),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('streamDescriptor re-encodes without fragment/query corruption',
        () async {
      final service = WebdavService.create(
        client: MockClient((request) async => http.Response('', 200)),
      );
      final remoteId =
          Uri.encodeComponent('/music/Album #1/What?.flac');

      final descriptor = await service.streamDescriptor(server(), remoteId,
          extension: 'flac');

      final uri = Uri.parse(descriptor!.url);
      expect(uri.pathSegments.join('/'), 'music/Album #1/What?.flac');
      expect(uri.fragment, isEmpty);
      expect(uri.hasQuery, isFalse);
    });

    test('cover 404 cancels unread response before releasing connection', () async {
      var cancelled = false;
      final controller = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      final service = WebdavService.create(
        client: _StreamResponseClient(
          (_) async => http.StreamedResponse(controller.stream, 404),
        ),
      );
      final marker = base64Encode(utf8.encode('/music/cover.jpg'));
      await expectLater(
        service.getCoverArt(server(), marker),
        throwsA(isA<WebdavNetworkException>()),
      );
      expect(cancelled, isTrue);
      await controller.close();
    });

    test('oversized cover response cancels stream before allocation', () async {
      var cancelled = false;
      final controller = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      final service = WebdavService.create(
        client: _StreamResponseClient(
          (_) async => http.StreamedResponse(
            controller.stream, 200, contentLength: 20 * 1024 * 1024,
          ),
        ),
      );
      final marker = base64Encode(utf8.encode('/music/cover.jpg'));
      await expectLater(
        service.getCoverArt(server(), marker),
        throwsA(isA<WebdavNetworkException>()),
      );
      expect(cancelled, isTrue);
      await controller.close();
    });

    test('getCoverArt requests the re-encoded path', () async {
      late Uri captured;
      final service = WebdavService.create(
        client: MockClient((request) async {
          captured = request.url;
          return http.Response.bytes([1, 2, 3], 200);
        }),
      );
      final marker = base64Encode(utf8.encode('/music/Album #1/cover.jpg'));

      final bytes = await service.getCoverArt(server(), marker);

      expect(captured.pathSegments.join('/'), 'music/Album #1/cover.jpg');
      expect(captured.fragment, isEmpty);
      expect(captured.hasQuery, isFalse);
      expect(bytes, [1, 2, 3]);
    });

    test('stream downloads non-ASCII remoteId into the cache', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('webdav_stream_test');
      addTearDown(() => tempDir.delete(recursive: true));
      late Uri captured;
      final service = WebdavService.create(
        client: MockClient((request) async {
          captured = request.url;
          return http.Response.bytes([9, 9], 200);
        }),
        networkCache: NetworkCacheService(
          rootDirectory: Directory(p.join(tempDir.path, 'cache')),
        ),
      );
      final remoteId =
          Uri.encodeComponent('/music/照井順政 - Delirious.flac');

      final path =
          await service.stream(server(), remoteId, extension: 'flac');

      expect(captured.pathSegments.join('/'), 'music/照井順政 - Delirious.flac');
      expect(await File(path).readAsBytes(), [9, 9]);
    });
  });
}
