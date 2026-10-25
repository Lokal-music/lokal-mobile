import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = 'android/app/src/main';
  final layouts = <String, List<String>>{
    '$root/res/layout/widget_mini_player.xml': ['widget_title', 'widget_artist'],
    '$root/res/layout/widget_compact.xml': ['compact_title', 'compact_artist'],
    '$root/res/layout/widget_flagship_art.xml': ['flagship_title', 'flagship_artist'],
  };
  test('all three widgets use native text instead of Binder title bitmaps', () {
    for (final entry in layouts.entries) {
      final xml = File(entry.key).readAsStringSync();
      for (final id in entry.value) {
        expect(
          xml,
          contains(RegExp('<TextView\\s+android:id="@\\+id/$id"')),
          reason: '${entry.key} should render ${id} as native text',
        );
        expect(
          xml,
          isNot(contains(RegExp('<ImageView\\s+android:id="@\\+id/$id"'))),
        );
      }
    }
  });

  test('all providers use crash-isolated async renderer and resize updates', () {
    for (final (type, name) in [
      ('MiniPlayer', 'mini_player'),
      ('Compact', 'compact'),
      ('Flagship', 'flagship'),
    ]) {
      final provider = File(
        '$root/kotlin/com/mossapps/flick/widgets/${type}WidgetProvider.kt',
      ).readAsStringSync();
      expect(provider, contains('WidgetUpdateDispatcher.submit'));
      expect(provider, contains('onAppWidgetOptionsChanged'));
      expect(provider, isNot(contains('createTextBitmap(')));
      final info = File('$root/res/xml/${name}_widget_info.xml')
          .readAsStringSync();
      expect(info, contains('resizeMode="horizontal|vertical"'));
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
}
