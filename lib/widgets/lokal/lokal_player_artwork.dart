import 'dart:ui' show lerpDouble;
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Paints the player's real cover above the moving sheet's clips. Its layout
/// stays in the full player, while its paint bounds follow the same progress
/// as the sheet, including a finger-held drag and its settling spring.
class LokalPlayerMorph extends StatelessWidget {
  const LokalPlayerMorph({
    super.key,
    required this.progress,
    required this.sheetOffset,
    required this.sourceArtwork,
    required this.child,
  });

  final double progress;
  final double sheetOffset;
  final Rect? Function() sourceArtwork;
  final Widget child;

  static bool activeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MorphScope>() != null;

  static double progressOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_MorphProgressScope>()
          ?.progress ??
      1;

  /// Reframe still art to the traveling viewport before scaling it. A tall
  /// fullscreen poster must reach the mini player's square crop without
  /// squeezing the image or switching crops on the final frame.
  static double artworkViewportHeight(BuildContext context, Size expanded) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_MorphProgressScope>();
    final source = scope?.sourceSize;
    if (source == null || source.isEmpty || expanded.isEmpty) {
      return expanded.height;
    }
    final viewport = Size.lerp(
      source,
      expanded,
      scope!.progress.clamp(0.0, 1.0),
    )!;
    return expanded.width * viewport.height / viewport.width;
  }

  @override
  Widget build(BuildContext context) => _MorphProgressScope(
    progress: progress,
    sourceSize: sourceArtwork()?.size,
    child: _MorphScope(
      child: _ArtworkPortal(
        progress: progress,
        sheetOffset: sheetOffset,
        sourceArtwork: sourceArtwork,
        child: child,
      ),
    ),
  );
}

class _MorphProgressScope extends InheritedWidget {
  const _MorphProgressScope({
    required this.progress,
    required this.sourceSize,
    required super.child,
  });
  final double progress;
  final Size? sourceSize;
  @override
  bool updateShouldNotify(_MorphProgressScope oldWidget) =>
      progress != oldWidget.progress || sourceSize != oldWidget.sourceSize;
}

class _MorphScope extends InheritedWidget {
  const _MorphScope({required super.child});
  @override
  bool updateShouldNotify(_MorphScope oldWidget) => false;
}

/// Wraps the whole cover, including its like animation. Ancestor carousel and
/// sheet clipping cannot split the cover's trip between the two real layouts.
class LokalPlayerArtwork extends StatelessWidget {
  const LokalPlayerArtwork({
    super.key,
    required this.child,
    this.enabled = true,
    this.expandedRadius = 28,
  });
  final bool enabled;
  final double expandedRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) => _ArtworkAnchor(
    enabled: enabled && LokalPlayerMorph.activeOf(context),
    expandedRadius: expandedRadius,
    child: child,
  );
}

/// Chrome (title, transport, seek bar, and buttons) that must stay above the
/// in-flight fullscreen artwork. The artwork portal otherwise paints the
/// travelling image *after* its entire sheet, which hides controls under a
/// full-height Canvas video until the final frame.
///
/// This keeps the same render subtree and opacity animation, but lifts its
/// paint order along with the moving artwork. Compact/collapsed layouts don't
/// need it and retain their original behaviour.
class LokalPlayerChrome extends StatelessWidget {
  const LokalPlayerChrome({
    super.key,
    required this.child,
    this.enabled = true,
  });

  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) => _ChromeAnchor(
    enabled: enabled && LokalPlayerMorph.activeOf(context),
    child: child,
  );
}

class _ArtworkPortal extends SingleChildRenderObjectWidget {
  const _ArtworkPortal({
    required this.progress,
    required this.sheetOffset,
    required this.sourceArtwork,
    required super.child,
  });
  final double progress;
  final double sheetOffset;
  final Rect? Function() sourceArtwork;

  @override
  _RenderArtworkPortal createRenderObject(BuildContext context) =>
      _RenderArtworkPortal(progress, sheetOffset, sourceArtwork);

  @override
  void updateRenderObject(BuildContext context, _RenderArtworkPortal object) {
    object.update(progress, sheetOffset, sourceArtwork);
  }
}

class _RenderArtworkPortal extends RenderProxyBox {
  _RenderArtworkPortal(this._progress, this._sheetOffset, this._sourceArtwork);

