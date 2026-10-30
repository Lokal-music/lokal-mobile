import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flick/features/settings/widgets/playback_source_priority_panel.dart';
import 'package:flick/services/playback_source_priority.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

OnlineSource _source(String id, String name) => OnlineSource(
  id: id,
  name: name,
  results: (_) async => const <OnlineResult>[],
  play: (_) async => throw UnimplementedError(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final direct in [true, false]) {
    testWidgets(
      'source priority persists an actual ${direct ? 'handle' : 'long-press'} drag',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          PlaybackSourcePriority.key: ['a-first', 'a-second', 'a-third'],
        });
        final sources = [
          _source('a-first', 'First source'),
          _source('a-second', 'Second source'),
          _source('a-third', 'Third source'),
        ];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: PlaybackSourcePriorityPanel(
                  sourcesLoader: (_) async => sources,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(ReorderableListView), findsOneWidget);
        expect(
          find.byType(ReorderableDelayedDragStartListener),
          findsNWidgets(3),
        );
        expect(find.byType(ReorderableDragStartListener), findsNWidgets(3));
        expect(
          find.text('Touch and hold a source to drag it, or drag its handle.'),
          findsOneWidget,
        );

        // Exercise the actual immediate handle gesture, including drop/persistence.
        final start = direct
            ? find.byType(ReorderableDragStartListener).first
            : find.text('First source');
        final gesture = await tester.startGesture(tester.getCenter(start));
        await tester.pump(
          direct ? Duration.zero : const Duration(milliseconds: 600),
        );
        // Cross touch slop before moving over the other rows.
        await gesture.moveBy(const Offset(0, 20));
        await tester.pump(const Duration(milliseconds: 300));
        await gesture.moveBy(const Offset(0, 180));
        await tester.pump(const Duration(milliseconds: 300));
        await gesture.up();
        await tester.pumpAndSettle();

        expect(await PlaybackSourcePriority.load(), [
          'a-second',
          'a-third',
          'a-first',
        ]);
        expect(
          find.byKey(const ValueKey('playback-source-a-first')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
