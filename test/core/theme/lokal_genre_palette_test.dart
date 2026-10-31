import 'package:flutter_test/flutter_test.dart';
import 'package:flick/core/theme/lokal_genre_palette.dart';

void main() {
  test('genre palette remains stable regardless of list order', () {
    expect(LokalGenrePalette.of('Jazz').base, LokalGenrePalette.of('Jazz').base);
    expect(LokalGenrePalette.of('Alternative').base,
        LokalGenrePalette.of('Indie / Alternative').base);
    expect(LokalGenrePalette.of('Electronic').base,
        LokalGenrePalette.of('Electronic').base);
  });

  test('white foreground has AA contrast over every gradient stop', () {
    const names = [
      'Jazz', 'Afrobeat', 'Indie / Alternative', 'R&B', 'Rock',
      'Electronic', 'Reggae', 'Hip-Hop', 'Folk', 'Pop', 'Classical',
      'Soundtrack', 'Other', 'No genre',
    ];
    final foreground = LokalGenrePalette.foreground.computeLuminance();
    for (final name in names) {
      final tone = LokalGenrePalette.of(name);
      for (final background in [tone.base, tone.highlight]) {
        final shade = background.computeLuminance();
        final contrast = (foreground + .05) / (shade + .05);
        expect(contrast, greaterThanOrEqualTo(4.5),
            reason: '$name must stay legible against both ends of its gradient');
      }
    }
  });
}
