import Flutter

/// Keep Flutter codecs separate from the transport so the identical production
/// sender can be compiled independently against Google's real device/sim SDK.
final class LokalCastBridge: NSObject, FlutterStreamHandler {
  private let controller = LokalCastController()
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel

  #if DEBUG
  var diagnosticState: [String: Any] { controller.diagnosticState }
  #endif

  init(messenger: FlutterBinaryMessenger) {
    methods = FlutterMethodChannel(name: "com.mossapps.flick/cast", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "com.mossapps.flick/cast_events", binaryMessenger: messenger)
    super.init()
    methods.setMethodCallHandler { [weak self] call, reply in
      guard let self = self else {
        reply(FlutterError(code: "CAST_UNAVAILABLE", message: "The Cast sender is unavailable.", details: nil)); return
      }
      self.controller.handle(call.method, arguments: call.arguments as? [String: Any] ?? [:]) { result in
        switch result {
        case .success(let value): reply(value)
        case .failure(let error): reply(FlutterError(code: error.code, message: error.message, details: nil))
        }
      }
    }
    events.setStreamHandler(self)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    // Listening alone never configures the SDK or starts LAN discovery.
    controller.onEvent = { events($0) }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    controller.onEvent = nil
    return nil
  }
}
