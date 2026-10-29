import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/atmos_diagnostics.dart';

void main() {
  test('codec handoffs retain both codecs while redacting private values', () {
    final line = AtmosDiagnostics.format('playback_handoff', {
      'from': 'ac4',
      'to': 'eac3_joc',
      'outcome': 'releasing_previous_decoder',
    });
    expect(line, contains('"from":"ac4"'));
    expect(line, contains('"to":"eac3_joc"'));
    final private = AtmosDiagnostics.format('playback_handoff', {
      'from': '/private/audio.mp4',
      'to': 'https://example.com/stream?token=secret',
    });
    expect(private, contains('"from":"redacted"'));
    expect(private, contains('"to":"redacted"'));
    expect(private, isNot(contains('secret')));
  });

  test('Atmos diagnostics preserve actionable categorical values', () {
    final line = AtmosDiagnostics.format('capability', {
      'available': true,
      'jocDecoder': false,
      'passthrough': true,
      'sdk': 36,
      'reason': 'native_route_available',
    });
    expect(line, contains('"event":"capability"'));
    expect(line, contains('"available":true'));
    expect(line, contains('"jocDecoder":false'));
    expect(line, contains('"sdk":36'));
    expect(line, contains('"reason":"native_route_available"'));
  });

  test('Paths, signed URLs, tokens and arbitrary sensitive keys never enter logs', () {
    const secret = 'topsecret987654321';
    final line = AtmosDiagnostics.format('source_probe', {
      'url': 'https://example.org/audio?token=$secret',
      'path': '/storage/emulated/0/Music/private/$secret.m4a',
      'authorization': 'Bearer $secret',
      'trackId': secret,
      'title': 'Private Song',
      'errorClass': 'PlatformException',
      'errorCode': 'file:///private/$secret',
      'quality': 'DOLBY_ATMOS',
      'outcome': 'confirmed',
    });
    expect(line, isNot(contains(secret)));
    expect(line, isNot(contains('example.org')));
    expect(line, isNot(contains('Private Song')));
    expect(line, isNot(contains('Bearer')));
    expect(line, contains('"quality":"DOLBY_ATMOS"'));
    expect(line, contains('"errorClass":"PlatformException"'));
    expect(line, contains('"errorCode":"redacted"'));
  });

  test('Malformed values and unexpected keys are omitted or redacted', () {
    final line = AtmosDiagnostics.format('playback_error', {
      'reason': 'https://provider.example.com/stream',
      'sdk': -1,
      'megabytes': 999999999,
      'headers': {'cookie': 'private'},
      'outcome': 'decoder_error',
    });
    expect(line, contains('"reason":"redacted"'));
    expect(line, contains('"outcome":"decoder_error"'));
    expect(line, isNot(contains('provider.example.com')));
    expect(line, isNot(contains('"headers"')));
    expect(line, isNot(contains('"sdk"')));
    expect(line, isNot(contains('"megabytes"')));
  });
}
