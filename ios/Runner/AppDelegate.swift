import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var lokalPlatform: LokalPlatform?
  private let transferHost = LokalTransferHost()
  private var transferBridge: LokalTransferBridge?
  #if DEBUG
  private var transferIntegrationHarness: LokalTransferIntegrationHarness?
  #endif
  private var protectedDataObserver: NSObjectProtocol?
  private var pendingDocuments: [URL] = []

  func openDocuments(_ urls: [URL]) {
    if let platform = lokalPlatform { platform.openDocuments(urls) }
    else { pendingDocuments.append(contentsOf: urls.filter { $0.isFileURL }) }
  }
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    transferHost.start()
    protectedDataObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.protectedDataDidBecomeAvailableNotification,
      object: nil, queue: .main) { [host = transferHost] _ in host.start() }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    guard identifier == LokalTransferRuntime.sessionIdentifier else {
      super.application(application, handleEventsForBackgroundURLSession: identifier,
        completionHandler: completionHandler)
      return
    }
    // This path works before Flutter initializes; importing into the library
    // is separate from retaining files and acknowledging native OS delivery.
    transferHost.handleBackgroundEvents(completion: completionHandler)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    lokalPlatform = LokalPlatform(messenger: engineBridge.applicationRegistrar.messenger())
    transferBridge = LokalTransferBridge(
      messenger: engineBridge.applicationRegistrar.messenger(), host: transferHost)
    #if DEBUG
    transferIntegrationHarness = LokalTransferIntegrationHarness(
      messenger: engineBridge.applicationRegistrar.messenger())
    #endif
    lokalPlatform?.openDocuments(pendingDocuments)
    pendingDocuments = []
  }
}
