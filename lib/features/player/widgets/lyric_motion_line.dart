import 'package:flick/core/theme/lokal_performance_scope.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flick/services/lyrics_service.dart';

/// One shaped paragraph for measurement and painting, including CJK fallback,
/// RTL shaping and accessibility text scaling. Timed units never change wrapping.
class LyricMotionLine extends StatefulWidget {
  const LyricMotionLine({
    super.key,
    required this.line,
    required this.position,
    required this.style,
    this.sung = Colors.white,
    this.unsung = const Color(0x6BFFFFFF),
    this.textAlign = TextAlign.start,
    this.timing = true,
    this.lightweight = false,
  });
  final LyricsLine line;
  final Duration position;
  final TextStyle style;
  final Color sung, unsung;
  final TextAlign textAlign;
  final bool timing;
  /// Fast subtitle path: clip timed syllables without GPU saveLayer/blur passes.
  final bool lightweight;
  static TextPainter layout(
    BuildContext context,
    String text,
    TextStyle style,
    double width, {
    TextAlign align = TextAlign.start,
  }) => TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textAlign: align,
    textScaler: MediaQuery.textScalerOf(context),
    locale: Localizations.maybeLocaleOf(context),
  )..layout(maxWidth: width);
  static double height(
    BuildContext context,
    String text,
    TextStyle style,
    double width,
  ) {
    final painter = layout(context, text, style, width);
    final height = painter.height + 8;
    painter.dispose();
    return height;
  }

  @override
  State<LyricMotionLine> createState() => _LyricMotionLineState();
}

class _Run {
  _Run(this.boxes, this.word, {this.letter = 0, this.letters = 0});
  final List<TextBox> boxes;
  final LyricsWord? word;
  final int letter, letters;
}

class _LyricMotionLineState extends State<LyricMotionLine> {
  TextPainter? _lit, _dim;
  Object? _key;
  List<_Run> _runs = [];
  static final _joined = RegExp(
    r'[\u0590-\u0DFF\u0E00-\u0E7F\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF]',
  );
  void _layout(double width) {
    final key = Object.hash(
      widget.line.text,
      widget.line.words,
      widget.timing,
      widget.style,
      widget.sung,
      widget.unsung,
      widget.textAlign,
      width,
      MediaQuery.textScalerOf(context),
      Directionality.of(context),
      Localizations.maybeLocaleOf(context),
    );
    if (_key == key) return;
    _key = key;
    _lit?.dispose();
    _dim?.dispose();
    _lit = LyricMotionLine.layout(
      context,
      widget.line.text,
      widget.style.copyWith(color: widget.sung),
      width,
      align: widget.textAlign,
    );
    _dim = LyricMotionLine.layout(
      context,
      widget.line.text,
      widget.style.copyWith(color: widget.unsung),
      width,
      align: widget.textAlign,
    );
    List<TextBox> boxes(int start, int end) => _lit!.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: end),
    );
    _runs = [];
    var cursor = 0;
    for (final word
        in widget.timing
            ? widget.line.words ?? const <LyricsWord>[]
            : const <LyricsWord>[]) {
      final text = word.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) continue;
      final start = widget.line.text.indexOf(text, cursor);
      if (start < 0) continue;
      if (start > cursor) _runs.add(_Run(boxes(cursor, start), null));
      final end = start + text.length;
      final chars = text.characters.toList();
      final held = (word.end - word.start).inMilliseconds / 1000;
      final n = chars.length;
      final grow =
          n > 0 &&
          n <= 7 &&
          !text.contains('-') &&
          !_joined.hasMatch(text) &&
          (n == 1
              ? held >= 1.1
              : n <= 3
              ? held >= 1.3 + (n - 2) * .15
              : n == 4
              ? held >= 1.05
              : held >= math.max(.9, n * .2));
      if (grow) {
        var at = start;
        for (var i = 0; i < n; i++) {
          _runs.add(
            _Run(boxes(at, at + chars[i].length), word, letter: i, letters: n),
          );
          at += chars[i].length;
        }
      } else {
        _runs.add(_Run(boxes(start, end), word));
      }
      cursor = end;
    }
    if (cursor < widget.line.text.length)
      _runs.add(_Run(boxes(cursor, widget.line.text.length), null));
  }

  @override
  void dispose() {
    _lit?.dispose();
    _dim?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _layout(constraints.maxWidth);
      return Semantics(
        label: widget.line.text,
        child: SizedBox(
          height: _lit!.height + 8,
          width: constraints.maxWidth,
          child: CustomPaint(
            painter: _LyricPainter(
              _lit!,
              _dim!,
              _runs,
              widget.position,
              MediaQuery.disableAnimationsOf(context) ||
                  LokalPerformanceScope.of(context),
              widget.style.fontSize ?? 24,
              widget.lightweight,
            ),
          ),
        ),
      );
    },
  );
}

