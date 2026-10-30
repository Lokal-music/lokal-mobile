import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/models/lokal_remote_state.dart';
import 'package:flick/providers/lokal_remote_provider.dart';
import 'package:flick/services/lokal_remote_service.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';
import 'package:flick/widgets/common/ios_transfer_root.dart';

/// Controls an already-running Lokal desktop over its authenticated LAN HTTP
/// protocol. This page never feeds desktop state into the phone's player.
class LokalRemoteSettingsScreen extends ConsumerStatefulWidget {
  const LokalRemoteSettingsScreen({super.key});

  @override
  ConsumerState<LokalRemoteSettingsScreen> createState() =>
      _LokalRemoteSettingsScreenState();
}

class _LokalRemoteSettingsScreenState
    extends ConsumerState<LokalRemoteSettingsScreen> {
  final _origin = TextEditingController();
  final _remoteToken = TextEditingController();
  final _apiKey = TextEditingController();
  double? _seekValue;
  double? _volumeValue;
  bool _saving = false;

  @override
  void dispose() {
    _origin.dispose();
    _remoteToken.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  Future<void> _saveAndConnect() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final controller = ref.read(lokalRemoteControllerProvider.notifier);
      final expected = await ref
          .read(lokalRemoteCredentialsStoreProvider)
          .read();
      if (!mounted) return;
      await IosTransferRoot.withPairingRetirement(
        context,
        expected: expected,
        mutation: () => controller.saveConfiguration(
          origin: _origin.text,
          remoteToken: _remoteToken.text,
          apiKey: _apiKey.text,
        ),
      );
      // Do not retain bearer values in editable controller text after saving.
      _remoteToken.clear();
      _apiKey.clear();
      await controller.connect();
    } catch (error) {
      if (mounted) _showError(_safeMessage(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _connect() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await ref.read(lokalRemoteControllerProvider.notifier).connect();
    } catch (error) {
      if (mounted) _showError(_safeMessage(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _forget() async {
    if (_saving) return;
    final confirmed = await showLokalConfirmSheet(
      context: context,
      title: 'Forget Lokal desktop?',
      message: 'The address and saved remote credentials are removed from this device.',
      confirmLabel: 'Forget',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _saving = true);
    try {
      final expected = await ref
          .read(lokalRemoteCredentialsStoreProvider)
          .read();
      if (!mounted) return;
      await IosTransferRoot.withPairingRetirement(
        context,
        expected: expected,
        mutation: () => ref
            .read(lokalRemoteControllerProvider.notifier)
            .forgetConfiguration(expected: expected),
      );
      if (!mounted) return;
      _origin.clear();
      _remoteToken.clear();
      _apiKey.clear();
    } catch (error) {
      if (mounted) {
        _showError(error is StateError
            ? error.message.toString()
            : _safeMessage(error));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _command(LokalRemoteAction action, {double? value}) async {
    try {
      await ref
          .read(lokalRemoteControllerProvider.notifier)
          .sendCommand(action, value: value);
    } catch (error) {
      if (mounted) _showError(_safeMessage(error));
    }
  }

  void _showError(String message) {
    if (mounted) LokalToast.show(context, message);
  }

  String _safeMessage(Object error) => error is LokalRemoteException
      ? error.message
      : 'Lokal remote control could not be updated.';

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(lokalRemoteControllerProvider);
    if (_origin.text.isEmpty && state.config != null) {
      _origin.text = state.config!.origin.toString();
    }
    final snapshot = state.snapshot;
    final track = snapshot?.currentTrack;
    final canControl = state.reachable && snapshot != null;
    final disabled = !canControl || state.commandInFlight;
    final seekMax = snapshot == null || snapshot.duration <= 0
        ? 1.0
        : snapshot.duration;
    final seek = (_seekValue ?? snapshot?.progress ?? 0).clamp(0, seekMax);
    final volume = (_volumeValue ?? snapshot?.volume ?? 1).clamp(0, 1);

    return LokalSettingsScaffold(
      title: 'Lokal Remote',
      subtitle: 'Control a Lokal desktop on your local network.',
      actions: [
        LokalSettingsHeaderAction(
          icon: Icons.refresh_rounded,
          tooltip: 'Refresh remote state',
          onPressed: state.configured && !_saving
              ? () => unawaited(_connect())
              : null,
        ),
      ],
      children: [
        LokalSettingsBlock(
          child: LokalSettingsNotice(
            text: 'Use the desktop address from Lokal’s Remote page. Remote tokens are stored in secure storage and are sent only as request headers. Plain HTTP is protected only by your LAN.',
            warning: state.config?.hasRemoteToken != true,
          ),
        ),
        LokalSettingsBlock(
          child: LokalSettingsCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                TextField(
                  key: const ValueKey('lokal-remote-origin'),
                  controller: _origin,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: lokalInputDecoration(
                    context,
                    label: 'Desktop address',
                    hint: 'http://192.168.1.20:3421',
                    helper: 'You can paste the desktop /remote link.',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('lokal-remote-token'),
                  controller: _remoteToken,
                  obscureText: true,
                  autocorrect: false,
                  decoration: lokalInputDecoration(
                    context,
                    label: 'Remote token',
                    hint: 'Optional if the desktop does not require one',
                    helper: 'Leave empty only when the desktop remote is intentionally unauthenticated.',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('lokal-remote-api-key'),
                  controller: _apiKey,
                  obscureText: true,
                  autocorrect: false,
                  decoration: lokalInputDecoration(
                    context,
                    label: 'API key',
                    hint: 'Optional',
                    helper: 'Only needed when Lokal also protects its API with an API key.',
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: LokalSettingsActionButton(
                        label: state.configured
                            ? 'Save & reconnect'
                            : 'Save & connect',
                        icon: Icons.link_rounded,
                        expand: true,
                        onPressed: _saving ? null : _saveAndConnect,
                      ),
                    ),
                    if (state.configured) ...[
                      const SizedBox(width: 10),
                      LokalSettingsActionButton(
                        label: 'Forget',
                        primary: false,
                        destructive: true,
                        onPressed: _saving ? null : _forget,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
        LokalSettingsBlock(
          child: _StatusCard(
            state: state,
            onDisconnect: ref
                .read(lokalRemoteControllerProvider.notifier)
                .disconnect,
          ),
        ),
        if (state.configured)
          LokalSettingsSection(
            title: 'Remote player',
            children: [
              LokalSettingRow(
                label: track == null || track.title.isEmpty
                    ? 'Nothing playing'
                    : track.title,
                description: track == null
                    ? 'The desktop is reachable, but it has no current track.'
                    : [
                        track.artist,
                        track.album,
                      ].where((value) => value.isNotEmpty).join(' · '),
                trailing: Icon(
                  snapshot?.isPlaying == true
                      ? Icons.graphic_eq_rounded
                      : Icons.pause_circle_outline_rounded,
                  color: context.lokal.accent,
                ),
              ),
              LokalSettingCustom(
                label: 'Playback controls',
                description:
                    'Play, pause, skip, seek and change the desktop volume.',
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                  child: Column(
                    children: [
                      Slider(
                        key: const ValueKey('lokal-remote-seek'),
                        value: seek.toDouble(),
                        min: 0,
                        max: seekMax.toDouble(),
                        onChanged: disabled
                            ? null
                            : (value) => setState(() => _seekValue = value),
                        onChangeEnd: disabled
                            ? null
                            : (value) {
                                _seekValue = null;
                                unawaited(
                                  _command(
                                    LokalRemoteAction.seek,
                                    value: value,
                                  ),
                                );
                              },
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: 'Previous track',
                            onPressed: disabled
                                ? null
                                : () => unawaited(
                                    _command(LokalRemoteAction.prev),
                                  ),
                            icon: const Icon(Icons.skip_previous_rounded),
                          ),
                          IconButton.filled(
                            tooltip: snapshot?.isPlaying == true
                                ? 'Pause'
                                : 'Play',
                            onPressed: disabled
                                ? null
                                : () => unawaited(
                                    _command(LokalRemoteAction.togglePlay),
                                  ),
                            icon: Icon(
                              snapshot?.isPlaying == true
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Next track',
                            onPressed: disabled
                                ? null
                                : () => unawaited(
                                    _command(LokalRemoteAction.next),
                                  ),
                            icon: const Icon(Icons.skip_next_rounded),
                          ),
                          IconButton(
                            tooltip: 'Like or unlike track',
                            onPressed: disabled
                                ? null
                                : () => unawaited(
                                    _command(LokalRemoteAction.toggleLike),
                                  ),
                            icon: const Icon(Icons.favorite_border_rounded),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          Icon(
                            Icons.volume_down_rounded,
                            size: 20,
                            color: context.lokal.muted,
                          ),
                          Expanded(
                            child: Slider(
                              key: const ValueKey('lokal-remote-volume'),
                              value: volume.toDouble(),
                              onChanged: disabled
                                  ? null
                                  : (value) =>
                                        setState(() => _volumeValue = value),
                              onChangeEnd: disabled
                                  ? null
                                  : (value) {
                                      _volumeValue = null;
                                      unawaited(
                                        _command(
                                          LokalRemoteAction.volume,
                                          value: value,
                                        ),
                                      );
                                    },
                            ),
                          ),
                          Icon(
                            Icons.volume_up_rounded,
                            size: 20,
                            color: context.lokal.muted,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.state, required this.onDisconnect});

  final LokalRemoteControllerState state;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final (label, color) = switch (state.status) {
      LokalRemoteConnectionStatus.unconfigured => ('Not configured', t.muted),
      LokalRemoteConnectionStatus.disconnected => ('Disconnected', t.muted),
      LokalRemoteConnectionStatus.connecting => ('Connecting…', t.accent),
      LokalRemoteConnectionStatus.connected => (
        state.snapshot?.connected == true
            ? 'Connected to Lokal desktop'
            : 'Lokal reachable · no player connected',
        t.accent,
      ),
      LokalRemoteConnectionStatus.offline => ('Offline · retrying', t.orange),
      LokalRemoteConnectionStatus.unauthorized => (
        'Authentication required',
        t.red,
      ),
    };
    return LokalSettingsCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontWeight: FontWeight.w700, color: t.text),
                ),
                if (state.error case final error?)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      error,
                      style: TextStyle(fontSize: 12, color: t.muted),
                    ),
                  ),
              ],
            ),
          ),
          if (state.status == LokalRemoteConnectionStatus.connected)
            LokalSettingButton(label: 'Disconnect', onPressed: onDisconnect),
        ],
      ),
    );
  }
}
