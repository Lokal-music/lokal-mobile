import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class NativeResult<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Result<T, Error>?
  func set(_ value: Result<T, Error>) { lock.lock(); defer { lock.unlock() }; self.value = value }
  func get() throws -> T {
    lock.lock(); defer { lock.unlock() }
    guard let value else { throw TestFailure.failed("No native result") }
    return try value.get()
  }
}

private func native<T: Sendable>(_ operation: (@escaping LokalTransferCompletion<T>) -> Void) throws -> T {
  let result = NativeResult<T>()
  let ready = DispatchSemaphore(value: 0)
  operation { value in result.set(value); ready.signal() }
  guard ready.wait(timeout: .now() + 10) == .success else { throw TestFailure.failed("Native operation timed out") }
  return try result.get()
}

private func state(_ origin: String) throws -> [String: Any] {
  let bytes: Data = try native { reply in
    URLSession.shared.dataTask(with: URL(string: origin + "/__state")!) { data, _, error in
      if let error { reply(.failure(error)) }
      else if let data { reply(.success(data)) }
      else { reply(.failure(TestFailure.failed("No fixture state"))) }
    }.resume()
  }
  guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
    throw TestFailure.failed("Invalid fixture state")
  }
  return value
}

private func awaitJob(_ runtime: LokalTransferRuntime, id: String,
                      phase: Set<LokalTransferPhase>) throws -> LokalTransferJob {
  let deadline = Date().addingTimeInterval(10)
  while Date() < deadline {
    let jobs: [LokalTransferJob] = try native { runtime.page(offset: 0, limit: 100, reply: $0) }
    if let job = jobs.first(where: { $0.id == id }), phase.contains(job.phase) { return job }
    Thread.sleep(forTimeInterval: 0.02)
  }
  throw TestFailure.failed("Native request did not reach expected phase")
}

private final class HostFixture: @unchecked Sendable {
  private let lock = NSLock()
  let root: URL
  private var blocked = true
  private var attempts = 0
  private var owners = Set<ObjectIdentifier>()
  private var failed = false
  init(_ root: URL) { self.root = root }
  func resolve() throws -> URL {
    lock.lock(); defer { lock.unlock() }
    attempts += 1
    if blocked { throw LokalTransferError.unsafeFile }
    return root
  }
  func allow() { lock.lock(); blocked = false; lock.unlock() }
  func record(_ owner: ObjectIdentifier?) {
    lock.lock(); defer { lock.unlock() }
    if let owner { owners.insert(owner) } else { failed = true }
  }
  func valid() -> Bool {
    lock.lock(); defer { lock.unlock() }
    return !failed && owners.count == 1 && attempts == 2
  }
}

private func runHostContracts() throws {
  let manager = FileManager.default
  let root = manager.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("lokal-native-host-" + UUID().uuidString)
  try manager.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? manager.removeItem(at: root) }
  let fixture = HostFixture(root)
  let host = LokalTransferHost(container: { try fixture.resolve() }, credentials: { nil })
  defer {
    let done = DispatchSemaphore(value: 0)
    host.shutdown { done.signal() }
    _ = done.wait(timeout: .now() + 10)
  }
  try rejects("unavailable storage cannot manufacture an empty working owner") {
    let _: LokalTransferSummary = try native { reply in
      host.withRuntime({ $0.summary(reply) }, unavailable: { reply(.failure($0)) })
    }
  }
  fixture.allow()
  let callers = DispatchGroup()
  for _ in 0..<12 {
    callers.enter()
    host.withRuntime({ runtime in
      fixture.record(ObjectIdentifier(runtime)); callers.leave()
    }, unavailable: { _ in fixture.record(nil); callers.leave() })
  }
  try require(callers.wait(timeout: .now() + 10) == .success && fixture.valid(),
    "concurrent engine clients share one native owner after recoverable storage unavailability")
  let summary: LokalTransferSummary = try native { reply in
    host.withRuntime({ $0.summary(reply) }, unavailable: { reply(.failure($0)) })
  }
  try require(summary.total == 0 && !summary.persistenceFailed, "host recovered the real empty journal")
  let stopped = DispatchSemaphore(value: 0)
  host.shutdown { stopped.signal() }
  try require(stopped.wait(timeout: .now() + 10) == .success, "host teardown waits for native owner")
  try rejects("stopped host cannot be revived by a late engine client") {
    let _: LokalTransferSummary = try native { reply in
      host.withRuntime({ $0.summary(reply) }, unavailable: { reply(.failure($0)) })
    }
  }
  print("Native app-owner contracts passed: unavailable storage recovery, 12 concurrent clients, one session owner and retired teardown. Portable evidence only.")
}