  double _progress;
  double _sheetOffset;
  Rect? Function() _sourceArtwork;
  // Queue/lyrics may briefly mount a second anchor before retiring it.
  // Retain the other live anchors so removing that temporary thumbnail cannot
  // erase the poster that must morph back into the miniplayer.
  final _anchors = <_RenderArtworkAnchor>[];
  final _chromeAnchors = <_RenderChromeAnchor>[];
  _RenderArtworkAnchor? get artwork => _anchors.isEmpty ? null : _anchors.last;

  void _invalidateChromePaint() {
    for (final anchor in _chromeAnchors) {
      if (anchor.attached) anchor.markNeedsPaint();
    }
  }

  bool get _hasFlyingArtwork {
    final anchor = artwork;
    return lifting &&
        anchor != null &&
        anchor.attached &&
        anchor.hasSize &&
        anchor.child != null &&
        !anchor.size.isEmpty;
  }

  void registerChrome(_RenderChromeAnchor anchor) {
    _chromeAnchors.remove(anchor);
    _chromeAnchors.add(anchor);
    anchor.markNeedsPaint();
    markNeedsPaint();
  }

  void unregisterChrome(_RenderChromeAnchor anchor) {
    _chromeAnchors.remove(anchor);
    if (anchor.attached) anchor.markNeedsPaint();
    markNeedsPaint();
  }

  void register(_RenderArtworkAnchor anchor) {
    artwork?.markNeedsPaint();
    _anchors.remove(anchor);
    _anchors.add(anchor);
    _invalidateChromePaint();
    markNeedsPaint();
  }

  void unregister(_RenderArtworkAnchor anchor) {
    _anchors.remove(anchor);
    artwork?.markNeedsPaint();
    _invalidateChromePaint();
    markNeedsPaint();
  }

  bool get lifting => _progress < 1 && _sourceArtwork() != null;

  void update(double progress, double offset, Rect? Function() source) {
    _progress = progress;
    _sheetOffset = offset;
    _sourceArtwork = source;
    // Repaint the anchor's original layer as well: a cached carousel layer
    // must not retain a second copy when a closing drag starts.
    artwork?.markNeedsPaint();
    _invalidateChromePaint();
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final anchor = artwork, source = _sourceArtwork();
    if (!lifting ||
        anchor == null ||
        !anchor.attached ||
        !anchor.hasSize ||
        anchor.child == null ||
        source == null ||
        anchor.size.isEmpty) {
      return;
    }
    final natural = MatrixUtils.transformRect(
      anchor.getTransformTo(this),
      Offset.zero & anchor.size,
    );
    final origin = localToGlobal(Offset.zero);
    final from = source.shift(-origin);
    final to = natural.shift(Offset(0, -_sheetOffset));
    final rect = Rect.lerp(from, to, _progress.clamp(0.0, 1.0))!;
    // One scale preserves the artwork's aspect ratio. Independent X/Y
    // scaling squashed tall fullscreen art into a square and snapped when
    // the actual miniplayer cover took over.
    final scale = math.max(
      rect.width / anchor.size.width,
      rect.height / anchor.size.height,
    );
    final radius = lerpDouble(
      source.shortestSide / 2,
      anchor.expandedRadius,
      _progress,
    )!;
    final transform = Matrix4.identity()
      ..translateByDouble(
        rect.center.dx - anchor.size.width * scale / 2,
        rect.center.dy - anchor.size.height * scale / 2,
        0,
        1,
      )
      ..scaleByDouble(scale, scale, 1, 1);
    context.pushClipRRect(
      needsCompositing,
      offset,
      rect,
      RRect.fromRectAndRadius(rect, Radius.circular(radius)),
      (context, at) => context.pushTransform(
        needsCompositing,
        at,
        transform,
        (context, at) => context.paintChild(anchor.child!, at),
      ),
    );

    // Paint the existing control subtree *after* the flying artwork, at
    // precisely the same sheet-transformed coordinates. With a portrait
    // Canvas, the overlay otherwise covers every control until progress=1,
    // where all controls suddenly pop into view. Nothing is laid out or
    // animated twice: the chrome anchor suppresses its ordinary paint during
    // the flight, and this pass draws it above the video/artwork.
    //
    // Match the route sheet's initial fade, so chrome doesn't abruptly
    // appear when the gesture has barely lifted off the mini-player.
    final chromeAlpha = ((_progress / .12).clamp(0.0, 1.0) * 255).round();
    if (chromeAlpha == 0) return;
    for (final chrome in _chromeAnchors.toList(growable: false)) {
      if (!chrome.attached || !chrome.hasSize || chrome.child == null) continue;
      final chromeTransform = chrome.getTransformTo(this);
      context.pushTransform(
        needsCompositing,
        offset,
        chromeTransform,
        (context, at) => context.pushOpacity(
          at,
          chromeAlpha,
          (context, at) => context.paintChild(chrome.child!, at),
        ),
      );
    }
  }
}

