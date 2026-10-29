import 'dart:ui' as ui;

import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_appearance.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/models/song.dart';
import 'package:flick/widgets/lokal/lokal_quality.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

Song _song(String type, {int? bits, int? rate, String? resolution}) => Song(
  id: '$type$bits$rate$resolution',
  title: 'T',
  artist: 'A',
  duration: const Duration(minutes: 3),
  fileType: type,
  bitDepth: bits,
  sampleRate: rate,
  resolution: resolution,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('tiers follow desktop src/quality.js', () {
    expect(
      LokalQualityTier.of(_song('flac', bits: 16, rate: 44100)),
      LokalQualityTier.lossless,
    );
    expect(
      LokalQualityTier.of(_song('FLAC', bits: 24, rate: 96000)),
      LokalQualityTier.hiRes,
    );
    expect(
      LokalQualityTier.of(_song('ALAC', bits: 16, rate: 96000)),
      LokalQualityTier.hiRes,
    );
    expect(
      LokalQualityTier.of(_song('MP3', resolution: '320 kbps')),
      LokalQualityTier.high,
    );
    expect(
      LokalQualityTier.of(_song('MP3', resolution: '192 kbps')),
      LokalQualityTier.low,
    );
    // Opus and Vorbis reach "High" at 160 kbps, as on desktop.
    expect(
      LokalQualityTier.of(_song('opus', resolution: '160 kbps')),
      LokalQualityTier.high,
    );
    expect(LokalQualityTier.of(_song('MP3')), LokalQualityTier.unknown);
    expect(LokalQualityTier.of(_song('FLAC')), LokalQualityTier.unknown);
  });

  test('pill colours are desktop Tailwind shades on every theme', () {
    expect(LokalQualityTier.lossless.text, const Color(0xFF7BF1A8));
    expect(LokalQualityTier.hiRes.text, const Color(0xFFC4B4FF));
    expect(LokalQualityTier.high.text, const Color(0xFF74D4FF));
    expect(LokalQualityTier.low.text, const Color(0xFFFFF085));
  });

  testWidgets('pill shows the label and explains itself', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.light)),
          home: const Center(
            child: LokalQualityPill(tier: LokalQualityTier.lossless),
          ),
        ),
      ),
    );
    expect(find.text('Lossless'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('^Lossless quality. Lossless, 16-bit')),
      findsOneWidget,
    );
    semantics.dispose();
  });


  test('full resolution uses known source measurements without inventing quality', () {
    expect(
      lokalSongResolutionLabel(_song('FLAC', bits: 24, rate: 96000)),
      'FLAC · 24-bit / 96 kHz',
    );
    expect(
      lokalSongResolutionLabel(_song('FLAC', resolution: '16/44.1')),
      'FLAC · 16-bit / 44.1 kHz',
    );
    expect(
      lokalSongResolutionLabel(_song('OPUS', bits: 24, rate: 48000,
          resolution: '160 kbps')),
      'OPUS · 160 kbps / 48 kHz',
      reason: 'Decoded lossy PCM bit depth is not encoded source depth',
    );
    expect(
      lokalSongResolutionLabel(_song('DSD', rate: 2822400)),
      'DSD64',
    );
    expect(lokalSongResolutionLabel(_song('FLAC')), isNull);
    expect(lokalSongResolutionLabel(_song('FLAC', resolution: 'HI_RES_LOSSLESS')), isNull);
    expect(lokalSongResolutionLabel(_song('MP3', resolution: 'HIGH')), isNull);
  });

  testWidgets('list and player resolution toggles are independent and keep colors',
      (tester) async {
    const song = Song(
      id: 'flac-96', title: 'Track', artist: 'Artist',
      duration: Duration(seconds: 180), fileType: 'FLAC',
      bitDepth: 24, sampleRate: 96000,
    );
    Widget app({required bool lists, required bool player}) => ProviderScope(
      key: ValueKey('$lists-$player'),
      overrides: [
        lokalInitialAppearanceProvider.overrideWithValue(
          LokalAppearance(
            resolutionTagsInLists: lists,
            resolutionTagsInFullPlayer: player,
          ),
        ),
      ],
      child: MaterialApp(
        theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.dark)),
        home: const Scaffold(
          body: Column(
            children: [
              LokalQualityPill(tier: LokalQualityTier.hiRes, song: song),
              LokalQualityPill(
                tier: LokalQualityTier.hiRes, song: song, fullPlayer: true,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpWidget(app(lists: true, player: false));
    await tester.pump();
    expect(find.text('FLAC · 24-bit / 96 kHz'), findsOneWidget);
    expect(find.text('Hi-res'), findsOneWidget);
    final text = tester.widget<Text>(find.text('FLAC · 24-bit / 96 kHz'));
    expect(text.style?.color, LokalQualityTier.hiRes.text);

    await tester.pumpWidget(app(lists: false, player: true));
    await tester.pump();
    expect(find.text('Hi-res'), findsOneWidget);
    expect(find.text('FLAC · 24-bit / 96 kHz'), findsOneWidget);
  });

  test('glass shaders compile and load', () async {
    for (final asset in [
      'shaders/lokal_glass_lens.frag',
      'shaders/lokal_glass_rim.frag',
    ]) {
      final program = await ui.FragmentProgram.fromAsset(asset);
      expect(program.fragmentShader(), isNotNull, reason: asset);
    }
  });
}
