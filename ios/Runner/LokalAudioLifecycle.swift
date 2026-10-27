import AVFoundation
import Flutter
import Foundation
import UIKit
import WebKit

/// Observes the system without changing AVAudioSession configuration/activation.
/// Construction is intentionally deferred until every Dart local output owner
/// participates in reset cleanup. Do not instantiate from AppDelegate early.
final class LokalAudioLifecycle: NSObject, FlutterStreamHandler {
  private let channel: FlutterEventChannel
  private let lock = NSLock()
  private var observers: [NSObjectProtocol] = []
  private var sink: FlutterEventSink?
  private var latestEpoch: UInt64
  private var latestPhase = "ready"

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterEventChannel(name: "lokal/audio_lifecycle", binaryMessenger: messenger)
    latestEpoch = lokal_audio_local_request_epoch()
    super.init()
    // queue:nil executes on the posting thread. Fence native requests before
    // dispatching anything to Dart, even when the main isolate is busy.
    for (notification, phase) in [
      (AVAudioSession.mediaServicesWereLostNotification, "lost"),
      (AVAudioSession.mediaServicesWereResetNotification, "reset"),
    ] {
      observers.append(NotificationCenter.default.addObserver(
        forName: notification, object: nil, queue: nil
      ) { [weak self] _ in self?.receive(phase) })
    }
    channel.setStreamHandler(self)
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  private func receive(_ phase: String) {
    let epoch = lokal_audio_invalidate_local_requests()
    lock.lock()
    // Concurrent notification delivery must not publish an older generation.
    if epoch > latestEpoch {
      latestEpoch = epoch
      latestPhase = phase
    }
    lock.unlock()
    DispatchQueue.main.async { [weak self] in
      // Stop existing iframe outputs even when Dart is occupied. This is an
      // early safeguard; Dart still requires its own native completion before
      // another output is permitted to start.
      self?.suspendWebVideo()
      self?.publishLatest()
    }
  }

  private func suspendWebVideo() {
    func suspend(_ view: UIView) {
      if let webView = view as? WKWebView {
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
      }
      for child in view.subviews { suspend(child) }
    }
    for scene in UIApplication.shared.connectedScenes {
      guard let scene = scene as? UIWindowScene else { continue }
      for window in scene.windows { suspend(window) }
    }
  }

  private func publishLatest() {
    dispatchPrecondition(condition: .onQueue(.main))
    lock.lock()
    // Decimal strings preserve all 64 bits through Flutter's standard codec.
    let event = ["phase": latestPhase, "epoch": String(latestEpoch)]
    lock.unlock()
    sink?(event)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    publishLatest()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  #if DEBUG
  /// App-path validation only; posting is not an actual media-daemon restart.
  func postResetForIntegrationTest() {
    NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification,
                                    object: AVAudioSession.sharedInstance())
  }

  func postLostForIntegrationTest() {
    NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereLostNotification,
                                    object: AVAudioSession.sharedInstance())
  }
  #endif
}
