import 'package:flutter/material.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/core/utils/app_haptics.dart';

import '../models/search_category.dart';
import '../providers/search_filter_provider.dart';

import 'package:flick/l10n/l10n.dart';

/// Source and result type are separate single-choice controls. Selecting a
/// category isolates it immediately without an All state.
class SearchFilterChips extends StatelessWidget {
  const SearchFilterChips({
    super.key,
    required this.enabled,
    required this.onToggle,
    required this.scope,
    required this.onScopeChanged,
    this.counts,
    this.query = '',
  });
  final Set<SearchCategory> enabled;
  final ValueChanged<SearchCategory> onToggle;
  final SearchScope scope;
  final ValueChanged<SearchScope> onScopeChanged;
  final Map<SearchCategory, int>? counts;
  final String query;
  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<SearchScope>(
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              textStyle: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(fontSize: 12),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            ),
            segments: [
              ButtonSegment(
                value: SearchScope.library,
                label: Text(lokalText('Library')),
              ),
              ButtonSegment(
                value: SearchScope.online,
                label: Text(lokalText('Online')),
              ),
            ],
            selected: {scope},
            onSelectionChanged: (value) {
              AppHaptics.tap();
              onScopeChanged(value.single);
            },
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final category in SearchCategory.values)
                if (scope != SearchScope.online ||
                    supportsOnlineCategory(category))
                  _chip(
                    context,
                    category.label,
                    enabled.contains(category),
                    () => onToggle(category),
                    count:
                        scope == SearchScope.library && query.trim().isNotEmpty
                        ? (counts ?? const <SearchCategory, int>{})[category]
                        : null,
                  ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 16, 0),
          child: Text(
            scope == SearchScope.online
                ? lokalText('Search online catalogues and playback sources')
                : !supportsOnlineCategory(enabled.singleOrNull)
                ? lokalText('This category searches your library')
                : lokalText('Choose a result type'),
            style: TextStyle(color: t.muted, fontSize: 11),
          ),
        ),
      ],
    );
  }

  Widget _chip(
    BuildContext context,
    String label,
    bool selected,
    VoidCallback tap, {
    int? count,
  }) {
    final t = context.lokal;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label),
            if (count != null) ...[
              const SizedBox(width: 6),
              Text('$count', style: TextStyle(color: t.muted)),
            ],
          ],
        ),
        selected: selected,
        showCheckmark: false,
        selectedColor: t.accent.withValues(alpha: .18),
        labelStyle: TextStyle(
          color: selected ? t.accent : t.text,
          fontSize: 12,
        ),
        onSelected: (_) {
          AppHaptics.tap();
          tap();
        },
      ),
    );
  }
}
