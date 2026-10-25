import 'package:flutter/material.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';
import 'package:flick/widgets/lokal/lokal_choice_sheet.dart';
import 'package:flick/core/theme/lokal_theme.dart';
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
    GlobalCatalogueSource.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    GlobalCatalogueSource.selected.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _pick() async {
    final picked = await showLokalChoiceSheet<String>(
      context: context,
      title: lokalText('Global search catalogue'),
      selected: GlobalCatalogueSource.selected.value,
      choices: [
        LokalChoice(
          value: GlobalCatalogueSource.apple,
          label: lokalText('Apple Music'),
        ),
        LokalChoice(
          value: GlobalCatalogueSource.spotify,
          label: lokalText('Spotify'),
          description: lokalText(
            'Spotify uses your existing account cookie. If unavailable, Global Search uses Apple Music. Actual playback always follows your source priority.',
          ),
        ),
      ],
    );
    if (picked != null) await GlobalCatalogueSource.set(picked);
  }

  @override
  Widget build(BuildContext context) => LokalSettingRow(
    label: lokalText('Global search catalogue'),
    description: lokalText(
      'Choose the source of Global results; this does not affect playback source priority.',
    ),
    onTap: _pick,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 120),
          child: Text(
            lokalText(
              GlobalCatalogueSource.selected.value ==
                      GlobalCatalogueSource.spotify
                  ? 'Spotify'
                  : 'Apple Music',
            ).toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: LokalTheme.label(
              context.lokal,
              size: 12,
              color: context.lokal.text,
            ),
          ),
        ),
        Icon(Icons.unfold_more_rounded, size: 18, color: context.lokal.muted),
      ],
    ),
  );
}
