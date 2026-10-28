import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/link/lokal_ghost_availability.dart';

void main() {
  test('paired desktop credentials allow HTTP playback without a websocket', () {
    expect(desktopStreamingCredentialsMatch(
      storedUsername: 'desktop-a:guest',
      storedBaseUrl: 'http://192.168.1.4:7860/',
      desktopId: 'desktop-a',
      desktopUserId: null,
      credentialOrigin: 'http://192.168.1.4:7860/',
    ), isTrue);
  });

  test('credentials for another desktop or origin cannot unlock a library', () {
    const server = 'desktop-a:guest';
    const url = 'http://192.168.1.4:7860/';
    bool check(String? id, String? origin) =>
        desktopStreamingCredentialsMatch(
          storedUsername: server, storedBaseUrl: url,
          desktopId: id, desktopUserId: null,
          credentialOrigin: origin,
        );
    expect(check(null, url), isFalse);
    expect(check('desktop-b', url), isFalse);
    expect(check('desktop-a', null), isFalse);
    expect(check('desktop-a', 'http://192.168.1.9:7860/'), isFalse);
  });
}
