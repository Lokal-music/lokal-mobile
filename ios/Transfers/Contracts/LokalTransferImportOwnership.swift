import Foundation

/// Immediate cancellation is independent of the utility/file queues. Publication
/// and revocation share this short lock; long copying/hashing never holds it.
/// A published file still needs the reservation/cleanup barrier before retiring
/// its database intent. This token alone does not implement that app barrier.
final class LokalTransferCopyCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  func check() throws { try whileCurrent {} }

  // Never call back into the ownership registry while holding this lock.
  func whileCurrent<T>(_ operation: () throws -> T) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled else { throw LokalTransferError.invalidTransition }
    return try operation()
  }
}

/// Ephemeral import ownership, separate from the durable job/Isar receipts.
/// Runtime must authorize the current pairing and journal phase before claim.
/// This class does not authorize credentials, open storage or import a song.
/// Runner exposes the private guard; product library import remains disabled
/// until its database/media/scanner/deletion adapters are accepted.
final class LokalTransferImportOwnership: @unchecked Sendable {
  struct Owner: Hashable, Sendable {
    fileprivate let engineID: String
    let clientID: String
  }
  struct Ticket: Sendable {
    let owner: Owner
    fileprivate let barrier: UUID
  }
  enum Permission: Equatable, Sendable { case write, reconcileOnly }
  struct Lease: Sendable {
    let id: String
    let jobID: String
    let revision: Int
    let permission: Permission
    let cancellation: LokalTransferCopyCancellation
    fileprivate let owner: Owner
    fileprivate let scope: LokalTransferScope
  }

  private let lock = NSLock()
  private var engineID: String?
  private var owner: Owner?
  private var barrier = UUID()
  private var active: Lease?

  private func locked<T>(_ operation: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try operation()
  }

  private func retireActive() {
    active?.cancellation.cancel()
    active = nil
  }

  private func normalized(_ value: LokalTransferScope) throws -> LokalTransferScope {
    try value.validate()
    return LokalTransferScope(desktopID: value.desktopID,
      origin: try LokalTransferRequest.originKey(value.origin), pairingID: value.pairingID)
  }

  func attachEngine() -> String {
    locked {
      barrier = UUID()
      retireActive()
      let id = UUID().uuidString.lowercased()
      engineID = id
      owner = nil
      return id
    }
  }

  func attachClient(engineID: String, clientID: String) throws -> Owner {
    guard UUID(uuidString: clientID)?.uuidString.lowercased() == clientID else {
      throw LokalTransferError.invalidRecord
    }
    return try locked {
      guard self.engineID == engineID else { throw LokalTransferError.invalidTransition }
      let next = Owner(engineID: engineID, clientID: clientID)
      if owner != next {
        barrier = UUID()
        retireActive()
        owner = next
      }
      return next
    }
  }

  /// Capture synchronously at the bridge, before dispatching a claim. Even a
  /// queued claim with no active lease must be retired by clear/unpair/handoff.
  func capture(_ owner: Owner) throws -> Ticket {
    try locked {
      guard self.owner == owner else { throw LokalTransferError.invalidTransition }
      return Ticket(owner: owner, barrier: barrier)
    }
  }

  func validateTicket(_ ticket: Ticket) throws {
    try locked {
      guard owner == ticket.owner, barrier == ticket.barrier else {
        throw LokalTransferError.staleRevision
      }
    }
  }

  func claim(_ ticket: Ticket, job: LokalTransferJob,
             permission: Permission) throws -> Lease {
    try job.validate()
    guard job.direction == .download, [.validating, .importing].contains(job.phase) else {
      throw LokalTransferError.invalidTransition
    }
    let scope = try normalized(LokalTransferScope(desktopID: job.identity.desktopID,
      origin: job.identity.origin, pairingID: job.identity.pairingID))
    return try locked {
      guard ticket.barrier == barrier, owner == ticket.owner else {
        throw LokalTransferError.staleRevision
      }
      if let active {
        guard active.jobID == job.id, active.revision == job.revision,
              active.owner == ticket.owner, active.scope == scope,
              active.permission == permission else { throw LokalTransferError.invalidTransition }
        try active.cancellation.check()
        return active
      }
      let lease = Lease(id: UUID().uuidString.lowercased(), jobID: job.id,
        revision: job.revision, permission: permission,
        cancellation: LokalTransferCopyCancellation(), owner: ticket.owner, scope: scope)
      active = lease
      return lease
    }
  }

  private func matching(_ owner: Owner, jobID: String, revision: Int, leaseID: String) throws -> Lease {
    guard self.owner == owner, let active, active.owner == owner,
          active.id == leaseID, active.jobID == jobID, active.revision == revision else {
      throw LokalTransferError.staleRevision
    }
    return active
  }

  /// Direct lock-only guard for an Isar writer. Do not dispatch this through a
  /// runtime/file queue that could be occupied by a long fsync or media probe.
  func validate(_ owner: Owner, jobID: String, revision: Int, leaseID: String,
                requiresWrite: Bool) throws {
    try locked {
      let lease = try matching(owner, jobID: jobID, revision: revision, leaseID: leaseID)
      guard !requiresWrite || lease.permission == .write else {
        throw LokalTransferError.invalidTransition
      }
      try lease.cancellation.check()
    }
  }

  /// Runtime must drain owned file work before acknowledging cleanup/releasing
  /// a database reservation. A stale client cannot release a replacement lease.
  func release(_ owner: Owner, jobID: String, revision: Int, leaseID: String) throws {
    try locked {
      _ = try matching(owner, jobID: jobID, revision: revision, leaseID: leaseID)
      barrier = UUID()
      retireActive()
    }
  }

  /// Stop publication immediately, but retain identity until the file-worker
  /// barrier has drained. Only then may Runtime acknowledge release.
  func cancel(_ owner: Owner, jobID: String, revision: Int, leaseID: String) throws {
    try locked {
      try matching(owner, jobID: jobID, revision: revision, leaseID: leaseID).cancellation.cancel()
    }
  }

  func stopClient(_ value: Owner) {
    locked {
      guard owner == value else { return }
      barrier = UUID()
      retireActive()
      owner = nil
    }
  }

  func detachEngine(_ value: String) {
    locked {
      guard engineID == value else { return }
      barrier = UUID()
      retireActive()
      owner = nil
      engineID = nil
    }
  }

  /// Advance the barrier even when no file operation has claimed a lease yet.
  func revokeAll() {
    locked {
      barrier = UUID()
      retireActive()
    }
  }

  func revoke(jobID: String, revision: Int) {
    locked {
      barrier = UUID()
      if active?.jobID == jobID, active?.revision == revision { retireActive() }
    }
  }

  func revoke(scope: LokalTransferScope) throws {
    let scope = try normalized(scope)
    locked {
      barrier = UUID()
      if active?.scope == scope { retireActive() }
    }
  }
}
