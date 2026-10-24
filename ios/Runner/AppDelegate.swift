import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var lokalPlatform: LokalPlatform?
  private var pendingDocuments: [URL] = []

  func openDocuments(_ urls: [URL]) {
    if let platform = lokalPlatform { platform.openDocuments(urls) }
    else { pendingDocuments.append(contentsOf: urls.filter { $0.isFileURL }) }
  }
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    lokalPlatform = LokalPlatform(messenger: engineBridge.applicationRegistrar.messenger())
    lokalPlatform?.openDocuments(pendingDocuments)
    pendingDocuments = []
  }
}
