import 'dart:async';
import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

import 'package:flutter/material.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/models/audio_output_diagnostics.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/eq_engine_hint.dart';
import 'package:flick/services/uac2_preferences_service.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/src/rust/api/audio_api.dart' as rust_audio;
import 'package:flick/src/rust/audio/engine.dart' show AudioApiPreference;
import 'package:flick/widgets/common/engine_restart_notice.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';
import 'package:flick/widgets/uac2/uac2_volume_control.dart';
import 'package:flick/features/settings/screens/logs_screen.dart';
import 'package:flick/l10n/l10n.dart';

/// The USB DAC's engine, bit-perfect, format and DSD preferences on their
/// own. The USB DAC page shows the same sections under its devices.
class Uac2PreferencesScreen extends ConsumerWidget {
  const Uac2PreferencesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isochronous =
        ref.watch(audioEnginePreferenceProvider).asData?.value ==
        AudioEnginePreference.isochronousUsb;
    return LokalSettingsScaffold(
      title: l10n.uac2Preferences,
      subtitle: 'Playback engine, bit-perfect output, format and DSD.',
      children: [
        const Uac2PreferencesSections(),
        if (isochronous) ...[
          LokalSettingsSection(
            title: l10n.volume,
            children: const [Uac2VolumeControl()],
          ),
        ],
      ],
    );
  }
}

/// The USB DAC preferences as Lokal settings sections, for a settings page.
class Uac2PreferencesSections extends ConsumerStatefulWidget {
  const Uac2PreferencesSections({super.key});

  @override
  ConsumerState<Uac2PreferencesSections> createState() =>
      _Uac2PreferencesSectionsState();
}

/// One choice in a preferences sheet.
class _Choice {
  const _Choice({
    required this.label,
    required this.description,
    required this.selected,
    required this.onTap,
    this.enabled = true,
    this.badge,
  });

  final String label;
  final String description;
  final bool selected;
  final bool enabled;
  final String? badge;
  final Future<void> Function(BuildContext sheet) onTap;
}

