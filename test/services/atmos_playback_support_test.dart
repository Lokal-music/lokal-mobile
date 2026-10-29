import 'package:flick/services/atmos_playback_support.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('lokal/atmos');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('does not request Atmos without a licensed decoder/output', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'capabilities') return {
        'available': false, 'jocDecoder': false, 'passthrough': false,
      };
      return false;
    });
    expect(await AtmosPlaybackSupport.available, isFalse);
    expect(await AtmosPlaybackSupport.isJocFile('/tmp/stereo.m4a',
      probeStreams: (_) async => [{'codec_name': 'aac', 'profile': 'LC'}]), isFalse);
  });

  test('uses native file inspection, never the source catalogue alone', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'capabilities') return {
        'available': true, 'jocDecoder': true, 'passthrough': false,
      };
      if (call.method == 'inspect') {
        final path = (call.arguments as Map)['path'] as String;
        return path.endsWith('/true-joc.m4a');
      }
      return null;
    });
    expect(await AtmosPlaybackSupport.available, isTrue);
    expect(await AtmosPlaybackSupport.isJocFile('/tmp/true-joc.m4a'), isTrue);
    expect(await AtmosPlaybackSupport.isJocFile('/tmp/lossless.m4a',
      probeStreams: (_) async => [{'codec_name': 'flac'}]), isFalse);
  });

  test('Amazon AC-4 uses independent decoder capability and verifies the downloaded codec', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'capabilities') return {
        'available': false, 'jocDecoder': false, 'passthrough': false,
        'ac4Decoder': true, 'ac4Passthrough': false,
      };
      if (call.method == 'inspectAc4') return false;
      return false;
    });
    expect(await AtmosPlaybackSupport.available, isFalse);
    expect(await AtmosPlaybackSupport.availableFor('ac4'), isTrue);
    expect(await AtmosPlaybackSupport.isAc4File('/tmp/amazon.mp4', probeStreams: (_) async => [
      {'codec_type': 'audio', 'codec_name': 'ac4'}
    ]), isTrue);
    expect(await AtmosPlaybackSupport.isAc4File('/tmp/stereo.mp4', probeStreams: (_) async => [
      {'codec_type': 'audio', 'codec_name': 'aac'}
    ]), isFalse);
  });

  test('missing plugin safely falls back to stereo', () async {
    expect(await AtmosPlaybackSupport.available, isFalse);
    expect(await AtmosPlaybackSupport.isJocFile('/tmp/file.m4a',
      probeStreams: (_) async => []), isFalse);
  });
  test('Android generic E-AC-3 MIME is recoverable by FFprobe JOC evidence', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'inspect') return false; // OEM reports audio/eac3.
      return null;
    });
    expect(await AtmosPlaybackSupport.isJocFile('/tmp/atmos.m4a',
      probeStreams: (_) async => [
        {'codec_type': 'audio', 'codec_name': 'eac3',
         'profile': 'Dolby Digital Plus + Dolby Atmos'}
      ]), isTrue);
  });

  test('unverified or ordinary E-AC-3 never becomes Atmos', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => false);
    for (final stream in [
      {'codec_type': 'audio', 'codec_name': 'eac3',
       'profile': 'Dolby Digital Plus'},
      {'codec_type': 'audio', 'codec_name': 'aac',
       'profile': 'Dolby Digital Plus + Dolby Atmos'},
      {'codec_type': 'audio', 'codec_name': 'flac'},
    ]) {
      expect(await AtmosPlaybackSupport.isJocFile('/tmp/unverified.m4a',
        probeStreams: (_) async => [stream]), isFalse);
    }
  });

  test('FFprobe errors cannot approve unverified files', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => false);
    expect(await AtmosPlaybackSupport.isJocFile('/tmp/broken.m4a',
      probeStreams: (_) async => throw StateError('no stream')), isFalse);
  });

  test('an OEM-recognized JOC stream does not require FFprobe', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => true);
    expect(await AtmosPlaybackSupport.isJocFile('/tmp/atmos.m4a',
      probeStreams: (_) async => throw StateError('should never run')), isTrue);
  });

  test('profile detection only accepts codec + JOC together', () {
    expect(AtmosPlaybackSupport.isJocProfile({
      'codec_name': 'eac3', 'profile': 'Dolby Digital Plus + Dolby Atmos',
    }), isTrue);
    expect(AtmosPlaybackSupport.isJocProfile({
      'codec_name': 'eac3', 'profile': 'E-AC-3 JOC',
    }), isTrue);
    expect(AtmosPlaybackSupport.isJocProfile({
      'codec_name': 'eac3', 'profile': 'Dolby Digital Plus',
    }), isFalse);
    expect(AtmosPlaybackSupport.isJocProfile({
      'codec_name': 'flac', 'profile': 'Dolby Atmos',
    }), isFalse);
  });

}
