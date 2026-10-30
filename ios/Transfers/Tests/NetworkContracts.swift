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

/// Atomic SQLite rollback, durable exact-scope cancellation and real native
/// URLSession callback drainage. This does not claim iOS daemon relaunch.
private func runNetworkRetirementContracts(origin: String, length: Int64, checksum: String) throws {
  let manager = FileManager.default
  let root = manager.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("lokal-network-retirement-" + UUID().uuidString)
  try manager.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? manager.removeItem(at: root) }

  let scope = LokalTransferScope(desktopID: "fixture-pc", origin: origin)
  func request(_ source: String, desktop: String = "fixture-pc") throws -> LokalTransferJob {
    try LokalTransferJob(direction: .download,
      identity: LokalTransferIdentity(desktopID: desktop, sourceID: source,
        localSongID: nil, origin: origin),
      metadata: LokalTransferMetadata(title: source, artist: "Retirement fixture",
        album: nil, fileExtension: "wav"),
      nowMs: 1000, expectedBytes: length, expectedSHA256: checksum)
  }

  // Importing Isar rows must block the *whole* scoped journal transaction,
  // not merely the importing member after other jobs were already revoked.
  let rollbackRoot = root.appendingPathComponent("rollback")
  try manager.createDirectory(at: rollbackRoot, withIntermediateDirectories: false)
  let rollback = try LokalTransferJournal(container: rollbackRoot)
  let importing = try request("importing"), queued = try request("queued")
  try rollback.create([importing, queued])
  _ = try rollback.update(id: importing.id, revision: 1) {
    try $0.bind(taskID: 61, nowMs: 1010)
  }
  _ = try rollback.update(id: importing.id, revision: 1) {
    try $0.retainedDownload(taskID: 61, bytes: length, nowMs: 1020)
  }
  _ = try rollback.update(id: importing.id, revision: 1) {
    try $0.acknowledgeDownload(taskID: 61, nowMs: 1030)
  }
  _ = try rollback.update(id: importing.id, revision: 1) {
    try $0.verifiedDownload(bytes: length, sha256: checksum, nowMs: 1040)
  }
  _ = try rollback.update(id: importing.id, revision: 1) {
    try $0.transition(to: .validating, nowMs: 1050)
  }
  _ = try rollback.update(id: importing.id, revision: 1) {
    try $0.transition(to: .importing, nowMs: 1060)
  }
  let before = try rollback.snapshot()
  try rejects("importing song refuses whole pairing retirement") {
    _ = try rollback.retireNetworkScope(scope, nowMs: 2000)
  }
  let after = try LokalTransferJournal(container: rollbackRoot).snapshot()
  try require(after.generation == before.generation && after.jobs == before.jobs &&
      after.pauses == before.pauses,
    "refusal leaves every network revision and pause untouched")

  // The standalone journal batch commits all scoped revisions at once, and
  // does not cancel an unrelated pairing at the same HTTP origin.
  let batchRoot = root.appendingPathComponent("batch")
  try manager.createDirectory(at: batchRoot, withIntermediateDirectories: false)
  let batch = try LokalTransferJournal(container: batchRoot)
  let a = try request("a"), b = try request("b"), foreign = try request("foreign", desktop: "other-pc")
  try batch.create([a, b, foreign])
  let batchBefore = try batch.snapshot()
  let changes = try batch.retireNetworkScope(scope, nowMs: 2000)
  let batchAfter = try LokalTransferJournal(container: batchRoot).snapshot()
  try require(changes.count == 2 && changes.allSatisfy {
      $0.retired.phase == .cancelled && $0.retired.revision == $0.previous.revision + 1
    }, "batch retires exactly the intended pairing revisions")
  try require(batchAfter.generation == batchBefore.generation + 1 &&
      batchAfter.jobs.first(where: { $0.id == foreign.id }) == foreign &&
      batchAfter.pauses == [LokalTransferPause(scope: scope, reason: .pairingChanged)],
    "durable pause and job transitions share one generation, preserve foreign scope")
  let reopenedBatch = try LokalTransferJournal(container: batchRoot).snapshot()
  try require(reopenedBatch.jobs == batchAfter.jobs && reopenedBatch.pauses == batchAfter.pauses,
    "reopen retains cancelled identities and pause after process replacement")
  try require(try batch.retireNetworkScope(scope, nowMs: 2001).isEmpty,
    "repeated scoped retirement cannot increment an already cancelled job revision")

  // Exercise the real ephemeral URLSession delegate, not a fake task list.
  let liveRoot = root.appendingPathComponent("live")
  try manager.createDirectory(at: liveRoot, withIntermediateDirectories: false)
  let foreignLive = try request("foreign", desktop: "other-pc")
  try LokalTransferJournal(container: liveRoot).create([foreignLive])
  let authorization = try LokalTransferAuthorization(
    desktopID: "fixture-pc", origin: origin, token: "transfer-fixture-token")
  let ownership = LokalTransferImportOwnership()
  let engine = ownership.attachEngine()
  let client = try ownership.attachClient(engineID: engine, clientID: UUID().uuidString.lowercased())
  let runtime = try LokalTransferRuntime(container: liveRoot,
    importOwnership: ownership, credentials: { authorization })
  defer {
    let done = DispatchSemaphore(value: 0)
    runtime.shutdown { done.signal() }
    _ = done.wait(timeout: .now() + 10)
  }
  let slow = try request("slow")
  let _: LokalTransferSummary = try native { runtime.enqueue([slow], reply: $0) }
  _ = try awaitJob(runtime, id: slow.id, phase: [.transferring])
  let ticket = try ownership.capture(client)
  let retired: LokalTransferSummary = try native {
    runtime.retireNetworkScope(scope, ticket: ticket, reply: $0)
  }
  try require(retired.pauses == [LokalTransferPause(scope: scope, reason: .pairingChanged)],
    "scoped retirement waits for task callback and persists an explicit pause")
  let old = try awaitJob(runtime, id: slow.id, phase: [.cancelled])
  try require(old.revision == 2 && old.receivedSHA256 == nil,
    "late native completion cannot revive a retired URLSession job")
  let snapshot = try LokalTransferJournal(container: liveRoot).snapshot()
  try require(snapshot.jobs.first(where: { $0.id == foreignLive.id }) == foreignLive,
    "real runtime keeps unrelated scopes untouched")
  let forbidden = try request("after-auth")
  try rejects("retired scope rejects a new plan while old credentials still exist") {
    let _: LokalTransferSummary = try native { runtime.enqueue([forbidden], reply: $0) }
  }
  let recovered: LokalTransferSummary = try native { runtime.recover($0) }
  try require(recovered.pauses == retired.pauses &&
      (try awaitJob(runtime, id: slow.id, phase: [.cancelled])).revision == 2,
    "runtime recovery never resurrects cancelled network work")
  try rejects("the same pairing cannot clear its retirement tombstone by reconnecting") {
    let _: LokalTransferSummary = try native { runtime.resume(scope: scope, reply: $0) }
  }
  print("Native scope retirement contracts passed: importing rollback, exact scope, durable journal, real URLSession callback drainage and recovery. Physical iOS suspension/Isar cleanup remain unqualified.")
}