class _Uac2PreferencesSectionsState
    extends ConsumerState<Uac2PreferencesSections>
    with WidgetsBindingObserver {
  bool _pendingEngineRestart = false;
  bool _forceUsbRestartInProgress = false;
  bool _usbRecordPermissionInProgress = false;
  PermissionStatus? _usbRecordPermissionStatus;
  bool _awaiting432HzConfirm = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshUsbRecordPermissionStatus());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshUsbRecordPermissionStatus());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refreshUsbRecordPermissionStatus() async {
    if (!Platform.isAndroid) return;
    try {
      final status = await Permission.microphone.status;
      if (mounted) setState(() => _usbRecordPermissionStatus = status);
    } catch (_) {
      // Permission status is best-effort; USB playback works without it.
    }
  }

  Future<void> _requestUsbRecordPermission(BuildContext context) async {
    if (!Platform.isAndroid || _usbRecordPermissionInProgress) return;
    setState(() => _usbRecordPermissionInProgress = true);
    String? feedback;
    try {
      var status = await Permission.microphone.status;
      if (status.isGranted) {
        feedback = 'USB audio recording permission is already granted.';
      } else if (status.isPermanentlyDenied) {
        await openAppSettings();
        feedback = 'Enable Microphone permission for Lokal in Android '
            'settings to remove the USB recording warning.';
      } else {
        // User explicitly selected the USB engine or its permission setting.
        // Lokal does not initialize a microphone recorder.
        status = await Permission.microphone.request();
        feedback = status.isGranted
            ? 'Permission granted. The USB recording warning should no '
                'longer appear; Android may still request USB access.'
            : 'Permission not granted. USB playback remains available, '
                'but Android may show its recording warning.';
      }
      if (mounted) setState(() => _usbRecordPermissionStatus = status);
    } catch (error) {
      feedback = 'Could not request USB recording permission: $error';
    } finally {
      if (mounted) setState(() => _usbRecordPermissionInProgress = false);
    }
    if (context.mounted && feedback != null) {
      LokalToast.show(context, feedback, duration: const Duration(seconds: 5));
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(uac2PreferencesServiceProvider);
    final formatPrefAsync = ref.watch(uac2FormatPreferenceProvider);
    final preferredFormatAsync = ref.watch(uac2PreferredFormatProvider);
    final audioFormatAsync = ref.watch(audioFormatEnabledProvider);
    final bitPerfectAsync = ref.watch(uac2BitPerfectEnabledProvider);
    final dapBitPerfectAsync = ref.watch(uac2DapBitPerfectEnabledProvider);
    final tuning432HzAsync = ref.watch(uac2432HzTuningEnabledProvider);
    final audioEngineAsync = ref.watch(audioEnginePreferenceProvider);
    final androidAudioApiAsync = ref.watch(androidAudioApiProvider);
    final developerModeAsync = ref.watch(developerModeEnabledProvider);
    final diagnostics = ref.watch(audioOutputDiagnosticsProvider);
    final killOnQuitAsync = ref.watch(killIsochronousUsbOnQuitProvider);
    final autoEngageUsbDacAsync = ref.watch(autoEngageUsbDacProvider);
    final declinedUsbDevicesAsync = ref.watch(declinedUsbDevicesProvider);
    final dsdOutputModeAsync = ref.watch(dsdOutputModeProvider);

    final isBitPerfectEnabled = bitPerfectAsync.value ?? false;
    final isAudioFormatEnabled = audioFormatAsync.value ?? true;
    final formatBlocked = !isAudioFormatEnabled || isBitPerfectEnabled;
    final declined = declinedUsbDevicesAsync.asData?.value ?? const {};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_pendingEngineRestart)
          const LokalSettingsBlock(top: 16, child: EngineRestartNotice()),
        LokalSettingsSection(
          title: l10n.playbackEngine,
          children: [
            _async(
              audioEngineAsync,
              l10n.playbackEngine,
              (engine) => LokalSettingLink(
                label: l10n.playbackEngine,
                description: _audioEnginePreferenceSubtitle(engine),
                onTap: () => _showAudioEngineSheet(
                  context,
                  service,
                  engine,
                  diagnostics: diagnostics,
                ),
              ),
            ),
            if (audioEngineAsync.asData?.value ==
                AudioEnginePreference.rustOboe)
              _async(
                androidAudioApiAsync,
                l10n.androidAudioApi,
                (pref) => LokalSettingLink(
                  label: l10n.androidAudioApi,
                  description: _androidAudioApiSubtitle(pref),
                  onTap: () =>
                      _showAndroidAudioApiSheet(context, service, pref),
                ),
              ),
            _modeStatusRow(diagnostics),
            if (Platform.isAndroid &&
                audioEngineAsync.asData?.value ==
                    AudioEnginePreference.isochronousUsb)
              LokalSettingRow(
                label: 'USB audio recording permission',
                description: _usbRecordPermissionStatus?.isGranted == true
                    ? 'Granted. USB access permission is handled separately.'
                    : 'Optional: remove Android’s recording warning for '
                        'USB DACs that expose an audio input. Lokal does '
                        'not record audio. Tap to grant permission.',
                icon: Icons.mic_none_rounded,
                enabled: !_usbRecordPermissionInProgress,
                trailing: _usbRecordPermissionInProgress
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : _usbRecordPermissionStatus?.isGranted == true
                        ? Icon(Icons.check_circle_outline_rounded,
                            color: context.lokal.accent)
                        : null,
                onTap: _usbRecordPermissionInProgress ||
                        _usbRecordPermissionStatus?.isGranted == true
                    ? null
                    : () => _requestUsbRecordPermission(context),
              ),
            if (audioEngineAsync.asData?.value ==
                AudioEnginePreference.isochronousUsb)
              LokalSettingRow(
                label: 'Force restart USB audio engine',
                description: 'Reopen the DAC, retry internally if necessary, '
                    'and restart the current track from the beginning.',
                icon: Icons.restart_alt_rounded,
                enabled: !_forceUsbRestartInProgress,
                trailing: _forceUsbRestartInProgress
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: _forceUsbRestartInProgress
                    ? null
                    : () => _forceRestartUsbAudioEngine(context),
              ),
          ],
        ),
        LokalSettingsSection(
          title: 'Bit-perfect',
          children: [
            _async(
              bitPerfectAsync,
              l10n.bitPerfectUsbDac,
              (enabled) => LokalSettingRow.toggle(
                label: l10n.bitPerfectUsbDac,
                description: l10n.useTheVerifiedDirectUsbPath,
                value: enabled,
                onChanged: (value) =>
                    _setBitPerfect(context, value, enabled, audioEngineAsync),
              ),
            ),
            if (diagnostics?.detectedDap == true)
              _async(
                dapBitPerfectAsync,
                l10n.bitPerfectDapInternal,
                (enabled) => LokalSettingRow.toggle(
                  label: l10n.bitPerfectDapInternal,
                  description: l10n.bypassAllDspEqDynamicsCrossfade,
                  value: enabled,
                  onChanged: (value) async {
                    await PlayerService().setDapBitPerfectEnabled(value);
                    ref.invalidate(uac2DapBitPerfectEnabledProvider);
                    if (!context.mounted) return;
                    final messenger = ScaffoldMessenger.of(context);
                    messenger.removeCurrentSnackBar();
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                          value
                              ? l10n.bitPerfectDapInternalEnabledAll
                              : l10n.bitPerfectDapInternalDisabledSoftware,
                        ),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                    _showRestartRequiredToast(context);
                  },
                ),
              ),
            _async(
              autoEngageUsbDacAsync,
              l10n.autoBitPerfectForUsbDacs,
              (enabled) => LokalSettingRow.toggle(
                label: l10n.autoBitPerfectForUsbDacs,
                description: l10n.switchToTheExclusiveUsbPath,
                value: enabled,
                onChanged: (value) async {
                  await service.setAutoEngageUsbDacEnabled(value);
                  ref.invalidate(autoEngageUsbDacProvider);
                },
              ),
            ),
            if (declined.isNotEmpty)
              LokalSettingLink(
                label: l10n.resetDeclinedUsbDacs,
                description: l10n.dacWillBeOfferedAgain(declined.length),
                onTap: () async {
                  await service.clearDeclinedUsbDevices();
                  ref.invalidate(declinedUsbDevicesProvider);
                  if (context.mounted) {
                    LokalToast.fromSnackBar(context, 
                      SnackBar(
                        content: Text(l10n.usbDacAutoBitPerfectOffers),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                },
              ),
            _async(
              killOnQuitAsync,
              l10n.stopUsbOnQuit,
              (killOnQuit) => LokalSettingRow.toggle(
                label: l10n.stopUsbOnQuit,
                description: killOnQuit
                    ? l10n.theIsochronousUsbEngineWillBe
                    : l10n.theIsochronousUsbEngineWillStay,
                value: killOnQuit,
                onChanged: (value) async {
                  await service.setKillIsochronousUsbOnQuit(value);
                  ref.invalidate(killIsochronousUsbOnQuitProvider);
                  unawaited(
                    Uac2Service.instance.syncKillIsochronousUsbOnQuitToNative(),
                  );
                },
              ),
            ),
          ],
        ),
        LokalSettingsSection(
          title: l10n.audioFormat,
          children: [
            _async(
              audioFormatAsync,
              l10n.audioFormat,
              (enabled) => LokalSettingRow.toggle(
                label: l10n.audioFormat,
                description: enabled
                    ? l10n.formatStrategyAndCustomFormatControls
                    : l10n.formatControlsAreDisabledTheEngine,
                value: enabled,
                onChanged: (value) async {
                  await service.setAudioFormatEnabled(value);
                  ref.invalidate(audioFormatEnabledProvider);
                },
              ),
            ),
            _async(
              formatPrefAsync,
              l10n.formatStrategy,
              (formatPref) => _blockable(
                label: l10n.formatStrategy,
                description: formatBlocked
                    ? (isBitPerfectEnabled
                          ? l10n.disabledInBitPerfectUsbDac
                          : l10n.audioFormatIsDisabled)
                    : _getFormatPreferenceLabel(formatPref),
                blocked: formatBlocked,
                onBlocked: () => _showBlockedSheet(
                  context,
                  l10n.formatStrategy,
                  isBitPerfectEnabled
                      ? l10n.formatStrategyIsDisabledInBit
                      : l10n.formatStrategyIsUnavailableBecauseAudio,
                ),
                onTap: () =>
                    _showFormatPreferenceSheet(context, service, formatPref),
              ),
            ),
            _async(
              preferredFormatAsync,
              l10n.customFormat,
              (format) => _blockable(
                label: l10n.customFormat,
                description: formatBlocked
                    ? (isBitPerfectEnabled
                          ? l10n.disabledInBitPerfectUsbDac
                          : l10n.audioFormatIsDisabled)
                    : format == null
                    ? l10n.notSet
                    : format.isDsdStream
                    ? l10n.ch3(format.displayRateLabel, format.channels)
                    : l10n.khzBitCh(
                        format.sampleRate ~/ 1000,
                        format.bitDepth,
                        format.channels,
                      ),
                blocked: formatBlocked,
                onBlocked: () => _showBlockedSheet(
                  context,
                  l10n.customFormat,
                  isBitPerfectEnabled
                      ? l10n.customFormatIsDisabledInBit
                      : l10n.customFormatIsUnavailableBecauseAudio,
                ),
                onTap: () => _showCustomFormatSheet(context, service, format),
              ),
            ),
          ],
        ),
        LokalSettingsSection(
          title: l10n.experimental,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: LokalSettingsNotice(
                text: l10n.notRecommendedForNormalUsageDsd,
                warning: true,
              ),
            ),
            _async(
              dsdOutputModeAsync,
              l10n.dsdOutputMode,
              (mode) => LokalSettingLink(
                label: l10n.dsdOutputMode,
                description: _dsdOutputModeSubtitle(mode),
                onTap: () => _showDsdOutputModeSheet(context, service, mode),
              ),
            ),
            ValueListenableBuilder<DsdWireVariant>(
              valueListenable: Uac2PreferencesService.dsdWireVariantNotifier,
              builder: (context, variant, _) => LokalSettingLink(
                label: l10n.dapNativeBitOrder,
                description: _dsdWireVariantSubtitle(variant),
                onTap: () =>
                    _showDsdWireVariantSheet(context, service, variant),
              ),
            ),
            ValueListenableBuilder<DsdWireGrouping>(
              valueListenable: Uac2PreferencesService.dsdWireGroupingNotifier,
              builder: (context, grouping, _) => LokalSettingLink(
                label: l10n.dapNativeByteGrouping,
                description: _dsdWireGroupingSubtitle(grouping),
                onTap: () =>
                    _showDsdWireGroupingSheet(context, service, grouping),
              ),
            ),
            _async(
              tuning432HzAsync,
              l10n.hzTuning,
              (enabled) => LokalSettingRow.toggle(
                label: l10n.hzTuning,
                description: l10n.experimentalDownTunePlaybackBy432,
                value: enabled,
                onChanged: (value) async {
                  if (value && !enabled && !_awaiting432HzConfirm) {
                    final confirmed = await _confirmEnable432HzTuning(context);
                    if (!confirmed || !context.mounted) return;
                  }
                  await service.set432HzTuningEnabled(value);
                  rust_audio.audioSet432HzTuningEnabled(enabled: value);
                  ref.invalidate(uac2432HzTuningEnabledProvider);
                },
              ),
            ),
          ],
        ),
        LokalSettingsSection(
          title: 'Diagnostics',
          children: [
            _async(
              developerModeAsync,
              l10n.developerMode,
              (enabled) => LokalSettingRow.toggle(
                label: l10n.developerMode,
                description: l10n.showVerboseAudioDiagnosticsAndEngine,
                value: enabled,
                onChanged: (value) async {
                  await service.setDeveloperModeEnabled(value);
                  ref.invalidate(developerModeEnabledProvider);
                },
              ),
            ),
            if (developerModeAsync.asData?.value == true)
              LokalSettingLink(
                label: l10n.logs,
                description: l10n.verboseDartRustAndCrashLogs,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const LogsScreen()),
                ),
              ),
            LokalSettingRow(
              label: l10n.resetPreferences,
              description: l10n.clearAllUac2Settings,
              trailing: LokalSettingButton(
                label: l10n.reset,
                destructive: true,
                onPressed: () => _showResetConfirmation(context, service),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// [data]'s row once [value] has loaded; a dimmed row with the [label]
  /// until then, or the load error.
  Widget _async<T>(
    AsyncValue<T> value,
    String label,
    Widget Function(T value) data,
  ) {
    return value.when(
      data: data,
      loading: () =>
          LokalSettingRow(label: label, description: '…', enabled: false),
      error: (_, _) => LokalSettingRow(
        label: label,
        description: l10n.errorLoadingPreference,
      ),
    );
  }

  /// A link that explains why it is off instead of opening, while [blocked].
  Widget _blockable({
    required String label,
    required String description,
    required bool blocked,
    required VoidCallback onBlocked,
    required VoidCallback onTap,
  }) {
    if (!blocked) {
      return LokalSettingLink(
        label: label,
        description: description,
        onTap: onTap,
      );
    }
    return Opacity(
      opacity: .55,
      child: LokalSettingRow(
        label: label,
        description: description,
        trailing: Icon(
          Icons.lock_outline_rounded,
          size: 18,
          color: context.lokal.muted,
        ),
        onTap: onBlocked,
      ),
    );
  }

  Future<void> _setBitPerfect(
    BuildContext context,
    bool value,
    bool enabled,
    AsyncValue<AudioEnginePreference> audioEngineAsync,
  ) async {
    final changed = value != enabled;
    // Read the service while this ConsumerState is still mounted. The audio
    // engine switch can navigate away from this screen before it completes.
    final uac2Service = ref.read(uac2ServiceProvider);
    // An engine switch can deactivate this settings subtree before an await
    // completes. Container invalidation does not touch an unmounted widget ref.
    final container = ProviderScope.containerOf(context, listen: false);
    if (value) {
      final engine = audioEngineAsync.asData?.value;
      if (engine != null && engine != AudioEnginePreference.isochronousUsb) {
        await PlayerService().setAudioEnginePreference(
          AudioEnginePreference.isochronousUsb,
        );
        if (!mounted) return;
        container.invalidate(audioEnginePreferenceProvider);
      }
    }
    final applied = await uac2Service.setBitPerfectEnabled(value);
    if (!mounted) return;
    container.invalidate(uac2BitPerfectEnabledProvider);
    container.invalidate(uac2ExclusiveDacModeProvider);
    container.invalidate(killIsochronousUsbOnQuitProvider);
    if (!context.mounted) return;
    if (!applied && value) {
      LokalToast.fromSnackBar(context, SnackBar(content: Text(l10n.bitPerfectUsbDacCouldNot)));
      return;
    }
    if (changed) {
      if (value && EqEngineHint.parametricPeqActive) {
        LokalToast.fromSnackBar(context, 
          SnackBar(
            content: Text(l10n.bitPerfectEnabledParametricEqIs),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        _showRestartRequiredToast(context);
      }
    }
  }

  Widget _modeStatusRow(AudioOutputDiagnostics? diagnostics) {
    final modeDescription = switch (diagnostics?.pathManagement) {
      AudioPathManagement.directUsbExperimental =>
        l10n.exclusiveUsbIsActiveAndBypassing,
      AudioPathManagement.alsaDirectDap => l10n.directAlsaOutputIsActiveAnd,
      AudioPathManagement.managedDirectExclusive =>
        l10n.exclusiveDirectPcmIsActiveAnd,
      AudioPathManagement.androidManagedLowLatency =>
        l10n.playbackIsUsingAndroidManagedOutput,
      AudioPathManagement.androidManagedShared =>
        l10n.playbackIsUsingTheStandardAndroid,
      null => l10n.playbackModeWillUpdateAfterThe,
    };
    return LokalSettingRow(
      label: l10n.currentPlaybackMode,
      description: modeDescription,
      stacked: true,
      trailing: Align(
        alignment: Alignment.centerLeft,
        child: LokalStatusPill(
          label: diagnostics?.capabilityStateLabel ?? l10n.waitingForPlayback,
          active: diagnostics != null,
        ),
      ),
    );
  }

  /// A sheet of [choices], with an optional warning [note] above them.
  Future<void> _pick(
    BuildContext context, {
    required String title,
    String? note,
    bool noteWarning = true,
    required List<_Choice> choices,
  }) {
    return showLokalSettingsSheet<void>(
      context: context,
      title: title,
      isScrollControlled: true,
      builder: (sheet) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (note != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
                child: LokalSettingsNotice(
                  text: note,
                  warning: noteWarning,
                  icon: noteWarning ? null : Icons.lock_outline_rounded,
                ),
              ),
            for (final choice in choices)
              Opacity(
                opacity: choice.enabled ? 1 : .45,
                child: IgnorePointer(
                  ignoring: !choice.enabled,
                  child: LokalSheetOption(
                    label: choice.badge == null
                        ? choice.label
                        : '${choice.label} · ${choice.badge}',
                    description: choice.description,
                    selected: choice.selected,
                    onTap: () => choice.onTap(sheet),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _audioEnginePreferenceSubtitle(AudioEnginePreference engine) {
    return switch (engine) {
      AudioEnginePreference.exoPlayer => l10n.justAudioExoplayerDefault,
      AudioEnginePreference.rustOboe => l10n.rustViaOboe,
      AudioEnginePreference.isochronousUsb => l10n.isochronousUsb,
    };
  }

  String _androidAudioApiSubtitle(AudioApiPreference pref) {
    return switch (pref) {
      AudioApiPreference.auto => l10n.aaudioWithOpenslEsFallbackDefault,
      AudioApiPreference.aAudio => l10n.aaudioAndroid81,
      AudioApiPreference.openSles => l10n.openslEsLegacy,
    };
  }

  Future<void> _showAndroidAudioApiSheet(
    BuildContext context,
    Uac2PreferencesService service,
    AudioApiPreference current,
  ) {
    _Choice choice(AudioApiPreference pref, String title, String subtitle) =>
        _Choice(
          label: title,
          description: subtitle,
          selected: current == pref,
          onTap: (sheet) async {
            final changed = current != pref;
            await service.setAndroidAudioApi(pref);
            rust_audio.audioSetAudioApi(preference: pref);
            ref.invalidate(androidAudioApiProvider);
            if (sheet.mounted) Navigator.of(sheet).pop();
            if (changed && context.mounted) {
              _showRestartRequiredToast(context);
            }
          },
        );
    return _pick(
      context,
      title: l10n.androidAudioApi,
      choices: [
        choice(AudioApiPreference.auto, l10n.auto, l10n.letOboePickTheBestApi),
        choice(
          AudioApiPreference.aAudio,
          l10n.aaudio,
          l10n.useAaudioDirectlyLowestLatencyOn,
        ),
        choice(
          AudioApiPreference.openSles,
          l10n.openslEs,
          l10n.useTheLegacyOpenslEsBackend,
        ),
      ],
    );
  }

  Future<void> _showAudioEngineSheet(
    BuildContext context,
    Uac2PreferencesService service,
    AudioEnginePreference current, {
    AudioOutputDiagnostics? diagnostics,
  }) async {
    final dapBothOff =
        diagnostics?.detectedDap == true &&
        !(await service.getBitPerfectEnabled()) &&
        !(await service.getDapBitPerfectEnabled());
    final effective = (dapBothOff && current == AudioEnginePreference.exoPlayer)
        ? AudioEnginePreference.rustOboe
        : current;
    if (dapBothOff && current == AudioEnginePreference.exoPlayer) {
      await PlayerService().setAudioEnginePreference(
        AudioEnginePreference.rustOboe,
      );
      ref.invalidate(audioEnginePreferenceProvider);
    }
    if (!context.mounted) return;

    /// Switches to [engine]; leaving the USB engine turns bit-perfect off.
    Future<void> select(
      BuildContext sheet,
      AudioEnginePreference engine, {
      bool dropBitPerfect = true,
    }) async {
      final wasBitPerfectEnabled =
          dropBitPerfect && await service.getBitPerfectEnabled();
      await PlayerService().setAudioEnginePreference(engine);
      if (wasBitPerfectEnabled) {
        await ref.read(uac2ServiceProvider).setBitPerfectEnabled(false);
        ref.invalidate(uac2BitPerfectEnabledProvider);
        ref.invalidate(uac2ExclusiveDacModeProvider);
        ref.invalidate(killIsochronousUsbOnQuitProvider);
      }
      ref.invalidate(audioEnginePreferenceProvider);
      if (sheet.mounted) Navigator.of(sheet).pop();
      // Selecting direct USB is an explicit user action. Ask once for the
      // optional runtime permission, if absent, rather than prompting at
      // every app launch. A denial never blocks USB playback.
      if (current != engine &&
          engine == AudioEnginePreference.isochronousUsb &&
          Platform.isAndroid &&
          context.mounted) {
        await _requestUsbRecordPermission(context);
      }
      if (current != engine && mounted) {
        setState(() => _pendingEngineRestart = true);
      }
    }

    await _pick(
      context,
      title: l10n.playbackEngine,
      note: dapBothOff ? l10n.bothBitPerfectOptionsAreOff : null,
      noteWarning: false,
      choices: [
        _Choice(
          label: l10n.justAudioExoplayer,
          description: dapBothOff
              ? l10n.disabledWhileBothBitPerfectOptions
              : l10n.defaultAndroidPlaybackEngineUsedBy,
          selected: effective == AudioEnginePreference.exoPlayer,
          enabled: !dapBothOff,
          badge: dapBothOff ? l10n.locked : null,
          onTap: (sheet) => select(sheet, AudioEnginePreference.exoPlayer),
        ),
        _Choice(
          label: l10n.rustViaOboe,
          description: dapBothOff
              ? l10n.keepsSoftwareVolumeAndDspActive
              : l10n.androidManagedRustPlaybackPathUsing,
          selected: effective == AudioEnginePreference.rustOboe,
          badge: (dapBothOff && effective != current) ? l10n.active : null,
          onTap: (sheet) => select(sheet, AudioEnginePreference.rustOboe),
        ),
        _Choice(
          label: l10n.isochronousUsb,
          description: l10n.directLibusbIsochronousUsbEngineBest,
          selected: effective == AudioEnginePreference.isochronousUsb,
          onTap: (sheet) => select(
            sheet,
            AudioEnginePreference.isochronousUsb,
            dropBitPerfect: false,
          ),
        ),
      ],
    );
  }

  Future<void> _forceRestartUsbAudioEngine(BuildContext context) async {
    if (_forceUsbRestartInProgress) return;
    setState(() => _forceUsbRestartInProgress = true);
    bool recovered = false;
    try {
      recovered = await PlayerService().forceRestartUsbAudioEngine();
      if (mounted) ref.invalidate(uac2DevicesProvider);
    } catch (error) {
      // The service keeps the failure reason in the exported diagnostics.
      recovered = false;
    } finally {
      if (mounted) setState(() => _forceUsbRestartInProgress = false);
    }
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(recovered
            ? 'USB engine verified. Track restarted from the beginning.'
            : 'USB audio restart failed. Check DAC connection and logs.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showRestartRequiredToast(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.restartTheAppToApplyPlayback),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showDeviceRestartRequiredToast(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.restartYourDeviceToApplyOutput),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _getFormatPreferenceLabel(Uac2FormatPreference pref) {
    switch (pref) {
      case Uac2FormatPreference.highestQuality:
        return l10n.highestQuality;
      case Uac2FormatPreference.compatibility:
        return l10n.compatibility;
      case Uac2FormatPreference.custom:
        return l10n.custom;
    }
  }

  Future<void> _showFormatPreferenceSheet(
    BuildContext context,
    Uac2PreferencesService service,
    Uac2FormatPreference current,
  ) {
    _Choice choice(
      Uac2FormatPreference preference,
      String title,
      String description,
    ) => _Choice(
      label: title,
      description: description,
      selected: preference == current,
      onTap: (sheet) async {
        final changed = preference != current;
        await service.setFormatPreference(preference);
        ref.invalidate(uac2FormatPreferenceProvider);
        if (sheet.mounted) Navigator.of(sheet).pop();
        if (changed && mounted) {
          _showDeviceRestartRequiredToast(this.context);
        }
      },
    );
    return _pick(
      context,
      title: l10n.formatStrategy,
      note: l10n.changingSampleRateBitDepthOr,
      choices: [
        choice(
          Uac2FormatPreference.highestQuality,
          l10n.highestQuality,
          l10n.useTheHighestFixedOutputRate,
        ),
        choice(
          Uac2FormatPreference.compatibility,
          l10n.compatibility,
          l10n.useAFixed48khz16bitOutput,
        ),
        choice(
          Uac2FormatPreference.custom,
          l10n.custom,
          'Use your selected fixed sample rate, bit depth, and channels',
        ),
      ],
    );
  }

  Future<void> _showCustomFormatSheet(
    BuildContext context,
    Uac2PreferencesService service,
    Uac2AudioFormat? current,
  ) {
    int sampleRate = current?.sampleRate ?? 48000;
    int bitDepth = current?.bitDepth ?? 16;
    int channels = current?.channels ?? 2;

    return showLokalSettingsSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(
        builder: (context, setSheetState) => SingleChildScrollView(
          child: LokalSheetBody(
            title: l10n.customFormat,
            children: [
              LokalSettingsNotice(
                text: l10n.customFormatForcesPlaybackToThe,
                warning: true,
              ),
              _FormatChips(
                label: l10n.sampleRate2,
                values: const [
                  44100,
                  48000,
                  88200,
                  96000,
                  176400,
                  192000,
                  352800,
                  384000,
                ],
                selected: sampleRate,
                labelOf: (rate) => l10n.khz(rate ~/ 1000),
                onSelected: (rate) => setSheetState(() => sampleRate = rate),
              ),
              _FormatChips(
                label: l10n.bitDepth2,
                values: const [16, 24, 32],
                selected: bitDepth,
                labelOf: l10n.bit,
                onSelected: (depth) => setSheetState(() => bitDepth = depth),
              ),
              _FormatChips(
                label: l10n.channels,
                values: const [1, 2],
                selected: channels,
                labelOf: (ch) => ch == 1 ? l10n.mono : l10n.stereo,
                onSelected: (ch) => setSheetState(() => channels = ch),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: LokalSettingsActionButton(
                      label: l10n.cancel,
                      primary: false,
                      onPressed: () => Navigator.of(sheet).pop(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: LokalSettingsActionButton(
                      label: l10n.save,
                      onPressed: () async {
                        final formatChanged =
                            current?.sampleRate != sampleRate ||
                            current?.bitDepth != bitDepth ||
                            current?.channels != channels;
                        final previousPreference = await service
                            .getFormatPreference();
                        await service.savePreferredFormat(
                          Uac2AudioFormat(
                            sampleRate: sampleRate,
                            bitDepth: bitDepth,
                            channels: channels,
                          ),
                        );
                        await service.setFormatPreference(
                          Uac2FormatPreference.custom,
                        );
                        ref.invalidate(uac2PreferredFormatProvider);
                        ref.invalidate(uac2FormatPreferenceProvider);
                        if (sheet.mounted) Navigator.of(sheet).pop();
                        if ((formatChanged ||
                                previousPreference !=
                                    Uac2FormatPreference.custom) &&
                            mounted) {
                          _showDeviceRestartRequiredToast(this.context);
                        }
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showResetConfirmation(
    BuildContext context,
    Uac2PreferencesService service,
  ) {
    unawaited(
      showLokalConfirmSheet(
        context: context,
        title: l10n.resetPreferences,
        message: l10n.areYouSureYouWantTo3,
        confirmLabel: l10n.reset,
        destructive: true,
      ).then((confirmed) async {
        if (!confirmed) return;
        await service.clearAllPreferences();
        await ref
            .read(uac2ServiceProvider)
            .setBitPerfectEnabled(false, persist: false);
        ref.invalidate(uac2FormatPreferenceProvider);
        ref.invalidate(uac2PreferredFormatProvider);
        ref.invalidate(uac2BitPerfectEnabledProvider);
        ref.invalidate(uac2ExclusiveDacModeProvider);
        if (context.mounted) {
          LokalToast.fromSnackBar(context, 
            SnackBar(content: Text(l10n.uac2PreferencesResetSuccessfully)),
          );
        }
      }),
    );
  }

  Future<void> _showBlockedSheet(
    BuildContext context,
    String featureName,
    String message,
  ) {
    return showLokalSettingsSheet<void>(
      context: context,
      builder: (sheet) => LokalSheetBody(
        title: l10n.unavailable(featureName),
        message: message,
        children: [
          LokalSettingsActionButton(
            label: 'OK',
            expand: true,
            onPressed: () => Navigator.of(sheet).pop(),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmEnable432HzTuning(BuildContext context) {
    if (_awaiting432HzConfirm) return Future.value(false);
    _awaiting432HzConfirm = true;
    return showLokalConfirmSheet(
      context: context,
      title: l10n.enable432HzTuning,
      message: l10n.thisSlowsPlaybackTo432440,
      confirmLabel: l10n.enable,
    ).then((result) {
      _awaiting432HzConfirm = false;
      return result;
    });
  }

  String _dsdOutputModeSubtitle(DsdOutputMode mode) {
    switch (mode) {
      case DsdOutputMode.auto:
        return l10n.autoNativeDsdOnDapsDop;
      case DsdOutputMode.forcePcm:
        return l10n.forcePcmAlwaysConvertDsdTo;
      case DsdOutputMode.forceDop:
        return l10n.forceDopAlwaysUseDsdOver;
      case DsdOutputMode.native:
        return l10n.nativeDsdExperimentalMayBeBuggy;
    }
  }

  Future<void> _showDsdOutputModeSheet(
    BuildContext context,
    Uac2PreferencesService service,
    DsdOutputMode current,
  ) {
    _Choice soon(String title) => _Choice(
      label: title,
      description: l10n.comingSoon,
      selected: false,
      enabled: false,
      onTap: (_) async {},
    );
    return _pick(
      context,
      title: l10n.dsdOutputMode,
      choices: [
        soon(l10n.auto),
        soon(l10n.forcePcm),
        soon(l10n.forceDop),
        _Choice(
          label: l10n.nativeDsdExperimental,
          description: l10n.rawDsdStreamToDacRequires,
          selected: current == DsdOutputMode.native,
          onTap: (sheet) async {
            await service.setDsdOutputMode(DsdOutputMode.native);
            ref.invalidate(dsdOutputModeProvider);
            if (sheet.mounted) Navigator.of(sheet).pop();
          },
        ),
      ],
    );
  }

  String _dsdWireVariantSubtitle(DsdWireVariant variant) {
    switch (variant) {
      case DsdWireVariant.auto:
        return l10n.autoBeMsbDefaultOnlyChange;
      case DsdWireVariant.beMsb:
        return l10n.beMsbBigEndianSubslotMsb;
      case DsdWireVariant.leMsb:
        return l10n.leMsbLittleEndianSubslotMsb;
      case DsdWireVariant.beLsb:
        return l10n.beLsbBigEndianSubslotLsb;
      case DsdWireVariant.leLsb:
        return l10n.leLsbLittleEndianSubslotLsb;
    }
  }

  String _dsdWireGroupingSubtitle(DsdWireGrouping grouping) {
    switch (grouping) {
      case DsdWireGrouping.auto:
        return l10n.autoU8ByteInterleavedRecommended;
      case DsdWireGrouping.u32:
        return l10n.u324ByteSubslotsLlllRrrr;
      case DsdWireGrouping.u16:
        return l10n.u162ByteSubslotsLlRr;
      case DsdWireGrouping.u8:
        return l10n.u8ByteInterleavedLrlr;
    }
  }

  Future<void> _showDsdWireGroupingSheet(
    BuildContext context,
    Uac2PreferencesService service,
    DsdWireGrouping current,
  ) {
    return _pick(
      context,
      title: l10n.dapNativeByteGrouping,
      choices: [
        for (final (grouping, title, subtitle) in [
          (
            DsdWireGrouping.auto,
            l10n.auto,
            l10n.u8ByteInterleavedRecommendedDefault,
          ),
          (DsdWireGrouping.u32, 'U32', l10n.bitSubslotsLlllRrrrPer),
          (DsdWireGrouping.u16, 'U16', l10n.bitSubslotsLlRrPer),
          (DsdWireGrouping.u8, 'U8', l10n.byteInterleavedLrlrStream),
        ])
          _Choice(
            label: title,
            description: subtitle,
            selected: current == grouping,
            onTap: (sheet) async {
              await service.setDsdWireGrouping(grouping);
              // Applies to the very next wire write — live A/B while a
              // DAP native-DSD track is playing.
              rust_audio.audioSetSasWireGrouping(
                grouping: switch (grouping) {
                  DsdWireGrouping.auto => 2,
                  DsdWireGrouping.u32 => 0,
                  DsdWireGrouping.u16 => 1,
                  DsdWireGrouping.u8 => 2,
                },
              );
              if (sheet.mounted) Navigator.of(sheet).pop();
            },
          ),
      ],
    );
  }

  Future<void> _showDsdWireVariantSheet(
    BuildContext context,
    Uac2PreferencesService service,
    DsdWireVariant current,
  ) {
    return _pick(
      context,
      title: l10n.dapNativeBitOrder,
      choices: [
        for (final (variant, title, subtitle) in [
          (DsdWireVariant.auto, l10n.auto, l10n.beMsbPackingTheDefaultWire),
          (DsdWireVariant.beMsb, 'BE-MSB', l10n.bigEndian32BitSubslotMsb),
          (
            DsdWireVariant.leMsb,
            'LE-MSB',
            l10n.littleEndianSubslotMsbFirstBits,
          ),
          (DsdWireVariant.beLsb, 'BE-LSB', l10n.bigEndianSubslotLsbFirstBit),
          (
            DsdWireVariant.leLsb,
            'LE-LSB',
            l10n.littleEndianSubslotLsbFirstBits,
          ),
        ])
          _Choice(
            label: title,
            description: subtitle,
            selected: current == variant,
            onTap: (sheet) async {
              await service.setDsdWireVariant(variant);
              // Applies to the very next wire write — live A/B while a
              // DAP native-DSD track is playing.
              rust_audio.audioSetSasWireVariant(
                variant: switch (variant) {
                  DsdWireVariant.auto => 0,
                  DsdWireVariant.beMsb => 0,
                  DsdWireVariant.leMsb => 1,
                  DsdWireVariant.beLsb => 2,
                  DsdWireVariant.leLsb => 3,
                },
              );
              if (sheet.mounted) Navigator.of(sheet).pop();
            },
          ),
      ],
    );
  }
}

/// A labelled row of choice pills, for the custom format sheet.
class _FormatChips extends StatelessWidget {
  const _FormatChips({
    required this.label,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
  });

  final String label;
  final List<int> values;
  final int selected;
  final String Function(int value) labelOf;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: LokalTheme.label(t)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final value in values)
                Semantics(
                  button: true,
                  selected: value == selected,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () => onSelected(value),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: value == selected ? t.accent : t.surface2,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: value == selected ? t.accent : t.border,
                        ),
                      ),
                      child: Text(
                        labelOf(value),
                        style: TextStyle(
                          fontFamily: LokalTheme.sans,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: value == selected ? t.onAccent : t.text,
                        ),
                      ),
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
