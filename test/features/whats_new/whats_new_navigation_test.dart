import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/manual/data/manual_data.dart';
import 'package:flick/features/settings/lokal/groups/about_group.dart';
import 'package:flick/features/settings/lokal/lokal_licences_page.dart';
import 'package:flick/features/whats_new/data/changelog_data.dart';
import 'package:flick/features/whats_new/widgets/whats_new_bottom_sheet.dart';
import 'package:flick/providers/app_build_info_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(Widget home) => ProviderScope(
  overrides: [
    appBuildInfoProvider.overrideWith(
      (ref) async => const AppBuildInfo(version: '1.0.0', build: '79'),
    ),
  ],
  child: MaterialApp(
    theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.dark)),
    home: home,
  ),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'iPhone About and licences use installed bundle version without APK actions',
    (tester) async {
      await tester.pumpWidget(
        _app(
          Consumer(
            builder: (context, ref, _) =>
                Scaffold(body: ListView(children: aboutSettings(context, ref))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1.0.0 (build 79)'), findsOneWidget);
      expect(find.text('Updates'), findsNothing);
      expect(find.text('Help'), findsNothing);
      await tester.pumpWidget(
        _app(LokalLicencesPage(licences: const Stream.empty())),
      );
      await tester.pumpAndSettle();
      expect(find.text('Lokal 1.0.0'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  test('iPhone Help describes Files and AirPlay without direct USB claims', () {
    final sections = manualSections(forIos: true);
    final text = sections
        .expand((section) => section.entries)
        .map((entry) => '${entry.title} ${entry.body}')
        .join(' ');
    expect(text, contains('AirPlay'));
    expect(text, contains('Files'));
    expect(text, isNot(contains('UAC2')));
    expect(text, isNot(contains('Bit-perfect capsule')));
    expect(manualSections(forIos: false), same(kManualSections));
  });

  testWidgets(
    'release sheet dismisses over a nested navigator and leaves the shell usable',
    (tester) async {
      await tester.pumpWidget(
        _app(
          Scaffold(
            key: const ValueKey('root-shell'),
            body: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () => WhatsNewBottomSheet.show<void>(
                      context,
                      entry: const ChangelogEntry(
                        version: '1.0',
                        date: '',
                        sections: [],
                      ),
                    ),
                    child: const Text('Open notes'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open notes'));
      await tester.pumpAndSettle();
      expect(find.byType(WhatsNewBottomSheet), findsOneWidget);
      expect(find.text('Got it'), findsNothing);
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      expect(find.byType(WhatsNewBottomSheet), findsNothing);
      expect(find.byKey(const ValueKey('root-shell')), findsOneWidget);
      await tester.tap(find.text('Open notes'));
      await tester.pumpAndSettle();
      expect(find.byType(WhatsNewBottomSheet), findsOneWidget);
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