func runNetworkContracts(origin: String, length: Int64, checksum: String) throws {
  try runHostContracts()
  try runNetworkRetirementContracts(origin: origin, length: length, checksum: checksum)
  try runRuntimeImportContracts(origin: origin, length: length, checksum: checksum)
  try runTrackedRuntimeContracts(origin: origin, length: length, checksum: checksum)
  try runCleanupResolutionContracts(origin: origin, length: length, checksum: checksum)
  try runOrphanCleanupContracts(origin: origin, length: length, checksum: checksum)
  try runSubmissionContracts(origin: origin, length: length, checksum: checksum)
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
  _ = try LokalTransferJournal(container: root).reserveImport(id: job.id, revision: 1, songID: 42)
  let cancelled: LokalTransferJob = try native { runtime.cancel(id: job.id, revision: 1, reply: $0) }
  try require(cancelled.phase == .cancelled && cancelled.revision == 2, "actual import cancellation advances durable revision")
  try rejects("cancelled import cannot pass the direct Isar guard") {
    try ownership.validate(replacement, jobID: job.id, revision: 1,
      leaseID: beforeCancel.leaseID, requiresWrite: true)
  }
  try rejects("cancelled durable jobs cannot be reclaimed using their old revision") { _ = try claim(write, replacement) }
  let request = LokalTransferProtocol.ImportWorkPage(after: nil, limit: 1, clientID: replacement.clientID)
  let ticket = try ownership.capture(replacement)
  let work: LokalTransferImportWorkPage = try native { runtime.importWorkPage(request, ticket: ticket, reply: $0) }
  try require(work.entries.count == 1 && work.entries[0].job.revision == 1 &&
    work.entries[0].currentRevision == 2 && work.entries[0].currentPhase == .cancelled,
    "actual runtime recovery retains frozen work independently of cancelled live revision")
  let candidates: LokalTransferImportCandidatePage = try native {
    runtime.importCandidatesPage(request, ticket: ticket, reply: $0)
  }
  try require(candidates.entries.isEmpty, "cancelled jobs are never app import candidates")
  let foreign = LokalTransferProtocol.ImportWorkPage(after: nil, limit: 1, clientID: owner.clientID)
  try rejects("recovery pages cannot borrow another client's ticket") {
    let _: LokalTransferImportWorkPage = try native { runtime.importWorkPage(foreign, ticket: ticket, reply: $0) }
  }
  ownership.revokeAll()
  try rejects("a queued recovery page cannot cross the native revocation barrier") {
    let _: LokalTransferImportWorkPage = try native { runtime.importWorkPage(request, ticket: ticket, reply: $0) }
  }
  print("Native runtime import contracts passed: real HTTP staging, durable validation phase, coalesced claims, independent guard during blocked native I/O, drained release, engine replacement, pairing refusal, read-only recovery and durable cancellation. Product Isar import remains disabled.")
}

private final class PublicationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var boundary: String?
  let entered = DispatchSemaphore(value: 0)
  let resume = DispatchSemaphore(value: 0)
  init(_ boundary: String?) { self.boundary = boundary }
  func arm(_ value: String) {
    lock.lock(); boundary = value; lock.unlock()
  }
  func visit(_ value: String) {
    lock.lock()
    let block = boundary == value
    if block { boundary = nil }
    lock.unlock()
    if block {
      entered.signal()
      // A failing contract must release/terminate rather than hang the suite.
      _ = resume.wait(timeout: .now() + 10)
    }
  }
}

