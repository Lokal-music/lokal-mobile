import 'dart:async';

import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/settings/screens/artwork_repair_screen.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/services/artwork_repair_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Repair implements ArtworkRepairService {
  final result = Completer<ArtworkRepairProgress>();
  int starts = 0, cancellations = 0, disposals = 0;
  @override
  Future<ArtworkRepairProgress> refresh({
    required void Function(ArtworkRepairProgress) onProgress,
  }) {
    starts++;
    onProgress(
      const ArtworkRepairProgress(
        total: 10000,
        checked: 1234,
        updated: 123,
        skipped: 1100,
        failed: 11,
        running: true,
      ),
    );
    return result.future;
  }

  @override
  void cancel() => cancellations++;
  @override
  void dispose() => disposals++;
  void finish() => result.complete(
    const ArtworkRepairProgress(
      total: 10000,
      checked: 1234,
      updated: 123,
      skipped: 1100,
      failed: 11,
      cancelled: true,
    ),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

Widget _host(_Repair service, {bool largeText = false}) => MaterialApp(
  theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.dark)),
  home: MediaQuery(
    data: MediaQueryData(
      disableAnimations: true,
      textScaler: TextScaler.linear(largeText ? 2 : 1),
    ),
    child: ArtworkRepairScreen(serviceOverride: service),
  ),
);

void main() {
  setUpAll(() async {
    for (final (family, asset) in [
      (LokalTheme.sans, 'assets/fonts/DMSans-Regular.ttf'),
      ('NotoSansSC', 'assets/fonts/NotoSansSC-Regular.ttf'),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
  });

  testWidgets(
    'cover repair fits eleven locales at 200% with start/stop feedback',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final previous = l10n;
      addTearDown(() => LocaleController.instance.bind(previous));
      for (final locale in kSupportedLocales) {
        LocaleController.instance.bindLocale(locale);
        final service = _Repair();
        await tester.pumpWidget(_host(service, largeText: true));
        await tester.pumpAndSettle();
        expect(
          service.starts,
          0,
          reason: 'Opening the screen never starts a scan',
        );
        final title = lokalText('Refresh low-quality covers');
        expect(find.text(title), findsAtLeastNWidgets(1));
        if (locale.languageCode != 'en') {
          for (final phrase in [
            'Refresh low-quality covers',
            'Stop refresh',
            'Checking your library…',
            'Stopping after the current operation…',
            'Could not refresh covers. Check access and try again.',
          ]) {
            expect(
              lokalText(phrase),
              isNot(phrase),
              reason: '$locale translation',
            );
          }
        }
        await tester.scrollUntilVisible(find.byType(FilledButton), 250);
        await tester.pumpAndSettle();
        await tester.tap(find.byType(FilledButton));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.byType(FilledButton), 250);
        await tester.pumpAndSettle();
        expect(service.starts, 1);
        expect(find.text(lokalText('Stop refresh')), findsOneWidget);
        expect(
          tester.takeException(),
          isNull,
          reason: '$locale running layout',
        );
        await tester.scrollUntilVisible(find.byType(FilledButton), 250);
        await tester.pumpAndSettle();
        await tester.tap(find.byType(FilledButton));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.byType(FilledButton), 250);
        await tester.pumpAndSettle();
        expect(service.cancellations, 1);
        expect(find.text(lokalText('Stopping…')), findsOneWidget);
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull,
        );
        expect(
          tester.takeException(),
          isNull,
          reason: '$locale stopping layout',
        );
        service.finish();
        await tester.pumpAndSettle();
        expect(find.textContaining(lokalText('Stopped')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(service.disposals, 1);
      }
    },
  );

  testWidgets('background cancels refresh; transient inactive state does not', (
    tester,
  ) async {
    final service = _Repair();
    await tester.pumpWidget(_host(service));
    await tester.scrollUntilVisible(find.byType(FilledButton), 250);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(service.cancellations, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(service.cancellations, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    service.finish();
    await tester.pumpAndSettle();
    expect(service.starts, 1);
    expect(find.textContaining(lokalText('Stopped')), findsOneWidget);
  });

  testWidgets(
    'refresh error keeps retry available without exposing raw response data',
    (tester) async {
      final service = _Repair();
      await tester.pumpWidget(_host(service));
      await tester.scrollUntilVisible(find.byType(FilledButton), 250);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      service.result.completeError(
        StateError('Controlled private response must not become UI'),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          lokalText('Could not refresh covers. Check access and try again.'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Controlled private response'), findsNothing);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    },
  );
}
