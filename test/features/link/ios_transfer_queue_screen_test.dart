import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/link/ios_transfer_queue_screen.dart';
import 'package:flick/services/ios_transfer_queue.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../services/ios_transfer_queue_test.dart' show QueueNative, queueJob;

void main() {
  for (final theme in [LokalThemeId.dark, LokalThemeId.light]) {
    testWidgets(
      'uncertain upload UI has no resend, supports large text in $theme',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final native = QueueNative();
        final queue = IosTransferQueueController(
          native: native,
          ensureReady: () async {},
          prepareUpload: (_) async => fail('Uncertain upload cannot prepare'),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: LokalTheme.build(LokalTokens.themes[theme]!),
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: IosTransferQueueScreen(controller: queue),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Check desktop receipt'), findsOneWidget);
        expect(find.text('Resume preparation'), findsNothing);
        expect(find.text('Retry download'), findsNothing);
        await tester.ensureVisible(find.text('Check desktop receipt'));
        await tester.pumpAndSettle();
        expect(find.text('Check desktop receipt').hitTestable(), findsOneWidget);
        await tester.tap(find.text('Check desktop receipt'));
        await tester.pumpAndSettle();
        expect(native.matchCalls, 1);
        expect(native.retryCalls, 0);
        expect(find.textContaining('no audio was resent'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        expect(native.didDispose, false);
        await native.events.close();
        await native.dispose();
      },
    );
  }
  testWidgets(
    'temporary cleanup explains original preservation and stays distinct from cancellation',
    (tester) async {
      final native = QueueNative()..rows = [queueJob(phase: 'complete')];
      final queue = IosTransferQueueController(
        native: native,
        ensureReady: () async {},
        prepareUpload: (_) async {},
      );
      await tester.pumpWidget(
        MaterialApp(home: IosTransferQueueScreen(controller: queue)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('keeps your original song'), findsOneWidget);
      expect(find.text('Cancel transfer'), findsNothing);
      await tester.tap(find.text('Free temporary copy'));
      await tester.pumpAndSettle();
      expect(native.cleanupCalls, 1);
      expect(native.cancelCalls, 0);
      await tester.pumpWidget(const SizedBox());
      await native.events.close();
      await native.dispose();
    },
  );
}
