import 'package:flutter/material.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/services/global_catalogue_source.dart';

/// Only determines where Global Search gets its metadata. No change to the
/// user's configured music playback sources or stored Spotify cookie.
class GlobalCatalogueSelector extends StatefulWidget {
  const GlobalCatalogueSelector({super.key});

  @override
  State<GlobalCatalogueSelector> createState() =>
      _GlobalCatalogueSelectorState();
}

class _GlobalCatalogueSelectorState extends State<GlobalCatalogueSelector> {
  @override
  void initState() {
    super.initState();
    GlobalCatalogueSource.selected.addListener(_refresh);
    GlobalCatalogueSource.load().then((_) { if (mounted) setState(() {}); });
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    GlobalCatalogueSource.selected.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: GlobalCatalogueSource.apple,
              label: Text(lokalText('Apple Music'))),
            ButtonSegment(value: GlobalCatalogueSource.spotify,
              label: Text(lokalText('Spotify'))),
          ],
          selected: {GlobalCatalogueSource.selected.value},
          onSelectionChanged: (values) =>
              GlobalCatalogueSource.set(values.single),
        ),
        const SizedBox(height: 6),
        Text(
          lokalText('Spotify uses your existing account cookie. If unavailable, Global Search uses Apple Music. Actual playback always follows your source priority.'),
          style: TextStyle(fontSize: 12, color: t.muted),
        ),
      ],
    );
  }
}
