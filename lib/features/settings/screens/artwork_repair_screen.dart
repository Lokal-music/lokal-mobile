import 'package:flutter/material.dart';

import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/services/artwork_repair_service.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';

/// Repair is user initiated. Leaving this screen requests cancellation so
/// catalogue lookups never continue as an invisible background operation.
class ArtworkRepairScreen extends StatefulWidget {
  const ArtworkRepairScreen({super.key});

  @override
  State<ArtworkRepairScreen> createState() => _ArtworkRepairScreenState();
}

class _ArtworkRepairScreenState extends State<ArtworkRepairScreen> {
  final _service = ArtworkRepairService();
  ArtworkRepairProgress? _progress;
  String? _error;

  @override
  void dispose() {
    _service.cancel();
    _service.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_progress?.running == true) return;
    setState(() {
      _error = null;
      _progress = const ArtworkRepairProgress(
        total: 0, checked: 0, updated: 0, skipped: 0, failed: 0, running: true,
      );
    });
    try {
      await _service.refresh(onProgress: (value) {
        if (mounted) setState(() => _progress = value);
      });
    } catch (error) {
      if (mounted) setState(() {
        _error = 'Could not refresh covers: $error';
        _progress = null;
      });
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
            const LokalSettingsHeader(
              title: 'Refresh low-quality covers',
              subtitle: 'Repair only covers smaller than 640 px.',
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Text(
                'Lokal checks your library artwork and looks for a larger '
                'image only when the album title and album artist match '
                'exactly. Manually chosen covers and uncertain matches stay '
                'untouched. The refresh updates your saved audio files where '
                'Android grants write access.',
                style: TextStyle(color: theme.muted),
              ),
            ),
            if (progress != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: LinearProgressIndicator(
                  value: fraction,
                  color: theme.accent,
                  backgroundColor: theme.muted.withValues(alpha: 0.2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  '${progress.checked} / ${progress.total} checked · '
                  '${progress.updated} upgraded · '
                  '${progress.skipped} skipped · ${progress.failed} failed'
                  '${progress.cancelled ? ' · stopped' : ''}',
                  style: TextStyle(color: theme.muted),
                ),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(_error!, style: TextStyle(color: theme.accent)),
              ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: FilledButton.icon(
                onPressed: busy ? _service.cancel : _start,
                icon: Icon(busy ? Icons.stop_circle_outlined : Icons.refresh),
                label: Text(busy ? 'Stop refresh' : 'Refresh low-quality covers'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