/// The actual native runtime, HTTP-retained WAV, ownership registry, serial file
/// worker and journal. This still does not acknowledge media or an Isar Song.
private func runSubmissionContracts(origin: String, length: Int64, checksum: String) throws {
  let manager = FileManager.default
  let root = manager.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("lokal-submission-epoch-" + UUID().uuidString)
  try manager.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? manager.removeItem(at: root) }
  let authorization = try LokalTransferAuthorization(desktopID: "fixture-pc", origin: origin,
    token: "transfer-fixture-token")
  let gate = PublicationGate(nil)
  let ownership = LokalTransferImportOwnership()
  let runtime = try LokalTransferRuntime(container: root, importOwnership: ownership,
    credentials: { gate.visit("credentials"); return authorization })
  defer {
    gate.resume.signal()
    let done = DispatchSemaphore(value: 0)
    runtime.shutdown { done.signal() }; _ = done.wait(timeout: .now() + 10)
  }
  let _: LokalTransferSummary = try native { runtime.recover($0) }
  let owner = try ownership.attachClient(engineID: ownership.attachEngine(), clientID: UUID().uuidString.lowercased())
  let ticket = try ownership.captureSubmission(owner)
  let job = try LokalTransferJob(direction: .download,
    identity: LokalTransferIdentity(desktopID: "fixture-pc", sourceID: "import-fixture", localSongID: "42", origin: origin),
    metadata: LokalTransferMetadata(title: "Submission epoch", artist: "Native fixture", album: nil, fileExtension: "wav"),
    nowMs: 1000, expectedBytes: length, expectedSHA256: checksum)
  let journal = try LokalTransferJournal(container: root)
  let before = try journal.snapshot().generation
  gate.arm("credentials")
  let result = NativeResult<LokalTransferSummary>(), done = DispatchSemaphore(value: 0)
  runtime.enqueue([job], submission: ticket) { result.set($0); done.signal() }
  try require(gate.entered.wait(timeout: .now() + 10) == .success, "actual runtime submission blocks during credentials")
  // This direct fence must return while the runtime queue is still blocked.
  try ownership.retireSubmissions(owner)
  gate.resume.signal()
  try require(done.wait(timeout: .now() + 10) == .success, "retired queued submission returns")
  try rejects("consent retired during queued authorization cannot persist work") { _ = try result.get() }
  try require(journal.snapshot().jobs.isEmpty && journal.snapshot().generation == before,
    "retired runtime submission creates no durable job or generation")
  let fresh = try ownership.captureSubmission(owner)
  let _: LokalTransferSummary = try native { runtime.enqueue([job], submission: fresh, reply: $0) }
  _ = try awaitJob(runtime, id: job.id, phase: [.downloaded])
  let _: LokalTransferSummary = try native { runtime.enqueue([job], submission: fresh, reply: $0) }
  try require(journal.snapshot().jobs.count == 1, "fresh owned consent remains idempotent after a lost reply")
  ownership.revokeAll()
  try rejects("clear invalidates a ticket captured before host dispatch") {
    let _: LokalTransferSummary = try native { runtime.enqueue([job], submission: fresh, reply: $0) }
  }
  print("Native submission epochs passed: actual blocked authorization, immediate fence, no stale persistence, fresh HTTP work and idempotency. Clear/unpair OS-task integration remains pending.")
}

