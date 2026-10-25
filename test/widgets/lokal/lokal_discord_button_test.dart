import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/konnekted/konnekted_home.dart';
import 'package:flick/widgets/lokal/lokal_discord_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.dark)),
    home: Scaffold(body: child),
  ),
);

void main() {
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  final calls = <MethodCall>[];
  var succeeds = true;
  var throws = false;
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    succeeds = true;
    throws = false;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      if (throws) throw PlatformException(code: 'unavailable');
      return succeeds;
    });
  });
  tearDown(
    () =>
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );

  testWidgets('Home puts Discord left of Settings on a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var settings = 0;
    await tester.pumpWidget(
      _app(
        KonnektedHomeTopBar(
          onSettings: () => settings++,
          onAppearance: () {},
          now: DateTime(2026, 10, 25, 10),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(find.byTooltip('Discord')).dx,
      lessThan(tester.getCenter(find.byTooltip('Settings')).dx),
    );
    expect(tester.getSize(find.byType(LokalDiscordButton)), const Size(44, 44));
    await tester.tap(find.byTooltip('Discord'));
    await tester.pumpAndSettle();
    expect(calls.single.method, 'launch');
    expect(calls.single.arguments['url'], lokalDiscordInvite);
    expect(calls.single.arguments['useWebView'], false);
    expect(calls.single.arguments['useSafariVC'], false);
    await tester.tap(find.byTooltip('Settings'));
    expect(settings, 1);
    expect(tester.takeException(), isNull);
  });

  for (final failsWithException in [false, true]) {
    testWidgets(
      'failed launch ($failsWithException) shows feedback without leaving the page',
      (tester) async {
        succeeds = false;
        throws = failsWithException;
        await tester.pumpWidget(_app(const LokalDiscordButton()));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Discord'));
        await tester.pumpAndSettle();
        expect(find.text('Discord: Try again in a moment.'), findsOneWidget);
        expect(find.byType(LokalDiscordButton), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
      },
    );
  }
}
