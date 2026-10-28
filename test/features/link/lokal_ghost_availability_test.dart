import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/link/lokal_ghost_availability.dart';

void main() {
  test(
    'origin comparison permits root slash but rejects credentials and subpaths',
    () {
      bool match(String value) => desktopStreamingCredentialsMatch(
        storedUsername: 'desktop-a:guest',
        storedBaseUrl: value,
        desktopId: 'desktop-a',
        desktopUserId: null,
        credentialOrigin: 'http://192.168.1.4:7860/',
      );
      expect(match('http://192.168.1.4:7860'), isTrue);
      for (final value in [
        'http://user:secret@192.168.1.4:7860/',
        'http://192.168.1.4:7860/other',
        'http://192.168.1.4:7860/?token=secret',
        'http://192.168.1.4:7860/#fragment',
        'https://192.168.1.4:7860/',
      ]) {
        expect(match(value), isFalse);
      }
    },
  );

  test(
    'HTTP desktop reachability is bounded and handles offline failure',
    () async {
      expect(await desktopHttpReachable(() async {}), isTrue);
      expect(
        await desktopHttpReachable(() async {
          throw StateError('Connection refused');
        }),
        isFalse,
      );
      expect(
        await desktopHttpReachable(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
          timeout: const Duration(milliseconds: 5),
        ),
        isFalse,
      );
    },
  );

  test(
    'paired desktop credentials allow HTTP playback without a websocket',
    () {
      expect(
        desktopStreamingCredentialsMatch(
          storedUsername: 'desktop-a:guest',
          storedBaseUrl: 'http://192.168.1.4:7860/',
          desktopId: 'desktop-a',
          desktopUserId: null,
          credentialOrigin: 'http://192.168.1.4:7860/',
        ),
        isTrue,
      );
    },
  );

  test('credentials for another desktop or origin cannot unlock a library', () {
    const server = 'desktop-a:guest';
    const url = 'http://192.168.1.4:7860/';
    bool check(String? id, String? origin) => desktopStreamingCredentialsMatch(
      storedUsername: server,
      storedBaseUrl: url,
      desktopId: id,
      desktopUserId: null,
      credentialOrigin: origin,
    );
    expect(check(null, url), isFalse);
    expect(check('desktop-b', url), isFalse);
    expect(check('desktop-a', null), isFalse);
    expect(check('desktop-a', 'http://192.168.1.9:7860/'), isFalse);
  });
}
