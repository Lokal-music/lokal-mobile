import 'package:flick/providers/app_preferences_provider.dart';
import 'package:flick/services/app_preferences_service.dart';
import 'package:flick/widgets/lokal/lokal_swipe_to_queue.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ReversedPreferences extends AppPreferencesNotifier {
  @override
  AppPreferences build() => const AppPreferences(swipeQueueDirectionsReversed: true);
}

Widget _app({
  required VoidCallback queue,
  VoidCallback? next,
  VoidCallback? tap,
  VoidCallback? longPress,
  bool enabled = true,
  bool reversed = false,
}) => ProviderScope(
  overrides: [
    if (reversed)
      appPreferencesProvider.overrideWith(_ReversedPreferences.new),
  ],
  child: MaterialApp(
    home: Scaffold(
      body: LokalSwipeToQueue(
        enabled: enabled,
        onQueue: queue,
        onNext: next,
        child: ListTile(
          title: const Text('Track'),
          onTap: tap,
          onLongPress: longPress,
        ),
      ),
    ),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('right swipe adds to queue and left swipe plays next', (tester) async {
    var queued = 0;
    var next = 0;
    await tester.pumpWidget(_app(queue: () => queued++, next: () => next++));
    await tester.drag(find.text('Track'), const Offset(110, 0));
    await tester.pumpAndSettle();
    expect(queued, 1);
    expect(next, 0);
    await tester.drag(find.text('Track'), const Offset(-110, 0));
    await tester.pumpAndSettle();
    expect(queued, 1);
    expect(next, 1);
    expect(find.text('Track'), findsOneWidget);
  });

  testWidgets('reversed preference swaps both gestures', (tester) async {
    var queued = 0;
    var next = 0;
    await tester.pumpWidget(_app(
      queue: () => queued++,
      next: () => next++,
      reversed: true,
    ));
    await tester.drag(find.text('Track'), const Offset(110, 0));
    await tester.pumpAndSettle();
    expect(next, 1);
    expect(queued, 0);
    await tester.drag(find.text('Track'), const Offset(-110, 0));
    await tester.pumpAndSettle();
    expect(queued, 1);
    expect(next, 1);
  });

  testWidgets('short and vertical drags do not enqueue', (tester) async {
    var queued = 0;
    var next = 0;
    await tester.pumpWidget(_app(queue: () => queued++, next: () => next++));
    await tester.drag(find.text('Track'), const Offset(24, 0));
    await tester.pumpAndSettle();
    await tester.drag(find.text('Track'), const Offset(-24, 0));
    await tester.pumpAndSettle();
    await tester.drag(find.text('Track'), const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(queued, 0);
    expect(next, 0);
  });

  testWidgets('tap and long press preserve the row actions', (tester) async {
    var queued = 0;
    var next = 0;
    var taps = 0;
    var longPresses = 0;
    await tester.pumpWidget(_app(
      queue: () => queued++,
      next: () => next++,
      tap: () => taps++,
      longPress: () => longPresses++,
    ));
    await tester.tap(find.text('Track'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Track'));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(longPresses, 1);
    expect(queued, 0);
    expect(next, 0);
  });

  testWidgets('disabled rows reject both directions', (tester) async {
    var queued = 0;
    var next = 0;
    await tester.pumpWidget(_app(
      queue: () => queued++, next: () => next++, enabled: false,
    ));
    await tester.drag(find.text('Track'), const Offset(115, 0));
    await tester.pumpAndSettle();
    await tester.drag(find.text('Track'), const Offset(-115, 0));
    await tester.pumpAndSettle();
    expect(queued, 0);
    expect(next, 0);
  });

  test('swipe direction preference survives service reload', () async {
    final service = AppPreferencesService();
    expect(await service.getSwipeQueueDirectionsReversed(), isFalse);
    await service.setSwipeQueueDirectionsReversed(true);
    expect(await AppPreferencesService().getSwipeQueueDirectionsReversed(), isTrue);
    expect((await AppPreferencesService().getPreferences())
        .swipeQueueDirectionsReversed, isTrue);
  });
}
