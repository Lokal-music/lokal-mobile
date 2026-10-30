import Foundation
import Flutter
import UIKit

private struct LokalTransferCapability: Encodable, Sendable {
  let available = true
  let protocolVersion = LokalTransferProtocol.version
  let download = true
  // The product adapter must require acknowledged library import before it
  // replaces existing copy flows. These flags describe actual implemented APIs.
  let libraryImport = false
  let upload = false
  let maximumIntents = LokalTransferProtocol.maximumBatch
  let maximumIntentBytes = LokalTransferProtocol.maximumPayloadBytes
}

private final class LokalTransferReply: @unchecked Sendable {
  private enum Value: Sendable {
    case data(Data), empty, failure(String, String)
  }
  private let callback: FlutterResult
  private let lock = NSLock()
  private var delivered = false
  init(_ callback: @escaping FlutterResult) { self.callback = callback }

  private func send(_ value: Value) {
    lock.lock()
    guard !delivered else { lock.unlock(); return }
    delivered = true
    lock.unlock()
    DispatchQueue.main.async {
      dispatchPrecondition(condition: .onQueue(.main))
      switch value {
      case .data(let bytes): self.callback(FlutterStandardTypedData(bytes: bytes))
      case .empty: self.callback(nil)
      case .failure(let code, let message):
        self.callback(FlutterError(code: code, message: message, details: nil))
      }
    }
  }

  func empty() { send(.empty) }
  func unsupported() { send(.failure("UNSUPPORTED_TRANSFER_METHOD", "Unknown transfer operation.")) }

  func encode<T: Encodable & Sendable>(_ result: Result<T, Error>) {
    do { send(.data(try JSONEncoder().encode(result.get()))) }
    catch { failure(error) }
  }

  func failure(_ error: Error) {
    if let failure = error as? LokalTransferError {
      switch failure {
      case .invalidRecord, .limitExceeded:
        send(.failure("INVALID_TRANSFER_REQUEST", "Invalid transfer request or queue limit."))
      case .staleRevision:
        send(.failure("TRANSFER_CHANGED", "This transfer changed. Refresh and try again."))
      case .duplicateJob:
        send(.failure("TRANSFER_ALREADY_QUEUED", "This original is already queued."))
      case .missingJob:
        send(.failure("TRANSFER_MISSING", "This transfer is no longer available."))
      case .invalidTransition:
        send(.failure("TRANSFER_NOT_READY", "This transfer cannot perform that operation now."))
      case .checksumMismatch:
        send(.failure("TRANSFER_CHECKSUM_MISMATCH", "The transferred file did not match its checksum."))
      case .unsupportedSchema:
        send(.failure("TRANSFER_STORAGE_NEEDS_REPAIR", "Transfer storage needs a compatible app version or repair."))
      case .unsafeFile, .posix, .database:
        send(.failure("TRANSFER_STORAGE_UNAVAILABLE", "Transfer storage is unavailable."))
      }
    } else if error is DecodingError || error is EncodingError {
      send(.failure("INVALID_TRANSFER_REQUEST", "Invalid transfer document."))
    } else if error is LokalTransferCredentialError {
      send(.failure("TRANSFER_PAIRING_UNAVAILABLE", "Reconnect to your paired desktop before starting transfers."))
    } else {
      // Never forward NSError/JSON/HTTP descriptions containing request or
      // credential bytes. The UI localizes these fixed protocol error codes.
      send(.failure("TRANSFER_OPERATION_FAILED", "The transfer operation could not be completed."))
    }
  }
}

private enum LokalTransferOperation: String, Sendable {
  case capability, summary, page, enqueue, cancel, retry, resume, verify, recover, currentPairing

  var needsPayload: Bool {
    switch self {
    case .page, .enqueue, .cancel, .retry, .resume, .verify: return true
    default: return false
    }
  }
}

