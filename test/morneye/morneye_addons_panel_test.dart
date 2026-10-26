import 'dart:io';

import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/morneye/morneye_addons_screen.dart';
import 'package:flick/features/morneye/morneye_packages.dart';
import 'package:flick/features/morneye/morneye_storage.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'morneye_fakes.dart';

void main() {
  testWidgets('the add-on panels are Lokal rows with a clear empty state', (
    tester,
  ) async {
    late Directory dir;
    late MorneyePackages packages;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('morneye-panel');
      final native = FakeNative();
      final storage = MorneyeStorage(
        dir,
        sealer: native,
        vault: MemoryVault(),
      );
      packages = MorneyePackages(dir, storage: storage, native: native);
      await packages.load();
    });
    addTearDown(() => dir.delete(recursive: true));

    await tester.pumpWidget(
      MaterialApp(
        theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.dark)),
        home: LokalSettingsScaffold(
          title: 'Online sources',
          children: [
            LokalSettingsSection(
              title: 'Add-ons',
              children: [MorneyeAddonsPanel(loader: () async => packages)],
            ),
            LokalSettingsSection(
              title: 'Add-on repositories',
              children: [
                MorneyeRepositoriesPanel(loader: () async => packages),
              ],
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('No add-ons yet'), findsOneWidget);
    expect(
      find.textContaining('Installed add-ons appear in Search once'),
      findsOneWidget,
    );
    expect(find.text('Install from file'), findsOneWidget);
    expect(find.textContaining('.spotiflac-ext'), findsOneWidget);
    expect(find.text('Morneye official'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);

    // Search finds the panels by what they hold.
    const section = LokalSettingsSection(
      title: 'Add-ons',
      children: [MorneyeAddonsPanel()],
    );
    expect(section.filtered('verify'), isNotNull);
    expect(section.filtered('qwerty'), isNull);
    expect(tester.takeException(), isNull);
  });
}