func runNetworkContracts(origin: String, length: Int64, checksum: String) throws {
  try runHostContracts()
  let manager = FileManager.default
  let root = manager.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("lokal-native-network-" + UUID().uuidString)
  try manager.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? manager.removeItem(at: root) }
  let authorization = try LokalTransferAuthorization(desktopID: "fixture-pc", origin: origin, token: "transfer-fixture-token")
  let runtime = try LokalTransferRuntime(container: root, credentials: { authorization })
  defer {
    let done = DispatchSemaphore(value: 0)
    runtime.shutdown { done.signal() }
    _ = done.wait(timeout: .now() + 10)
  }
  func job(_ source: String, expected: Bool = true) throws -> LokalTransferJob {
    try LokalTransferJob(direction: .download,
      identity: LokalTransferIdentity(desktopID: "fixture-pc", sourceID: source, localSongID: nil, origin: origin),
      metadata: LokalTransferMetadata(title: source, artist: "Native fixture", album: nil, fileExtension: "wav"),
      nowMs: 1000, expectedBytes: length, expectedSHA256: expected ? checksum : nil)
  }
  func enqueue(_ jobs: [LokalTransferJob]) throws {
    let _: LokalTransferSummary = try native { runtime.enqueue(jobs, reply: $0) }
  }
  let pairing: LokalTransferPairing? = try native { runtime.currentPairing($0) }
  try require(pairing?.scope.desktopID == "fixture-pc" && pairing?.scope.origin == origin,
    "public native pairing descriptor preserves the authorized scope")

  let complete = try job("complete")
  try enqueue([complete])
  try enqueue([complete])
  let received = try awaitJob(runtime, id: complete.id, phase: [.downloaded])
  try require(received.receivedSHA256 == nil, "networking and verification are separate")
  let verified: LokalTransferJob = try native { runtime.verify(id: complete.id, revision: 1, reply: $0) }
  try require(verified.phase == .staged && verified.receivedSHA256 == checksum,
    "actual URLSession bytes match the standalone HTTP fixture")
  let owned = try LokalTransferFiles(container: root).inspect(verified)
  try require(owned.bytes == length && owned.sha256 == checksum, "actual retained media survives verification")
  let afterComplete = try state(origin)
  try require((afterComplete["requests"] as? [String: Int])?["complete"] == 1,
    "lost/repeated submission does not duplicate a native request")
  try rejects("a reconstructed plan cannot start a second copy of an active original") {
    try enqueue([job("complete")])
  }

  let unacknowledged = try LokalTransferJob(direction: .download,
    identity: LokalTransferIdentity(desktopID: "another-desktop", sourceID: "recover-only", localSongID: nil, origin: origin),
    metadata: complete.metadata, nowMs: 1000)
  try LokalTransferJournal(container: root).create([unacknowledged])
  let recovered: LokalTransferSummary = try native { runtime.recover($0) }
  try require(recovered.total == 2 && !recovered.persistenceFailed,
    "recovery reloads committed intent missing from an acknowledgement cache")
  try require((try state(origin))["requests"] as? [String: Int] != nil, "actual recovery fixture remains responsive")
  try require(((try state(origin))["requests"] as! [String: Int])["recover-only"] == nil,
    "recovered work for another desktop never inherits the active token")

  let redirect = try job("redirect")
  try enqueue([redirect])
  _ = try awaitJob(runtime, id: redirect.id, phase: [.failed])
  try require((try state(origin))["redirectHits"] as? Int == 0, "redirect not followed with pairing header")

  let truncated = try job("truncated")
  try enqueue([truncated])
  _ = try awaitJob(runtime, id: truncated.id, phase: [.failed, .interrupted])
  try require(LokalTransferFiles(container: root).retainedSize(truncated) == nil, "partial native response never staged")

  let checksumJob = try job("bad-checksum", expected: false)
  try enqueue([checksumJob])
  _ = try awaitJob(runtime, id: checksumJob.id, phase: [.downloaded])
  try rejects("actual mismatched bytes cannot become verified media") {
    let _: LokalTransferJob = try native { runtime.verify(id: checksumJob.id, revision: 1, reply: $0) }
  }
  let checksumFailed = try awaitJob(runtime, id: checksumJob.id, phase: [.failed])
  try require(checksumFailed.lastFailure == .checksum, "checksum failure persists an actionable category")

  let cancelled = try job("slow")
  try enqueue([cancelled])
  _ = try awaitJob(runtime, id: cancelled.id, phase: [.transferring])
  let cancellation: LokalTransferJob = try native { runtime.cancel(id: cancelled.id, revision: 1, reply: $0) }
  try require(cancellation.revision == 2 && cancellation.phase == .cancelled, "cancel retires actual request revision")
  Thread.sleep(forTimeInterval: 0.1)
  let late = try awaitJob(runtime, id: cancelled.id, phase: [.cancelled])
  try require(late.revision == 2 && late.receivedSHA256 == nil, "late callbacks cannot resurrect cancelled media")

  let unauthorized = try job("unauthorized"), inFlight = try job("slow"), blocked = try job("after-auth")
  try enqueue([unauthorized, inFlight, blocked])
  let rejected = try awaitJob(runtime, id: unauthorized.id, phase: [.failed])
  try require(rejected.lastFailure == .unauthorized, "pairing refusal is explicit")
  Thread.sleep(forTimeInterval: 0.1)
  let paused: LokalTransferSummary = try native { runtime.summary($0) }
  try require(paused.pauses.count == 1, "pairing failure pauses this desktop queue")
  try require((try state(origin))["requests"] as? [String: Int] != nil, "fixture reports actual requests")
  let pausedRequests = (try state(origin))["requests"] as! [String: Int]
  try require(pausedRequests["after-auth"] == nil, "remaining queue is not drained with rejected authorization")
  let scope = LokalTransferScope(desktopID: "fixture-pc", origin: origin)
  let _: LokalTransferSummary = try native { runtime.resume(scope: scope, reply: $0) }
  _ = try awaitJob(runtime, id: blocked.id, phase: [.downloaded])
  try require((try state(origin))["cookiesSeen"] as? Bool == false, "shared cookies are not attached to later requests")
  let stopped = DispatchSemaphore(value: 0)
  runtime.shutdown { stopped.signal() }
  runtime.shutdown { stopped.signal() }
  try require(stopped.wait(timeout: .now() + 10) == .success && stopped.wait(timeout: .now() + 10) == .success,
    "repeated shutdown acknowledges every caller after native file work settles")
  try rejects("shutdown cannot accept another intent") { try enqueue([job("after-shutdown")]) }
  let reopened = try LokalTransferRuntime(container: root, credentials: { authorization })
  defer {
    let done = DispatchSemaphore(value: 0)
    reopened.shutdown { done.signal() }
    _ = done.wait(timeout: .now() + 10)
  }
  let _: LokalTransferSummary = try native { reopened.recover($0) }
  let reopenedComplete = try awaitJob(reopened, id: complete.id, phase: [.staged])
  try require(reopenedComplete.receivedSHA256 == checksum, "verified actual bytes and receipt survive runtime reconstruction")
  print("Native URLSession HTTP contracts passed: real WAV bytes, idempotent submission, redirect refusal, truncation, checksum verification, cancellation and persisted pairing pause. Not iOS daemon/suspension acceptance.")
}
