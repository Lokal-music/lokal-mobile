import 'package:flick/features/morneye/morneye_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('signed session contract for Morneye Tidal ticket resolution', () {
    test('a rejected ticket is terminal instead of retried across every tier', () {
      final reply = morneyeSignedAddonResponse(
        {'ok': false, 'status': 403, 'body': '{"code":"TICKET_DENIED"}'},
        {'code': 'TICKET_DENIED', 'origin': 'gateway',
         'retryable': false, 'retry_mode': 'none'},
      );
      expect(reply['status'], 403);
      expect(reply['code'], 'TICKET_DENIED');
      expect(reply['retryable'], isFalse);
      expect(reply['retryMode'], 'none');
      expect(reply['needsVerification'], isFalse);
    });

    test('missing gateway retry fields still treat HTTP 403 as terminal', () {
      final reply = morneyeSignedAddonResponse(
        {'status': 403, 'body': ''}, const {},
      );
      expect(reply['retryMode'], 'none');
      expect(reply['retryable'], isFalse);
    });

    test('retry-after, poll and transient provider errors propagate correctly', () {
      final reply = morneyeSignedAddonResponse(
        {'status': 503, 'headers': {'retry-after': '3'}},
        {'code': 'PROVIDER_UNAVAILABLE', 'retryable': true,
         'retry_mode': 'poll_existing', 'retry_after_seconds': 3},
      );
      expect(reply['retryMode'], 'poll_existing');
      expect(reply['retryable'], isTrue);
      expect(reply['retryAfterSeconds'], 3);
      expect(reply['code'], 'PROVIDER_UNAVAILABLE');
      expect(reply['headers'], containsPair('retry-after', '3'));
    });

    test('verification required is explicitly forwarded', () {
      final reply = morneyeSignedAddonResponse(
        {'status': 428}, {'code': 'VERIFY_REQUIRED', 'action': 'verify'},
      );
      expect(reply['needsVerification'], isTrue);
      expect(reply['retryMode'], 'none');
    });
  });


  test('signed headers match desktop byte for byte', () {
    // Expected values come from desktop's electron/morneye/session.js.
    final headers = morneyeSignedHeaders(
      {
        'headerPrefix': 'X-Zarz-',
        'schemeLabel': 'ZARZ-HMAC-V1',
        'appVersion': 'tidal-web@1.2.5',
        'platform': 'extension',
        'timeWindowSeconds': 300,
      },
      {'session_id': 'sid1', 'session_secret': 'sec'},
      'post',
      'https://api.zarz.moe/v2/tickets',
      '{"a":"é"}',
      now: DateTime.fromMicrosecondsSinceEpoch(1760937314949123, isUtc: true),
      nonce: 'abcd',
    );
    expect(headers['X-Zarz-Timestamp'], '2025-10-20T05:15:14.949Z');
    expect(
      headers['X-Zarz-Body-SHA256'],
      'b3a092a6af48807fa9482b2ee140105575daa26d5b24b3c0e60a7e2dee6683b1',
    );
    expect(
      headers['X-Zarz-Signature'],
      'd_UznKcHXh1P8UujgutVoKaevKApl08RhCSwPeee7fE',
    );
  });
}
