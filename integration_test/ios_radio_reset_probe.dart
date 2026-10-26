import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flick/features/internet_radio/radio_catalog.dart';
import 'package:flick/features/internet_radio/radio_providers.dart';
import 'package:flick/services/ios_local_audio_requests.dart';
import 'package:flick/services/local_audio_lifecycle.dart';
import 'package:flick/services/player_service.dart';

/// Real iPhone just_audio/AVPlayer with an app-owned loopback WAV station.
/// No public catalogue, external station or clock interpolation qualifies this
/// check: require native Ready, a fresh HTTP open, and paused reset retention.
Future<void> probeIosRadioReset(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
  File wav,
) async {
  final content = await wav.readAsBytes();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final handlers = <Future<void>>[];
  var opens = 0;
  final subscription = server.listen((request) {
    opens++;
    final handling = () async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final match = range == null
          ? null
          : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
      final start = match == null ? 0 : int.parse(match.group(1)!);
      final end = match == null || match.group(2)!.isEmpty
          ? content.length - 1
          : int.parse(match.group(2)!).clamp(0, content.length - 1);
      if (start >= content.length || start > end) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      } else {
        request.response.headers.set(
          HttpHeaders.contentTypeHeader,
          'audio/wav',
        );
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        if (match != null) {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${content.length}',
          );
        }
        request.response.contentLength = end - start + 1;
        if (request.method != 'HEAD') {
          request.response.add(content.sublist(start, end + 1));
        }
      }
      await request.response.close();
    }();
    handlers.add(
      handling.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  });
  final container = ProviderContainer();
  final radio = container.read(radioPlayerProvider.notifier);
  final station = RadioStation(
    id: 'ios-native-radio-fixture',
    title: 'Local radio reset fixture',
    url: 'http://127.0.0.1:${server.port}/station.wav',
  );
  try {
    await PlayerService().pause();
    await radio.play(station);
    expect(container.read(radioPlayerProvider).station?.id, station.id);
    expect(container.read(radioPlayerProvider).playing, isTrue);
    expect(container.read(radioPlayerProvider).loading, isFalse);
    expect(opens, greaterThan(0));
    final beforeReplay = opens;
    for (var reset = 0; reset < 2; reset++) {
      await const MethodChannel('lokal/ios')
          .invokeMethod<void>('postMediaServicesResetForIntegrationTest');
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        final phase = IosLocalAudioRequests.lifecycle.phase.value;
        expect(
          phase,
          isNot(LocalAudioPhase.blocked),
          reason: '${IosLocalAudioRequests.lifecycle.cleanupError}',
        );
        if (phase == LocalAudioPhase.paused) break;
      }
      expect(
        IosLocalAudioRequests.lifecycle.phase.value,
        LocalAudioPhase.paused,
      );
      final retained = container.read(radioPlayerProvider);
      expect(retained.station?.id, station.id);
      expect(retained.playing, isFalse);
      expect(retained.loading, isFalse);
      expect(retained.error, isNull);
      await tester.pump(const Duration(milliseconds: 500));
      expect(container.read(radioPlayerProvider).playing, isFalse);
      expect(PlayerService().isPlayingNotifier.value, isFalse);
      if (reset == 0) {
        await radio.toggle();
        expect(container.read(radioPlayerProvider).playing, isTrue);
        expect(
          opens,
          greaterThan(beforeReplay),
          reason: 'Explicit replay must reopen the stream with a new player',
        );
        expect(
          IosLocalAudioRequests.lifecycle.phase.value,
          LocalAudioPhase.ready,
        );
      }
    }
    binding.reportData!['media_reset_radio'] = {
      'scope': 'Native AVPlayer Ready and actual loopback stream reopens; not a live radio or daemon reset',
      'notifications': 2,
      'station_retained_paused': true,
      'explicit_play_reopens_stream': true,
      'http_opens': opens,
    };
  } finally {
    await radio.stop();
    container.dispose();
    await server.close(force: true);
    await subscription.cancel();
    await Future.wait(handlers);
  }
}
