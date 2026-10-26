import 'package:flick/features/music_videos/music_video_surface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'iPhone embed identifies the installed signed bundle, including a suffix',
    () {
      const installedId = 'App.Lokal.Mobile.FreeSigned';
      final origin = musicVideoOriginForAppId(installedId);
      expect(origin, 'https://app.lokal.mobile.freesigned');
      final html = musicVideoEmbedHtml('abcdefghijk', appId: installedId);
      expect(html, contains('origin=${Uri.encodeComponent(origin)}'));
      expect(html, isNot(contains('com.lokalkonnekt.konnekted2')));
      expect(
        html,
        contains('referrerpolicy="strict-origin-when-cross-origin"'),
      );
    },
  );

  test(
    'the bridge accepts only the installed origin and default HTTPS port',
    () {
      final allowed = RegExp(
        musicVideoOriginPattern('https://app.lokal.mobile'),
      );
      expect(allowed.hasMatch('https://app.lokal.mobile'), isTrue);
      expect(allowed.hasMatch('https://app.lokal.mobile:443'), isTrue);
      for (final other in [
        'https://appXlokalXmobile',
        'https://app.lokal.mobile.attacker.example',
        'https://app.lokal.mobile:444',
        'http://app.lokal.mobile',
        'https://com.lokalkonnekt.konnekted2',
      ]) {
        expect(allowed.hasMatch(other), isFalse, reason: other);
      }
    },
  );

  test(
    'missing or malformed identity cannot introduce HTML or another origin',
    () {
      for (final invalid in [
        '',
        'https://app.lokal.mobile',
        'app.lokal/<script>',
        'app.lokal.mobile?x=1',
        'app.lokal.mobile\" onload=\"alert(1)',
        'app..mobile',
      ]) {
        expect(
          () => musicVideoEmbedHtml('abcdefghijk', appId: invalid),
          throwsFormatException,
          reason: invalid,
        );
      }
    },
  );
}
