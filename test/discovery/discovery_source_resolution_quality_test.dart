import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flick/features/discovery/discovery_http.dart';
import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flick/features/discovery/discovery_sources.dart';
import 'package:flick/features/discovery/recommendation_match.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flick/services/catalogue_quality.dart';
import 'package:flick/widgets/lokal/lokal_quality.dart';
import 'package:http/testing.dart';

void main() {
  test('HTTP Search accepts Hz, fractional kHz and unit-bearing rates', () {
    expect(providerAudioSampleRate({'sampleRate': 44100}), 44100);
    expect(providerAudioSampleRate({'sample_rate': 44.1}), 44100);
    expect(providerAudioSampleRate({'samplingRate': '44.1 kHz'}), 44100);
    expect(providerAudioSampleRate({'sample_rate': '96khz'}), 96000);
    expect(providerAudioSampleRate({'sampleRate': '48000 Hz'}), 48000);
    expect(providerAudioSampleRate({'sampleRate': 0}), isNull);
    expect(providerAudioSampleRate({'sampleRate': 'bogus'}), isNull);
  });

  test('resolved HTTP stream keeps per-rendition codec and CD sample rate', () {
    final client = MockClient((_) async => throw StateError('Unexpected request'));
    addTearDown(client.close);
    final addon = DiscoveryAddon(
      DiscoveryHttp(client),
      endpoint: 'https://addon.example.com',
    );
    final stream = addon.parseStream({
      'url': 'https://cdn.example.com/signed/opaque?id=1',
      'format': 'audio/flac',
      'quality': '16/44.1',
      'bit_depth': 16,
      'sample_rate': 44.1,
    });
    expect(stream.url.host, 'cdn.example.com');
    expect(stream.codec, 'FLAC');
    expect(stream.quality, '16/44.1');
    expect(stream.bitDepth, 16);
    expect(stream.sampleRate, 44100);
  });

  test('Nebula-style nested Tidal rendition metadata is retained', () {
    final client = MockClient((_) async => throw StateError('Unexpected request'));
    addTearDown(client.close);
    final addon = DiscoveryAddon(
      DiscoveryHttp(client), endpoint: 'https://tidal.example.com',
    );
    final audio = addon.parseStream({
      'url': 'https://cdn.example.com/track.flac?signature=secret',
      'audio': {
        'codec': 'FLAC',
        'audioQuality': 'HI_RES_LOSSLESS',
        'bitDepth': 24,
        'sampleRate': '96 kHz',
      },
    });
    expect(audio.codec, 'FLAC');
    expect(audio.quality, 'HI_RES_LOSSLESS');
    expect(audio.bitDepth, 24);
    expect(audio.sampleRate, 96000);
    final song = progressiveAddonSong(
      const DiscoveryTrack(
        id: 'tidal-test', title: 'Tidal track', artist: 'Artist',
        source: DiscoverySource.addon,
      ),
      audio,
    );
    expect(song.fileType, 'FLAC');
    expect(song.resolution, 'HI_RES_LOSSLESS');
    expect(song.bitDepth, 24);
    expect(song.sampleRate, 96000);
    expect(LokalQualityTier.of(song), LokalQualityTier.hiRes);
  });

  test('HTTP Tidal lossy bitrate labels come from exact stream, not catalogue', () {
    final addon = DiscoveryAddon(
      DiscoveryHttp(MockClient((_) async => throw StateError('no network'))),
      endpoint: 'https://tidal.example.com',
    );
    final audio = addon.parseStream({
      'url': 'https://cdn.example.com/audio.mp4?token=private',
      'metadata': {'codec': 'AAC', 'bitrate': 320},
    });
    expect(audio.bitrate, 320000);
    final song = progressiveAddonSong(
      const DiscoveryTrack(
        id: 'high', title: 'High', artist: 'Artist',
        source: DiscoverySource.addon,
        catalogueQuality: 'HI_RES_LOSSLESS',
        catalogueBitDepth: 24,
        catalogueSampleRate: 96000,
      ),
      audio,
    );
    expect(song.fileType, 'AAC');
    expect(song.resolution, '320 kbps');
    expect(song.sampleRate, isNull);
    expect(song.bitDepth, isNull);
    expect(LokalQualityTier.of(song), LokalQualityTier.high);
  });

  test('unreported HTTP rendition is not mislabeled as verified hi-res', () {
    final addon = DiscoveryAddon(
      DiscoveryHttp(MockClient((_) async => throw StateError('no network'))),
      endpoint: 'https://tidal.example.com',
    );
    final audio = addon.parseStream({
      'url': 'https://cdn.example.com/audio.m4a?token=private',
    });
    expect(audio.quality, isNull);
    expect(audio.bitrate, isNull);
    expect(audio.codec, isNull);
  });

  test('automatic HTTP circuit breaker cools down repeated timeouts only', () {
    final guard = OnlineAddonCooldown(
      failureThreshold: 2, cooldown: const Duration(minutes: 2),
    );
    final at = DateTime.utc(2026, 10, 31);
    const timeout = DiscoveryException('The source timed out. Try again.');
    guard.failed('w-unhealthy', timeout, now: at);
    expect(guard.shouldSkip('w-unhealthy', now: at), isFalse);
    guard.failed('w-unhealthy', timeout, now: at.add(const Duration(seconds: 1)));
    expect(guard.shouldSkip('w-unhealthy', now: at.add(const Duration(seconds: 2))),
        isTrue);
    // Explicit retry succeeds, clearing the breaker immediately.
    guard.succeeded('w-unhealthy');
    expect(guard.shouldSkip('w-unhealthy', now: at), isFalse);
    guard.failed('w-unhealthy', const DiscoveryException('HTTP 403'), now: at);
    expect(guard.shouldSkip('w-unhealthy', now: at), isFalse);
    guard.failed('a-morneye', timeout, now: at);
    guard.failed('a-morneye', timeout, now: at);
    expect(guard.shouldSkip('a-morneye', now: at), isFalse);
    guard.failed('w-unhealthy', timeout, now: at);
    guard.failed('w-unhealthy', timeout, now: at);
    expect(guard.shouldSkip('w-unhealthy', now: at.add(const Duration(minutes: 3))),
        isFalse);
  });

  test('16/44.1 metadata stays visible in Search and Full Player', () {
    expect(compactAudioResolution('16/44.1')?.sampleRate, 44100);
    expect(compactAudioResolution('24/96')?.sampleRate, 96000);
    expect(compactAudioResolution('320kbps'), isNull);
    expect(catalogueQualityLabel('16/44.1'), '16-bit / 44.1 kHz');
    expect(catalogueAudioDetails(
      codec: 'FLAC', quality: '16/44.1',
    ), 'FLAC · 16-bit / 44.1 kHz');
    expect(catalogueStreamTierLabel(
      codec: 'FLAC', quality: '16/44.1',
    ), 'LOSSLESS');
    final stream = ResolvedDiscoveryAudio(
      Uri.parse('https://cdn.example.com/audio?token=hidden'),
      codec: 'FLAC', quality: '16/44.1',
    );
    final song = progressiveAddonSong(
      const DiscoveryTrack(
        id: 'cd', title: 'CD audio', artist: 'Artist',
        source: DiscoverySource.addon,
      ),
      stream,
    );
    expect(song.fileType, 'FLAC');
    expect(song.bitDepth, 16);
    expect(song.sampleRate, 44100);
    expect(LokalQualityTier.of(song), LokalQualityTier.lossless);
  });

  test('resolved lower rendition overrides catalogue hi-res maximum', () {
    final song = progressiveAddonSong(
      const DiscoveryTrack(
        id: 'cd', title: 'CD audio', artist: 'Artist',
        source: DiscoverySource.addon,
        catalogueQuality: '24/96',
        catalogueCodec: 'FLAC',
        catalogueBitDepth: 24,
        catalogueSampleRate: 96000,
      ),
      ResolvedDiscoveryAudio(
        Uri.parse('https://cdn.example.com/actual.flac'),
        codec: 'FLAC', quality: '16/44.1',
        bitDepth: 16, sampleRate: 44100,
      ),
    );
    expect(song.bitDepth, 16);
    expect(song.sampleRate, 44100);
    expect(LokalQualityTier.of(song), LokalQualityTier.lossless);
  });

  test('incomplete resolver metadata does not inherit catalogue maxima', () {
    final song = progressiveAddonSong(
      const DiscoveryTrack(
        id: 'partial', title: 'Partial', artist: 'Artist',
        source: DiscoverySource.addon,
        catalogueQuality: '24/96', catalogueCodec: 'FLAC',
        catalogueBitDepth: 24, catalogueSampleRate: 96000,
      ),
      ResolvedDiscoveryAudio(
        Uri.parse('https://cdn.example.com/selected.flac'),
        codec: 'FLAC',
      ),
    );
    expect(song.fileType, 'FLAC');
    expect(song.bitDepth, isNull);
    expect(song.sampleRate, isNull);
    expect(LokalQualityTier.of(song), LokalQualityTier.unknown);
  });

  test('Discovery skips alternate queries when the first matches', () async {
    final calls = <String>[];
    final source = OnlineSource(
      id: 'web', name: 'HTTP',
      results: (query) async {
        calls.add(query);
        return [const OnlineResult(DiscoveryTrack(
          id: '1', title: 'Song', artist: 'Artist',
          source: DiscoverySource.addon,
        ))];
      },
      play: (_) async => throw UnimplementedError(),
    );
    final found = await findDiscoverySourceMatch(
      source: source,
      candidate: const RecommendationCandidate(title: 'Song', artist: 'Artist'),
      queries: ['first', 'second', 'third'],
    );
    expect(found?.id, '1');
    expect(calls, ['first']);
  });

  test('Discovery starts two fallback searches concurrently', () async {
    final second = Completer<List<OnlineResult>>();
    final third = Completer<List<OnlineResult>>();
    final calls = <String>[];
    final source = OnlineSource(
      id: 'web', name: 'HTTP',
      results: (query) {
        calls.add(query);
        if (query == 'first') return Future.value(const []);
        if (query == 'second') return second.future;
        if (query == 'third') return third.future;
        throw StateError('Unknown query');
      },
      play: (_) async => throw UnimplementedError(),
    );
    final searching = findDiscoverySourceMatch(
      source: source,
      candidate: const RecommendationCandidate(title: 'Song', artist: 'Artist'),
      queries: ['first', 'second', 'third'],
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['first', 'second', 'third'],
        reason: 'The third alternate must not wait for the second network reply');
    third.complete([const OnlineResult(DiscoveryTrack(
      id: '3', title: 'Song', artist: 'Artist',
      source: DiscoverySource.addon,
    ))]);
    second.complete(const []);
    expect((await searching)?.id, '3');
  });

  test('slow HTTP primary search does not block a matching alternate', () async {
    final first = Completer<List<OnlineResult>>();
    final second = Completer<List<OnlineResult>>();
    final calls = <String>[];
    final source = OnlineSource(
      id: 'w-add-on', name: 'HTTP provider',
      results: (query) {
        calls.add(query);
        if (query == 'first') return first.future;
        if (query == 'second') return second.future;
        if (query == 'third') {
          return Future.value([const OnlineResult(DiscoveryTrack(
            id: 'verified', title: 'Song', artist: 'Artist',
            source: DiscoverySource.addon,
          ))]);
        }
        throw StateError('Unexpected query');
      },
      play: (_) async => throw UnimplementedError(),
    );
    final matched = findDiscoverySourceMatch(
      source: source,
      candidate: const RecommendationCandidate(title: 'Song', artist: 'Artist'),
      queries: ['first', 'second', 'third'],
      hedgeDelay: Duration.zero,
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(calls, ['first', 'second', 'third']);
    expect((await matched)?.id, 'verified',
        reason: 'No need to await the hanging primary metadata request');
    first.complete(const []);
    second.complete(const []);
  });

  test('Morneye guest stays serial even with hedging enabled', () async {
    final first = Completer<List<OnlineResult>>();
    final calls = <String>[];
    final source = OnlineSource(
      id: 'a-tidal', name: 'Tidal Morneye',
      results: (query) {
        calls.add(query);
        if (query == 'first') return first.future;
        return Future.value([const OnlineResult(DiscoveryTrack(
          id: 'verified', title: 'Song', artist: 'Artist',
          source: DiscoverySource.morneye,
        ))]);
      },
      play: (_) async => throw UnimplementedError(),
    );
    final matched = findDiscoverySourceMatch(
      source: source,
      candidate: const RecommendationCandidate(title: 'Song', artist: 'Artist'),
      queries: ['first', 'second'],
      hedgeDelay: Duration.zero,
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(calls, ['first']);
    first.complete(const []);
    expect((await matched)?.id, 'verified');
    expect(calls, ['first', 'second']);
  });

  test('Discovery cancellation is never swallowed by a failed search', () async {
    var cancelled = false;
    final source = OnlineSource(
      id: 'web', name: 'HTTP',
      results: (_) async {
        cancelled = true;
        throw StateError('Interrupted');
      },
      play: (_) async => throw UnimplementedError(),
    );
    await expectLater(
      findDiscoverySourceMatch(
        source: source,
        candidate: const RecommendationCandidate(title: 'Song', artist: 'Artist'),
        queries: ['first'],
        checkCancelled: () {
          if (cancelled) throw StateError('cancelled');
        },
      ),
      throwsA(isA<StateError>()),
    );
  });
}
