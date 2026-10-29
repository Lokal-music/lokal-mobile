import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flick/providers/app_build_info_provider.dart';
import 'package:flick/features/whats_new/data/changelog_data.dart';
import 'package:flick/features/whats_new/data/lokal_minor_release_notes.dart';
import 'package:flick/providers/app_preferences_provider.dart';

/// Release notes for the first tagged build of each major.minor line.
final lokalMinorReleaseNotesProvider =
    FutureProvider.family<ChangelogEntry?, String>(
      (ref, minor) => loadLokalMinorRelease(minor, forIos: Platform.isIOS),
    );

ChangelogEntry? _fallback(String minor) => (Platform.isIOS
    ? lokalIosMinorReleaseFallback
    : lokalMinorReleaseFallback)[minor];

/// Read persisted state before treating null startup preferences as a fresh
/// install. A new install silently establishes its current minor as baseline.
final lokalChangelogBaselineProvider = FutureProvider<String?>((ref) async {
  final info = await ref.watch(appBuildInfoProvider.future);
  final minor = lokalMinorVersion(info.version);
  if (minor == null) return null;
  final service = ref.watch(appPreferencesServiceProvider);
  final seen = await service.getLastSeenChangelogVersion();
  if (!ref.mounted) return null;
  if (seen != null) return seen;
  await service.setLastSeenChangelogVersion(minor);
  return minor;
});

class WhatsNewState {
  const WhatsNewState({required this.currentEntry, required this.pendingEntry});

  /// The notes for this installed major.minor line, not the current patch.
  final ChangelogEntry? currentEntry;

  /// The minor-version entry not yet seen by this installation.
  final ChangelogEntry? pendingEntry;
}

class WhatsNewNotifier extends Notifier<WhatsNewState> {
  String? _acknowledgedMinor;

  @override
  WhatsNewState build() {
    final info = ref.watch(appBuildInfoProvider).value;
    final baseline = ref.watch(lokalChangelogBaselineProvider).value;
    final lastSeen =
        ref.watch(appPreferencesProvider).lastSeenChangelogVersion ?? baseline;
    final minor = lokalMinorVersion(info?.version);
    final notes = minor == null
        ? null
        : (ref.watch(lokalMinorReleaseNotesProvider(minor)).value ??
              _fallback(minor));
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

    return WhatsNewState(
      currentEntry: notes,
      pendingEntry:
          notes != null &&
              _acknowledgedMinor != minor &&
              lokalMinorHasChanged(minor, lastSeen)
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
              _fallback(minor));
    state = _resolve(
      info,
      ref.read(appPreferencesProvider).lastSeenChangelogVersion ??
          ref.read(lokalChangelogBaselineProvider).value,
      notes,
    );
  }

  /// Mark this major.minor release as seen. Patches never show the same note.
  Future<void> markCurrentVersionSeen() async {
    final info = ref.read(appBuildInfoProvider).value;
    final minor = lokalMinorVersion(info?.version);
    if (minor == null) return;
    _acknowledgedMinor = minor;
    state = WhatsNewState(currentEntry: state.currentEntry, pendingEntry: null);
    await ref
        .read(appPreferencesProvider.notifier)
        .setLastSeenChangelogVersion(minor);
  }
}

final whatsNewProvider = NotifierProvider<WhatsNewNotifier, WhatsNewState>(
  WhatsNewNotifier.new,
);
