import AVFoundation
import AVKit
import Flutter
import MediaPlayer
import Photos
import Security
import UIKit
import UniformTypeIdentifiers

/// Apple integration for the shared application. The Dart audio-session owner
/// configures AVAudioSession; this bridge owns system commands and documents.
final class LokalPlatform: NSObject, UIDocumentPickerDelegate {
  private let player: FlutterMethodChannel
  private let integration: FlutterMethodChannel
  private var pendingPlayback: [String: Any]?
  private var dartReady = false
  private var channels: [FlutterMethodChannel] = []
  private var commandTargets: [(MPRemoteCommand, Any)] = []
  private var pickerResult: FlutterResult?
  private var nowPlaying: [String: Any] = [:]
  private var spotify: LokalSpotifySession?
  private var cast: LokalCastBridge?
  private var audioLifecycle: LokalAudioLifecycle?
  private let desktopDiscovery = LokalDesktopDiscovery()
  private let fileQueue = DispatchQueue(label: "app.lokal.mobile.import", qos: .userInitiated)

  init(messenger: FlutterBinaryMessenger) {
    player = FlutterMethodChannel(name: "com.mossapps.flick/player", binaryMessenger: messenger)
    integration = FlutterMethodChannel(name: "com.mossapps.flick/integration", binaryMessenger: messenger)
    super.init()
    // A killed import must not consume storage forever. Only our private UUID
    // staging folders are eligible; committed music and database files stay put.
    fileQueue.async {
      if let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true),
         let entries = try? FileManager.default.contentsOfDirectory(at: support, includingPropertiesForKeys: nil) {
        for entry in entries where entry.lastPathComponent.hasPrefix("Import-") {
          if UUID(uuidString: String(entry.lastPathComponent.dropFirst(7))) != nil {
            try? FileManager.default.removeItem(at: entry)
          }
        }
      }
    }
    spotify = LokalSpotifySession(messenger: messenger, presenter: { [weak self] in self?.presenter })
    cast = LokalCastBridge(messenger: messenger)
    register("lokal/desktop_link", messenger) { [weak self] call, result in
      guard call.method == "discover" else { result(FlutterMethodNotImplemented); return }
      self?.desktopDiscovery.discover(result)
    }
    player.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "showNotification", "updateNotification":
        self.publish(call.arguments as? [String: Any] ?? [:])
        result(nil)
      case "hideNotification":
        self.nowPlaying = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        result(nil)
      case "androidAutoReady": result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
    register("lokal/app_info", messenger) { call, result in
      guard call.method == "get" else { result(FlutterMethodNotImplemented); return }
      result([
        "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
        "bundleId": Bundle.main.bundleIdentifier ?? "",
      ])
    }
    integration.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "consumePendingExternalPlayback":
        self.dartReady = true
        let payload = self.pendingPlayback
        self.pendingPlayback = nil
        result(payload)
      case "returnToLocker": result(false)
      default: result(FlutterMethodNotImplemented)
      }
    }
    register("com.mossapps.flick/diagnostics", messenger) { call, result in
      switch call.method {
      case "getBuildFlavor": result("ios-sideload")
      case "getProcessExitInfo": result([])
      default: result(FlutterMethodNotImplemented)
      }
    }
    register("com.mossapps.flick/storage", messenger) { [weak self] call, result in
      self?.storage(call, result)
    }
    register("lokal/ios", messenger) { [weak self] call, result in
      switch call.method {
      case "canStartWebVideo":
        let args = call.arguments as? [String: Any]
        let expected = (args?["epoch"] as? String).flatMap(UInt64.init)
        result(UIApplication.shared.applicationState == .active &&
          expected == lokal_audio_local_request_epoch())
      case "startAudioLifecycle":
        guard let self = self else {
          result(FlutterError(code: "AUDIO_LIFECYCLE_UNAVAILABLE", message: "Audio lifecycle owner unavailable", details: nil))
          return
        }
        if self.audioLifecycle == nil {
          self.audioLifecycle = LokalAudioLifecycle(messenger: messenger)
        }
        result(nil)
      case "preparePlaybackCredentials":
        // flutter_secure_storage 10.3.4's default service and unlocked class.
        // Change only accessibility, atomically, without retrieving/replacing
        // credential bytes. Other services and synchronized items stay unchanged;
        // no shared access group is requested.
        DispatchQueue.global(qos: .utility).async {
          let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "flutter_secure_storage_service",
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
          ]
          let attributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
          ]
          let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
          DispatchQueue.main.async {
            if status == errSecSuccess || status == errSecItemNotFound {
              result(nil)
            } else {
              result(FlutterError(code: "KEYCHAIN_ACCESS", message: "Credential protection could not be prepared.", details: Int(status)))
            }
          }
        }
      case "libraryRoot": result(try? self?.libraryRoot().path)
      #if DEBUG
      case "postMediaServicesResetForIntegrationTest":
        guard let lifecycle = self?.audioLifecycle else {
          result(FlutterError(code: "AUDIO_LIFECYCLE_UNAVAILABLE", message: "Audio lifecycle observer has not started", details: nil))
          return
        }
        lifecycle.postResetForIntegrationTest()
        result(nil)
      case "invalidateLocalAudioRequestsForIntegrationTest":
        // Destructive pre-owner bootstrap check, not a media-daemon reset.
        let previous = lokal_audio_local_request_epoch()
        let epoch = lokal_audio_invalidate_local_requests()
        result(["previous": String(previous), "epoch": String(epoch)])
      case "castSenderState": result(self?.cast?.diagnosticState)
      case "initializeCastSenderForAcceptance": result(self?.cast?.initializeForAcceptance())
      case "nowPlayingMetadataState":
        // Native acceptance probe only; no song names, paths or credentials.
        let metadata = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        let artwork = metadata[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        let state: [String: Any] = [
          "artworkWidth": Double(artwork?.bounds.width ?? 0),
          "artworkHeight": Double(artwork?.bounds.height ?? 0),
          "durationSeconds": metadata[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0,
          "elapsedSeconds": metadata[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0,
          "playbackRate": metadata[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0,
        ]
        result(state)
      #endif
      case "audioRoute":
        let session = AVAudioSession.sharedInstance()
        result([
          "sampleRate": session.sampleRate,
          "channels": session.outputNumberOfChannels,
          "outputs": session.currentRoute.outputs.map { ["name": $0.portName, "type": $0.portType.rawValue] },
        ])
      case "showRoutePicker":
        guard let controller = self?.presenter else { result(false); return }
        let sheet = UIViewController()
        sheet.view.backgroundColor = .systemBackground
        sheet.title = "Audio output"
        let picker = AVRoutePickerView()
        picker.translatesAutoresizingMaskIntoConstraints = false
        sheet.view.addSubview(picker)
        NSLayoutConstraint.activate([
          picker.centerXAnchor.constraint(equalTo: sheet.view.centerXAnchor),
          picker.centerYAnchor.constraint(equalTo: sheet.view.centerYAnchor),
          picker.widthAnchor.constraint(equalToConstant: 64),
          picker.heightAnchor.constraint(equalToConstant: 64),
        ])
        sheet.sheetPresentationController?.detents = [.medium()]
        controller.present(sheet, animated: true)
        result(true)
      case "showIconPicker":
        guard UIApplication.shared.supportsAlternateIcons, let controller = self?.presenter else { result(false); return }
        let sheet = UIAlertController(title: "App icon", message: nil, preferredStyle: .actionSheet)
        let accents = ["lime", "purple", "pink", "orange", "blue", "red", "teal", "white", "yellow", "cyan", "magenta", "gray", "chartreuse", "midnight", "rosegold", "neon"]
        sheet.addAction(UIAlertAction(title: "Default", style: .default) { _ in
          UIApplication.shared.setAlternateIconName(nil)
        })
        for accent in accents {
          sheet.addAction(UIAlertAction(title: accent.capitalized, style: .default) { _ in
            UIApplication.shared.setAlternateIconName("Lokal" + accent.capitalized)
          })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = controller.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
        controller.present(sheet, animated: true)
        result(true)
      default: result(FlutterMethodNotImplemented)
      }
    }
    installRemoteCommands()
  }

  private func register(_ name: String, _ messenger: FlutterBinaryMessenger,
                        _ handler: @escaping FlutterMethodCallHandler) {
    let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
    channel.setMethodCallHandler(handler)
    channels.append(channel)
  }

  private func installRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()
    let commands: [(MPRemoteCommand, String)] = [
      (center.playCommand, "play"), (center.pauseCommand, "pause"),
      (center.togglePlayPauseCommand, "togglePlayPause"), (center.stopCommand, "stop"),
      (center.nextTrackCommand, "next"), (center.previousTrackCommand, "previous"),
    ]
    for (command, method) in commands {
      let target = command.addTarget { [weak self] _ in
        guard let self = self else { return .commandFailed }
        DispatchQueue.main.async { self.player.invokeMethod(method, arguments: nil) }
        return .success
      }
      commandTargets.append((command, target))
    }
    let seek = center.changePlaybackPositionCommand
    let target = seek.addTarget { [weak self] event in
      guard let self = self, let event = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      DispatchQueue.main.async {
        self.player.invokeMethod("seek", arguments: ["position": Int(event.positionTime * 1000)])
      }
      return .success
    }
    commandTargets.append((seek, target))
  }

  private func publish(_ args: [String: Any]) {
    if let title = args["title"] as? String { nowPlaying[MPMediaItemPropertyTitle] = title }
    if let artist = args["artist"] as? String { nowPlaying[MPMediaItemPropertyArtist] = artist }
    if let duration = args["duration"] as? NSNumber {
      nowPlaying[MPMediaItemPropertyPlaybackDuration] = duration.doubleValue / 1000
    }
    if let position = args["position"] as? NSNumber {
      nowPlaying[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position.doubleValue / 1000
    }
    if let playing = args["isPlaying"] as? Bool {
      nowPlaying[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
    }
    if let live = args["isLive"] as? Bool {
      nowPlaying[MPNowPlayingInfoPropertyIsLiveStream] = live
      MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = !live
      MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = !live
      MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled = !live
    }
    if args.keys.contains("albumArtPath") {
      nowPlaying.removeValue(forKey: MPMediaItemPropertyArtwork)
      if let path = args["albumArtPath"] as? String,
         let image = UIImage(contentsOfFile: path) {
        nowPlaying[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
      }
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlaying
  }

  private func libraryRoot() throws -> URL {
    let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
    let root = documents.appendingPathComponent("Music", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private var presenter: UIViewController? {
    var controller = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }.first { $0.isKeyWindow }?.rootViewController
    while let presented = controller?.presentedViewController { controller = presented }
    return controller
  }

  private func storage(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "openDocumentTree":
      guard pickerResult == nil else {
        result(FlutterError(code: "IMPORT_BUSY", message: "An import is already open.", details: nil)); return
      }
      guard let controller = presenter else {
        result(FlutterError(code: "IMPORT_UNAVAILABLE", message: "The file picker is unavailable.", details: nil)); return
      }
      pickerResult = result
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder, .data], asCopy: false)
      picker.allowsMultipleSelection = true
      picker.delegate = self
      controller.present(picker, animated: true)
    case "takePersistableUriPermission":
      guard let path = args["uri"] as? String, let root = try? libraryRoot() else { result(false); return }
      result(path == root.path || path.hasPrefix(root.path + "/"))
    case "releasePersistableUriPermission", "scanMediaFiles": result(nil)
    case "getPersistedUriPermissions": result((try? libraryRoot()).map { [$0.path] } ?? [])
    case "hasAllFilesAccess", "requestAllFilesAccess", "isAllFilesAccessSupported": result(false)
    case "getDocumentDisplayName":
      result((args["uri"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent })
    case "resolveTreeUriToPath", "cacheUriForPlayback": result(args["uri"])
    case "saveImageToGallery": saveImage(args, result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let result = pickerResult; pickerResult = nil; result?(nil)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pickerResult else { return }
    copyDocuments(urls) { imported in
      self.pickerResult = nil
      switch imported {
      case .success: result(try? self.libraryRoot().path)
      case .failure:
        result(FlutterError(code: "IMPORT_FAILED", message: "Music could not be copied. Check available space and file access.", details: nil))
      }
    }
  }

  /// Open-in from Files uses the same scoped, transactional copy as the picker.
  /// Never retain a temporary external URL as a library or playback location.
  func openDocuments(_ urls: [URL]) {
    let files = urls.filter { $0.isFileURL }
    guard !files.isEmpty else { return }
    copyDocuments(files) { imported in
      guard case .success(let destination) = imported,
            let first = files.first else {
        if let controller = self.presenter {
          let alert = UIAlertController(title: "Couldn’t import music", message: "Check available storage and file access, then try again. The original files were kept.", preferredStyle: .alert)
          alert.addAction(UIAlertAction(title: "OK", style: .default))
          controller.present(alert, animated: true)
        }
        return
      }
      let local = destination.appendingPathComponent(first.lastPathComponent)
      let payload: [String: Any] = ["uri": local.path, "displayName": first.lastPathComponent]
      if self.dartReady { self.integration.invokeMethod("externalPlaybackIntent", arguments: payload) }
      else { self.pendingPlayback = payload }
    }
  }

  private func copyDocuments(_ urls: [URL], completion: @escaping (Result<URL, Error>) -> Void) {
    // Keep the import busy until copying is complete, including remote providers.
    fileQueue.async {
      do {
        let root = try self.libraryRoot()
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let staging = support.appendingPathComponent("Import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for source in urls {
          let scoped = source.startAccessingSecurityScopedResource()
          defer { if scoped { source.stopAccessingSecurityScopedResource() } }
          var coordinationError: NSError?
          var copyError: Error?
          NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges,
                                         error: &coordinationError) { coordinated in
            do {
              let name = coordinated.lastPathComponent
              guard name != ".", name != "..", !name.isEmpty else { throw CocoaError(.fileReadInvalidFileName) }
              try FileManager.default.copyItem(at: coordinated, to: staging.appendingPathComponent(name))
            } catch { copyError = error }
          }
          if let error = coordinationError { throw error }
          if let error = copyError { throw error }
        }
        #if !targetEnvironment(simulator)
        // Permit legitimate screen-off playback after the listener unlocks the
        // phone once, while retaining data protection across device restarts.
        let entries = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: [.isRegularFileKey])
        while let entry = entries?.nextObject() as? URL {
          if (try entry.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: entry.path)
          }
        }
        #endif
        let destination = root.appendingPathComponent("Import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.moveItem(at: staging, to: destination)
        DispatchQueue.main.async { completion(.success(destination)) }
      } catch {
        DispatchQueue.main.async { completion(.failure(error)) }
      }
    }
  }

  private func saveImage(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard let bytes = args["bytes"] as? FlutterStandardTypedData,
          let image = UIImage(data: bytes.data) else {
      result(FlutterError(code: "INVALID_IMAGE", message: "The image could not be read.", details: nil)); return
    }
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        DispatchQueue.main.async { result(FlutterError(code: "PHOTOS_PERMISSION", message: "Allow Lokal to save photos in Settings.", details: nil)) }; return
      }
      var identifier: String?
      PHPhotoLibrary.shared().performChanges({
        identifier = PHAssetChangeRequest.creationRequestForAsset(from: image).placeholderForCreatedAsset?.localIdentifier
      }) { success, _ in
        DispatchQueue.main.async {
          if success { result(identifier) }
          else { result(FlutterError(code: "PHOTOS_SAVE_FAILED", message: "The image could not be saved.", details: nil)) }
        }
      }
    }
  }

  deinit {
    for (command, target) in commandTargets { command.removeTarget(target) }
  }
}
