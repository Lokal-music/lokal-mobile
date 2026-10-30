import Foundation

private final class ImportLeaseResults: @unchecked Sendable {
  private let lock = NSLock()
  private var ids = Set<String>()
  private var failures = 0
  func add(_ value: String?) {
    lock.lock()
    defer { lock.unlock() }
    if let value { ids.insert(value) } else { failures += 1 }
  }
  var snapshot: (Int, Int) {
    lock.lock()
    defer { lock.unlock() }
    return (ids.count, failures)
  }
}

/// Real lock/thread contracts only, independent of Runner/Isar acceptance.
func runImportOwnershipContracts(job: LokalTransferJob) throws {
  let registry = LokalTransferImportOwnership()
  let firstEngine = registry.attachEngine()
  let first = try registry.attachClient(engineID: firstEngine, clientID: UUID().uuidString.lowercased())
  let pending = try registry.capture(first)
  registry.revokeAll()
  try rejects("clear retires a queued claim even before any lease exists") {
    _ = try registry.claim(pending, job: job, permission: .write)
  }
  let ticket = try registry.capture(first)
  let lease = try registry.claim(ticket, job: job, permission: .write)
  try registry.validate(first, jobID: job.id, revision: job.revision,
    leaseID: lease.id, requiresWrite: true)
  try require(registry.claim(ticket, job: job, permission: .write).id == lease.id,
    "lost claim acknowledgement reuses the same owned lease")

  let results = ImportLeaseResults()
  DispatchQueue.concurrentPerform(iterations: 24) { _ in
    do { results.add(try registry.claim(ticket, job: job, permission: .write).id) }
    catch { results.add(nil) }
  }
  let counts = results.snapshot
  try require(counts.0 == 1 && counts.1 == 0, "24 actual concurrent claims coalesce to one native lease")
  try rejects("wrong revision cannot validate a current lease") {
    try registry.validate(first, jobID: job.id, revision: job.revision + 1,
      leaseID: lease.id, requiresWrite: true)
  }
  try rejects("wrong recording cannot validate a current lease") {
    try registry.validate(first, jobID: UUID().uuidString.lowercased(), revision: job.revision,
      leaseID: lease.id, requiresWrite: true)
  }

  // The real utility worker is occupied; direct guard/revocation must finish
  // independently. No sleep or relaxed timing threshold substitutes for this.
  let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
  let finished = DispatchSemaphore(value: 0)
  DispatchQueue(label: "app.lokal.import-ownership-contract-worker").async {
    entered.signal()
    resume.wait()
    finished.signal()
  }
  try require(entered.wait(timeout: .now() + 5) == .success, "worker reached its actual blocked boundary")
  try registry.validate(first, jobID: job.id, revision: job.revision,
    leaseID: lease.id, requiresWrite: true)
  registry.revokeAll()
  try rejects("immediate revocation cancels the token while utility work remains blocked") {
    try lease.cancellation.check()
  }
  try require(finished.wait(timeout: .now()) == .timedOut,
    "guard and revocation returned without waiting behind the worker")
  resume.signal()
  try require(finished.wait(timeout: .now() + 5) == .success, "worker teardown drains")

  let oldClientTicket = try registry.capture(first)
  let second = try registry.attachClient(engineID: firstEngine, clientID: UUID().uuidString.lowercased())
  registry.stopClient(first)
  try rejects("old same-engine client ticket cannot revive after a replacement") {
    _ = try registry.claim(oldClientTicket, job: job, permission: .write)
  }
  let secondLease = try registry.claim(registry.capture(second), job: job, permission: .write)
  let secondEngine = registry.attachEngine()
  let third = try registry.attachClient(engineID: secondEngine, clientID: UUID().uuidString.lowercased())
  registry.detachEngine(firstEngine)
  try rejects("old engine disposal cannot revive its cancelled copy") { try secondLease.cancellation.check() }
  try rejects("retired engine cannot register another client") {
    _ = try registry.attachClient(engineID: firstEngine, clientID: UUID().uuidString.lowercased())
  }
  let thirdLease = try registry.claim(registry.capture(third), job: job, permission: .write)
  try registry.validate(third, jobID: job.id, revision: job.revision,
    leaseID: thirdLease.id, requiresWrite: true)
  try rejects("old client cannot release replacement ownership") {
    try registry.release(second, jobID: job.id, revision: job.revision, leaseID: thirdLease.id)
  }
  let beforeOtherScope = try registry.capture(third)
  try registry.revoke(scope: LokalTransferScope(desktopID: "another-desktop",
    origin: job.identity.origin, pairingID: job.identity.pairingID))
  try registry.validate(third, jobID: job.id, revision: job.revision,
    leaseID: thirdLease.id, requiresWrite: true)
  try registry.release(third, jobID: job.id, revision: job.revision, leaseID: thirdLease.id)
  try rejects("revocation also fences claims queued without an active file lease") {
    _ = try registry.claim(beforeOtherScope, job: job, permission: .write)
  }

  let recovery = try registry.claim(registry.capture(third), job: job, permission: .reconcileOnly)
  try registry.validate(third, jobID: job.id, revision: job.revision,
    leaseID: recovery.id, requiresWrite: false)
  try rejects("historical reconciliation cannot authorize a new library write") {
    try registry.validate(third, jobID: job.id, revision: job.revision,
      leaseID: recovery.id, requiresWrite: true)
  }
  let origin = try LokalTransferRequest.originKey(job.identity.origin)
  try registry.revoke(scope: LokalTransferScope(desktopID: job.identity.desktopID,
    origin: origin + "/", pairingID: job.identity.pairingID))
  try rejects("equivalent origin spelling revokes the matching copy") { try recovery.cancellation.check() }

  let beforeCleanup = try registry.capture(third)
  let cleanupTicket = try registry.beginCleanup(beforeCleanup)
  try rejects("cleanup intent fences publication queued before the file barrier") {
    _ = try registry.claim(beforeCleanup, job: job, permission: .write)
  }
  try rejects("pending cleanup blocks new writers before its file barrier completes") {
    _ = try registry.claim(registry.capture(third), job: job, permission: .write)
  }
  let cleanup = try registry.claim(cleanupTicket, job: job, permission: .cleanup)
  try registry.validateCleanup(third, jobID: job.id, revision: job.revision, leaseID: cleanup.id)
  try require(registry.cleanupCancellation(third, jobID: job.id, revision: job.revision,
    leaseID: cleanup.id) === cleanup.cancellation, "cleanup receives its own exact revocable token")
  let cleanupResults = ImportLeaseResults()
  DispatchQueue.concurrentPerform(iterations: 12) { _ in
    do { cleanupResults.add(try registry.claim(cleanupTicket, job: job, permission: .cleanup).id) }
    catch { cleanupResults.add(nil) }
  }
  try require(cleanupResults.snapshot == (1, 0), "12 cleanup claims coalesce without creating another writer")
  for requiresWrite in [true, false] {
    try rejects("cleanup cannot impersonate publication or committed-receipt authority") {
      try registry.validate(third, jobID: job.id, revision: job.revision,
        leaseID: cleanup.id, requiresWrite: requiresWrite)
    }
  }
  try rejects("cleanup cannot obtain a publication token") {
    _ = try registry.writerCancellation(third, jobID: job.id, revision: job.revision, leaseID: cleanup.id)
  }
  try rejects("normal claims cannot upgrade active cleanup authority") {
    _ = try registry.claim(cleanupTicket, job: job, permission: .write)
  }
  try rejects("a retired client cannot validate replacement cleanup") {
    try registry.validateCleanup(first, jobID: job.id, revision: job.revision, leaseID: cleanup.id)
  }
  registry.revokeAll()
  try rejects("clear immediately retires cleanup without waiting on a file queue") { try cleanup.cancellation.check() }
  try rejects("an old cleanup ticket cannot survive the mutation barrier") {
    _ = try registry.claim(cleanupTicket, job: job, permission: .cleanup)
  }
  let aborted = try registry.beginCleanup(registry.capture(third))
  registry.abortCleanup(aborted)
  try rejects("aborted cleanup cannot later claim a lease") {
    _ = try registry.claim(aborted, job: job, permission: .cleanup)
  }
  var retired = job
  try retired.cancel(nowMs: retired.updatedMs + 1)
  let orphanTicket = try registry.beginCleanup(registry.capture(third))
  try rejects("orphan cannot retire a current revision") {
    _ = try registry.claimOrphanCleanup(orphanTicket, current: job, retiringRevision: job.revision)
  }
  let orphan = try registry.claimOrphanCleanup(orphanTicket, current: retired, retiringRevision: job.revision)
  try registry.validateOrphanCleanup(third, jobID: job.id, revision: job.revision, leaseID: orphan.id)
  try require(registry.claimOrphanCleanup(orphanTicket, current: retired,
    retiringRevision: job.revision).id == orphan.id, "lost orphan claim coalesces")
  for write in [true, false] {
    try rejects("bookkeeping authority cannot write or acknowledge a recording") {
      try registry.validate(third, jobID: job.id, revision: job.revision,
        leaseID: orphan.id, requiresWrite: write)
    }
  }
  try rejects("bookkeeping authority cannot obtain a file cleanup token") {
    _ = try registry.cleanupCancellation(third, jobID: job.id, revision: job.revision, leaseID: orphan.id)
  }
  try rejects("bookkeeping authority cannot obtain a publication token") {
    _ = try registry.writerCancellation(third, jobID: job.id, revision: job.revision, leaseID: orphan.id)
  }
  registry.revokeAll()
  try rejects("clear retires an orphan Isar guard immediately") {
    try registry.validateOrphanCleanup(third, jobID: job.id, revision: job.revision, leaseID: orphan.id)
  }
  let last = try registry.claim(registry.capture(third), job: job, permission: .write)
  try rejects("a publication writer cannot authorize abandonment") {
    try registry.validateCleanup(third, jobID: job.id, revision: job.revision, leaseID: last.id)
  }
  registry.stopClient(third)
  try rejects("client teardown invalidates its direct writer guard") {
    try registry.validate(third, jobID: job.id, revision: job.revision,
      leaseID: last.id, requiresWrite: true)
  }
  print("Native import-ownership contracts passed: queued barrier tickets, 24 actual claim threads, blocked-worker-independent guard/revocation, engine/client replacement, scoped cancellation and read-only recovery. Product Isar import remains disabled.")
}
