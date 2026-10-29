import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// AppDelegate owns this object, independently of any Flutter engine. Opening
/// storage and reconnecting the OS session never block the main/UI queue.
final class LokalTransferHost: @unchecked Sendable {
  let importOwnership = LokalTransferImportOwnership()
  private let queue = DispatchQueue(label: "app.lokal.mobile.transfer-host", qos: .utility)
  private let container: @Sendable () throws -> URL
  private let credentials: @Sendable () throws -> LokalTransferAuthorization?
  private let configuration: @Sendable () -> URLSessionConfiguration?
  private var runtime: LokalTransferRuntime?
  private var stopped = false
  private var pendingBackgroundReplies: [BackgroundReply] = []

  private final class BackgroundReply: @unchecked Sendable {
    private let callback: () -> Void
    private let lock = NSLock()
    private var sent = false
    init(_ callback: @escaping () -> Void) { self.callback = callback }
    func send() {
      lock.lock()
      guard !sent else { lock.unlock(); return }
      sent = true
      lock.unlock()
      DispatchQueue.main.async { self.callback() }
    }
  }

  static func applicationContainer() throws -> URL {
    try FileManager.default.url(for: .applicationSupportDirectory,
      in: .userDomainMask, appropriateFor: nil, create: true)
  }

  static func backgroundCredentials() throws -> LokalTransferAuthorization? {
    #if canImport(Security)
    return try LokalTransferCredentials.read()
    #else
    return nil
    #endif
  }

  init(container: @escaping @Sendable () throws -> URL = { try applicationContainer() },
       configuration: @escaping @Sendable () -> URLSessionConfiguration? = { nil },
       credentials: @escaping @Sendable () throws -> LokalTransferAuthorization? = { try backgroundCredentials() }) {
    self.container = container
    self.configuration = configuration
    self.credentials = credentials
  }

  private func resolve() throws -> LokalTransferRuntime {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !stopped else { throw LokalTransferError.invalidTransition }
    if let runtime { return runtime }
    let value = try LokalTransferRuntime(container: container(), configuration: configuration(),
      importOwnership: importOwnership, credentials: credentials)
    runtime = value
    let pending = pendingBackgroundReplies
    pendingBackgroundReplies.removeAll()
    for reply in pending { value.handleBackgroundEvents { reply.send() } }
    return value
  }

  func start() {
    withRuntime({ _ in }, unavailable: { _ in })
  }

  func stopObserving(id: String) {
    queue.async { self.runtime?.stopObserving(id: id) }
  }

  func withRuntime(_ operation: @escaping @Sendable (LokalTransferRuntime) -> Void,
                   unavailable: @escaping @Sendable (Error) -> Void) {
    queue.async {
      do { operation(try self.resolve()) }
      catch { unavailable(error) }
    }
  }

  /// Storage failure never acknowledges OS delivery as if events had committed.
  /// Keep the callback until a later successful initialization can reconcile.
  func handleBackgroundEvents(completion: @escaping () -> Void) {
    let reply = BackgroundReply(completion)
    queue.async {
      do { try self.resolve().handleBackgroundEvents { reply.send() } }
      catch { self.pendingBackgroundReplies.append(reply) }
    }
  }

  /// Tests and explicit teardown only; normal engine detachment leaves the app's
  /// native owner and OS transfers alive. Runtime teardown is itself idempotent.
  func shutdown(_ reply: @escaping @Sendable () -> Void) {
    importOwnership.revokeAll()
    queue.async {
      self.stopped = true
      if let runtime = self.runtime { runtime.shutdown(reply) }
      else { reply() }
    }
  }
}
