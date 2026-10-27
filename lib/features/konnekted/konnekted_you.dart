import 'package:flick/l10n/l10n.dart';

import '../link/lokal_devices_card.dart';

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:flick/services/you_profile_service.dart';

import 'package:flick/providers/lokal_remote_provider.dart';

import 'package:flick/widgets/common/overflow_marquee_title.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/data/repositories/recently_played_repository.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flick/features/milestone/screens/milestones_screen.dart';
import 'package:flick/features/recap/screens/listening_recap_screen.dart';
import 'package:flick/features/settings/lokal/lokal_settings_group.dart';
import 'package:flick/features/whats_new/widgets/whats_new_bottom_sheet.dart';
import 'package:flick/providers/app_preferences_provider.dart';
import 'package:flick/providers/lastfm_provider.dart';
import 'package:flick/providers/listenbrainz_provider.dart';
import 'package:flick/providers/milestone_provider.dart';
import 'package:flick/services/milestone_service.dart';
import 'package:flick/widgets/lokal/lokal_glass.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'konnekted_data.dart';
import 'konnekted_destination.dart';
import 'konnekted_style.dart';

/// The recaps You shows: this week, this month and this year, rebuilt as
/// plays are recorded.
final youRecapsProvider =
    StreamProvider<Map<ListeningRecapPeriod, ListeningRecap>>((ref) {
      final repository = ref.watch(konnektedHistoryRepositoryProvider);
      final changes = StreamController<void>();
      final subscription = repository.watchHistory().listen(
        changes.add,
        onError: changes.addError,
      );
      changes.add(null);
      ref.onDispose(() {
        unawaited(subscription.cancel());
        unawaited(changes.close());
      });
      return changes.stream.asyncMap(
        (_) => repository.getListeningRecaps(periods: youRecapPeriods),
      );
    });

/// The periods You's recap cards and stats offer, in order.
const youRecapPeriods = [
  ListeningRecapPeriod.weekly,
  ListeningRecapPeriod.monthly,
  ListeningRecapPeriod.yearly,
];

/// Your day streak, or `null` when streaks are turned off.
final youStreakProvider = FutureProvider.autoDispose<int?>((ref) async {
  ref.watch(milestoneRevisionProvider);
  if (!ref.watch(appPreferencesProvider.select((p) => p.streaksEnabled))) {
    return null;
  }
  return ref.watch(milestoneServiceProvider).getCurrentDayStreak();
});

/// The milestones you have unlocked, newest first.
final youMilestonesProvider = FutureProvider.autoDispose<List<MilestoneRecord>>(
  (ref) async {
    ref.watch(milestoneRevisionProvider);
    final records = await ref
        .watch(milestoneServiceProvider)
        .getShownMilestones();
    return records.toList()
      ..sort((a, b) => b.achievedAt.compareTo(a.achievedAt));
  },
);

/// Which accounts are connected, from each one's saved session.
@immutable
class YouAccounts {
  const YouAccounts({
    this.lastFm,
    this.listenBrainz,
    this.youtubeMusic = false,
  });

  /// The Last.fm username; `null` when not connected.
  final String? lastFm;

  /// The ListenBrainz username; `null` when not connected.
  final String? listenBrainz;

  final bool youtubeMusic;

  /// The name You greets you by: an account's username, else "You".
  String get name {
    for (final user in [lastFm, listenBrainz]) {
      final trimmed = user?.trim() ?? '';
      if (trimmed.isNotEmpty) return trimmed;
    }
    return 'You';
  }
}

final youAccountsProvider = Provider.autoDispose<YouAccounts>(
  (ref) => YouAccounts(
    lastFm: ref.watch(lastFmSessionProvider).value?.username,
    listenBrainz: ref.watch(listenbrainzSessionProvider).value?.username,
    youtubeMusic:
        ref.watch(konnektedYoutubeMusicSessionProvider).value?.signedIn == true,
  ),
);