private func executeTransfer(_ operation: LokalTransferOperation, payload: Data?,
                             runtime: LokalTransferRuntime, reply: LokalTransferReply) {
  do {
    switch operation {
    case .capability: reply.encode(.success(LokalTransferCapability()))
    case .summary: runtime.summary { reply.encode($0) }
    case .currentPairing: runtime.currentPairing { reply.encode($0) }
    case .recover: runtime.recover { reply.encode($0) }
    case .page:
      let request = try LokalTransferProtocol.page(payload!)
      runtime.page(offset: request.offset, limit: request.limit) { reply.encode($0) }
    case .enqueue:
      runtime.enqueue(try LokalTransferProtocol.intents(payload!)) { reply.encode($0) }
    case .resume:
      runtime.resume(scope: try LokalTransferProtocol.scope(payload!)) { reply.encode($0) }
    case .cancel, .retry, .verify:
      let request = try LokalTransferProtocol.control(payload!)
      switch operation {
      case .cancel: runtime.cancel(id: request.id, revision: request.revision) { reply.encode($0) }
      case .retry: runtime.retry(id: request.id, revision: request.revision) { reply.encode($0) }
      case .verify: runtime.verify(id: request.id, revision: request.revision) { reply.encode($0) }
      default: break
      }
    }
  } catch { reply.failure(error) }
}

private final class LokalTransferObservationLease: @unchecked Sendable {
  let id = UUID().uuidString.lowercased()
  private let host: LokalTransferHost
  init(_ host: LokalTransferHost) { self.host = host }
  func stop() { host.stopObserving(id: id) }
  deinit { stop() }
}

/// Independent of foreground observation: inactive scenes retain their root
/// client, while releasing/replacing an engine immediately cancels its import.
private final class LokalTransferImportEngineLease: @unchecked Sendable {
  let id: String
  private let ownership: LokalTransferImportOwnership
  init(_ ownership: LokalTransferImportOwnership) {
    self.ownership = ownership
    id = ownership.attachEngine()
  }
  deinit { ownership.detachEngine(id) }
}

private final class LokalTransferNotifications: @unchecked Sendable {
  // Registration occurs once during main-actor initialization. Afterwards the
  // immutable tokens are only removed when their owner is released.
  private var tokens: [NSObjectProtocol] = []
  func add(_ token: NSObjectProtocol) { tokens.append(token) }
  deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}

/// Main-actor channel and observation only. Typed work and replies cross to
/// utility/native queues; engine disposal never tears down the app's session.
@MainActor
final class LokalTransferBridge {
  private let channel: FlutterMethodChannel
  private let host: LokalTransferHost
  private let lease: LokalTransferObservationLease
  private let importEngine: LokalTransferImportEngineLease
  private var importOwner: LokalTransferImportOwnership.Owner?
  private let notifications = LokalTransferNotifications()
  private var clientID: String?
  private var wantsObservation = false
  private var active: Bool

