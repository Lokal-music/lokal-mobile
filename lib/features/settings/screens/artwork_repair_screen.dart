import 'package:flutter/material.dart';

import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/services/artwork_repair_service.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';

/// Repair is user initiated. Leaving this screen requests cancellation so
/// catalogue lookups never continue as an invisible background operation.
class ArtworkRepairScreen extends StatefulWidget {
  const ArtworkRepairScreen({super.key, this.serviceOverride});

  @visibleForTesting
  final ArtworkRepairService? serviceOverride;

  @override
  State<ArtworkRepairScreen> createState() => _ArtworkRepairScreenState();
}

class _ArtworkRepairScreenState extends State<ArtworkRepairScreen>
    with WidgetsBindingObserver {
  late final _service = widget.serviceOverride ?? ArtworkRepairService();
  ArtworkRepairProgress? _progress;
  bool _failed = false;
  bool _stopping = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _stop();
    }
  }

  void _stop() {
    if (_progress?.running != true || _stopping) return;
    _service.cancel();
    setState(() => _stopping = true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _service.cancel();
    _service.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_progress?.running == true) return;
    setState(() {
      _failed = false;
      _stopping = false;
      _progress = const ArtworkRepairProgress(
        total: 0,
        checked: 0,
        updated: 0,
        skipped: 0,
        failed: 0,
        running: true,
      );
    });
    try {
      final result = await _service.refresh(
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      if (mounted) setState(() => _progress = result);
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _progress = null;
        });
      }
    } finally {
      if (mounted) setState(() => _stopping = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.lokal;
    final progress = _progress;
    final busy = progress?.running == true;
    final fraction = progress == null || progress.total == 0
        ? null
        : progress.checked / progress.total;
    return Scaffold(
      backgroundColor: theme.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.only(
            bottom: 40 + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            LokalSettingsHeader(
              title: lokalText('Refresh low-quality covers'),
              subtitle: lokalText('Repair only covers smaller than 640 px.'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Text(
                lokalText(
                  'Lokal looks for larger covers only when the album '
                  'title and album artist match exactly. Manually chosen covers '
                  'and uncertain matches stay unchanged. Updates apply to writable '
                  'music files in your library.',
                ),
                style: TextStyle(color: theme.muted),
              ),
            ),
            if (progress != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                child: LinearProgressIndicator(
                  value: fraction,
                  color: theme.accent,
                  backgroundColor: theme.muted.withValues(alpha: 0.2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _stopping
                        ? lokalText('Stopping after the current operation…')
                        : progress.total == 0 && busy
                        ? lokalText('Checking your library…')
                        : '${lokalText('{checked} / {total} checked · {updated} upgraded · {skipped} skipped · {failed} failed', args: {'checked': progress.checked, 'total': progress.total, 'updated': progress.updated, 'skipped': progress.skipped, 'failed': progress.failed})}${progress.cancelled ? ' · ${lokalText('Stopped')}' : ''}',
                    style: TextStyle(color: theme.muted),
                  ),
                ),
              ),
            ],
            if (_failed)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    lokalText(
                      'Could not refresh covers. Check access and try again.',
                    ),
                    style: TextStyle(color: theme.accent),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: FilledButton.icon(
                onPressed: _stopping
                    ? null
                    : busy
                    ? _stop
                    : _start,
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                icon: Icon(busy ? Icons.stop_circle_outlined : Icons.refresh),
                label: Text(
                  lokalText(
                    _stopping
                        ? 'Stopping…'
                        : busy
                        ? 'Stop refresh'
                        : 'Refresh low-quality covers',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
