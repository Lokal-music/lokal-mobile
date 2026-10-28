import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flick/providers/app_build_info_provider.dart';
import 'package:flick/features/whats_new/data/changelog_data.dart';
import 'package:flick/features/whats_new/data/lokal_minor_release_notes.dart';
import 'package:flick/providers/app_preferences_provider.dart';

/// Release notes for the first tagged build of each major.minor line.
final lokalMinorReleaseNotesProvider =
    FutureProvider.family<ChangelogEntry?, String>((ref, minor) =>
        loadLokalMinorRelease(minor));

class WhatsNewState {
  const WhatsNewState({required this.currentEntry, required this.pendingEntry});

  /// The notes for this installed major.minor line, not the current patch.
  final ChangelogEntry? currentEntry;

  /// The minor-version entry not yet seen by this installation.
  final ChangelogEntry? pendingEntry;
}

class WhatsNewNotifier extends Notifier<WhatsNewState> {
  @override
  WhatsNewState build() {
    final info = ref.watch(appBuildInfoProvider).value;
    final lastSeen = ref.watch(appPreferencesProvider).lastSeenChangelogVersion;
    final minor = lokalMinorVersion(info?.version);
    final notes = minor == null
        ? null
        : (ref.watch(lokalMinorReleaseNotesProvider(minor)).value ??
            lokalMinorReleaseFallback[minor]);
    return _resolve(info, lastSeen, notes);
  }

  WhatsNewState _resolve(
    AppBuildInfo? info,
    String? lastSeen,
    ChangelogEntry? notes,
  ) {
    final minor = lokalMinorVersion(info?.version);
    if (minor == null) {
      return const WhatsNewState(currentEntry: null, pendingEntry: null);
    }
    // Old installations stored version+build. Treat any patch of the same
    // minor as already seen, and persist just the minor going forward.
    final seenMinor = lokalMinorVersion(lastSeen?.split('+').first);
    return WhatsNewState(
      currentEntry: notes,
      pendingEntry: notes != null && lastSeen != null && seenMinor != minor
          ? notes
          : null,
    );
  }

  /// Re-read preferences after asynchronous initialization. The provider
  /// rebuilds again when GitHub release notes finish loading.
  void evaluate() {
    final info = ref.read(appBuildInfoProvider).value;
    final minor = lokalMinorVersion(info?.version);
    final notes = minor == null
        ? null
        : (ref.read(lokalMinorReleaseNotesProvider(minor)).value ??
            lokalMinorReleaseFallback[minor]);
    state = _resolve(
      info,
      ref.read(appPreferencesProvider).lastSeenChangelogVersion,
      notes,
    );
  }

  /// Mark this major.minor release as seen. Patches never show the same note.
  Future<void> markCurrentVersionSeen() async {
    final info = ref.read(appBuildInfoProvider).value;
    final minor = lokalMinorVersion(info?.version);
    if (minor == null) return;
    await ref
        .read(appPreferencesProvider.notifier)
        .setLastSeenChangelogVersion(minor);
    state = WhatsNewState(currentEntry: state.currentEntry, pendingEntry: null);
  }
}

final whatsNewProvider = NotifierProvider<WhatsNewNotifier, WhatsNewState>(
  WhatsNewNotifier.new,
);
