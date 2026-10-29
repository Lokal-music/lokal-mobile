import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/manual/data/manual_data.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';

/// Help: every control, explained, in Lokal's settings look, with a search
/// across every entry.
class ManualScreen extends ConsumerStatefulWidget {
  final String? initialSection;

  const ManualScreen({super.key, this.initialSection});

  @override
  ConsumerState<ManualScreen> createState() => _ManualScreenState();
}

class _ManualScreenState extends ConsumerState<ManualScreen> {
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _sectionKeys = {};
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  List<ManualSection> get _sections => manualSections(
    forIos: defaultTargetPlatform == TargetPlatform.iOS,
  );

  @override
  void initState() {
    super.initState();
    for (final s in _sections) {
      _sectionKeys[s.id] = GlobalKey();
    }
    if (widget.initialSection != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSection());
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _scrollToSection() {
    final key = _sectionKeys[widget.initialSection];
    if (key == null) return;
    final ctx = key.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: AppConstants.animationNormal,
      curve: Curves.easeOutCubic,
      alignment: 0.0,
    );
  }

  List<_SearchHit> _searchHits() {
    if (_query.isEmpty) return const [];
    final q = _query.toLowerCase();
    final hits = <_SearchHit>[];
    for (final section in _sections) {
      for (final entry in section.entries) {
        final inTitle = entry.title.toLowerCase().contains(q);
        final inBody = entry.body.toLowerCase().contains(q);
        final inSection = section.title.toLowerCase().contains(q);
        if (inTitle || inBody || inSection) {
          hits.add(_SearchHit(section: section, entry: entry));
        }
      }
    }
    return hits;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final searching = _query.trim().isNotEmpty;
    final hits = searching ? _searchHits() : const <_SearchHit>[];
    return LokalSettingsScaffold(
      title: 'Help',
      subtitle: 'Every control in Lokal, explained.',
      controller: _scrollController,
      children: [
        LokalSettingsBlock(
          top: 12,
          child: LokalSettingsSearchField(
            controller: _searchController,
            hintText: l10n.searchTheManual,
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        if (!searching)
          for (final section in _sections)
            LokalSettingsBlock(
              top: 12,
              child: _ManualSectionCard(
                key: _sectionKeys[section.id],
                section: section,
                initiallyExpanded: widget.initialSection == section.id,
              ),
            )
        else if (hits.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 40, 24, 0),
            child: Text(
              l10n.noMatchesFor(_query),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: t.muted),
            ),
          )
        else
          for (final hit in hits)
            LokalSettingsBlock(
              top: 12,
              child: LokalSettingsCard(
                padding: const EdgeInsets.all(16),
                child: _ManualEntryContent(
                  sectionLabel: hit.section.title,
                  entry: hit.entry,
                ),
              ),
            ),
      ],
    );
  }
}

class _SearchHit {
  final ManualSection section;
  final ManualEntry entry;
  const _SearchHit({required this.section, required this.entry});
}

class _ManualSectionCard extends StatefulWidget {
  final ManualSection section;
  final bool initiallyExpanded;

  const _ManualSectionCard({
    super.key,
    required this.section,
    required this.initiallyExpanded,
  });

  @override
  State<_ManualSectionCard> createState() => _ManualSectionCardState();
}

class _ManualSectionCardState extends State<_ManualSectionCard> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final entries = widget.section.entries;
    return LokalSettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: _expanded,
            child: InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 15,
                ),
                child: Row(
                  children: [
                    Icon(widget.section.icon, size: 20, color: t.accent),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        widget.section.title,
                        style: TextStyle(
                          fontFamily: LokalTheme.sans,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                          color: t.text,
                        ),
                      ),
                    ),
                    Text(
                      '${entries.length}',
                      style: LokalTheme.label(t, size: 11.5),
                    ),
                    const SizedBox(width: 6),
                    AnimatedRotation(
                      turns: _expanded ? 0.25 : 0,
                      duration: AppConstants.animationNormal,
                      child: Icon(
                        Icons.chevron_right_rounded,
                        size: 22,
                        color: t.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: AppConstants.animationNormal,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final entry in entries) ...[
                        const LokalSettingsDivider(),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: _ManualEntryContent(entry: entry),
                        ),
                      ],
                    ],
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

class _ManualEntryContent extends StatelessWidget {
  final ManualEntry entry;
  final String? sectionLabel;

  const _ManualEntryContent({required this.entry, this.sectionLabel});

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (sectionLabel != null) ...[
          Text(sectionLabel!.toUpperCase(), style: LokalTheme.label(t)),
          const SizedBox(height: 6),
        ],
        Text(
          entry.title,
          style: TextStyle(
            fontFamily: LokalTheme.sans,
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: t.text,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          entry.body,
          style: TextStyle(
            fontFamily: LokalTheme.sans,
            fontSize: 13.5,
            color: t.muted,
            height: 1.5,
          ),
        ),
        if (entry.tips != null && entry.tips!.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final tip in entry.tips!)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 6),
                    child: Icon(
                      Icons.lightbulb_outline_rounded,
                      size: 14,
                      color: t.accent,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      tip,
                      style: TextStyle(
                        fontFamily: LokalTheme.sans,
                        fontSize: 12.5,
                        color: t.muted,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}
