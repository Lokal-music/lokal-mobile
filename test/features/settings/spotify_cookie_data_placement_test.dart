import 'package:flick/features/settings/lokal/groups/data_group.dart';
import 'package:flick/features/settings/lokal/lokal_settings_group.dart';
import 'package:flick/features/settings/widgets/spotify_account_settings_tile.dart';
import 'package:flick/features/settings/widgets/youtube_music_settings_tile.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Spotify cookie login is first in Data, together with likes sync',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    late List<LokalSettingsSection> sections;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              sections = dataSettings(context, ref);
              // Inspect configuration without mounting account controls:
              // secure Spotify credentials must not be read by this test.
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(sections.first.title, LokalDataSections.accounts);
    final accounts = sections.first.children;
    final spotifyEntry = accounts.first as LokalSettingCustom;
    expect(spotifyEntry.label, 'Spotify');
    expect(spotifyEntry.child, isA<SpotifyAccountSettingsTile>());

    final spotify = spotifyEntry.child as SpotifyAccountSettingsTile;
    expect(spotify.showCookie, isTrue);
    expect(spotify.showLikesSync, isTrue);

    final youtubeEntry = accounts[1] as LokalSettingCustom;
    expect(youtubeEntry.label, 'YouTube');
    expect(youtubeEntry.child, isA<YoutubeMusicSettingsTile>());

    // Don't reintroduce a second account tile when moving or adding controls.
    expect(
      accounts
          .whereType<LokalSettingCustom>()
          .where((entry) => entry.child is SpotifyAccountSettingsTile),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });
}
