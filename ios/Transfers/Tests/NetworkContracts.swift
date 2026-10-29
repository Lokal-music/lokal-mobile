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
  try runRuntimeImportContracts(origin: origin, length: length, checksum: checksum)
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

/// Real runtime queue, journal, HTTP staging and independent lock guard. The
/// blocked credential read stands at the native I/O boundary; no queue or job
/// implementation is replaced. This does not qualify iOS/Isar product import.
private final class ImportAuthorizationFixture: @unchecked Sendable {
  private let lock = NSLock()
  private var authorization: LokalTransferAuthorization?
  private var nextBarrier: (DispatchSemaphore, DispatchSemaphore)?
  init(_ authorization: LokalTransferAuthorization) { self.authorization = authorization }
  func set(_ authorization: LokalTransferAuthorization?) {
    lock.lock(); defer { lock.unlock() }; self.authorization = authorization
  }
  func blockNextRead(entered: DispatchSemaphore, resume: DispatchSemaphore) {
    lock.lock(); defer { lock.unlock() }; nextBarrier = (entered, resume)
  }
  func read() throws -> LokalTransferAuthorization? {
    lock.lock()
    let barrier = nextBarrier
    nextBarrier = nil
    lock.unlock()
    if let barrier {
      barrier.0.signal()
      guard barrier.1.wait(timeout: .now() + 10) == .success else {
        throw TestFailure.failed("Import credential boundary was not released")
      }
    }
    lock.lock(); defer { lock.unlock() }; return authorization
  }
}