private func runOrphanCleanupContracts(origin: String, length: Int64, checksum: String) throws {
  let manager = FileManager.default
  let root = manager.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("lokal-orphan-cleanup-" + UUID().uuidString)
  try manager.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? manager.removeItem(at: root) }
  let ownership = LokalTransferImportOwnership()
  let authorization = try LokalTransferAuthorization(desktopID: "fixture-pc", origin: origin,
    token: "transfer-fixture-token")
  let runtime = try LokalTransferRuntime(container: root, importOwnership: ownership, credentials: { authorization })
  defer {
    let done = DispatchSemaphore(value: 0)
    runtime.shutdown { done.signal() }; _ = done.wait(timeout: .now() + 10)
  }
  let job = try LokalTransferJob(direction: .download,
    identity: LokalTransferIdentity(desktopID: "fixture-pc", sourceID: "import-fixture", localSongID: "42", origin: origin),
    metadata: LokalTransferMetadata(title: "Orphan", artist: "Native fixture", album: nil, fileExtension: "wav"),
    nowMs: 1000, expectedBytes: length, expectedSHA256: checksum)
  let _: LokalTransferSummary = try native { runtime.recover($0) }
  let _: LokalTransferSummary = try native { runtime.enqueue([job], reply: $0) }
  _ = try awaitJob(runtime, id: job.id, phase: [.downloaded])
  let owner = try ownership.attachClient(engineID: ownership.attachEngine(), clientID: UUID().uuidString.lowercased())
  let request = LokalTransferProtocol.ImportOrphanClaim(id: job.id, revision: 1, songID: 42, clientID: owner.clientID)
  func claim(_ request: LokalTransferProtocol.ImportOrphanClaim) throws -> LokalTransferOrphanCleanupClaim {
    let ticket = try ownership.beginCleanup(ownership.capture(owner))
    return try native { runtime.claimOrphanCleanup(request, ticket: ticket, reply: $0) }
  }
  try rejects("current ready job is not an orphan") { _ = try claim(request) }
  let cancelled: LokalTransferJob = try native { runtime.cancel(id: job.id, revision: 1, reply: $0) }
  let journal = try LokalTransferJournal(container: root)
  let before = try journal.snapshot()
  let lease = try claim(request)
  try require(lease.currentJob == cancelled && lease.revision == 1 && lease.songID == 42,
    "actual native no-custody barrier binds an older revision to the live cancelled job")
  try ownership.validateOrphanCleanup(owner, jobID: job.id, revision: 1, leaseID: lease.leaseID)
  try rejects("orphan runtime reply cannot authorize tracked file resolution") {
    _ = try ownership.cleanupCancellation(owner, jobID: job.id, revision: 1, leaseID: lease.leaseID)
  }
  let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf:
    URL(fileURLWithPath: "test/fixtures/ios_transfer_orphan_v1.json"))) as! [String: Any]
  let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(lease)) as! [String: Any]
  try require(Set(encoded.keys) == Set(fixture["replyKeys"] as! [String]) &&
    encoded["permission"] as? String == fixture["permission"] as? String,
    "runtime orphan reply matches shared codec without paths or file provenance")
  try require(journal.snapshot().generation == before.generation && journal.snapshot().custodies.isEmpty,
    "orphan claim writes no journal history or file custody")
  let control = LokalTransferProtocol.ImportLease(id: job.id, revision: 1,
    leaseID: lease.leaseID, clientID: owner.clientID)
  try ownership.cancel(owner, jobID: job.id, revision: 1, leaseID: lease.leaseID)
  let _: Bool = try native { runtime.releaseImport(control, owner: owner, reply: $0) }
  try rejects("a missing native job is not proof of safe orphan retirement") {
    _ = try claim(LokalTransferProtocol.ImportOrphanClaim(id: UUID().uuidString.lowercased(), revision: 1,
      songID: 42, clientID: owner.clientID))
  }
  print("Native orphan bookkeeping contracts passed: actual cancelled job, drained no-custody claim, current/missing-job refusal, separate guard and shared codec. No file cleanup or Isar claim.")
}

