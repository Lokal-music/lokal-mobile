import 'package:flick/l10n/l10n.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';

import 'groups/about_group.dart';
import 'groups/appearance_group.dart';
import 'groups/data_group.dart';
import 'groups/online_sources_group.dart';
import 'groups/library_group.dart';
import 'groups/playback_group.dart';
import 'lokal_settings_group.dart';

/// Builds a group's sections; see [lokalSettingsSections].
typedef LokalSettingsSectionsBuilder = List<LokalSettingsSection> Function(
  LokalSettingsGroup group,
  BuildContext context,
  WidgetRef ref,
);

/// The sections of [group], built from the providers they show.
///
/// Called inside a build, so rows can watch providers through [ref].
List<LokalSettingsSection> lokalSettingsSections(
  LokalSettingsGroup group,
  BuildContext context,
  WidgetRef ref,
) => switch (group) {
  LokalSettingsGroup.integrations => onlineSourcesSettings(context, ref),
  LokalSettingsGroup.playback => playbackSettings(context, ref),
  LokalSettingsGroup.output => outputSettings(context, ref),
  LokalSettingsGroup.library => librarySettings(context, ref),
  // Add-ons is a section of Online sources, found there.
  LokalSettingsGroup.addons => const [],
  LokalSettingsGroup.appearance => appearanceSettings(context, ref),
  LokalSettingsGroup.themeAccent => themeAccentSettings(context, ref),
  LokalSettingsGroup.data => dataSettings(context, ref),
  LokalSettingsGroup.about => aboutSettings(context, ref),
};

/// The page for [group] (the Settings page itself when `null`), scrolled to
/// [section].
Widget lokalSettingsPage({
  LokalSettingsGroup? group,
  String? section,
  bool aboutDataOnly = false,
}) {
  if (aboutDataOnly) return const LokalSettingsAboutDataPage();
  if (group == null) return const LokalSettingsPage();
  // Follow older account links after moving connections into Data.
  if ((group == LokalSettingsGroup.integrations ||
          group == LokalSettingsGroup.data) &&
      LokalDataSections.accountAliases.contains(section?.toLowerCase())) {
    return const LokalSettingsGroupPage(
      group: LokalSettingsGroup.data,
      section: LokalDataSections.accounts,
    );
  }
  // Add-ons are part of Online sources: open it at them.
  if (group == LokalSettingsGroup.addons) {
    return LokalSettingsGroupPage(
      group: LokalSettingsGroup.integrations,
      section: section ?? LokalOnlineSections.addons,
    );
  }
  return LokalSettingsGroupPage(group: group, section: section);
}

