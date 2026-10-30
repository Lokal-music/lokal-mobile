import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:http/http.dart' as http;
import 'package:flick/l10n/l10n.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flick/services/playback_source_priority.dart';

class PlaybackSourcePriorityPanel extends StatefulWidget {
  const PlaybackSourcePriorityPanel({super.key, this.sourcesLoader});

  /// Allows widget tests to supply an offline, deterministic source list.
  @visibleForTesting
  final Future<List<OnlineSource>> Function(http.Client client)? sourcesLoader;

  @override
  State<PlaybackSourcePriorityPanel> createState() =>
      _PlaybackSourcePriorityPanelState();
}

class _PlaybackSourcePriorityPanelState
    extends State<PlaybackSourcePriorityPanel> {
  final _client = http.Client();
  List<OnlineSource> _sources = [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sources = await (widget.sourcesLoader?.call(_client) ??
          onlineSources(_client));
      if (mounted) setState(() => _sources = sources);
    } catch (_) {
      if (mounted) {
        setState(() =>
            _error = lokalText('Could not load playback sources. Try again.'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Flutter reports a pre-removal drop index. Show the new order immediately
  /// so the row does not snap back while its preference is being persisted.
  void _reorder(int from, int to) {
    if (_busy || from < 0 || from >= _sources.length ||
        to < 0 || to > _sources.length) return;
    final target = to > from ? to - 1 : to;
    if (target == from) return;
    final before = [..._sources];
    final after = [...before];
    after.insert(target, after.removeAt(from));
    setState(() {
      _sources = after;
      _busy = true;
      _error = null;
    });
    unawaited(_saveReorder(before, from, to));
  }

  Future<void> _saveReorder(List<OnlineSource> before, int from, int to) async {
    try {
      await PlaybackSourcePriority.reorder(
        before.map((source) => source.id).toList(),
        from,
        to,
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _sources = before;
          _error = lokalText('Could not save source priority. Try again.');
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (_busy) const LinearProgressIndicator(),
      if (_sources.length > 1)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            lokalText('Touch and hold a source to drag it, or drag its handle.'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      if (_sources.isNotEmpty)
        // A bounded inner viewport lets the drag auto-scroll over long lists,
        // rather than fighting the parent Settings scroll view for gestures.
        SizedBox(
          height: (_sources.length * 88.0).clamp(0.0, 420.0),
          child: ReorderableListView.builder(
            key: const ValueKey('playback-source-reorder-list'),
            itemCount: _sources.length,
            buildDefaultDragHandles: false,
            padding: EdgeInsets.zero,
            autoScrollerVelocityScalar: 12,
            onReorder: _reorder,
            onReorderStart: (_) => HapticFeedback.selectionClick(),
            onReorderEnd: (_) => HapticFeedback.lightImpact(),
            proxyDecorator: (child, index, animation) => AnimatedBuilder(
              animation: animation,
              builder: (context, child) => Material(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                elevation: 6.0 * Curves.easeOut.transform(animation.value),
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: child,
              ),
              child: child,
            ),
            itemBuilder: (context, index) {
              final source = _sources[index];
              return ReorderableDelayedDragStartListener(
                key: ValueKey('playback-source-${source.id}'),
                index: index,
                enabled: !_busy,
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  minLeadingWidth: 24,
                  horizontalTitleGap: 12,
                  leading: SizedBox(
                    width: 24,
                    child: Text(
                      '${index + 1}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: context.lokal.muted,
                        fontSize: 13,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  title: Text(source.name),
                  subtitle: source.needsVerification?.call() == true
                      ? Text(lokalText('Needs verification'))
                      : null,
                  trailing: Tooltip(
                    message: lokalText('Drag to reorder'),
                    child: ReorderableDragStartListener(
                      index: index,
                      enabled: !_busy,
                      child: const Padding(
                        padding: EdgeInsets.all(10),
                        child: Icon(Icons.drag_indicator_rounded),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      TextButton.icon(
        onPressed: _busy ? null : _load,
        icon: const Icon(Icons.refresh_rounded),
        label: Text(lokalText('Refresh sources')),
      ),
    ],
  );
}
