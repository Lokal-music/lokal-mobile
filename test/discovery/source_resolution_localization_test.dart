import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('provider resolution phases translate in every shipped locale', () {
    final previous = l10n;
    addTearDown(() => LocaleController.instance.bind(previous));
    const source = 'Qobuz';
    for (final locale in kSupportedLocales) {
      LocaleController.instance.bindLocale(locale);
      for (final stage in [
        'initializing',
        'metadata',
        'availability',
        'preparing_media',
        'cross_provider_enrichment',
        'availability_retry',
        'worker_start',
      ]) {
        final label = morneyeResolutionStageLabel(stage, source);
        expect(label, contains(source));
        expect(label, isNot(contains('{source}')));
        if (locale.languageCode != 'en') {
          expect(
            label,
            isNot(
              matches(
                r'^(Starting|Checking|Verifying|Resolving|Preparing|Matching|Fetching) ',
              ),
            ),
            reason: '$locale $stage',
          );
        }
      }
    }
  });
  test('swipe and genre controls translate in every shipped locale', () {
    final previous = l10n;
    addTearDown(() => LocaleController.instance.bind(previous));
    const phrases = [
      'Reverse song swipe actions',
      'Swipe right to Play next, left to Add to queue.',
      'Swipe right to Add to queue, left to Play next.',
      'Couldn’t play this song next.',
      'No genre',
      'Search genres...',
      'No genres match your search.',
    ];
    for (final locale in kSupportedLocales) {
      if (locale.languageCode == 'en') continue;
      LocaleController.instance.bindLocale(locale);
      for (final phrase in phrases) {
        expect(lokalText(phrase), isNot(phrase), reason: '$locale $phrase');
      }
    }
  });
}
