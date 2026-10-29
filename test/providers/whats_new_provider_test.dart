import 'dart:async';

import 'package:flick/features/whats_new/data/changelog_data.dart';
import 'package:flick/providers/app_build_info_provider.dart';
import 'package:flick/providers/app_preferences_provider.dart';
import 'package:flick/providers/whats_new_provider.dart';
import 'package:flick/services/app_preferences_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _DelayedPreferences extends AppPreferencesService {
  final load = Completer<AppPreferences>();
  @override
  Future<AppPreferences> getPreferences() => load.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'fresh install establishes a minor baseline and the next minor is new',
    () async {
      SharedPreferences.setMockInitialValues({});
      var version = '1.0.0';
      final container = ProviderContainer(
        overrides: [
          appBuildInfoProvider.overrideWith(
            (ref) async => AppBuildInfo(version: version, build: '79'),
          ),
          for (final minor in ['1.0', '1.1'])
            lokalMinorReleaseNotesProvider(minor).overrideWith(
              (ref) async =>
                  ChangelogEntry(version: minor, date: '', sections: const []),
            ),
        ],
      );
      addTearDown(container.dispose);
      container.read(whatsNewProvider);
      expect(
        await container.read(lokalChangelogBaselineProvider.future),
        '1.0',
      );
      await container.read(lokalMinorReleaseNotesProvider('1.0').future);
      await container.pump();
      expect(container.read(whatsNewProvider).pendingEntry, isNull);
      expect(
        await AppPreferencesService().getLastSeenChangelogVersion(),
        '1.0',
      );

      version = '1.1.0';
      container.invalidate(appBuildInfoProvider);
      await container.read(lokalChangelogBaselineProvider.future);
      await container.read(lokalMinorReleaseNotesProvider('1.1').future);
      await container.pump();
      expect(container.read(whatsNewProvider).pendingEntry?.version, '1.1');
      await container.read(whatsNewProvider.notifier).markCurrentVersionSeen();
      expect(
        await AppPreferencesService().getLastSeenChangelogVersion(),
        '1.1',
      );
      version = '1.1.9';
      container.invalidate(appBuildInfoProvider);
      await container.read(lokalChangelogBaselineProvider.future);
      await container.pump();
      expect(container.read(whatsNewProvider).pendingEntry, isNull);
    },
  );

  test(
    'delayed notes appear once and late old preferences cannot reshow them',
    () async {
      SharedPreferences.setMockInitialValues({
        'last_seen_changelog_version': '1.0.7+55',
      });
      final preferences = _DelayedPreferences();
      final notes = Completer<ChangelogEntry?>();
      final container = ProviderContainer(
        overrides: [
          appBuildInfoProvider.overrideWith(
            (ref) async => const AppBuildInfo(version: '1.1.0', build: '79'),
          ),
          appPreferencesServiceProvider.overrideWithValue(preferences),
          lokalMinorReleaseNotesProvider('1.1')
              .overrideWith((ref) => notes.future),
        ],
      );
      addTearDown(container.dispose);
      container.read(whatsNewProvider);
      await container.read(lokalChangelogBaselineProvider.future);
      await container.pump();
      expect(container.read(whatsNewProvider).pendingEntry, isNull);
      notes.complete(
        const ChangelogEntry(version: '1.1', date: '', sections: []),
      );
      await container.read(lokalMinorReleaseNotesProvider('1.1').future);
      await container.pump();
      expect(container.read(whatsNewProvider).pendingEntry?.version, '1.1');
      await container.read(whatsNewProvider.notifier).markCurrentVersionSeen();
      preferences.load.complete(
        const AppPreferences(lastSeenChangelogVersion: '1.0.7+55'),
      );
      await container.pump();
      expect(container.read(whatsNewProvider).pendingEntry, isNull);
      expect(await preferences.getLastSeenChangelogVersion(), '1.1');
    },
  );
}
