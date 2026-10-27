import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/android_audio_engine.dart';
import 'package:flick/services/automix_analysis_cache.dart';

void main() {
  group('crossfadeInVolume', () {
    test('endpoints are 0 at start and 1 at end for every curve', () {
      for (final curve in AndroidCrossfadeCurve.values) {
        expect(crossfadeInVolume(curve, 0), closeTo(0.0, 1e-9));
        expect(crossfadeInVolume(curve, 1), closeTo(1.0, 1e-9));
      }
    });

    test('outgoing fraction is the symmetric complement (1 - p)', () {
      // out(p) == in(1 - p) keeps each curve symmetric; for equal-power this is
      // exactly cos/sin so out^2 + in^2 == 1 throughout.
      for (final curve in AndroidCrossfadeCurve.values) {
        for (final p in [0.0, 0.1, 0.25, 0.5, 0.73, 0.9, 1.0]) {
          final incoming = crossfadeInVolume(curve, p);
          final outgoing = crossfadeInVolume(curve, 1 - p);
          expect(incoming, inInclusiveRange(0.0, 1.0));
          expect(outgoing, inInclusiveRange(0.0, 1.0));
          if (curve == AndroidCrossfadeCurve.equalPower) {
            expect(
              incoming * incoming + outgoing * outgoing,
              closeTo(1.0, 1e-9),
            );
          }
        }
      }
    });

    test('linear maps progress directly; sqrt and s-curve differ', () {
      expect(crossfadeInVolume(AndroidCrossfadeCurve.linear, 0.5), 0.5);
      expect(
        crossfadeInVolume(AndroidCrossfadeCurve.squareRoot, 0.5),
        closeTo(math.sqrt(0.5), 1e-9),
      );
      // smoothstep: p*p*(3 - 2p) at 0.5 == 0.5, but shaped differently.
      expect(
        crossfadeInVolume(AndroidCrossfadeCurve.sCurve, 0.5),
        closeTo(0.5, 1e-9),
      );
      // At 0.25 linear=0.25 but s-curve is lower (ease-in).
      expect(
        crossfadeInVolume(AndroidCrossfadeCurve.sCurve, 0.25),
        closeTo(0.15625, 1e-9),
      );
    });

    test('clamps progress outside 0..1', () {
      for (final curve in AndroidCrossfadeCurve.values) {
        expect(crossfadeInVolume(curve, -0.5), closeTo(0.0, 1e-9));
        expect(crossfadeInVolume(curve, 1.5), closeTo(1.0, 1e-9));
      }
    });
  });

  group('shouldPrepareCrossfade', () {
    const duration = Duration(minutes: 3);

    test('starts preparation eight seconds before the configured fade', () {
      expect(
        shouldPrepareCrossfade(
          enabled: true,
          duration: duration,
          position: duration - const Duration(seconds: 11),
          fadeSecs: 3,
        ),
        isTrue,
      );
      expect(
        shouldPrepareCrossfade(
          enabled: true,
          duration: duration,
          position: duration - const Duration(milliseconds: 11001),
          fadeSecs: 3,
        ),
        isFalse,
      );
      expect(
        shouldArmCrossfade(
          enabled: true,
          duration: duration,
          position: duration - const Duration(seconds: 11),
          fadeSecs: 3,
        ),
        isFalse,
      );
    });

    test('does not prepare invalid, completed or disabled sources', () {
      for (final enabled in [true, false]) {
        expect(
          shouldPrepareCrossfade(
            enabled: enabled,
            duration: Duration.zero,
            position: Duration.zero,
            fadeSecs: 3,
          ),
          isFalse,
        );
      }
      expect(
        shouldPrepareCrossfade(
          enabled: true,
          duration: const Duration(seconds: 2),
          position: Duration.zero,
          fadeSecs: 3,
        ),
        isFalse,
      );
      expect(
        shouldPrepareCrossfade(
          enabled: true,
          duration: duration,
          position: duration,
          fadeSecs: 3,
        ),
        isFalse,
      );
      expect(
        shouldPrepareCrossfade(
          enabled: false,
          duration: duration,
          position: duration - const Duration(seconds: 3),
          fadeSecs: 3,
        ),
        isFalse,
      );
    });
  });

  group('cached AutoMix timing', () {
    const length = Duration(minutes: 3);
    AutoMixProfile profile(double audibleEnd, {double duration = 180}) =>
        AutoMixProfile(
          durationSeconds: duration,
          leadInSeconds: 0,
          audibleEndSeconds: audibleEnd,
          fadeOutStartSeconds: audibleEnd - 4,
          entrances: const [],
          exits: const [],
          energy: .6,
        );

    test('moves overlap ahead of substantial terminal digital silence', () {
      expect(
        automixEffectiveAudibleEnd(length, profile(173)),
        const Duration(seconds: 173),
      );
    });

    test('rejects uncertain or implausibly long trimming', () {
      expect(automixEffectiveAudibleEnd(length, null), length);
      expect(automixEffectiveAudibleEnd(length, profile(179)), length);
      expect(automixEffectiveAudibleEnd(length, profile(150)), length);
      expect(
        automixEffectiveAudibleEnd(length, profile(170, duration: 190)),
        length,
      );
    });
  });

  group('32-beat native model overlap eligibility', () {
    AutoMixProfile model(double bpm) => AutoMixProfile(
      durationSeconds: 180,
      leadInSeconds: 0,
      audibleEndSeconds: 180,
      fadeOutStartSeconds: 176,
      entrances: const [],
      exits: const [],
      analyzedBpm: bpm,
      modelExits: const [158],
      modelEntrances: const [6],
    );

    test('prepares a matched 32-beat model phrase before the cue', () {
      final outgoing = model(120);
      final incoming = model(120.6);
      final phrase = automixPhraseOverlapSeconds(outgoing);
      expect(phrase, closeTo(16, 0.001));
      expect(automixNativePhraseCompatible(outgoing, incoming), isTrue);
      final end = automixModelEnd(
        const Duration(minutes: 3),
        outgoing,
        phrase!,
      );
      expect(end, const Duration(seconds: 174));
      expect(
        shouldPrepareCrossfade(
          enabled: true,
          duration: end!,
          position: const Duration(seconds: 149),
          fadeSecs: phrase,
        ),
        isFalse,
      );
      expect(
        shouldPrepareCrossfade(
          enabled: true,
          duration: end,
          position: const Duration(seconds: 150),
          fadeSecs: phrase,
        ),
        isTrue,
      );
    });

    test(
      'incompatible BPM, missing BPM and extreme BPM retain short fades',
      () {
        expect(automixNativePhraseCompatible(model(120), model(128)), isFalse);
        expect(automixNativePhraseCompatible(model(120), null), isFalse);
        expect(automixPhraseOverlapSeconds(model(60)), isNull);
        expect(automixPhraseOverlapSeconds(model(double.nan)), isNull);
        expect(automixPhraseOverlapSeconds(model(180)), closeTo(10.667, 0.001));
        expect(
          automixModelEnd(const Duration(minutes: 3), model(120), 16),
          const Duration(seconds: 174),
        );
      },
    );
  });

  group('offline CUE-DETR scheduling', () {
    const duration = Duration(minutes: 3);
    AutoMixProfile advanced(List<double> exits) => AutoMixProfile(
      durationSeconds: 180,
      leadInSeconds: 0,
      audibleEndSeconds: 180,
      fadeOutStartSeconds: 177,
      entrances: const [],
      exits: const [],
      modelExits: exits,
    );

    test('uses a reported outgoing overlap start near the outro', () {
      expect(
        automixModelEnd(duration, advanced([158]), 3),
        const Duration(seconds: 161),
      );
      expect(automixModelEnd(duration, advanced([140]), 3), isNull);
    });

    test('rejects implausible or mismatched report timings', () {
      expect(automixModelEnd(duration, advanced([179]), 3), isNull);
      expect(automixModelEnd(duration, advanced([]), 3), isNull);
      expect(automixModelEnd(duration, advanced([158]), double.nan), isNull);
      const invalid = AutoMixProfile(
        durationSeconds: 195,
        leadInSeconds: 0,
        audibleEndSeconds: 195,
        fadeOutStartSeconds: 190,
        entrances: [],
        exits: [],
        modelExits: [158],
      );
      expect(automixModelEnd(duration, invalid, 3), isNull);
    });
  });

  group('shouldArmCrossfade', () {
    const dur = Duration(minutes: 3);

    test('never arms when disabled', () {
      expect(
        shouldArmCrossfade(
          enabled: false,
          duration: dur,
          position: dur - const Duration(seconds: 1),
          fadeSecs: 3,
        ),
        isFalse,
      );
    });

    test('arms exactly inside the fade window', () {
      expect(
        shouldArmCrossfade(
          enabled: true,
          duration: dur,
          position: dur - const Duration(seconds: 3),
          fadeSecs: 3,
        ),
        isTrue,
      );
      expect(
        shouldArmCrossfade(
          enabled: true,
          duration: dur,
          position: dur - const Duration(seconds: 4),
          fadeSecs: 3,
        ),
        isFalse,
      );
    });

    test('does not arm for tracks shorter than the fade', () {
      expect(
        shouldArmCrossfade(
          enabled: true,
          duration: const Duration(seconds: 2),
          position: Duration.zero,
          fadeSecs: 3,
        ),
        isFalse,
      );
    });

    test('does not arm when duration is unknown', () {
      expect(
        shouldArmCrossfade(
          enabled: true,
          duration: Duration.zero,
          position: Duration.zero,
          fadeSecs: 3,
        ),
        isFalse,
      );
    });
  });
}