private func runRuntimeImportContracts(origin: String, length: Int64, checksum: String) throws {
  let manager = FileManager.default
  let root = manager.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("lokal-runtime-import-" + UUID().uuidString)
  try manager.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? manager.removeItem(at: root) }
  let authorization = try LokalTransferAuthorization(desktopID: "fixture-pc", origin: origin,
    token: "transfer-fixture-token")
  let credentials = ImportAuthorizationFixture(authorization)
  let ownership = LokalTransferImportOwnership()
  let runtime = try LokalTransferRuntime(container: root, importOwnership: ownership,
    credentials: { try credentials.read() })
  defer {
    let done = DispatchSemaphore(value: 0)
    runtime.shutdown { done.signal() }
    _ = done.wait(timeout: .now() + 10)
  }
  let job = try LokalTransferJob(direction: .download,
    identity: LokalTransferIdentity(desktopID: "fixture-pc", sourceID: "import-fixture",
      localSongID: nil, origin: origin),
    metadata: LokalTransferMetadata(title: "Import fixture", artist: "Native fixture", album: nil,
      fileExtension: "wav"), nowMs: 1000, expectedBytes: length, expectedSHA256: checksum)
  let _: LokalTransferSummary = try native { runtime.recover($0) }
  let _: LokalTransferSummary = try native { runtime.enqueue([job], reply: $0) }
  _ = try awaitJob(runtime, id: job.id, phase: [.downloaded])
  let staged: LokalTransferJob = try native { runtime.verify(id: job.id, revision: 1, reply: $0) }
  let engine = ownership.attachEngine()
  let owner = try ownership.attachClient(engineID: engine, clientID: UUID().uuidString.lowercased())
  let write = LokalTransferProtocol.ImportClaim(id: job.id, revision: 1, reconcileOnly: false, clientID: owner.clientID)
  let recovery = LokalTransferProtocol.ImportClaim(id: job.id, revision: 1, reconcileOnly: true, clientID: owner.clientID)
  func claim(_ request: LokalTransferProtocol.ImportClaim,
             _ owner: LokalTransferImportOwnership.Owner) throws -> LokalTransferImportClaim {
    let ticket = try ownership.capture(owner)
    let bound = LokalTransferProtocol.ImportClaim(id: request.id, revision: request.revision,
      reconcileOnly: request.reconcileOnly, clientID: owner.clientID)
    return try native { runtime.claimImport(bound, ticket: ticket, reply: $0) }
  }
  func control(_ claim: LokalTransferImportClaim) -> LokalTransferProtocol.ImportLease {
    LokalTransferProtocol.ImportLease(id: claim.job.id, revision: claim.job.revision,
      leaseID: claim.leaseID, clientID: claim.clientID)
  }
  try rejects("read-only recovery cannot move a staged job into validation") { _ = try claim(recovery, owner) }
  let queuedEntered = DispatchSemaphore(value: 0), queuedResume = DispatchSemaphore(value: 0)
  let queuedDone = DispatchSemaphore(value: 0)
  let queuedResult = NativeResult<LokalTransferImportClaim>()
  credentials.blockNextRead(entered: queuedEntered, resume: queuedResume)
  let beforeClaim = try ownership.capture(owner)
  runtime.claimImport(write, ticket: beforeClaim) { queuedResult.set($0); queuedDone.signal() }
  try require(queuedEntered.wait(timeout: .now() + 5) == .success,
    "unclaimed runtime work reached its real credential boundary")
  ownership.revokeAll()
  queuedResume.signal()
  try require(queuedDone.wait(timeout: .now() + 5) == .success, "revoked queued claim settles")
  try rejects("revocation before any lease exists fences the queued runtime claim") { _ = try queuedResult.get() }
  let stillStaged = try awaitJob(runtime, id: job.id, phase: [.staged])
  try require(stillStaged.revision == 1, "revoked queued claim never advances durable validation")
  let first = try claim(write, owner)
  try require(first.job.phase == .validating && first.job.receivedSHA256 == checksum &&
    !first.reconcileOnly && first.sourcePath == LokalTransferFiles(container: root).importURL(first.job).path &&
    first.targetRelativePath == LokalTransferLibrary.directoryName + "/" + LokalTransferLibrary.fileName(staged),
    "actual staged bytes acquire a native-derived, revision-bound import target")
  try require(claim(write, owner).leaseID == first.leaseID, "lost runtime claim reply coalesces to the same lease")
  try rejects("a read-only claim cannot silently reuse a writer lease") { _ = try claim(recovery, owner) }

  let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
  let duplicateDone = DispatchSemaphore(value: 0), releaseDone = DispatchSemaphore(value: 0)
  let duplicate = NativeResult<LokalTransferImportClaim>(), release = NativeResult<Bool>()
  credentials.blockNextRead(entered: entered, resume: resume)
  let queued = try ownership.capture(owner)
  runtime.claimImport(write, ticket: queued) { duplicate.set($0); duplicateDone.signal() }
  try require(entered.wait(timeout: .now() + 5) == .success, "real runtime entered its blocked credential read")
  // Direct guard must return before the native queue is released.
  try ownership.validate(owner, jobID: job.id, revision: 1, leaseID: first.leaseID, requiresWrite: true)
  runtime.releaseImport(control(first), owner: owner) { release.set($0); releaseDone.signal() }
  try rejects("runtime release cancels publication immediately, before queue drainage") {
    try ownership.validate(owner, jobID: job.id, revision: 1, leaseID: first.leaseID, requiresWrite: true)
  }
  try require(releaseDone.wait(timeout: .now()) == .timedOut,
    "release cannot acknowledge while earlier native work is still blocked")
  resume.signal()
  try require(duplicateDone.wait(timeout: .now() + 5) == .success &&
    releaseDone.wait(timeout: .now() + 5) == .success && release.get(), "release drains the actual runtime barrier")
  try rejects("the blocked duplicate cannot restore cancelled publication") { _ = try duplicate.get() }
  try rejects("a pre-release ticket cannot acquire a replacement lease") {
    let _: LokalTransferImportClaim = try native { runtime.claimImport(write, ticket: queued, reply: $0) }
  }
  let second = try claim(write, owner)
  let newEngine = ownership.attachEngine()
  let replacement = try ownership.attachClient(engineID: newEngine, clientID: UUID().uuidString.lowercased())
  let current = try claim(write, replacement)
  let replacementTicket = try ownership.capture(replacement)
  try rejects("an old client cannot inherit the replacement's ticket or coalesced lease") {
    let _: LokalTransferImportClaim = try native { runtime.claimImport(write, ticket: replacementTicket, reply: $0) }
  }
  let foreignRelease = LokalTransferProtocol.ImportLease(id: job.id, revision: 1,
    leaseID: current.leaseID, clientID: owner.clientID)
  try rejects("even a known lease ID cannot let another client cancel its replacement") {
    let _: Bool = try native { runtime.releaseImport(foreignRelease, owner: replacement, reply: $0) }
  }
  ownership.detachEngine(engine)
  try rejects("old runtime client cannot release the new engine's import") {
    let _: Bool = try native { runtime.releaseImport(control(second), owner: owner, reply: $0) }
  }
  try ownership.validate(replacement, jobID: job.id, revision: 1, leaseID: current.leaseID, requiresWrite: true)
  let _: Bool = try native { runtime.releaseImport(control(current), owner: replacement, reply: $0) }
  credentials.set(nil)
  let historical = try claim(recovery, replacement)
  try require(historical.reconcileOnly && historical.sourcePath == nil,
    "receipt-only reconciliation needs no current bearer and exposes no source path")
  try ownership.validate(replacement, jobID: job.id, revision: 1, leaseID: historical.leaseID, requiresWrite: false)
  try rejects("receipt-only recovery never authorizes database or file publication") {
    try ownership.validate(replacement, jobID: job.id, revision: 1, leaseID: historical.leaseID, requiresWrite: true)
  }
  try rejects("a missing current pairing cannot acquire writer authority") { _ = try claim(write, replacement) }
  credentials.set(authorization)
  let beforeRecovery = try claim(write, replacement)
  let oldTicket = try ownership.capture(replacement)
  let _: LokalTransferSummary = try native { runtime.recover($0) }
  try rejects("durable recovery retires the previous writer") {
    try ownership.validate(replacement, jobID: job.id, revision: 1,
      leaseID: beforeRecovery.leaseID, requiresWrite: true)
  }
  try rejects("durable recovery rejects an earlier queued claim") {
    let bound = LokalTransferProtocol.ImportClaim(id: job.id, revision: 1,
      reconcileOnly: false, clientID: replacement.clientID)
    let _: LokalTransferImportClaim = try native { runtime.claimImport(bound, ticket: oldTicket, reply: $0) }
  }
  let beforeCancel = try claim(write, replacement)
  let cancelled: LokalTransferJob = try native { runtime.cancel(id: job.id, revision: 1, reply: $0) }
  try require(cancelled.phase == .cancelled && cancelled.revision == 2, "actual import cancellation advances durable revision")
  try rejects("cancelled import cannot pass the direct Isar guard") {
    try ownership.validate(replacement, jobID: job.id, revision: 1,
      leaseID: beforeCancel.leaseID, requiresWrite: true)
  }
  try rejects("cancelled durable jobs cannot be reclaimed using their old revision") { _ = try claim(write, replacement) }
  print("Native runtime import contracts passed: real HTTP staging, durable validation phase, coalesced claims, independent guard during blocked native I/O, drained release, engine replacement, pairing refusal, read-only recovery and durable cancellation. Product Isar import remains disabled.")
}
