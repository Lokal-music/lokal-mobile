import 'dart:io';
import 'dart:ui' as ui;

import 'package:flick/features/player/widgets/full_player_action_chip_row.dart';
import 'package:flick/services/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/features/player/widgets/pitch_bottom_sheet.dart';
import 'package:flick/l10n/l10n.dart';

class _PlayerServiceFake extends Fake implements PlayerService {
  @override
  final pitchSemitonesNotifier = ValueNotifier<double>(0);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final (family, asset) in [
      ('GoogleSansFlex', 'assets/fonts/GoogleSansFlex-Regular.ttf'),
      (LokalTheme.sans, 'assets/fonts/DMSans-Regular.ttf'),
      ('NotoSansSC', 'assets/fonts/NotoSansSC-Regular.ttf'),
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      (
        'packages/lucide_icons_flutter/Lucide',
        'packages/lucide_icons_flutter/assets/lucide.ttf',
      ),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('full player action strip exposes labeled, scrollable actions', (
    tester,
  ) async {
    final calls = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: FullPlayerActionChipRow(
              playerService: _PlayerServiceFake(),
              lyricsActive: false,
              onOpenQueue: () => calls.add('queue'),
              onToggleLyrics: () => calls.add('lyrics'),
              onOpenEqualizer: () => calls.add('equalizer'),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Queue'), findsOneWidget);
    expect(find.text('Lyrics'), findsOneWidget);
    expect(find.text('Sleep timer'), findsOneWidget);
    expect(find.text('Speed up'), findsOneWidget);
    expect(find.byType(ListView), findsOneWidget);

    await tester.tap(find.text('Queue'));
    await tester.tap(find.text('Lyrics'));
    await tester.scrollUntilVisible(
      find.text('Equalizer'),
      180,
      scrollable: find.byType(Scrollable),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Equalizer'));
    expect(calls, ['queue', 'lyrics', 'equalizer']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'immersive Pitch is reachable at 200% text and follows semitone changes',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final player = _PlayerServiceFake();
      addTearDown(player.pitchSemitonesNotifier.dispose);
      final semantics = tester.ensureSemantics();
      final previous = l10n;
      final previousTokens = AppColors.tokens;
      addTearDown(() => LocaleController.instance.bind(previous));
      final output = Platform.environment['IOS_UI_296_ARTIFACT_DIR'];
      try {
        for (final locale in kSupportedLocales) {
          for (final theme in [LokalThemeId.dark, LokalThemeId.light]) {
            LocaleController.instance.bindLocale(locale);
            AppColors.bind(LokalTokens.resolve(theme));
            final boundary = GlobalKey();
            await tester.pumpWidget(
              MaterialApp(
                key: ValueKey('${locale.toLanguageTag()}-${theme.name}'),
                debugShowCheckedModeBanner: false,
                theme: LokalTheme.build(LokalTokens.resolve(theme)),
                builder: (context, child) => RepaintBoundary(
                  key: boundary,
                  child: MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(2)),
                    child: child!,
                  ),
                ),
                home: Scaffold(
                  body: Center(
                    child: FullPlayerActionChipRow(
                      playerService: player,
                      lyricsActive: false,
                      compactTransformsOnly: true,
                      onOpenQueue: () {},
                      onToggleLyrics: () {},
                      onOpenEqualizer: () {},
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final pitch = find.byKey(const ValueKey('full-player-pitch'));
            await tester.scrollUntilVisible(
              pitch,
              180,
              scrollable: find.byType(Scrollable),
            );
            await tester.pumpAndSettle();
            expect(tester.getSize(pitch).height, greaterThanOrEqualTo(44));
            player.pitchSemitonesNotifier.value = 3;
            await tester.pump();
            expect(find.text('+3 st'), findsOneWidget);
            expect(
              find.bySemanticsLabel('${l10n.pitch}: ${l10n.pitchSemitones(3)}'),
              findsOneWidget,
            );
            Future<void> capture(String state) async {
              if (output == null) return;
              await tester.runAsync(() async {
                final image =
                    await (boundary.currentContext!.findRenderObject()!
                            as RenderRepaintBoundary)
                        .toImage();
                try {
                  final bytes = await image.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  final directory = Directory(output)
                    ..createSync(recursive: true);
                  File(
                    '${directory.path}/${locale.toLanguageTag()}-${theme.name}-$state.png',
                  ).writeAsBytesSync(bytes!.buffer.asUint8List());
                } finally {
                  image.dispose();
                }
              });
            }

            await capture('footer');
            await tester.tap(pitch);
            await tester.pumpAndSettle();
            expect(find.byType(PitchBottomSheet), findsOneWidget);
            expect(
              tester.takeException(),
              isNull,
              reason: locale.toLanguageTag(),
            );
            await capture('sheet');
            await tester.pumpWidget(const SizedBox.shrink());
            player.pitchSemitonesNotifier.value = 0;
          }
        }
      } finally {
        semantics.dispose();
        AppColors.bind(previousTokens);
      }
    },
  );
}
