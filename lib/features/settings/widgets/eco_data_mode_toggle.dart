import 'package:flutter/material.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/services/playback_source_priority.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';

/// Eco Data Mode appears as a regular, accessible Lokal settings row instead
/// of an isolated Android switch. The stored preference and cellular-only
/// source-priority behavior are unchanged.
class EcoDataModeToggle extends StatefulWidget implements LokalSearchable {
  const EcoDataModeToggle({super.key});

  static const label = 'Eco Data Mode';
  static const description =
      'On mobile data, try YouTube Music and SoundCloud before lossless sources. '
      'Uses your normal order on Wi-Fi and for manually selected sources.';

  @override
  String get searchText => '$label $description mobile cellular bandwidth';

  @override
  State<EcoDataModeToggle> createState() => _EcoDataModeToggleState();
}

class _EcoDataModeToggleState extends State<EcoDataModeToggle> {
  bool _enabled = false;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final enabled = await EcoDataMode.enabled();
      if (mounted) setState(() { _enabled = enabled; _busy = false; });
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _change(bool value) async {
    if (_busy) return;
    setState(() { _busy = true; _enabled = value; });
    try {
      await EcoDataMode.setEnabled(value);
    } catch (_) {
      if (mounted) setState(() => _enabled = !value);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => LokalSettingRow(
    key: const ValueKey('eco-data-mode-row'),
    label: lokalText(EcoDataModeToggle.label),
    description: lokalText(EcoDataModeToggle.description),
    toggled: _enabled,
    enabled: !_busy,
    trailing: LokalOnOffPill(value: _enabled),
    onTap: _busy ? null : () => _change(!_enabled),
  );
}
