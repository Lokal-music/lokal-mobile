import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/core/theme/adaptive_color_provider.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/services/uac2_service.dart';

/// A new DAC can replace another on the same port without changing the
/// number of devices. Compare identities rather than list length.
@visibleForTesting
bool usbInventoryChanged(Set<String>? previous, Set<String> current) =>
    previous == null ||
    previous.length != current.length ||
    !previous.containsAll(current);

/// Keep the visible physical USB inventory in sync while the DAC settings
/// page is open. A cached FutureProvider read is NOT a poll: it will never
/// discover a new attachment unless something else invalidates it.
class Uac2HotplugMonitor extends ConsumerStatefulWidget {
  const Uac2HotplugMonitor({super.key});

  @override
  ConsumerState<Uac2HotplugMonitor> createState() =>
      _Uac2HotplugMonitorState();
}

class _Uac2HotplugMonitorState extends ConsumerState<Uac2HotplugMonitor> {
  Timer? _pollTimer;
  StreamSubscription<void>? _attachSubscription;
  StreamSubscription<void>? _detachSubscription;
  Set<String>? _lastDeviceIds;
  String? _lastEventMessage;
  DateTime? _lastEventTime;
  bool _lastEventWasAttach = false;
  bool _checking = false;
  bool _checkAgain = false;

  @override
  void initState() {
    super.initState();
    final service = Uac2Service.instance;
    _attachSubscription = service.deviceAttachedEvents.listen((_) {
      _refreshAfterUsbEvent();
    });
    _detachSubscription = service.deviceDetachedEvents.listen((_) {
      _refreshAfterUsbEvent();
    });
    // Hotplug broadcasts are fast. This low-rate, inventory-only fallback
    // covers OEMs which fail to deliver them while the app is foregrounded.
    _pollTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => unawaited(_checkDevices()),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_checkDevices());
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    unawaited(_attachSubscription?.cancel());
    unawaited(_detachSubscription?.cancel());
    super.dispose();
  }

  void _refreshAfterUsbEvent() {
    if (!mounted) return;
    // A USB grant may change capabilities without changing the device count.
    ref.invalidate(uac2DevicesProvider);
    unawaited(_checkDevices());
  }

  Future<void> _checkDevices() async {
    if (_checking) {
      _checkAgain = true;
      return;
    }
    _checking = true;
    try {
      // Only inspect UsbManager's inventory. Never open or claim a device
      // while an exclusive Rust isochronous stream may be active.
      final devices = await Uac2Service.instance.listDevices(
        verifyPhysicalAttachment: true,
      );
      if (!mounted) return;
      final ids = <String>{
        for (final d in devices)
          d.deviceName ??
              '${d.vendorId}:${d.productId}:${d.serial ?? ''}',
      };
      final previous = _lastDeviceIds;
      _lastDeviceIds = ids;
      if (usbInventoryChanged(previous, ids)) {
        ref.invalidate(uac2DevicesProvider);
        for (final device in devices) {
          ref.invalidate(uac2DeviceCapabilitiesProvider(device));
        }
        if (previous != null) {
          final added = ids.difference(previous).isNotEmpty;
          setState(() {
            _lastEventMessage = added
                ? l10n.deviceConnected
                : l10n.deviceDisconnected;
            _lastEventWasAttach = added;
            _lastEventTime = DateTime.now();
          });
        }
      } else if (_lastEventTime != null &&
          DateTime.now().difference(_lastEventTime!).inSeconds > 5) {
        setState(() => _lastEventTime = null);
      }
    } catch (_) {
      // Discovery failures cannot affect playback or dismiss a known DAC.
    } finally {
      _checking = false;
      if (_checkAgain && mounted) {
        _checkAgain = false;
        unawaited(_checkDevices());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_lastEventMessage == null || _lastEventTime == null) {
      return const SizedBox.shrink();
    }
    if (DateTime.now().difference(_lastEventTime!).inSeconds > 5) {
      return const SizedBox.shrink();
    }
    final isConnected = _lastEventWasAttach;
    return Container(
      margin: const EdgeInsets.only(bottom: AppConstants.spacingMd),
      padding: const EdgeInsets.all(AppConstants.spacingMd),
      decoration: BoxDecoration(
        color: (isConnected ? Colors.green : Colors.orange)
            .withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(AppConstants.radiusLg),
        border: Border.all(
          color: isConnected ? Colors.green : Colors.orange,
        ),
      ),
      child: Row(
        children: [
          Icon(
            isConnected ? LucideIcons.plugZap : LucideIcons.unplug,
            color: isConnected ? Colors.green : Colors.orange,
            size: 20,
          ),
          const SizedBox(width: AppConstants.spacingMd),
          Expanded(
            child: Text(
              _lastEventMessage!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: context.adaptiveTextPrimary,
                    fontWeight: FontWeight.w500,
                  ),
            ),
          ),
          Text(
            l10n.sAgo(DateTime.now().difference(_lastEventTime!).inSeconds),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.adaptiveTextTertiary,
                ),
          ),
        ],
      ),
    );
  }
}
