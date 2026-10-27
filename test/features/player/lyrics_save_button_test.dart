import 'package:flick/features/player/widgets/lyrics_save_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('tap saves originals and long-press can save translation',
      (tester) async {
    var originalSaves = 0;
    var translatedSaves = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LyricsSaveButton(
            saving: false,
            onSaveOriginal: () => originalSaves++,
            onSaveWithTranslation: () => translatedSaves++,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(IconButton));
    expect(originalSaves, 1);
    expect(translatedSaves, 0);

    await tester.longPress(find.byType(LyricsSaveButton));
    await tester.pumpAndSettle();
    expect(find.text('Save original lyrics'), findsOneWidget);
    expect(find.text('Save with selected translation'), findsOneWidget);
    await tester.tap(find.text('Save with selected translation'));
    await tester.pumpAndSettle();
    expect(originalSaves, 1);
    expect(translatedSaves, 1);
  });

  testWidgets('translation option is disabled without a selected subline',
      (tester) async {
    var saves = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LyricsSaveButton(
            saving: false,
            onSaveOriginal: () => saves++,
          ),
        ),
      ),
    );

    await tester.longPress(find.byType(LyricsSaveButton));
    await tester.pumpAndSettle();
    final translation = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('Save with selected translation'),
        matching: find.byType(ListTile),
      ),
    );
    expect(translation.enabled, isFalse);
    await tester.tap(find.text('Save original lyrics'));
    await tester.pumpAndSettle();
    expect(saves, 1);
  });

  testWidgets('saving disables tap and hold actions', (tester) async {
    var saves = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LyricsSaveButton(
            saving: true,
            onSaveOriginal: () => saves++,
            onSaveWithTranslation: () => saves++,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(IconButton));
    await tester.longPress(find.byType(LyricsSaveButton));
    await tester.pumpAndSettle();
    expect(saves, 0);
    expect(find.text('Save original lyrics'), findsNothing);
  });
}
