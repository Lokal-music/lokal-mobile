import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flick/core/theme/app_theme.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/services/local_audio_lifecycle.dart';
import 'package:flick/widgets/common/audio_recovery_notice.dart';

void main() {
  testWidgets(
    'recovery tells the user what to do without starting another output',
    (tester) async {
      final phase = ValueNotifier(LocalAudioPhase.ready);
      addTearDown(phase.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(body: AudioRecoveryNotice(phase: phase)),
        ),
      );
      expect(find.byKey(const ValueKey('audio-recovery-notice')), findsNothing);
      phase.value = LocalAudioPhase.lost;
      await tester.pump();
      expect(find.text('Audio is temporarily unavailable.'), findsOneWidget);
      phase.value = LocalAudioPhase.recovering;
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      phase.value = LocalAudioPhase.paused;
      await tester.pump();
      expect(
        find.text('Audio is ready. Use Play to continue.'),
        findsOneWidget,
      );
      phase.value = LocalAudioPhase.blocked;
      await tester.pump();
      expect(
        find.text('Close and reopen the app to restore audio.'),
        findsOneWidget,
      );
      expect(find.byType(TextButton), findsNothing);
      expect(
        tester
            .widget<Semantics>(
              find.byKey(const ValueKey('audio-recovery-notice')),
            )
            .properties
            .liveRegion,
        isTrue,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AudioRecoveryNotice(phase: phase, remoteOutputActive: true),
        ),
      );
      expect(find.byKey(const ValueKey('audio-recovery-notice')), findsNothing);
    },
  );

  testWidgets(
    'all recovery states fit a narrow iPhone at 200% in every locale',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(
        () => LocaleController.instance.bindLocale(const Locale('en')),
      );
      final phase = ValueNotifier(LocalAudioPhase.lost);
      addTearDown(phase.dispose);
      for (final locale in kSupportedLocales) {
        LocaleController.instance.bindLocale(locale);
        for (final value in LocalAudioPhase.values.where(
          (p) => p != LocalAudioPhase.ready,
        )) {
          phase.value = value;
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.darkTheme,
              home: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: Scaffold(
                  body: Column(
                    children: [
                      const Expanded(child: SizedBox()),
                      AudioRecoveryNotice(phase: phase),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull, reason: '$locale / $value');
        }
      }
    },
  );
}