class _ChromeAnchor extends SingleChildRenderObjectWidget {
  const _ChromeAnchor({required this.enabled, required super.child});
  final bool enabled;

  @override
  _RenderChromeAnchor createRenderObject(BuildContext context) =>
      _RenderChromeAnchor(enabled);

  @override
  void updateRenderObject(BuildContext context, _RenderChromeAnchor object) {
    object.enabled = enabled;
  }
}

class _RenderChromeAnchor extends RenderProxyBox {
  _RenderChromeAnchor(this._enabled);
  bool _enabled;
  _RenderArtworkPortal? _portal;

  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    _register();
    markNeedsPaint();
  }

  void _register() {
    RenderObject? ancestor = _enabled ? parent : null;
    while (ancestor != null && ancestor is! _RenderArtworkPortal) {
      ancestor = ancestor.parent;
    }
    final next = ancestor is _RenderArtworkPortal ? ancestor : null;
    if (identical(next, _portal)) return;
    _unregister();
    _portal = next;
    next?.registerChrome(this);
  }

  void _unregister() {
    _portal?.unregisterChrome(this);
    _portal = null;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _register();
  }

  @override
  void performLayout() {
    super.performLayout();
    _register();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // Do not draw twice: this subtree is repainted on top of the canvas by
    // the portal while its fullscreen artwork is being morphed.
    if (_portal?._hasFlyingArtwork ?? false) return;
    super.paint(context, offset);
  }

  @override
  void detach() {
    _unregister();
    super.detach();
  }
}

class _ArtworkAnchor extends SingleChildRenderObjectWidget {
  const _ArtworkAnchor({
    required this.enabled,
    required this.expandedRadius,
    required super.child,
  });
  final bool enabled;
  final double expandedRadius;
  @override
  _RenderArtworkAnchor createRenderObject(BuildContext context) =>
      _RenderArtworkAnchor(enabled, expandedRadius);

  @override
  void updateRenderObject(BuildContext context, _RenderArtworkAnchor object) {
    object.enabled = enabled;
    object.expandedRadius = expandedRadius;
  }
}

class _RenderArtworkAnchor extends RenderProxyBox {
  _RenderArtworkAnchor(this._enabled, this._expandedRadius);
  bool _enabled;
  double _expandedRadius;
  double get expandedRadius => _expandedRadius;
  set expandedRadius(double value) {
    if (_expandedRadius == value) return;
    _expandedRadius = value;
    _portal?.markNeedsPaint();
    markNeedsPaint();
  }

  _RenderArtworkPortal? _portal;

  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    _register();
    markNeedsPaint();
  }

  // Register before painting: the carousel's retained repaint layers can skip
  // our paint entirely when the player moves from the preview into its route.
  void _register() {
    RenderObject? ancestor = _enabled ? parent : null;
    while (ancestor != null && ancestor is! _RenderArtworkPortal) {
      ancestor = ancestor.parent;
    }
    final next = ancestor is _RenderArtworkPortal ? ancestor : null;
    if (identical(next, _portal)) return;
    _unregister();
    _portal = next;
    if (next != null) {
      next.register(this);
    }
    markNeedsPaint();
  }

  void _unregister() {
    final portal = _portal;
    _portal = null;
    portal?.unregister(this);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _register();
  }

  @override
  void performLayout() {
    super.performLayout();
    _register();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final portal = _portal;
    if (portal != null && identical(portal.artwork, this) && portal.lifting) {
      return;
    }
    super.paint(context, offset);
  }

  @override
  void detach() {
    _unregister();
    super.detach();
  }
}
