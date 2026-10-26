/// Audio engine type selected by the session manager.
///
/// These map to Rust [BackendType] variants as follows:
/// - normalAndroid → ResampledFallback (Android-managed audio via just_audio)
/// - rustOboe      → MixerBitPerfect or MixerMatched (Rust Oboe/AAudio mixer path)
/// - usbDacExperimental → UsbDirect (Rust USB direct/isochronous)
/// - dapInternalHighRes → DapNative (Rust Oboe exclusive on confirmed DAP)
enum AudioEngineType {
  normalAndroid,
  rustOboe,
  usbDacExperimental,
  dapInternalHighRes,
  iosSystem,
  iosRust;

  bool get usesRustBackend =>
      this != AudioEngineType.normalAndroid &&
      this != AudioEngineType.iosSystem;

  bool get isDirectUsbExperimental =>
      this == AudioEngineType.usbDacExperimental;

  bool get isAndroidManaged =>
      this == AudioEngineType.normalAndroid ||
      this == AudioEngineType.rustOboe ||
      this == AudioEngineType.dapInternalHighRes;

  String get backendType => switch (this) {
    AudioEngineType.normalAndroid => 'resampled_fallback',
    AudioEngineType.rustOboe => 'mixer_bit_perfect',
    AudioEngineType.usbDacExperimental => 'usb_direct',
    AudioEngineType.dapInternalHighRes => 'dap_native',
    AudioEngineType.iosSystem => 'ios_system',
    AudioEngineType.iosRust => 'ios_core_audio',
  };

  String get logLabel => switch (this) {
    AudioEngineType.normalAndroid => 'NORMAL_ANDROID',
    AudioEngineType.rustOboe => 'RUST_OBOE',
    AudioEngineType.usbDacExperimental => 'USB_DAC_EXPERIMENTAL',
    AudioEngineType.dapInternalHighRes => 'DAP_INTERNAL_HIGH_RES',
    AudioEngineType.iosSystem => 'IOS_SYSTEM',
    AudioEngineType.iosRust => 'IOS_RUST_CORE_AUDIO',
  };
}
