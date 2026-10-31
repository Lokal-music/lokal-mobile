import 'dart:convert';

import 'package:flick/features/discovery/youtube_music_account.dart';
import 'package:flick/features/discovery/youtube_music_playlist_cache.dart';
import 'package:flick/features/discovery/youtube_music_store.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flick/features/spotify/provider_playlist_visibility.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('sign-out removes only the account visibility and keeps saved playlists for re-sign-in', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const session = YoutubeMusicSession(cookies: {'SAPISID': 'fake-test-cookie'});
    const other = 'bbbbbbbbbbbbbbbbbbbbbbbb';
    final account = session.accountKey;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('lokal.youtube.playlists.cache.v1.$account.library',
        jsonEncode({'version': 1, 'items': [{'id': 'PLfirst', 'title': 'First'}]}));
    const visibility = ProviderPlaylistVisibility();
    await visibility.setHidden('youtube', account, 'PLfirst', true);
    await visibility.setHidden('youtube', other, 'PLother', true);
    await visibility.setHidden('spotify', account, 'PLspotify', true);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(konnektedYoutubeMusicSessionProvider.notifier);
    await container.read(konnektedYoutubeMusicSessionProvider.future);
    await notifier.save(session);
    await notifier.signOut();
    expect(await YoutubeMusicSessionStore().read(), isNull);
    expect(prefs.containsKey('lokal.playlists.hidden.v1.youtube.$account'), isFalse);
    expect(await visibility.hidden('youtube', other), {'PLother'});
    expect(await visibility.hidden('spotify', account), {'PLspotify'});
    await notifier.save(session);
    expect((await YoutubeMusicPlaylistCache().playlists(account))!.single.id, 'PLfirst');
    expect(await visibility.hidden('youtube', account), isEmpty);
  });
}
