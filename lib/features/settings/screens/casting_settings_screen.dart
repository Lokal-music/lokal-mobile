import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/services/casting/cast_device.dart';
import 'package:flick/services/casting/chromecast_backend.dart';
import 'package:flick/l10n/l10n.dart';

class CastingSettingsScreen extends ConsumerStatefulWidget {
  const CastingSettingsScreen({super.key});

  @override
  ConsumerState<CastingSettingsScreen> createState() =>
      _CastingSettingsScreenState();
}

class _CastingSettingsScreenState extends ConsumerState<CastingSettingsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _runCastAction(() => ref.read(castProvider.notifier).discover());
    });
  }

  IconData _iconFor(CastDevice d) => switch (d.backend) {
    CastBackend.dlna => LucideIcons.radio,
    CastBackend.chromecast => LucideIcons.cast,
  };

  String _subtitleFor(CastDevice d) => switch (d.backend) {
    CastBackend.dlna => l10n.dlnaUpnp,
    CastBackend.chromecast => l10n.chromecast,
  };

  Future<void> _onSelect(CastDevice device) async {
    await _runCastAction(
      () => ref.read(castProvider.notifier).connect(device),
      success: l10n.castingTo2(device.name),
    );
  }

  Future<void> _runCastAction(
    Future<void> Function() action, {
    String? success,
  }) async {
    try {
      await action();
      if (!mounted || success == null) return;
      LokalToast.fromSnackBar(context, SnackBar(content: Text(success)));
    } catch (error) {
      if (!mounted) return;
      final message =
          error is PlatformException && error.code.startsWith('CAST_')
          ? error.message ?? l10n.error3
          : l10n.error3;
      LokalToast.fromSnackBar(
        context,
        SnackBar(content: Text(message), duration: const Duration(seconds: 5)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final castState = ref.watch(castProvider);
    final active = castState.activeDevice;

    return LokalSettingsScaffold(
      title: l10n.casting,
      subtitle: l10n.discoversDlnaUpnpAndChromecastReceivers,
      children: [
        if (castState.errorMessage != null)
          LokalSettingsSection(
            title: l10n.session,
            children: [
              LokalSettingRow(
                label: castState.errorMessage!,
                icon: Icons.info_outline,
                enabled: false,
              ),
            ],
          ),
        LokalSettingsSection(
          title: l10n.availableDevices,
          children: [
            LokalSettingRow(
              label: castState.isDiscovering
                  ? l10n.searching
                  : l10n.scanForDevices,
              icon: Icons.refresh_rounded,
              enabled: !castState.isDiscovering && !castState.isChangingOutput,
              onTap: () => _runCastAction(
                () => ref.read(castProvider.notifier).discover(),
              ),
            ),
            if (castState.isChangingOutput)
              LokalSettingRow(
                label: l10n.connecting,
                icon: LucideIcons.cast,
                enabled: false,
              ),
            if (castState.devices.isEmpty)
              _EmptyState(visible: !castState.isDiscovering)
            else
              for (final d in castState.devices)
                LokalSettingRow.option(
                  icon: _iconFor(d),
                  label: d.name,
                  description: _subtitleFor(d),
                  selected: active?.id == d.id,
                  onTap: castState.isChangingOutput ? null : () => _onSelect(d),
                ),
          ],
        ),
        if (active != null)
          LokalSettingsSection(
            title: l10n.session,
            children: [
              LokalSettingRow(
                label: l10n.stopCasting,
                description: l10n.disconnectFrom(active.name),
                icon: Icons.power_settings_new_rounded,
                enabled: !castState.isChangingOutput,
                onTap: () => _runCastAction(
                  () => ref.read(castProvider.notifier).disconnect(),
                ),
              ),
            ],
          ),
        LokalSettingsSection(
          title: l10n.outputDevice,
          heading:
              '${l10n.outputDevice} · ${Platform.isIOS ? 'iPhone' : l10n.android}',
          children: [
            if (Platform.isIOS)
              LokalSettingRow(
                label: 'AirPlay and headphones',
                onTap: () async {
                  await const MethodChannel('lokal/ios')
                      .invokeMethod<bool>('showRoutePicker');
                },
              )
            else
              _OutputSection(),
          ],
        ),
        LokalSettingsSection(title: l10n.about, children: [_AboutBody()]),
        if (Platform.isIOS)
          LokalSettingsSection(
            title: l10n.casting,
            children: [
              LokalSettingRow(
                label: 'Casting files from iPhone',
                description: 'Keep Lokal open when casting files stored on this iPhone. Network-hosted tracks play directly on the receiver.',
                icon: LucideIcons.info,
                enabled: false,
              ),
            ],
          ),
      ],
    );
  }
}

class _EmptyState extends StatefulWidget {
  const _EmptyState({required this.visible});
  final bool visible;

  @override
  State<_EmptyState> createState() => _EmptyStateState();
}

class _EmptyStateState extends State<_EmptyState>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spinner;

  @override
  void initState() {
    super.initState();
    _spinner = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    if (!widget.visible) _spinner.repeat();
  }

  @override
  void didUpdateWidget(covariant _EmptyState oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    if (widget.visible) {
      _spinner.stop();
    } else {
      _spinner.repeat();
    }
  }

  @override
  void dispose() {
    _spinner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final searching = !widget.visible;
    final icon = searching
        ? RotationTransition(
            turns: _spinner,
            child: Icon(
              LucideIcons.loaderCircle,
              color: context.lokal.muted,
              size: 28,
            ),
          )
        : Icon(LucideIcons.wifiOff, color: context.lokal.muted, size: 28);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: Column(
          children: [
            icon,
            const SizedBox(height: 10),
            Text(
              widget.visible
                  ? l10n.noCastingDevicesFoundMakeSure
                  : l10n.searchingTheLocalNetwork,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: context.lokal.muted,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OutputSection extends StatefulWidget {
  @override
  State<_OutputSection> createState() => _OutputSectionState();
}

class _OutputSectionState extends State<_OutputSection> {
  Future<List<Map<String, dynamic>>>? _routesFuture;

  @override
  void initState() {
    super.initState();
    _routesFuture = ChromecastBackend().getOutputRoutes();
  }

  void _refresh() {
    setState(() {
      _routesFuture = ChromecastBackend().getOutputRoutes();
    });
  }

  IconData _iconFor(String? type) => switch (type) {
    'Speaker' => LucideIcons.speaker,
    'Wired Headset / AUX' => LucideIcons.headphones,
    'Bluetooth' => LucideIcons.bluetooth,
    'System' => LucideIcons.smartphone,
    _ => LucideIcons.usb,
  };

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _routesFuture,
      builder: (context, snapshot) {
        final routes = snapshot.data ?? const [];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LokalSettingRow(
              label: l10n.refreshOutputs,
              description: l10n.listAvailableLocalAudioOutputDevices,
              icon: Icons.refresh_rounded,
              onTap: _refresh,
            ),
            if (routes.isEmpty) ...[
              const LokalSettingsDivider(),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  l10n.noOutputDevicesAvailable,
                  style: TextStyle(fontSize: 13, color: context.lokal.muted),
                ),
              ),
            ] else
              for (final route in routes) ...[
                const LokalSettingsDivider(),
                _outputTile(route),
              ],
          ],
        );
      },
    );
  }

  Widget _outputTile(Map<String, dynamic> r) {
    final selected = r['selected'] == true;
    return LokalSettingRow.option(
      icon: _iconFor(r['type'] as String?),
      label: r['name'] as String? ?? l10n.output,
      description: r['type'] as String? ?? '',
      selected: selected,
      onTap: selected
          ? null
          : () async {
              await ChromecastBackend().selectOutputRoute(r['id'] as String);
              _refresh();
            },
    );
  }
}

class _AboutBody extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        l10n.dlnaAndUpnpReceiversAreControlled,
        style: TextStyle(
          fontFamily: LokalTheme.sans,
          fontSize: 13.5,
          color: context.lokal.muted,
          height: 1.45,
        ),
      ),
    );
  }
}
