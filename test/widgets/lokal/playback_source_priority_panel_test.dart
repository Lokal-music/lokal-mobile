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

  testWidgets('source rows support long-press dragging and a direct handle',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      PlaybackSourcePriority.key: ['a-first', 'a-second', 'a-third'],
    });
    final sources = [
      _source('a-first', 'First source'),
      _source('a-second', 'Second source'),
      _source('a-third', 'Third source'),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PlaybackSourcePriorityPanel(
            sourcesLoader: (_) async => sources,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(ReorderableListView), findsOneWidget);
    expect(find.byType(ReorderableDelayedDragStartListener), findsNWidgets(3));
    expect(find.byType(ReorderableDragStartListener), findsNWidgets(3));
    expect(find.text('Touch and hold a source to drag it, or drag its handle.'),
        findsOneWidget);

    // The UI must relay Flutter's pre-removal drop index to persistent order,
    // not swap the starting and ending positions.
    final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView));
    list.onReorder(0, 3);
    await tester.pumpAndSettle();

    expect(await PlaybackSourcePriority.load(),
        ['a-second', 'a-third', 'a-first']);
    expect(find.byKey(const ValueKey('playback-source-a-first')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