/// The route every way into Settings uses, named `/konnekted/settings`.
Route<void> lokalSettingsRoute(
  BuildContext context, {
  LokalSettingsGroup? group,
  String? section,
  bool aboutDataOnly = false,
}) {
  final duration = MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : AppConstants.animationNormal;
  return PageRouteBuilder<void>(
    settings: const RouteSettings(name: '/konnekted/settings'),
    transitionDuration: duration,
    reverseTransitionDuration: duration,
    pageBuilder: (context, _, _) => lokalSettingsPage(
      group: group,
      section: section,
      aboutDataOnly: aboutDataOnly,
    ),
    transitionsBuilder: (_, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  );
}

/// Opens Settings, at [group] and [section] when given.
Future<void> openLokalSettings(
  BuildContext context, {
  LokalSettingsGroup? group,
  String? section,
}) =>
    Navigator.of(context)
        .push(lokalSettingsRoute(context, group: group, section: section));

/// Settings: a large title, a search field that filters every row of every
/// group by label and description, and the groups.
/// About and Data are combined here so the You-page wheel opens every
/// section on one fully expanded page rather than an intermediate group list.
class LokalSettingsAboutDataPage extends ConsumerWidget {
  const LokalSettingsAboutDataPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => LokalSettingsScaffold(
    title: lokalText('About & Data'),
    children: [...aboutSettings(context, ref), ...dataSettings(context, ref)],
  );
}

class LokalSettingsPage extends ConsumerStatefulWidget {
  const LokalSettingsPage({super.key, this.sectionsBuilder});

  /// Replaces [lokalSettingsSections], for tests.
  @visibleForTesting
  final LokalSettingsSectionsBuilder? sectionsBuilder;

  @override
  ConsumerState<LokalSettingsPage> createState() => _LokalSettingsPageState();
}

class _LokalSettingsPageState extends ConsumerState<LokalSettingsPage> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Widget> _results(BuildContext context, WidgetRef activeRef) {
    final results = <Widget>[];
    for (final group in LokalSettingsGroup.values) {
      if (group == LokalSettingsGroup.themeAccent) continue;
      final build = widget.sectionsBuilder ?? lokalSettingsSections;
      for (final section in build(group, context, activeRef)) {
        final heading = section.title == group.label
            ? group.label
            : '${group.label} · ${section.title}';
        final match = section.filtered(_query, heading: heading);
        if (match != null) results.add(match);
      }
    }
    // A group's own name finds the group, as a link.
    final groups = [
      for (final group in LokalSettingsGroup.listed)
        if (lokalSettingsMatch('${group.label} ${group.description}', _query))
          _GroupLink(group: group),
    ];
    if (groups.isNotEmpty) {
      results.insert(
        0,
        LokalSettingsSection(title: lokalText('Groups'), children: groups),
      );
    }
    return results;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final searching = _query.trim().isNotEmpty;
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          // Only search shows the player's switches here.
          listenable: searching && widget.sectionsBuilder == null
              ? lokalSettingsListenable(ref)
              : const _Never(),
          builder: (context, _) => Consumer(
            // The filtered sections watch Riverpod providers. Build them inside
            // a Consumer rather than from a notifier listener's callback so
            // WidgetRef.watch always runs in an active provider build.
            builder: (context, liveRef, _) {
              final results = searching
                  ? _results(context, liveRef)
                  : const <Widget>[];
              return ListView(
                key: const PageStorageKey('lokal-settings'),
                padding: EdgeInsets.only(
                  bottom: 32 + MediaQuery.paddingOf(context).bottom,
                ),
                children: [
                  LokalSettingsHeader(title: lokalText('Settings')),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: LokalSettingsSearchField(
                      controller: _search,
                      onChanged: (value) => setState(() => _query = value),
                    ),
                  ),
                  if (!searching)
                    LokalSettingsSection(
                      title: lokalText('Settings'),
                      heading: 'Groups',
                      children: [
                        for (final group in LokalSettingsGroup.listed)
                          _GroupLink(group: group),
                      ],
                    )
                  else if (results.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 40, 24, 0),
                      child: Text(
                        lokalText('No settings match your search.'),
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: t.muted),
                      ),
                    )
                  else
                    ...results,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Never extends Listenable {
  const _Never();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

class _GroupLink extends StatelessWidget implements LokalSearchable {
  const _GroupLink({required this.group});

  final LokalSettingsGroup group;

  @override
  String get searchText => '${group.label} ${group.description}';

  @override
  Widget build(BuildContext context) => LokalSettingLink(
    label: group.label,
    description: group.description,
    icon: group.icon,
    onTap: () => unawaited(openLokalSettings(context, group: group)),
  );
}

/// One group: a large title and its sections on one scrolling page.
class LokalSettingsGroupPage extends ConsumerStatefulWidget {
  const LokalSettingsGroupPage({
    super.key,
    required this.group,
    this.section,
    this.sectionsBuilder,
  });

  final LokalSettingsGroup group;

  /// Replaces [lokalSettingsSections], for tests.
  @visibleForTesting
  final LokalSettingsSectionsBuilder? sectionsBuilder;

  /// The title of the section to scroll to.
  final String? section;

  @override
  ConsumerState<LokalSettingsGroupPage> createState() =>
      _LokalSettingsGroupPageState();
}

/// The groups that show the player's own switches.
const _playerGroups = {LokalSettingsGroup.playback, LokalSettingsGroup.output};

class _LokalSettingsGroupPageState
    extends ConsumerState<LokalSettingsGroupPage> {
  final _target = GlobalKey();

  @override
  void initState() {
    super.initState();
    if (widget.section != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _target.currentContext;
        if (target != null && target.mounted) {
          unawaited(
            Scrollable.ensureVisible(
              target,
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
            ),
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final asked = widget.section?.toLowerCase();
    // Older links name sections that moved; follow them.
    final wanted = widget.group == LokalSettingsGroup.integrations
        ? (LokalOnlineSections.aliases[asked]?.toLowerCase() ?? asked)
        : asked;
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable:
              widget.sectionsBuilder == null &&
                  _playerGroups.contains(widget.group)
              ? lokalSettingsListenable(ref)
              : const _Never(),
          builder: (context, _) {
            final build = widget.sectionsBuilder ?? lokalSettingsSections;
            final sections = build(widget.group, context, ref);
            return SingleChildScrollView(
              padding: EdgeInsets.only(
                bottom: 32 + MediaQuery.paddingOf(context).bottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LokalSettingsHeader(
                    title: widget.group.label,
                    subtitle: widget.group.description,
                  ),
                  for (final section in sections)
                    if (wanted != null && section.title.toLowerCase() == wanted)
                      KeyedSubtree(key: _target, child: section)
                    else
                      section,
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
