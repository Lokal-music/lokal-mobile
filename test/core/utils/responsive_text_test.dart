import 'package:flick/core/utils/responsive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('responsive text receives the system font scale exactly once', (
    tester,
  ) async {
    for (final width in [320.0, 375.0, 430.0]) {
      for (final scale in [.8, 1.0, 2.0]) {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 900),
                textScaler: TextScaler.linear(scale),
              ),
              child: Builder(
                builder: (context) => Text(
                  'Readable',
                  style: TextStyle(fontSize: Responsive.textSize(context, 17)),
                ),
              ),
            ),
          ),
        );
        final paragraph = tester.renderObject<RenderParagraph>(
          find.text('Readable'),
        );
        final span = paragraph.text as TextSpan;
        final base = 17 * (width / 375).clamp(.85, 1.5);
        expect(span.style!.fontSize, closeTo(base, .00001));
        expect(
          paragraph.textScaler.scale(span.style!.fontSize!),
          closeTo(base * scale, .00001),
        );
        expect(tester.takeException(), isNull);
      }
    }
  });
}
