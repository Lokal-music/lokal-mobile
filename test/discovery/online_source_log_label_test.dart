import 'package:flick/core/utils/online_source_log_label.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('public provider diagnostics stay recognizable', () {
    expect(onlineSourceLogLabel('youtube'), 'youtube');
    expect(onlineSourceLogLabel('spotify'), 'spotify');
    expect(onlineSourceLogLabel('soundcloud'), 'soundcloud');
  });

  test(
    'URL credentials, signed queries and line breaks never enter labels',
    () {
      for (final source in [
        'https://user:test-password@example.invalid/addon?signature=test-signed-secret',
        'addon:test-token:private-account',
        'custom\r\nforged-log-line',
      ]) {
        final label = onlineSourceLogLabel(source);
        expect(label, matches(r'^custom:[a-f0-9]{12}$'));
        expect(label, isNot(contains('test-password')));
        expect(label, isNot(contains('test-signed-secret')));
        expect(label, isNot(contains('private-account')));
        expect(label, isNot(contains('forged-log-line')));
        expect(label, onlineSourceLogLabel(source));
      }
      expect(
        onlineSourceLogLabel('addon:one'),
        isNot(onlineSourceLogLabel('addon:two')),
      );
    },
  );
}