  init(messenger: FlutterBinaryMessenger, host: LokalTransferHost) {
    self.host = host
    channel = FlutterMethodChannel(name: "lokal/transfers", binaryMessenger: messenger)
    lease = LokalTransferObservationLease(host)
    importEngine = LokalTransferImportEngineLease(host.importOwnership)
    active = UIApplication.shared.applicationState == .active
    channel.setMethodCallHandler { [weak self] call, result in
      let reply = LokalTransferReply(result)
      guard let self else { reply.failure(LokalTransferError.invalidTransition); return }
      self.handle(call, reply: reply)
    }
    notifications.add(NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      DispatchQueue.main.async { self?.setActive(false) }
    })
    notifications.add(NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      DispatchQueue.main.async { self?.setActive(true) }
    })
  }

  private func setActive(_ value: Bool) { active = value; updateObservation() }

  private func updateObservation() {
    guard active, wantsObservation, let owner = importOwner else { lease.stop(); return }
    let ownerID = lease.id
    let ownership = host.importOwnership
    host.withRuntime({ [weak self] runtime in
      runtime.observe(id: ownerID, when: { (try? ownership.capture(owner)) != nil }) { [weak self] in
        DispatchQueue.main.async { self?.changed() }
      }
    }, unavailable: { _ in })
  }

  private func changed() {
    guard active, wantsObservation, let owner = importOwner,
          (try? host.importOwnership.capture(owner)) != nil else { return }
    channel.invokeMethod("changed", arguments: nil)
  }

  private func handle(_ call: FlutterMethodCall, reply: LokalTransferReply) {
    if call.method == "observe" || call.method == "stopObserving" {
      do {
        guard let data = call.arguments as? FlutterStandardTypedData, data.data.count <= 8192 else {
          throw LokalTransferError.invalidRecord
        }
        let client = try LokalTransferProtocol.client(data.data)
        if call.method == "observe" {
          importOwner = try host.importOwnership.attachClient(engineID: importEngine.id, clientID: client.clientID)
          clientID = client.clientID
          wantsObservation = true
          updateObservation()
        } else if clientID == client.clientID {
          if let owner = importOwner { host.importOwnership.stopClient(owner) }
          importOwner = nil
          wantsObservation = false
          lease.stop()
        }
        reply.empty()
      } catch { reply.failure(error) }
      return
    }
    if ["drainImports", "importCandidatesPage", "importWorkPage", "claimImport", "claimImportCleanup", "claimOrphanCleanup", "validateOrphanCleanup", "resolveImportCleanup", "finalizeImportCleanup", "publishImport", "acknowledgeImport", "validateImport", "validateImportCleanup", "validateImportReconciliation", "releaseImport"].contains(call.method) {
      handleImport(call, reply: reply)
      return
    }
    guard let operation = LokalTransferOperation(rawValue: call.method) else { reply.unsupported(); return }
    let bytes: Data?
    if operation.needsPayload {
      let budget = operation == .enqueue ? LokalTransferProtocol.maximumPayloadBytes : 8192
      guard let data = call.arguments as? FlutterStandardTypedData,
            !data.data.isEmpty, data.data.count <= budget else {
        reply.failure(LokalTransferError.invalidRecord); return
      }
      bytes = data.data
    } else {
      guard call.arguments == nil else { reply.failure(LokalTransferError.invalidRecord); return }
      bytes = nil
    }
    host.withRuntime({ runtime in
      executeTransfer(operation, payload: bytes, runtime: runtime, reply: reply)
    }, unavailable: { reply.failure($0) })
  }

  private func handleImport(_ call: FlutterMethodCall, reply: LokalTransferReply) {
    do {
      guard let data = call.arguments as? FlutterStandardTypedData,
            !data.data.isEmpty, data.data.count <= 8192 else { throw LokalTransferError.invalidRecord }
      if call.method == "drainImports" {
        let request = try LokalTransferProtocol.client(data.data)
        guard let owner = importOwner else { throw LokalTransferError.invalidTransition }
        guard request.clientID == clientID else { throw LokalTransferError.staleRevision }
        let ticket = try host.importOwnership.capture(owner)
        host.withRuntime({ runtime in runtime.drainImports(ticket: ticket) { reply.encode($0) } },
                         unavailable: { reply.failure($0) })
      } else if call.method == "importWorkPage" || call.method == "importCandidatesPage" {
        let request = try LokalTransferProtocol.importWorkPage(data.data)
        guard let owner = importOwner else { throw LokalTransferError.invalidTransition }
        guard request.clientID == clientID else { throw LokalTransferError.staleRevision }
        let ticket = try host.importOwnership.capture(owner)
        if call.method == "importWorkPage" {
          host.withRuntime({ runtime in runtime.importWorkPage(request, ticket: ticket) { reply.encode($0) } },
                           unavailable: { reply.failure($0) })
        } else {
          host.withRuntime({ runtime in runtime.importCandidatesPage(request, ticket: ticket) { reply.encode($0) } },
                           unavailable: { reply.failure($0) })
        }
      } else if call.method == "claimOrphanCleanup" {
        let request = try LokalTransferProtocol.importOrphanClaim(data.data)
        guard let owner = importOwner else { throw LokalTransferError.invalidTransition }
        guard request.clientID == clientID else { throw LokalTransferError.staleRevision }
        let ownership = host.importOwnership
        let ticket = try ownership.beginCleanup(ownership.capture(owner))
        host.withRuntime({ runtime in runtime.claimOrphanCleanup(request, ticket: ticket) { reply.encode($0) } },
                         unavailable: { ownership.abortCleanup(ticket); reply.failure($0) })
      } else if call.method == "claimImportCleanup" {
        let request = try LokalTransferProtocol.importCleanupClaim(data.data)
        guard let owner = importOwner else { throw LokalTransferError.invalidTransition }
        guard request.clientID == clientID else { throw LokalTransferError.staleRevision }
        let ownership = host.importOwnership
        let ticket = try ownership.beginCleanup(ownership.capture(owner))
        host.withRuntime({ runtime in runtime.claimImportCleanup(request, ticket: ticket) { reply.encode($0) } },
                         unavailable: { ownership.abortCleanup(ticket); reply.failure($0) })
      } else if call.method == "resolveImportCleanup" || call.method == "finalizeImportCleanup" {
        let request = try LokalTransferProtocol.importCleanupDecision(data.data,
          finalized: call.method == "finalizeImportCleanup")
        guard let owner = importOwner else { throw LokalTransferError.invalidTransition }
        guard request.clientID == clientID else { throw LokalTransferError.staleRevision }
        try host.importOwnership.validateCleanup(owner, jobID: request.id,
          revision: request.revision, leaseID: request.leaseID)
        if call.method == "resolveImportCleanup" {
          host.withRuntime({ runtime in runtime.resolveImportCleanup(request, owner: owner) { reply.encode($0) } },
                           unavailable: { reply.failure($0) })
        } else {
          host.withRuntime({ runtime in runtime.finalizeImportCleanup(request, owner: owner) { reply.encode($0) } },
                           unavailable: { reply.failure($0) })
        }
      } else if call.method == "claimImport" {
        let request = try LokalTransferProtocol.importClaim(data.data)
        guard let owner = importOwner else { throw LokalTransferError.invalidTransition }
        guard request.clientID == clientID else { throw LokalTransferError.staleRevision }
        // Capture before host/runtime dispatch, so a queued claim cannot cross
        // clear, revocation, client replacement or engine disposal barriers.
        let ticket = try host.importOwnership.capture(owner)
        host.withRuntime({ runtime in runtime.claimImport(request, ticket: ticket) { reply.encode($0) } },
                         unavailable: { reply.failure($0) })
      } else if call.method == "publishImport" || call.method == "acknowledgeImport" {
        let request = try LokalTransferProtocol.importPublication(data.data)
        guard let owner = importOwner else { throw LokalTransferError.invalidTransition }
        guard request.clientID == clientID else { throw LokalTransferError.staleRevision }
        try host.importOwnership.validate(owner, jobID: request.id, revision: request.revision,
          leaseID: request.leaseID, requiresWrite: call.method == "publishImport")
        if call.method == "publishImport" {
          host.withRuntime({ runtime in runtime.publishImport(request, owner: owner) { reply.encode($0) } },
                           unavailable: { reply.failure($0) })
        } else {
          host.withRuntime({ runtime in runtime.acknowledgeImport(request, owner: owner) { reply.encode($0) } },
                           unavailable: { reply.failure($0) })
        }
      } else {
        let request = try LokalTransferProtocol.importLease(data.data)
        guard let owner = importOwner else { throw LokalTransferError.invalidTransition }
        guard request.clientID == clientID else { throw LokalTransferError.staleRevision }
        if call.method == "releaseImport" {
          // Stop publication before entering a potentially busy host queue.
          try host.importOwnership.cancel(owner, jobID: request.id,
            revision: request.revision, leaseID: request.leaseID)
          host.withRuntime({ runtime in runtime.releaseImport(request, owner: owner) { reply.encode($0) } },
                           unavailable: { reply.failure($0) })
        } else if call.method == "validateOrphanCleanup" {
          try host.importOwnership.validateOrphanCleanup(owner, jobID: request.id,
            revision: request.revision, leaseID: request.leaseID)
          reply.encode(.success(true))
        } else if call.method == "validateImportCleanup" {
          try host.importOwnership.validateCleanup(owner, jobID: request.id,
            revision: request.revision, leaseID: request.leaseID)
          reply.encode(.success(true))
        } else {
          // Intentionally direct. Isar's writer must not wait behind native
          // fsync, hashing, journal I/O or a Keychain read to check ownership.
          try host.importOwnership.validate(owner, jobID: request.id, revision: request.revision,
            leaseID: request.leaseID, requiresWrite: call.method == "validateImport")
          reply.encode(.success(true))
        }
      }
    } catch { reply.failure(error) }
  }
}