class _LyricPainter extends CustomPainter {
  _LyricPainter(
    this.lit,
    this.dim,
    this.runs,
    this.position,
    this.reduced,
    this.fontSize,
    this.lightweight,
  );
  final TextPainter lit, dim;
  final List<_Run> runs;
  final Duration position;
  final bool reduced;
  final double fontSize;
  final bool lightweight;
  static double smooth(double x) {
    final v = x.clamp(0.0, 1.0);
    return v * v * (3 - 2 * v);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Untimed lines stay line-synced; do not invent syllable timestamps.
    if (runs.every((r) => r.word == null)) {
      lit.paint(canvas, const Offset(0, 4));
      return;
    }
    canvas.save();
    canvas.translate(0, 4);
    for (final run in runs) {
      final word = run.word;
      final span = word == null
          ? 1
          : math.max(1, (word.end - word.start).inMilliseconds);
      final elapsed = word == null
          ? -1
          : (position - word.start).inMilliseconds;
      var p = (elapsed / span).clamp(0.0, 1.0);
      var lift = word == null || reduced || lightweight
          ? 0.0
          : .06 * smooth(math.min(elapsed / 700, 1 - (elapsed - span) / 700));
      var scale = 1.0;
      if (run.letters > 0) {
        p = (p * run.letters - run.letter).clamp(0.0, 1.0);
        if (!reduced && !lightweight) {
          final phase = ((elapsed - run.letter * span * .09) / (span * 1.5))
              .clamp(0.0, 1.0);
          final k = phase < .25
              ? smooth(phase / .25)
              : phase < .3
              ? 1.0
              : phase < .75
              ? 1 - smooth((phase - .3) / .45)
              : 0.0;
          final earned = math.pow(
            ((span / 1000 - .4) / 2.6).clamp(0.0, 1.0),
            2,
          );
          final swell = .04 + earned * .08;
          scale += swell * k;
          lift += swell * k * .9;
        }
      }
      for (final box in run.boxes) {
        final rect = box.toRect();
        canvas.save();
        canvas.translate(rect.center.dx, rect.center.dy - fontSize * lift);
        canvas.scale(scale);
        canvas.translate(-rect.center.dx, -rect.center.dy);
        canvas.clipRect(rect.inflate(.15));
        dim.paint(canvas, Offset.zero);
        if (word != null && p > 0) {
          if (p >= 1) {
            lit.paint(canvas, Offset.zero);
          } else if (reduced || lightweight) {
            final width = rect.width * p;
            canvas.clipRect(
              Rect.fromLTRB(
                box.direction == TextDirection.rtl
                    ? rect.right - width
                    : rect.left,
                rect.top,
                box.direction == TextDirection.rtl
                    ? rect.right
                    : rect.left + width,
                rect.bottom,
              ),
            );
            lit.paint(canvas, Offset.zero);
          } else {
            canvas.saveLayer(rect, Paint());
            lit.paint(canvas, Offset.zero);
            final feather = math.min(
              .45,
              fontSize * .6 / math.max(1, rect.width),
            );
            final edge = p * (1 + feather * 2) - feather;
            canvas.drawRect(
              rect,
              Paint()
                ..blendMode = BlendMode.dstIn
                ..shader = LinearGradient(
                  begin: box.direction == TextDirection.rtl
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  end: box.direction == TextDirection.rtl
                      ? Alignment.centerLeft
                      : Alignment.centerRight,
                  colors: const [Colors.white, Colors.transparent],
                  stops: [
                    (edge - feather).clamp(0.0, 1.0),
                    (edge + feather).clamp(0.0, 1.0),
                  ],
                ).createShader(rect),
            );
            canvas.restore();
          }
        }
        canvas.restore();
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LyricPainter old) =>
      old.position != position || old.lit != lit ||
      old.reduced != reduced || old.lightweight != lightweight;
}