/// A mobile-only identity override. Desktop and provider account data remain
/// unchanged; clearing either field falls back to the linked profile.
final youProfileServiceProvider = Provider<YouProfileService>(
  (ref) => YouProfileService(),
);

final localYouProfileProvider = FutureProvider<LocalYouProfile>(
  (ref) => ref.watch(youProfileServiceProvider).load(),
);

const _accountsSection = KonnektedDestination.settingsAt(
  LokalSettingsGroup.data,
  section: LokalDataSections.accounts,
);
const _scrobblingSection = KonnektedDestination.settingsAt(
  LokalSettingsGroup.data,
  section: LokalDataSections.accounts,
);

String _periodLabel(ListeningRecapPeriod period) => switch (period) {
  ListeningRecapPeriod.daily => 'Today',
  ListeningRecapPeriod.weekly => 'Week',
  ListeningRecapPeriod.monthly => 'Month',
  ListeningRecapPeriod.yearly => 'Year',
};

String _count(int value) {
  final digits = value.toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// The You tab: you and your listening. A header with your name, this
/// week's minutes, your streak and a gear for Settings; recaps; stats;
/// milestones; accounts; and links to Settings, What's new, Help and About.
class KonnektedYou extends ConsumerStatefulWidget {
  const KonnektedYou({super.key, required this.onNavigate});

  final ValueChanged<KonnektedDestination> onNavigate;

  @override
  ConsumerState<KonnektedYou> createState() => _KonnektedYouState();
}

class _KonnektedYouState extends ConsumerState<KonnektedYou> {
  ListeningRecapPeriod _statsPeriod = ListeningRecapPeriod.weekly;

  void _push(Widget page) => unawaited(
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)),
  );

  void _openRecap(ListeningRecapPeriod period) =>
      _push(ListeningRecapScreen(initialPeriod: period));

  Future<void> _editProfile() async {
    try {
      final existing = await ref.read(localYouProfileProvider.future);
      if (!mounted) return;
      final profile = ref.read(linkedDesktopProfileProvider).value;
      final defaultName = profile?.displayName.trim().isNotEmpty == true
          ? profile!.displayName
          : profile?.username.trim().isNotEmpty == true
              ? profile!.username
              : ref.read(youAccountsProvider).name;
      final service = ref.read(youProfileServiceProvider);
      final saved = await showModalBottomSheet<bool>(
        context: context,
        // The tab navigator is below the persistent miniplayer/dock.
        useRootNavigator: true,
        useSafeArea: true,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => _YouProfileEditor(
          service: service,
          profile: existing,
          defaultName: defaultName,
          linkedAvatarPath: profile?.avatarPath,
        ),
      );
      if (saved == true && mounted) ref.invalidate(localYouProfileProvider);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Could not open profile editor.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final recaps = ref.watch(youRecapsProvider).value ?? const {};
    final accounts = ref.watch(youAccountsProvider);
    final profile = ref.watch(linkedDesktopProfileProvider).value;
    final local = ref.watch(localYouProfileProvider).value;
    final defaultName = profile?.displayName.trim().isNotEmpty == true
        ? profile!.displayName
        : profile?.username.trim().isNotEmpty == true
            ? profile!.username
            : accounts.name;
    final name = local?.username ?? defaultName;
    final streak = ref.watch(youStreakProvider).value;
    final milestones =
        ref.watch(youMilestonesProvider).value ?? const <MilestoneRecord>[];
    final navigate = widget.onNavigate;
    return SafeArea(
      bottom: false,
      child: ListView(
        key: const PageStorageKey('konnekted-you'),
        padding: EdgeInsets.only(
          bottom: 28 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          _YouHeader(
            name: name,
            avatarPath: local?.avatarPath ?? profile?.avatarPath,
            username: local?.username ?? profile?.username,
            onEdit: _editProfile,
            weekMinutes: recaps[ListeningRecapPeriod.weekly]
                ?.totalListeningTime
                .inMinutes,
            streak: streak,
            onSettings: () => navigate(KonnektedDestination.settings),
          ),
          const LokalDevicesCard(),
          _Label(lokalText('Recap')),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              lokalText(
                'Your week, month and year in music. Tap one for the story.',
              ),
              style: TextStyle(fontSize: 13, color: context.lokal.muted),
            ),
          ),
          SizedBox(
            height: 136,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: youRecapPeriods.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final period = youRecapPeriods[i];
                return _RecapCard(
                  period: period,
                  recap: recaps[period],
                  onTap: () => _openRecap(period),
                );
              },
            ),
          ),
          _StatsSection(
            period: _statsPeriod,
            recap: recaps[_statsPeriod],
            onPeriod: (period) => setState(() => _statsPeriod = period),
            onHistory: () => navigate(KonnektedDestination.recentlyPlayed),
          ),
          _MilestonesSection(
            milestones: milestones,
            onOpen: () => _push(const MilestonesScreen()),
          ),
          _Label(lokalText('Accounts')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _AccountChip(
                  label: lokalText('Last.fm'),
                  connected: accounts.lastFm != null,
                  onTap: () => navigate(_scrobblingSection),
                ),
                _AccountChip(
                  label: lokalText('ListenBrainz'),
                  connected: accounts.listenBrainz != null,
                  onTap: () => navigate(_scrobblingSection),
                ),
                _AccountChip(
                  label: lokalText('YouTube'),
                  connected: accounts.youtubeMusic,
                  onTap: () => navigate(_accountsSection),
                ),
              ],
            ),
          ),
          LokalSettingsSection(
            title: lokalText('More'),
            children: [
              LokalSettingLink(
                label: lokalText('What’s new'),
                description: lokalText('What changed in this version.'),
                icon: Icons.auto_awesome_rounded,
                onTap: () => unawaited(WhatsNewBottomSheet.show<void>(context)),
              ),
              LokalSettingLink(
                label: lokalText('Help'),
                description: lokalText('Every control, explained.'),
                icon: Icons.help_outline_rounded,
                onTap: () => navigate(
                  const KonnektedDestination.settingsAt(
                    LokalSettingsGroup.about,
                    section: 'Help',
                  ),
                ),
              ),
              LokalSettingLink(
                label: lokalText('About'),
                description: lokalText(
                  'Version, updates, licences and privacy.',
                ),
                icon: Icons.info_outline_rounded,
                onTap: () => navigate(
                  const KonnektedDestination.settingsAt(
                    LokalSettingsGroup.about,
                    section: 'About',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A DM Mono section title, like the settings kit's.
class _Label extends StatelessWidget {
  const _Label(this.text, {this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 22, 16, 10),
    child: Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              text.toUpperCase(),
              style: LokalTheme.label(context.lokal),
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class _YouHeader extends StatelessWidget {
  const _YouHeader({
    required this.name,
    required this.weekMinutes,
    required this.streak,
    required this.onSettings,
    required this.onEdit,
    this.avatarPath,
    this.username,
  });

  final String name;
  final String? avatarPath;
  final String? username;
  final int? weekMinutes;
  final int? streak;
  final VoidCallback onSettings;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final initial = name.characters.first.toUpperCase();
    return Padding(
      padding: konnektedTopBarPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 44,
            child: Row(
              children: [
                SizedBox.square(
                  dimension: 44,
                  child: Semantics(
                    label: 'Edit profile photo',
                    button: true,
                    onTap: onEdit,
                    excludeSemantics: true,
                    child: InkWell(
                      onTap: onEdit,
                      customBorder: const CircleBorder(),
                      child: Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [t.accent, t.accentDim],
                          ),
                        ),
                        child: avatarPath != null
                            ? ClipOval(
                                child: Image.file(
                                  File(avatarPath!),
                                  width: 44,
                                  height: 44,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => Text(
                                    initial,
                                    style: TextStyle(color: t.bg, fontSize: 20),
                                  ),
                                ),
                              )
                            : Text(
                                initial,
                                style: TextStyle(
                                  fontFamily: LokalTheme.sans,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  color: t.bg,
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Semantics(
                    header: true,
                    label: name,
                    child: ExcludeSemantics(
                      child: OverflowMarqueeTitle(
                        key: ValueKey('you-header-name:$name'),
                        title: name,
                        style: TextStyle(
                          fontFamily: LokalTheme.sans,
                          fontSize: 22,
                          height: 1.1,
                          letterSpacing: -.7,
                          fontWeight: FontWeight.w800,
                          color: t.text,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                KonnektedHeaderActions(
                  onEditProfile: onEdit,
                  onSettings: onSettings,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _HeaderStat(
                  value: weekMinutes == null ? '—' : _count(weekMinutes!),
                  label: lokalText('Minutes this week'),
                ),
              ),
              if (streak != null) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: _HeaderStat(
                    value: _count(streak!),
                    label: lokalText('Day streak'),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}


/// A small on-device editor. Photos are copied out of the gallery picker
/// cache by YouProfileService; leaving the username empty restores the linked
/// account/desktop name rather than changing a remote account.
class _YouProfileEditor extends StatefulWidget {
  const _YouProfileEditor({
    required this.service,
    required this.profile,
    required this.defaultName,
    required this.linkedAvatarPath,
  });

  final YouProfileService service;
  final LocalYouProfile profile;
  final String defaultName;
  final String? linkedAvatarPath;

  @override
  State<_YouProfileEditor> createState() => _YouProfileEditorState();
}

class _YouProfileEditorState extends State<_YouProfileEditor> {
  late final TextEditingController _username = TextEditingController(
    text: widget.profile.username ?? '',
  );
  Uint8List? _pickedPhoto;
  bool _removePhoto = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    if (_saving) return;
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      if (bytes.isEmpty || bytes.length > 12 * 1024 * 1024) {
        setState(() => _error = 'Choose a photo smaller than 12 MB.');
        return;
      }
      setState(() {
        _pickedPhoto = bytes;
        _removePhoto = false;
        _error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not open that photo.');
      }
    }
  }

  void _removePicture() {
    setState(() {
      _pickedPhoto = null;
      _removePhoto = true;
      _error = null;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.service.save(
        username: _username.text,
        avatarBytes: _pickedPhoto,
        removeAvatar: _removePhoto,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error is FormatException
              ? error.message
              : 'Could not save profile. Try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final initialName = _username.text.trim().isEmpty
        ? widget.defaultName
        : _username.text.trim();
    final initial = initialName.isNotEmpty
        ? initialName.characters.first.toUpperCase() : 'Y';
    final path = _removePhoto
        ? widget.linkedAvatarPath
        : widget.profile.avatarPath ?? widget.linkedAvatarPath;
    Widget photo;
    if (_pickedPhoto != null) {
      photo = Image.memory(_pickedPhoto!, width: 86, height: 86, fit: BoxFit.cover);
    } else if (path != null) {
      photo = Image.file(
        File(path), width: 86, height: 86, fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Center(
          child: Text(initial, style: TextStyle(fontSize: 34, color: t.bg)),
        ),
      );
    } else {
      photo = Center(
        child: Text(initial, style: TextStyle(fontSize: 34, color: t.bg)),
      );
    }
    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Edit profile', style: TextStyle(
                fontSize: 23, fontWeight: FontWeight.w700, color: t.text,
              )),
              const SizedBox(height: 6),
              Text('This profile belongs to your phone. Linked accounts are not renamed.',
                style: TextStyle(color: t.muted, fontSize: 13)),
              const SizedBox(height: 18),
              Center(
                child: ClipOval(
                  child: Container(
                    color: t.accent, width: 86, height: 86, child: photo,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: _saving ? null : _pickPhoto,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Choose photo'),
                  ),
                  if (path != null || _pickedPhoto != null)
                    TextButton(
                      onPressed: _saving ? null : _removePicture,
                      child: const Text('Reset photo'),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _username,
                maxLength: 40,
                textCapitalization: TextCapitalization.none,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _save(),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Username',
                  hintText: widget.defaultName,
                  helperText: 'Leave empty to use your connected account name.',
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!, style: TextStyle(color: t.orange)),
                ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 12,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? 'Saving…' : 'Save profile'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderStat extends StatelessWidget {
  const _HeaderStat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return MergeSemantics(
      child: LokalGlass(
        borderRadius: const BorderRadius.all(Radius.circular(18)),
        thickness: LokalGlassThickness.thin,
        shadow: false,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: TextStyle(
                fontFamily: LokalTheme.sans,
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: t.text,
              ),
            ),
            const SizedBox(height: 2),
            Text(label.toUpperCase(), style: LokalTheme.label(t, size: 10)),
          ],
        ),
      ),
    );
  }
}

class _RecapCard extends StatelessWidget {
  const _RecapCard({
    required this.period,
    required this.recap,
    required this.onTap,
  });

  final ListeningRecapPeriod period;
  final ListeningRecap? recap;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final recap = this.recap;
    final has = recap?.hasData ?? false;
    final headline = has
        ? '${_count(recap!.totalListeningTime.inMinutes)} min'
        : 'Nothing yet';
    final detail = has
        ? (recap!.topArtist?.artist ?? '${_count(recap.totalPlays)} plays')
        : 'Play a few songs';
    return Semantics(
      button: true,
      label: lokalText(
        "{arg0} recap. {arg1}. {arg2}",
        args: {'arg0': _periodLabel(period), 'arg1': headline, 'arg2': detail},
      ),
      excludeSemantics: true,
      child: SizedBox(
        width: 156,
        child: LokalGlass(
          borderRadius: const BorderRadius.all(Radius.circular(20)),
          thickness: LokalGlassThickness.thin,
          shadow: false,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _periodLabel(period).toUpperCase(),
                            style: LokalTheme.label(t, color: t.accent),
                          ),
                        ),
                        Icon(
                          Icons.play_circle_fill_rounded,
                          size: 20,
                          color: t.accent,
                        ),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      headline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: LokalTheme.sans,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: t.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: t.muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatsSection extends StatelessWidget {
  const _StatsSection({
    required this.period,
    required this.recap,
    required this.onPeriod,
    required this.onHistory,
  });

  final ListeningRecapPeriod period;
  final ListeningRecap? recap;
  final ValueChanged<ListeningRecapPeriod> onPeriod;
  final VoidCallback onHistory;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final recap = this.recap;
    final has = recap?.hasData ?? false;
    final peak = recap?.peakHour;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Label(
          lokalText('Stats'),
          trailing: LokalSegmented<ListeningRecapPeriod>(
            segments: [
              for (final p in youRecapPeriods) LokalSegment(p, _periodLabel(p)),
            ],
            value: period,
            onChanged: onPeriod,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: LokalGlass(
            borderRadius: const BorderRadius.all(Radius.circular(20)),
            thickness: LokalGlassThickness.thin,
            shadow: false,
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                    child: Row(
                      children: [
                        _Figure(
                          value: has
                              ? _count(recap!.totalListeningTime.inMinutes)
                              : '0',
                          label: lokalText('Minutes'),
                        ),
                        _Figure(
                          value: has ? _count(recap!.totalPlays) : '0',
                          label: lokalText('Plays'),
                        ),
                        _Figure(
                          value: peak == null
                              ? '—'
                              : TimeOfDay(
                                  hour: peak,
                                  minute: 0,
                                ).format(context),
                          label: lokalText('Peak hour'),
                        ),
                      ],
                    ),
                  ),
                  if (!has)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Text(
                        lokalText(
                          "Your top artists and songs show up here once you’ve played some music.",
                        ),
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.4,
                          color: t.muted,
                        ),
                      ),
                    )
                  else ...[
                    if (recap!.topArtists.isNotEmpty)
                      _TopList(
                        title: lokalText('Top artists'),
                        rows: [
                          for (final a in recap.topArtists.take(3))
                            (a.artist, '${_count(a.plays)} plays'),
                        ],
                      ),
                    if (recap.topSongs.isNotEmpty)
                      _TopList(
                        title: lokalText('Top songs'),
                        rows: [
                          for (final s in recap.topSongs.take(3))
                            (s.song.title, s.song.artist),
                        ],
                      ),
                    if (recap.topAlbums.isNotEmpty)
                      _TopList(
                        title: lokalText('Top albums'),
                        rows: [
                          for (final a in recap.topAlbums.take(3))
                            (a.album, a.artist),
                        ],
                      ),
                  ],
                  Divider(height: 1, thickness: 1, color: t.border),
                  LokalSettingLink(
                    label: lokalText('Full history'),
                    description: lokalText(
                      'Every song you’ve played, newest first.',
                    ),
                    icon: Icons.history_rounded,
                    onTap: onHistory,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Expanded(
      child: MergeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: TextStyle(
                  fontFamily: LokalTheme.sans,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: t.text,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(label.toUpperCase(), style: LokalTheme.label(t, size: 10)),
          ],
        ),
      ),
    );
  }
}

class _TopList extends StatelessWidget {
  const _TopList({required this.title, required this.rows});

  final String title;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(), style: LokalTheme.label(t, size: 10)),
          const SizedBox(height: 6),
          for (var i = 0; i < rows.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 22,
                    child: Text(
                      lokalText("{arg0}", args: {'arg0': i + 1}),
                      style: LokalTheme.label(t, size: 12, color: t.accent),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      rows[i].$1,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: t.text,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      rows[i].$2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: TextStyle(fontSize: 12, color: t.muted),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _MilestonesSection extends StatelessWidget {
  const _MilestonesSection({required this.milestones, required this.onOpen});

  final List<MilestoneRecord> milestones;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Label(
          lokalText('Milestones'),
          trailing: TextButton(
            onPressed: onOpen,
            child: Text(
              lokalText('SEE ALL'),
              style: LokalTheme.label(t, color: t.accent),
            ),
          ),
        ),
        if (milestones.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LokalGlass(
              borderRadius: const BorderRadius.all(Radius.circular(20)),
              thickness: LokalGlassThickness.thin,
              shadow: false,
              child: Material(
                type: MaterialType.transparency,
                child: LokalSettingLink(
                  label: lokalText('No badges yet'),
                  description: lokalText(
                    'Your first one unlocks at 100 songs.',
                  ),
                  icon: Icons.emoji_events_outlined,
                  onTap: onOpen,
                ),
              ),
            ),
          )
        else
          SizedBox(
            height: 104,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: milestones.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (_, i) =>
                  _Badge(type: milestones[i].type, onTap: onOpen),
            ),
          ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.type, required this.onTap});

  final MilestoneType type;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Semantics(
      button: true,
      label: type.shortLabel,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 76,
          child: Column(
            children: [
              SizedBox.square(
                dimension: 60,
                child: LokalGlass.capsule(
                  thickness: LokalGlassThickness.thin,
                  tint: type.tierColor.withValues(alpha: .22),
                  shadow: false,
                  child: Center(
                    child: Icon(type.tierIcon, color: type.tierColor, size: 26),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                type.shortLabel,
                maxLines: 2,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, height: 1.2, color: t.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountChip extends StatelessWidget {
  const _AccountChip({
    required this.label,
    required this.connected,
    required this.onTap,
  });

  final String label;
  final bool connected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final state = connected ? 'Connected' : 'Connect';
    return Semantics(
      button: true,
      label: lokalText(
        "{arg0}, {arg1}",
        args: {
          'arg0': label,
          'arg1': connected ? 'connected' : 'not connected',
        },
      ),
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: LokalGlass.capsule(
          thickness: LokalGlassThickness.thin,
          shadow: false,
          padding: const EdgeInsets.fromLTRB(12, 9, 14, 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: connected ? t.accent : t.muted2,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: t.text,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                state.toUpperCase(),
                style: LokalTheme.label(
                  t,
                  size: 10,
                  color: connected ? t.accent : t.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
