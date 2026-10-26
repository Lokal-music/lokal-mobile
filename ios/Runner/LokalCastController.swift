import Foundation
import GoogleCast

/// Native sender transport. Constructing this object does not initialize the SDK
/// or start network discovery. The Flutter bridge calls it only on the main queue.
/// No SDK error text is exposed: it may contain private receiver URLs or names.
final class LokalCastController: NSObject, GCKSessionManagerListener,
  GCKRemoteMediaClientListener {
  struct Failure: Error {
    let code: String
    let message: String
  }
  typealias Reply = (Result<Any?, Failure>) -> Void

  var onEvent: (([String: Any]) -> Void)?
  private var context: GCKCastContext?
  private var client: GCKRemoteMediaClient?
  private var ticker: Timer?
  private var discoveryReply: Reply?
  private var discoveryDeadline: DispatchWorkItem?
  private var connectionReply: Reply?
  private var connectionDeadline: DispatchWorkItem?
  private var disconnectReply: Reply?
  private var disconnectDeadline: DispatchWorkItem?
  private var ownedDeviceID: String?
  private var receiverMayBePlaying = false
  private var requests: [UUID: LokalCastRequest] = [:]

  #if DEBUG
  func initializeForAcceptance() -> [String: Any] {
    _ = prepare()
    return diagnosticState
  }

  var diagnosticState: [String: Any] {
    ["sdkInitialized": context != nil, "pendingRequests": requests.count,
     "discoveryActive": context?.discoveryManager.discoveryActive ?? false,
     "discoveryPending": discoveryReply != nil, "connectionPending": connectionReply != nil]
  }
  #endif

  func handle(_ method: String, arguments: [String: Any], reply: @escaping Reply) {
    dispatchPrecondition(condition: .onQueue(.main))
    switch method {
    case "discover": discover(reply)
    case "connect":
      guard let id = arguments["id"] as? String, !id.isEmpty else {
        reject(reply, "CAST_ARGUMENT", "Select a Cast device first."); return
      }
      connect(id, reply)
    case "disconnect": disconnect(reply)
    case "getVolume":
      guard let session = connectedSession else {
        reject(reply, "CAST_DISCONNECTED", "The Cast receiver is not connected."); return
      }
      reply(.success(Double(session.currentDeviceVolume)))
    case "setVolume":
      guard let value = arguments["volume"] as? NSNumber,
            value.doubleValue.isFinite, (0...1).contains(value.doubleValue) else {
        reject(reply, "CAST_ARGUMENT", "Volume must be between zero and one."); return
      }
      guard let session = connectedSession else {
        reject(reply, "CAST_DISCONNECTED", "The Cast receiver is not connected."); return
      }
      track(session.setDeviceVolume(value.floatValue), reply)
    case "load", "play", "pause", "stop", "seek":
      guard connectedSession != nil, let client = client else {
        reject(reply, "CAST_DISCONNECTED", "The Cast receiver is not connected."); return
      }
      switch method {
      case "load": load(arguments, client, reply)
      case "play":
        receiverMayBePlaying = true
        track(client.play(), reply)
      case "pause": track(client.pause(), reply)
      case "stop":
        track(client.stop()) { [weak self] result in
          if case .success = result { self?.receiverMayBePlaying = false }
          reply(result)
        }
      default:
        guard let ms = arguments["position"] as? NSNumber,
              ms.doubleValue.isFinite, ms.doubleValue >= 0 else {
          reject(reply, "CAST_ARGUMENT", "Choose a valid playback position."); return
        }
        let options = GCKMediaSeekOptions()
        options.interval = ms.doubleValue / 1000
        options.relative = false
        track(client.seek(with: options), reply)
      }
    case "getOutputRoutes": reply(.success([])) // AirPlay uses AVRoutePickerView.
    case "selectOutputRoute": reply(.success(false))
    default: reject(reply, "CAST_METHOD", "This Cast command is unavailable.")
    }
  }

  private var connectedSession: GCKCastSession? {
    guard let context = context, context.sessionManager.hasConnectedCastSession(),
          let session = context.sessionManager.currentCastSession,
          session.device.uniqueID == ownedDeviceID else { return nil }
    return session
  }

  private func prepare() -> GCKCastContext {
    if let context = context { return context }
    let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
    let options = GCKCastOptions(discoveryCriteria: criteria)
    options.disableDiscoveryAutostart = true
    options.startDiscoveryAfterFirstTapOnCastButton = false
    options.disableAnalyticsLogging = true
    options.physicalVolumeButtonsWillControlDeviceVolume = false
    // Background suspension ends only the sender connection, not receiver audio.
    options.suspendSessionsWhenBackgrounded = true
    GCKCastContext.setSharedInstanceWith(options)
    let context = GCKCastContext.sharedInstance()
    self.context = context
    context.sessionManager.add(self)
    return context
  }

  private func discover(_ reply: @escaping Reply) {
    guard discoveryReply == nil else {
      reject(reply, "CAST_BUSY", "Cast discovery is already running."); return
    }
    let manager = prepare().discoveryManager
    discoveryReply = reply
    manager.startDiscovery()
    let deadline = DispatchWorkItem { [weak self] in
      guard let self = self, let reply = self.discoveryReply else { return }
      self.discoveryReply = nil
      self.discoveryDeadline = nil
      var devices: [[String: Any]] = []
      for index in 0..<min(manager.deviceCount, 64) {
        let device = manager.device(at: index)
        devices.append(["id": device.uniqueID, "name": device.friendlyName ?? "Chromecast"])
      }
      manager.stopDiscovery()
      reply(.success(devices))
    }
    discoveryDeadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: deadline)
  }

  private func connect(_ id: String, _ reply: @escaping Reply) {
    guard connectionReply == nil, disconnectReply == nil else {
      reject(reply, "CAST_BUSY", "Wait for the current Cast connection change."); return
    }
    let context = prepare()
    let manager = context.sessionManager
    if manager.hasConnectedCastSession(), let session = manager.currentCastSession {
      guard session.device.uniqueID == id else {
        reject(reply, "CAST_BUSY", "Disconnect the current Cast receiver first."); return
      }
      ownedDeviceID = id
      receiverMayBePlaying = true // An existing session may already have audio.
      attach(session)
      reply(.success(nil))
      return
    }
    guard let device = context.discoveryManager.device(withUniqueID: id) else {
      reject(reply, "CAST_NOT_FOUND", "The receiver is no longer available. Search again."); return
    }
    ownedDeviceID = id
    connectionReply = reply
    let deadline = DispatchWorkItem { [weak self] in
      guard let self = self, self.connectionReply != nil else { return }
      self.ownedDeviceID = nil
      self.finishConnection(.failure(Failure(code: "CAST_TIMEOUT", message: "The Cast receiver did not connect in time.")))
      _ = manager.endSessionAndStopCasting(true)
    }
    connectionDeadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: deadline)
    if !manager.startSession(with: device) {
      ownedDeviceID = nil
      finishConnection(.failure(Failure(code: "CAST_CONNECTION", message: "The Cast connection could not be started.")))
    }
  }

  private func disconnect(_ reply: @escaping Reply) {
    guard disconnectReply == nil else {
      reject(reply, "CAST_BUSY", "A Cast disconnection is already running."); return
    }
    discoveryDeadline?.cancel()
    discoveryDeadline = nil
    let discovery = discoveryReply
    discoveryReply = nil
    context?.discoveryManager.stopDiscovery()
    discovery?(.failure(Failure(code: "CAST_CANCELLED", message: "Cast discovery was cancelled.")))
    finishConnection(.failure(Failure(code: "CAST_CANCELLED", message: "The Cast connection was cancelled.")))
    guard let manager = context?.sessionManager, manager.currentSession != nil else {
      if receiverMayBePlaying {
        reject(reply, "CAST_UNCERTAIN", "Reconnect to the receiver before confirming Stop casting."); return
      }
      detach()
      ownedDeviceID = nil
      reply(.success(nil)); return
    }
    disconnectReply = reply
    let deadline = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      // Keep ownership when receiver shutdown is unconfirmed. The caller must
      // not start local audio on a timeout and risk simultaneous playback.
      self.finishDisconnect(.failure(Failure(code: "CAST_TIMEOUT", message: "Receiver shutdown could not be confirmed. Try disconnecting again.")))
    }
    disconnectDeadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 40, execute: deadline)
    if receiverMayBePlaying {
      guard manager.hasConnectedCastSession(), let client = client else {
        finishDisconnect(.failure(Failure(code: "CAST_UNCERTAIN", message: "Reconnect to the receiver before confirming Stop casting."))); return
      }
      // Session-ended alone is not proof the receiver stopped (network loss can
      // end the sender session while audio continues). Require STOP acknowledgement.
      track(client.stop()) { [weak self] result in
        guard let self = self, self.disconnectReply != nil else { return }
        switch result {
        case .success:
          self.receiverMayBePlaying = false
          self.endConfirmedSession(manager)
        case .failure(let error): self.finishDisconnect(.failure(error))
        }
      }
    } else {
      endConfirmedSession(manager)
    }
  }

  private func endConfirmedSession(_ manager: GCKSessionManager) {
    detach()
    if !manager.endSessionAndStopCasting(true) {
      finishDisconnect(.failure(Failure(code: "CAST_CONNECTION", message: "Receiver shutdown could not be started.")))
    }
  }

  private func load(_ args: [String: Any], _ client: GCKRemoteMediaClient, _ reply: @escaping Reply) {
    guard let raw = args["url"] as? String, let url = URL(string: raw),
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          url.host != nil, url.user == nil, url.password == nil else {
      reject(reply, "CAST_SOURCE", "Cast requires a receiver-accessible HTTP audio source."); return
    }
    let metadata = GCKMediaMetadata(metadataType: .musicTrack)
    if let title = args["title"] as? String { metadata.setString(title, forKey: kGCKMetadataKeyTitle) }
    if let artist = args["artist"] as? String { metadata.setString(artist, forKey: kGCKMetadataKeyArtist) }
    let media = GCKMediaInformationBuilder(contentURL: url)
    media.streamType = .buffered
    media.contentType = args["contentType"] as? String ?? "audio/*"
    media.metadata = metadata
    let load = GCKMediaLoadRequestDataBuilder()
    load.mediaInformation = media.build()
    load.autoplay = NSNumber(value: args["autoplay"] as? Bool ?? true)
    if load.autoplay?.boolValue == true { receiverMayBePlaying = true }
    if let ms = args["position"] as? NSNumber, ms.doubleValue.isFinite, ms.doubleValue >= 0 {
      load.startTime = ms.doubleValue / 1000
    }
    track(client.loadMedia(with: load.build()), reply)
  }

  private func track(_ request: GCKRequest, _ reply: @escaping Reply) {
    let id = UUID()
    let pending = LokalCastRequest(request: request) { [weak self] result in
      self?.requests.removeValue(forKey: id)
      reply(result)
    }
    requests[id] = pending // SDK holds its request delegate weakly.
    pending.start()
  }

  private func attach(_ session: GCKCastSession) {
    detach()
    client = session.remoteMediaClient
    client?.add(self)
    ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.emitStatus() }
    emitStatus()
  }

  private func detach() {
    ticker?.invalidate()
    ticker = nil
    client?.remove(self)
    client = nil
    let pending = Array(requests.values)
    for request in pending { request.cancel() }
  }

  private func emitStatus() {
    guard let session = connectedSession, let client = client, let status = client.mediaStatus else { return }
    switch status.playerState {
    case .playing, .buffering, .loading: receiverMayBePlaying = true
    default: break
    }
    func milliseconds(_ seconds: TimeInterval) -> Int {
      guard seconds.isFinite, seconds >= 0 else { return 0 }
      return Int(min(seconds, Double(Int32.max)) * 1000)
    }
    onEvent?(["event": "status", "position": milliseconds(client.approximateStreamPosition()),
              "duration": milliseconds(status.mediaInformation?.streamDuration ?? 0),
              "playing": status.playerState == .playing])
    onEvent?(["event": "volume", "volume": Double(session.currentDeviceVolume)])
  }

  private func reject(_ reply: Reply, _ code: String, _ message: String) {
    reply(.failure(Failure(code: code, message: message)))
  }

  private func finishConnection(_ result: Result<Any?, Failure>) {
    connectionDeadline?.cancel()
    connectionDeadline = nil
    let reply = connectionReply
    connectionReply = nil
    reply?(result)
  }

  private func finishDisconnect(_ result: Result<Any?, Failure>) {
    disconnectDeadline?.cancel()
    disconnectDeadline = nil
    let reply = disconnectReply
    disconnectReply = nil
    reply?(result)
  }

  func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
    guard session.device.uniqueID == ownedDeviceID, disconnectReply == nil else { return }
    attach(session)
    finishConnection(.success(nil))
    onEvent?(["event": "sessionStarted"])
  }

  func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKCastSession, withError error: Error) {
    ownedDeviceID = nil
    finishConnection(.failure(Failure(code: "CAST_CONNECTION", message: "The receiver could not establish a Cast session.")))
  }

  func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
    detach()
    if !receiverMayBePlaying { ownedDeviceID = nil }
    finishConnection(.failure(Failure(code: "CAST_DISCONNECTED", message: "The Cast session ended before connecting.")))
    if receiverMayBePlaying {
      finishDisconnect(.failure(Failure(code: "CAST_UNCERTAIN", message: "The connection ended before receiver shutdown was confirmed.")))
    } else {
      finishDisconnect(.success(nil))
    }
    onEvent?(["event": "sessionEnded", "shutdownConfirmed": !receiverMayBePlaying])
  }

  func sessionManager(_ sessionManager: GCKSessionManager, didSuspend session: GCKCastSession, with reason: GCKConnectionSuspendReason) {
    detach()
    // Never emit sessionEnded here: suspension must not resume local playback.
    onEvent?(["event": "sessionSuspended"])
  }

  func sessionManager(_ sessionManager: GCKSessionManager, didResume session: GCKCastSession) {
    guard session.device.uniqueID == ownedDeviceID, disconnectReply == nil else { return }
    attach(session)
    onEvent?(["event": "sessionResumed"])
  }

  func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
    emitStatus()
  }
}

