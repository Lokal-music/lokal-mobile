import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Process-lifetime observer for optional motion-art decoders.
///
/// A widget observer cannot see memory pressure that arrives while the player
/// screen is unmounted. Start this at app bootstrap so even the next newly
/// mounted artwork view respects the complete memory recovery window.
class MotionArtMemoryPressure extends WidgetsBindingObserver {
  MotionArtMemoryPressure._();

  static final MotionArtMemoryPressure instance = MotionArtMemoryPressure._();
  static const Duration recoveryDelay = Duration(minutes: 2);

  final ValueNotifier<bool> _suspended = ValueNotifier<bool>(false);
  ValueListenable<bool> get suspended => _suspended;
  bool get isSuspended => _suspended.value;

  Timer? _recoveryTimer;
  bool _observing = false;

  void start() {
    if (_observing) return;
    WidgetsBinding.instance.addObserver(this);
    _observing = true;
  }

  @override
  void didHaveMemoryPressure() {
    // A further low-memory notification extends the entire quiet period.
    _recoveryTimer?.cancel();
    _suspended.value = true;
    _recoveryTimer = Timer(recoveryDelay, () {
      _recoveryTimer = null;
      _suspended.value = false;
    });
  }

  @visibleForTesting
  void resetForTesting() {
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _suspended.value = false;
  }
}
