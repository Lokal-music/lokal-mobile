import 'package:flutter/material.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/services/playback_source_priority.dart';

/// Override source *lookup* order on cellular only. The normal user-defined
/// priority is neither changed nor written back.
class EcoDataModeToggle extends StatefulWidget {
  const EcoDataModeToggle({super.key});

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
  Widget build(BuildContext context) => Semantics(
    label: lokalText('Eco Data Mode'),
    child: Switch.adaptive(
      value: _enabled,
      onChanged: _busy ? null : _change,
    ),
  );
}