/// Exactly one completion, retained delegate, and bounded lifetime for every SDK
/// request. Cancelling request tracking does not promise to undo receiver work.
private final class LokalCastRequest: NSObject, GCKRequestDelegate {
  private let request: GCKRequest
  private var reply: LokalCastController.Reply?
  private var deadline: DispatchWorkItem?

  init(request: GCKRequest, reply: @escaping LokalCastController.Reply) {
    self.request = request
    self.reply = reply
  }

  func start() {
    request.delegate = self
    if !request.inProgress {
      if request.error != nil { failed() } else { finish(.success(nil)) }
      return
    }
    let deadline = DispatchWorkItem { [weak self] in
      self?.finish(.failure(.init(code: "CAST_TIMEOUT", message: "The receiver did not confirm the command in time.")))
    }
    self.deadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: deadline)
  }

  func cancel() {
    finish(.failure(.init(code: "CAST_DISCONNECTED", message: "The receiver connection changed before the command completed.")))
  }

  private func failed() {
    finish(.failure(.init(code: "CAST_REQUEST", message: "The Cast receiver could not complete the command.")))
  }

  private func finish(_ result: Result<Any?, LokalCastController.Failure>) {
    guard let reply = reply else { return }
    self.reply = nil
    deadline?.cancel()
    deadline = nil
    request.delegate = nil
    if request.inProgress { request.cancel() }
    reply(result)
  }

  func requestDidComplete(_ request: GCKRequest) { finish(.success(nil)) }
  func request(_ request: GCKRequest, didFailWithError error: GCKError) { failed() }
  func request(_ request: GCKRequest, didAbortWith reason: GCKRequestAbortReason) {
    finish(.failure(.init(code: "CAST_CANCELLED", message: "The Cast command was interrupted.")))
  }
}
