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
        'worker_start',
      ]) {
        final label = morneyeResolutionStageLabel(stage, source);
        expect(label, contains(source));
        expect(label, isNot(contains('{source}')));
        if (locale.languageCode != 'en') {
          expect(
            label,
            isNot(
              matches(r'^(Starting|Checking|Verifying|Resolving|Preparing) '),
            ),
            reason: '$locale $stage',
          );
        }
      }
    }
  });
}
