import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = 'android/app/src/main';
  final layouts = <String, List<String>>{
    '$root/res/layout/widget_mini_player.xml': ['widget_title', 'widget_artist'],
    '$root/res/layout/widget_now_playing_portrait.xml': ['widget_title', 'widget_artist'],
    '$root/res/layout/widget_now_playing_expanded.xml': ['widget_title', 'widget_artist'],
    '$root/res/layout/widget_flow_radio.xml': ['flow_title', 'flow_status'],
    '$root/res/layout/widget_recommended_flow.xml': ['rec_title', 'rec_artist'],
  };
  test('adaptive home widgets use native text, not Binder text bitmaps', () {
    for (final entry in layouts.entries) {
      final xml = File(entry.key).readAsStringSync();
      for (final id in entry.value) {
        expect(xml, contains(RegExp('<TextView\\s+android:id="@\\+id/$id"')),
          reason: '${entry.key} should contain native text $id');
      }
    }
  });

  test('the picker exposes exactly three distinct resizable widget purposes', () {
    final manifest = File('$root/AndroidManifest.xml').readAsStringSync();
    for (final name in [
      'MiniPlayerWidgetProvider',
      'FlowRadioWidgetProvider',
      'CoverFlowRecommendationWidgetProvider',
    ]) {
      expect(manifest, contains('android:name=".widgets.$name"'));
    }
    expect(manifest, isNot(contains('android:name=".widgets.FlagshipWidgetProvider"')));
    expect(manifest, isNot(contains('android:name=".widgets.CompactWidgetProvider"')));
    for (final (type, info) in [
      ('MiniPlayer', 'mini_player'),
      ('FlowRadio', 'flow_radio'),
      ('CoverFlowRecommendation', 'recommended_flow'),
    ]) {
      final provider = File(
        '$root/kotlin/com/mossapps/flick/widgets/${type}WidgetProvider.kt',
      ).readAsStringSync();
      expect(provider, contains('WidgetUpdateDispatcher.submit'));
      expect(provider, contains('onAppWidgetOptionsChanged'));
      expect(provider, isNot(contains('createTextBitmap(')));
      expect(File('$root/res/xml/${info}_widget_info.xml').readAsStringSync(),
        contains('resizeMode="horizontal|vertical"'));
    }
    final player = File('$root/kotlin/com/mossapps/flick/widgets/MiniPlayerWidgetProvider.kt')
        .readAsStringSync();
    expect(player, contains('R.layout.widget_now_playing_portrait'));
    expect(player, contains('R.layout.widget_now_playing_expanded'));
    expect(player, contains('R.layout.widget_mini_player'));
    final settings = File('lib/features/settings/screens/widget_settings_screen.dart')
        .readAsStringSync();
    expect(settings, isNot(contains('4×3 Flagship')));
    expect(settings, isNot(contains("label: () => '2×2'")));
    final sync = File('lib/services/widget_sync_service.dart').readAsStringSync();
    expect(sync, isNot(contains('updateWidget(qualifiedAndroidName: flagshipProvider)')));
    expect(sync, isNot(contains('updateWidget(qualifiedAndroidName: compactProvider)')));
  });

  test('resize layouts keep playback controls, actual art and track text', () {
    for (final name in [
      'widget_mini_player',
      'widget_now_playing_portrait',
      'widget_now_playing_expanded',
    ]) {
      final xml = File('$root/res/layout/$name.xml').readAsStringSync();
      for (final id in [
        'widget_art_bg', 'widget_title', 'widget_artist',
        'widget_prev', 'widget_play_pause', 'widget_next',
        'widget_progress', 'widget_time', 'widget_scrim',
      ]) {
        expect(xml, contains('@+id/$id'), reason: '$name missing $id');
      }
    }
  });

  test('Cover Flow hides absent art and shows a useful offline empty state', () {
    final cover = File(
      '$root/kotlin/com/mossapps/flick/widgets/CoverFlowRecommendationWidgetProvider.kt',
    ).readAsStringSync();
    expect(cover, contains('R.drawable.widget_art_placeholder'));
    expect(cover, contains('View.INVISIBLE'));
    expect(cover, contains('R.string.widget_open_app'));
    final strings = File('$root/res/values/widget_strings.xml').readAsStringSync();
    expect(strings, contains('<string name="widget_open_app">Open Lokal</string>'));
    expect(cover, contains('count / 2'));
    for (final variant in ['widget_recommended_flow', 'widget_recommended_flow_small']) {
      final xml = File('$root/res/layout/$variant.xml').readAsStringSync();
      expect(xml, contains('@+id/rec_art_strip'));
      expect(xml, isNot(contains('@drawable/widget_default_art')));
    }
    final art = File('lib/services/widget_recommendation_service.dart').readAsStringSync();
    expect(art, contains('i.ytimg.com/vi/'));
  });

  test('album artwork is mandatory on all three widget types and at every size', () {
    final base = '$root/kotlin/com/mossapps/flick/widgets';
    final player = File('$base/MiniPlayerWidgetProvider.kt').readAsStringSync();
    final flow = File('$base/FlowRadioWidgetProvider.kt').readAsStringSync();
    final cover = File('$base/CoverFlowRecommendationWidgetProvider.kt').readAsStringSync();
    expect(player, contains('setViewVisibility(R.id.widget_art_bg, View.VISIBLE)'));
    expect(player, isNot(contains('getShowAlbumArt(context)')));
    expect(player, contains('KEY_LAST_ALBUM_ART'));
    expect(flow, contains('setViewVisibility(R.id.flow_cover, View.VISIBLE)'));
    expect(flow, contains('KEY_ALBUM_ART'));
    expect(flow, contains('KEY_FLOW_ENABLED'));
    expect(cover, contains('R.id.rec_art_strip, View.VISIBLE'));
    expect(cover, contains('KEY_LAST_ALBUM_ART'));
    expect(cover, contains('WidgetArtLoader.load(context, item.optString("artwork"), 64)'));
    for (final variant in [
      'widget_mini_player', 'widget_now_playing_portrait',
      'widget_now_playing_expanded', 'widget_flow_radio', 'widget_flow_radio_small',
      'widget_recommended_flow', 'widget_recommended_flow_small',
    ]) {
      final xml = File('$root/res/layout/$variant.xml').readAsStringSync();
      expect(xml, contains('widget_art_placeholder'),
          reason: '$variant must reserve a visible sleeve');
      expect(xml, isNot(contains('android:visibility="gone" android:src="@drawable/widget_art_placeholder"')),
          reason: '$variant should not hide its sleeve');
    }
    final settings = File('lib/features/settings/screens/widget_settings_screen.dart')
        .readAsStringSync();
    expect(settings, isNot(contains('label: () => l10n.albumArt,')));
  });

  test('artwork lookup covers cached, MediaStore, video and verified catalogue art', () {
    final service = File('lib/services/widget_recommendation_service.dart')
        .readAsStringSync();
    expect(service, contains('resolveTrackArtwork(Song song)'));
    expect(service, contains("i.ytimg.com/vi/"));
    expect(service, contains('AppleMusicMetadataService.instance'));
    expect(service, contains('radioRecordingKey(candidate.artist, candidate.title)'));
    expect(service, contains("rows.where((row) => (row['artwork']"));
    expect(service, contains('qualifiedAndroidName: flowProvider'));
    expect(service, contains('flick_widget_flow_enabled'));
    final loader = File('$root/kotlin/com/mossapps/flick/widgets/WidgetArtLoader.kt')
        .readAsStringSync();
    expect(loader, contains('contentResolver.openInputStream'));
    expect(loader, contains('Bitmap.Config.RGB_565'));
  });

  test('all widgets use album-derived dark surfaces without giant backdrop bitmaps', () {
    final path = '$root/kotlin/com/mossapps/flick/widgets';
    final palette = File('$path/WidgetArtworkPalette.kt').readAsStringSync();
    expect(palette, contains('Color.colorToHSV'));
    expect(palette, contains('widget_surface_rose'));
    expect(palette, contains('widget_surface_blue'));
    expect(palette, contains('widget_surface_green'));
    expect(palette, contains('widget_surface_violet'));
    for (final type in [
      'MiniPlayerWidgetProvider', 'FlowRadioWidgetProvider',
      'CoverFlowRecommendationWidgetProvider',
    ]) {
      final provider = File('$path/$type.kt').readAsStringSync();
      expect(provider, contains('WidgetArtworkPalette.background('));
    }
    final control = File('$root/res/drawable/widget_music_action_primary.xml')
        .readAsStringSync();
    expect(control, contains('corners'));
    for (final tone in ['rose', 'gold', 'green', 'blue', 'violet']) {
      final surface = File('$root/res/drawable/widget_surface_$tone.xml')
          .readAsStringSync();
      expect(surface, contains('24dp'));
    }
  });

  test('widget art is bounded and cold-start commands are durable', () {
    final path = '$root/kotlin/com/mossapps/flick/widgets';
    final art = File('$path/WidgetArtLoader.kt').readAsStringSync();
    expect(art, contains('MAX_ART_EDGE = 288'));
    expect(art, contains('inPreferredConfig = Bitmap.Config.RGB_565'));
    final dispatcher = File('$path/WidgetUpdateDispatcher.kt').readAsStringSync();
    expect(dispatcher, contains('goAsync()'));
    expect(dispatcher, contains('result?.finish()'));
    expect(dispatcher, contains('AtomicLong'));
    final inbox = File('$path/WidgetActionInbox.kt').readAsStringSync();
    expect(inbox, contains('putString(KEY_PENDING, uri)'));
    expect(inbox, contains('prefs.edit().remove(KEY_PENDING).commit()'));
  });

  test('Flow and Cover Flow widgets are registered, responsive and actionable', () {
    final manifest = File('$root/AndroidManifest.xml').readAsStringSync();
    final base = '$root/kotlin/com/mossapps/flick/widgets';
    expect(manifest, contains('FlowRadioWidgetProvider'));
    expect(manifest, contains('CoverFlowRecommendationWidgetProvider'));
    final flow = File('$base/FlowRadioWidgetProvider.kt').readAsStringSync();
    final cover = File('$base/CoverFlowRecommendationWidgetProvider.kt').readAsStringSync();
    expect(flow, contains('WidgetUpdateDispatcher.submit'));
    expect(cover, contains('WidgetUpdateDispatcher.submit'));
    expect(flow, contains('onAppWidgetOptionsChanged'));
    expect(cover, contains('onAppWidgetOptionsChanged'));
    expect(File('$root/res/xml/flow_radio_widget_info.xml').readAsStringSync(),
      contains('resizeMode="horizontal|vertical"'));
    expect(File('$root/res/xml/recommended_flow_widget_info.xml').readAsStringSync(),
      contains('resizeMode="horizontal|vertical"'));
    expect(File('$base/WidgetSize.kt').readAsStringSync(),
      contains('OPTION_APPWIDGET_MIN_HEIGHT'));
    final intents = File('$base/WidgetIntents.kt').readAsStringSync();
    expect(intents, contains('flickwidget://recommend/play'));
    expect(intents, contains('flickwidget://flow/'));
    final actions = File('lib/services/widget_intent_handler.dart').readAsStringSync();
    expect(actions, contains("case 'flow':"));
    expect(actions, contains("case 'recommend':"));
    expect(actions, contains('stableOnlinePlaylistSong'));
    final sync = File('lib/services/widget_sync_service.dart').readAsStringSync();
    expect(sync, contains('WidgetRecommendationService.instance.refreshFor'));
    expect(sync, contains('WidgetRecommendationService.resolveTrackArtwork(song)'));
  });

  test('failed rich updates still show real track metadata and transport', () {
    final dispatcher = File('$root/kotlin/com/mossapps/flick/widgets/WidgetUpdateDispatcher.kt')
        .readAsStringSync();
    expect(dispatcher, contains('WidgetPrefs.KEY_TITLE'));
    expect(dispatcher, contains('WidgetPrefs.KEY_ARTIST'));
    expect(dispatcher, contains('WidgetIntents.playerPlayPause'));
    expect(dispatcher, isNot(contains('R.string.widget_tap_to_open')));
  });
}