private func runCleanupResolutionContracts(origin: String, length: Int64, checksum: String) throws {
  let manager = FileManager.default
  for mode in [LokalTransferImportResolution.Mode.committed, .abandoned] {
    let root = manager.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("lokal-cleanup-resolution-" + UUID().uuidString)
    let music = root.appendingPathComponent("Music")
    try manager.createDirectory(at: music, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let authorization = try LokalTransferAuthorization(desktopID: "fixture-pc", origin: origin,
      token: "transfer-fixture-token")
    let ownership = LokalTransferImportOwnership()
    let runtime = try LokalTransferRuntime(container: root, importOwnership: ownership,
      library: { try LokalTransferLibrary(root: music) }, credentials: { authorization })
    defer {
      let done = DispatchSemaphore(value: 0)
      runtime.shutdown { done.signal() }; _ = done.wait(timeout: .now() + 10)
    }
    let job = try LokalTransferJob(direction: .download,
      identity: LokalTransferIdentity(desktopID: "fixture-pc", sourceID: "import-fixture",
        localSongID: "42", origin: origin),
      metadata: LokalTransferMetadata(title: "Cleanup resolution", artist: "Native fixture", album: nil, fileExtension: "wav"),
      nowMs: 1000, expectedBytes: length, expectedSHA256: checksum)
    let _: LokalTransferSummary = try native { runtime.recover($0) }
    let _: LokalTransferSummary = try native { runtime.enqueue([job], reply: $0) }
    _ = try awaitJob(runtime, id: job.id, phase: [.downloaded])
    let _: LokalTransferJob = try native { runtime.verify(id: job.id, revision: 1, reply: $0) }
    let owner = try ownership.attachClient(engineID: ownership.attachEngine(), clientID: UUID().uuidString.lowercased())
    let writerRequest = LokalTransferProtocol.ImportClaim(id: job.id, revision: 1, reconcileOnly: false, clientID: owner.clientID)
    let writerTicket = try ownership.capture(owner)
    let writer: LokalTransferImportClaim = try native { runtime.claimImport(writerRequest, ticket: writerTicket, reply: $0) }
    let journal = try LokalTransferJournal(container: root)
    let files = try LokalTransferFiles(container: root)
    if mode == .committed {
      // Restoration/uncertain app history is an explicit app-commit fixture.
      // Native must preserve bytes; this does not assert an actual Isar commit.
      _ = try LokalTransferLibrary(root: music).installTracked(writer.job, songID: 42,
        journal: journal, files: files, cancellation: LokalTransferCopyCancellation(), validateOwnership: {})
      let _: LokalTransferJob = try native { runtime.cancel(id: job.id, revision: 1, reply: $0) }
    } else {
      let request = LokalTransferProtocol.ImportPublication(id: job.id, revision: 1, leaseID: writer.leaseID,
        clientID: owner.clientID, songID: 42)
      let _: LokalTransferPublishedImport = try native { runtime.publishImport(request, owner: owner, reply: $0) }
    }
    let target = music.appendingPathComponent(writer.targetRelativePath)
    if mode == .committed {
      let orphanTicket = try ownership.beginCleanup(ownership.capture(owner))
      let orphanRequest = LokalTransferProtocol.ImportOrphanClaim(id: job.id, revision: 1,
        songID: 42, clientID: owner.clientID)
      try rejects("cancelled job with actual frozen custody cannot claim bookkeeping-only absence") {
        let _: LokalTransferOrphanCleanupClaim = try native {
          runtime.claimOrphanCleanup(orphanRequest, ticket: orphanTicket, reply: $0)
        }
      }
    }
    let ticket = try ownership.beginCleanup(ownership.capture(owner))
    let request = LokalTransferProtocol.ImportCleanupClaim(id: job.id, revision: 1, clientID: owner.clientID)
    let cleanup: LokalTransferImportCleanupClaim = try native { runtime.claimImportCleanup(request, ticket: ticket, reply: $0) }
    let decision = LokalTransferProtocol.ImportCleanupDecision(id: job.id, revision: 1, leaseID: cleanup.leaseID,
      clientID: owner.clientID, songID: 42, mode: mode, isarState: mode == .abandoned ? "retiring" : "committed")
    let finalize = LokalTransferProtocol.ImportCleanupDecision(id: job.id, revision: 1, leaseID: cleanup.leaseID,
      clientID: owner.clientID, songID: 42, mode: mode, isarState: mode == .abandoned ? "retired" : "committed")
    try rejects("unresolved cleanup cannot discard frozen native bookkeeping") {
      let _: Bool = try native { runtime.finalizeImportCleanup(finalize, owner: owner, reply: $0) }
    }
    #if os(Linux)
    if mode == .abandoned {
      try rejects("runtime refuses uncoordinated public cleanup on a portable host") {
        let _: LokalTransferResolvedCleanup = try native { runtime.resolveImportCleanup(decision, owner: owner, reply: $0) }
      }
      try require(Data(contentsOf: target).count == length && journal.snapshot().custodies.first?.resolution == nil &&
        journal.snapshot().jobs.first?.revision == 2,
        "portable refusal retains actual public bytes and provenance after authorized native retirement")
      continue
    }
    #endif
    let first = NativeResult<LokalTransferResolvedCleanup>(), second = NativeResult<LokalTransferResolvedCleanup>()
    let done = DispatchSemaphore(value: 0)
    runtime.resolveImportCleanup(decision, owner: owner) { first.set($0); done.signal() }
    runtime.resolveImportCleanup(decision, owner: owner) { second.set($0); done.signal() }
    try require(done.wait(timeout: .now() + 10) == .success && done.wait(timeout: .now() + 10) == .success,
      "both native cleanup callers settle")
    let resolved = try first.get()
    try require(resolved == second.get() && resolved.resolution.mode == mode,
      "concurrent/lost cleanup replies coalesce one durable decision")
    if mode == .committed {
      try require(Data(contentsOf: target).count == length, "committed history preserves actual public audio")
    } else {
      try require(!manager.fileExists(atPath: target.path) && resolved.resolution.abandonment == .removedOwnedFile,
        "actual Apple-coordinated abandoned copy is removed")
    }
    try require(journal.snapshot().custodies.first?.resolution == resolved.resolution &&
      !manager.fileExists(atPath: root.appendingPathComponent(LokalTransferJournal.directoryName)
        .appendingPathComponent(writer.job.stagedName).path),
      "native result is durable after real private staging drainage, before Isar finalization")
    let before: LokalTransferSummary = try native { runtime.summary($0) }
    let repeated: LokalTransferResolvedCleanup = try native { runtime.resolveImportCleanup(decision, owner: owner, reply: $0) }
    let after: LokalTransferSummary = try native { runtime.summary($0) }
    try require(repeated == resolved && before.generation == after.generation, "lost cleanup reply emits no new generation")
    let _: Bool = try native { runtime.finalizeImportCleanup(finalize, owner: owner, reply: $0) }
    let finalized: LokalTransferSummary = try native { runtime.summary($0) }
    let _: Bool = try native { runtime.finalizeImportCleanup(finalize, owner: owner, reply: $0) }
    let finalizedAgain: LokalTransferSummary = try native { runtime.summary($0) }
    try require(journal.snapshot().custodies.isEmpty && finalized.generation == finalizedAgain.generation,
      "acknowledged app finalization removes only bookkeeping and repeated replies are inert")
    try ownership.validateCleanup(owner, jobID: job.id, revision: 1, leaseID: cleanup.leaseID)
    let control = LokalTransferProtocol.ImportLease(id: job.id, revision: 1, leaseID: cleanup.leaseID, clientID: owner.clientID)
    let _: Bool = try native { runtime.releaseImport(control, owner: owner, reply: $0) }
  }
  print("Native cleanup driver contracts passed: real HTTP/custody/staging, coalesced durable resolution and finalization, committed-file preservation; app Isar states are explicit fixtures. Public abandonment requires actual Apple coordination and is refused on Linux.")
}

private func runTrackedRuntimeContracts(origin: String, length: Int64, checksum: String) throws {
  let manager = FileManager.default
  for boundary in ["none", "trackedCopyCheckpoint", "afterTrackedPublication"] {
    let root = manager.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("lokal-tracked-runtime-" + UUID().uuidString)
    let music = root.appendingPathComponent("Music")
    try manager.createDirectory(at: music, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let gate = PublicationGate(boundary == "none" ? nil : boundary)
    defer { gate.resume.signal() }
    let authorization = try LokalTransferAuthorization(desktopID: "fixture-pc", origin: origin,
      token: "transfer-fixture-token")
    let credentials = ImportAuthorizationFixture(authorization)
    let ownership = LokalTransferImportOwnership()
    let runtime = try LokalTransferRuntime(container: root, importOwnership: ownership,
      library: { try LokalTransferLibrary(root: music, testingBoundary: { gate.visit($0) }) },
      credentials: { try credentials.read() })
    defer {
      gate.resume.signal()
      let done = DispatchSemaphore(value: 0)
      runtime.shutdown { done.signal() }
      _ = done.wait(timeout: .now() + 10)
    }
    let job = try LokalTransferJob(direction: .download,
      identity: LokalTransferIdentity(desktopID: "fixture-pc", sourceID: "import-fixture",
        localSongID: nil, origin: origin),
      metadata: LokalTransferMetadata(title: "Tracked import", artist: "Native fixture", album: nil,
        fileExtension: "wav"), nowMs: 1000, expectedBytes: length, expectedSHA256: checksum)
    let _: LokalTransferSummary = try native { runtime.recover($0) }
    let _: LokalTransferSummary = try native { runtime.enqueue([job], reply: $0) }
    _ = try awaitJob(runtime, id: job.id, phase: [.downloaded])
    let _: LokalTransferJob = try native { runtime.verify(id: job.id, revision: 1, reply: $0) }
    let engine = ownership.attachEngine()
    var owner = try ownership.attachClient(engineID: engine, clientID: UUID().uuidString.lowercased())
    func claim(_ owner: LokalTransferImportOwnership.Owner, readOnly: Bool = false) throws -> LokalTransferImportClaim {
      let request = LokalTransferProtocol.ImportClaim(id: job.id, revision: 1,
        reconcileOnly: readOnly, clientID: owner.clientID)
      let ticket = try ownership.capture(owner)
      return try native { runtime.claimImport(request, ticket: ticket, reply: $0) }
    }
    func publication(_ lease: LokalTransferImportClaim, songID: Int64 = 42,
                     clientID: String? = nil) -> LokalTransferProtocol.ImportPublication {
      LokalTransferProtocol.ImportPublication(id: job.id, revision: 1, leaseID: lease.leaseID,
        clientID: clientID ?? lease.clientID, songID: songID)
    }
    var lease = try claim(owner)
    let missingCleanupTicket = try ownership.beginCleanup(ownership.capture(owner))
    let missingCleanup = LokalTransferProtocol.ImportCleanupClaim(id: job.id, revision: 1,
      clientID: owner.clientID)
    try rejects("cleanup cannot invent missing frozen native custody") {
      let _: LokalTransferImportCleanupClaim = try native {
        runtime.claimImportCleanup(missingCleanup, ticket: missingCleanupTicket, reply: $0)
      }
    }
    lease = try claim(owner)
    try rejects("foreign client cannot borrow a known publication lease") {
      let _: LokalTransferPublishedImport = try native {
        runtime.publishImport(publication(lease, clientID: UUID().uuidString.lowercased()), owner: owner, reply: $0)
      }
    }
    credentials.set(nil)
    try rejects("publication rechecks current pairing before touching the library") {
      let _: LokalTransferPublishedImport = try native { runtime.publishImport(publication(lease), owner: owner, reply: $0) }
    }
    try require(!manager.fileExists(atPath: music.appendingPathComponent(LokalTransferLibrary.directoryName).path),
      "unauthorized publication does not initialize Music custody")
    credentials.set(authorization)
    let result = NativeResult<LokalTransferPublishedImport>(), completed = DispatchSemaphore(value: 0)
    runtime.publishImport(publication(lease), owner: owner) { result.set($0); completed.signal() }
    let target = music.appendingPathComponent(lease.targetRelativePath)
    if boundary != "none" {
      try require(gate.entered.wait(timeout: .now() + 5) == .success,
        "actual runtime file worker reaches the requested publication boundary")
      // A direct writer check remains independent of a blocked copy worker.
      try ownership.validate(owner, jobID: job.id, revision: 1, leaseID: lease.leaseID, requiresWrite: true)
      if boundary == "trackedCopyCheckpoint" {
        let release = NativeResult<Bool>(), released = DispatchSemaphore(value: 0)
        let control = LokalTransferProtocol.ImportLease(id: job.id, revision: 1,
          leaseID: lease.leaseID, clientID: owner.clientID)
        runtime.releaseImport(control, owner: owner) { release.set($0); released.signal() }
        try rejects("release revokes a real blocked copy immediately") {
          try ownership.validate(owner, jobID: job.id, revision: 1, leaseID: lease.leaseID, requiresWrite: true)
        }
        try require(released.wait(timeout: .now()) == .timedOut,
          "release cannot acknowledge before the real file worker drains")
        gate.resume.signal()
        try require(released.wait(timeout: .now() + 5) == .success && release.get(),
          "release acknowledges after the actual cancelled copy drains")
        try require(!manager.fileExists(atPath: target.path), "cancelled copying never publishes")
      } else {
        try require(manager.fileExists(atPath: target.path), "engine handoff occurs after an actual public link")
        let nextEngine = ownership.attachEngine()
        owner = try ownership.attachClient(engineID: nextEngine, clientID: UUID().uuidString.lowercased())
        // Claiming a replacement does not wait behind the blocked file queue.
        lease = try claim(owner)
        let cleanupTicket = try ownership.beginCleanup(ownership.capture(owner))
        try rejects("cleanup intent immediately retires a replacement publication writer") {
          try ownership.validate(owner, jobID: job.id, revision: 1, leaseID: lease.leaseID, requiresWrite: true)
        }
        credentials.set(nil)
        let cleanupRequest = LokalTransferProtocol.ImportCleanupClaim(id: job.id, revision: 1,
          clientID: owner.clientID)
        let cleanup = NativeResult<LokalTransferImportCleanupClaim>(), cleanupDone = DispatchSemaphore(value: 0)
        runtime.claimImportCleanup(cleanupRequest, ticket: cleanupTicket) { cleanup.set($0); cleanupDone.signal() }
        let drained = NativeResult<Bool>(), drainDone = DispatchSemaphore(value: 0)
        let ticket = try ownership.capture(owner)
        runtime.drainImports(ticket: ticket) { drained.set($0); drainDone.signal() }
        try require(drainDone.wait(timeout: .now()) == .timedOut,
          "current-root drainage cannot pass an actual blocked retired file worker")
        try require(cleanupDone.wait(timeout: .now()) == .timedOut,
          "cleanup lease cannot be granted before the actual old file worker drains")
        gate.resume.signal()
        try require(drainDone.wait(timeout: .now() + 5) == .success && drained.get(),
          "replacement root independently drains prior native file work")
        try require(cleanupDone.wait(timeout: .now() + 5) == .success, "drained cleanup claim settles")
        let cleanupLease = try cleanup.get()
        try require(cleanupLease.songID == 42 && cleanupLease.job.id == job.id &&
          cleanupLease.currentRevision == 1 && cleanupLease.permission == "cleanup" &&
          cleanupLease.publicationRecorded,
          "cleanup retains the exact frozen native Song binding without current pairing")
        try ownership.validateCleanup(owner, jobID: job.id, revision: 1, leaseID: cleanupLease.leaseID)
        let cleanupJSON = String(decoding: try JSONEncoder().encode(cleanupLease), as: UTF8.self)
        let cleanupFixture = try JSONSerialization.jsonObject(with: Data(contentsOf:
          URL(fileURLWithPath: "test/fixtures/ios_transfer_cleanup_v1.json"))) as! [String: Any]
        let cleanupObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cleanupLease)) as! [String: Any]
        let requiredKeys = Set(cleanupFixture["replyKeys"] as! [String])
        let optionalKeys = Set(cleanupFixture["optionalReplyKeys"] as! [String])
        try require(requiredKeys.isSubset(of: Set(cleanupObject.keys)) &&
          Set(cleanupObject.keys).isSubset(of: requiredKeys.union(optionalKeys)) &&
          cleanupObject["permission"] as? String == cleanupFixture["permission"] as? String,
          "actual native cleanup encoding matches the shared Dart wire schema")
        try require(!cleanupJSON.contains("sourcePath") && !cleanupJSON.contains(root.path) &&
          !cleanupJSON.contains("copyNonce") && !cleanupJSON.contains("transfer-fixture-token"),
          "cleanup claim exposes no writer source path, private marker or bearer")
        let cleanupControl = LokalTransferProtocol.ImportLease(id: job.id, revision: 1,
          leaseID: cleanupLease.leaseID, clientID: owner.clientID)
        let _: Bool = try native { runtime.releaseImport(cleanupControl, owner: owner, reply: $0) }
        credentials.set(authorization)
        lease = try claim(owner)
      }
      try require(completed.wait(timeout: .now() + 5) == .success, "retired publication settles")
      try rejects("revoked publication cannot return an importing acknowledgement") { _ = try result.get() }
      if boundary == "trackedCopyCheckpoint" { lease = try claim(owner) }
    } else {
      try require(completed.wait(timeout: .now() + 5) == .success, "real tracked publication completes")
      let published = try result.get()
      try require(published.job.phase == .importing && published.songID == 42 &&
        published.receipt.bytes == length && published.receipt.sha256 == checksum,
        "native publication persists importing with actual byte proof, without declaring completion")
    }
    let completedCopy: LokalTransferPublishedImport = try native {
      runtime.publishImport(publication(lease), owner: owner, reply: $0)
    }
    let inode = try manager.attributesOfItem(atPath: target.path)[.systemFileNumber] as! NSNumber
    let files = try LokalTransferFiles(container: root)
    if boundary != "none" { try files.discard(completedCopy.job) }
    let repeated: LokalTransferPublishedImport = try native {
      runtime.publishImport(publication(lease), owner: owner, reply: $0)
    }
    try require(repeated.receipt == completedCopy.receipt &&
      (manager.attributesOfItem(atPath: target.path)[.systemFileNumber] as! NSNumber) == inode,
      "lost publication acknowledgement needs no staging and keeps the same actual inode")
    let journal = try LokalTransferJournal(container: root)
    let snapshot = try journal.snapshot()
    try require(snapshot.custodies.count == 1 && snapshot.custodies.first?.publication != nil &&
      snapshot.jobs.first?.phase == .importing, "one actual frozen publication remains, never native complete")
    try rejects("publication cannot change its prepared Song identity") {
      let _: LokalTransferPublishedImport = try native {
        runtime.publishImport(publication(lease, songID: 43), owner: owner, reply: $0)
      }
    }
    let control = LokalTransferProtocol.ImportLease(id: job.id, revision: 1,
      leaseID: lease.leaseID, clientID: owner.clientID)
    let _: Bool = try native { runtime.releaseImport(control, owner: owner, reply: $0) }
    let readOnly = try claim(owner, readOnly: true)
    try rejects("receipt-only authority cannot publish even an already tracked file") {
      let _: LokalTransferPublishedImport = try native {
        runtime.publishImport(publication(readOnly), owner: owner, reply: $0)
      }
    }
    try require(manager.fileExists(atPath: target.path), "release and receipt-only refusal preserve the actual copy")
    // Fixture attestation only: product Root must prove a real committed Isar
    // receipt before this acknowledgement API is reachable in normal flows.
    credentials.set(nil)
    let request = LokalTransferProtocol.ImportWorkPage(after: nil, limit: 1, clientID: owner.clientID)
    let pageTicket = try ownership.capture(owner)
    let page: LokalTransferImportWorkPage = try native {
      runtime.importWorkPage(request, ticket: pageTicket, reply: $0)
    }
    try require(page.entries.count == 1 && page.entries[0].publicationRecorded &&
      page.entries[0].currentPhase == .importing, "pending cleanup is exposed as bounded recovery work")
    let encodedPage = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
    try require(!encodedPage.contains(root.path) && !encodedPage.contains("copyNonce") &&
      !encodedPage.contains("transfer-fixture-token"), "recovery replies expose no private path, marker or bearer")
    try rejects("completion cannot acknowledge a different prepared Song ID") {
      let _: LokalTransferJob = try native {
        runtime.acknowledgeImport(publication(readOnly, songID: 43), owner: owner, reply: $0)
      }
    }
    try require((try journal.snapshot()).jobs.first?.phase == .importing,
      "wrong completion identity never changes native job truth")
    if boundary == "afterTrackedPublication" { try manager.removeItem(at: target) }
    if boundary == "trackedCopyCheckpoint" { try Data("edited after fixture commit".utf8).write(to: target) }
    let completedJob: LokalTransferJob = try native {
      runtime.acknowledgeImport(publication(readOnly), owner: owner, reply: $0)
    }
    try require(completedJob.phase == .complete && completedJob.revision == 1,
      "app acknowledgement commits complete for the exact frozen revision without current pairing")
    try require(!manager.fileExists(atPath: root.appendingPathComponent(LokalTransferJournal.directoryName)
      .appendingPathComponent(completedJob.stagedName).path), "completion drains actual private retained staging")
    try require(journal.snapshot().custodies.count == 1,
      "completion retains native publication provenance for lost acknowledgements")
    try require(journal.snapshot().custodies[0].stagingRetired == true,
      "actual staging drainage is durable separately from app library completion")
    let retiredTicket = try ownership.capture(owner)
    let retiredPage: LokalTransferImportWorkPage = try native {
      runtime.importWorkPage(request, ticket: retiredTicket, reply: $0)
    }
    try require(retiredPage.entries.isEmpty && retiredPage.nextCursor == nil,
      "retained completed history is omitted from app recovery work")
    let historical = try claim(owner, readOnly: true)
    try require(historical.job.phase == .complete && historical.sourcePath == nil,
      "complete recovery is receipt-only and never exposes an old staged source")
    try rejects("a completed historical claim never becomes writer authority") {
      try ownership.validate(owner, jobID: job.id, revision: 1, leaseID: historical.leaseID, requiresWrite: true)
    }
    try rejects("completed jobs cannot acquire a fresh publication lease") { _ = try claim(owner) }
    let beforeRepeated: LokalTransferSummary = try native { runtime.summary($0) }
    let repeatedCompletion: LokalTransferJob = try native {
      runtime.acknowledgeImport(publication(historical), owner: owner, reply: $0)
    }
    try require(repeatedCompletion == completedJob, "lost completion reply coalesces the same durable job")
    let afterRepeated: LokalTransferSummary = try native { runtime.summary($0) }
    try require(beforeRepeated.generation == afterRepeated.generation,
      "duplicate completion does not generate another event-driven recovery mutation")
    if boundary == "afterTrackedPublication" {
      try require(!manager.fileExists(atPath: target.path), "historical completion cannot recreate a deleted public copy")
    } else if boundary == "trackedCopyCheckpoint" {
      try require(Data(contentsOf: target) == Data("edited after fixture commit".utf8),
        "completion never edits or deletes user-modified public bytes")
    } else {
      try require((manager.attributesOfItem(atPath: target.path)[.systemFileNumber] as! NSNumber) == inode,
        "completion leaves the original public inode untouched")
    }
  }
  print("Tracked runtime contracts passed: real HTTP WAV publication, importing persistence, exact Song binding, ownership/pairing refusal, blocked-copy cancellation/drainage, engine handoff, app-attested completion, actual private staging drainage, read-only complete recovery and preservation of deleted/edited public copies. Actual Isar completion/product adapter remains disabled.")
}
