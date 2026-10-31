import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct LokalTransferProgress: Codable, Sendable {
  let id: String
  let revision: Int
  let bytes: Int64
  let expectedBytes: Int64?
  let waitingForConnectivity: Bool
}

struct LokalTransferSummary: Codable, Sendable {
  let generation: Int
  let total: Int
  let counts: [String: Int]
  let progress: [LokalTransferProgress]
  let pauses: [LokalTransferPause]
  let persistenceFailed: Bool
}

typealias LokalTransferCompletion<T: Sendable> = @Sendable (Result<T, Error>) -> Void

/// Source path is native-derived and transient, never part of the job journal.
/// A missing staging file permits receipt reconciliation, not a new write.
struct LokalTransferImportClaim: Encodable, Sendable {
  let job: LokalTransferJob
  let leaseID: String
  let reconcileOnly: Bool
  let targetRelativePath: String
  let sourcePath: String?
  let clientID: String
}

struct LokalTransferPublishedImport: Encodable, Sendable {
  let job: LokalTransferJob
  let songID: Int64
  let receipt: LokalTransferLibraryReceipt
}

struct LokalTransferImportCleanupClaim: Encodable, Sendable {
  let permission = "cleanup"
  let job: LokalTransferJob
  let songID: Int64
  let leaseID, clientID, targetRelativePath: String
  let currentRevision: Int
  let currentPhase: LokalTransferPhase
  let publicationRecorded: Bool
  let resolution: LokalTransferImportResolution?
}

struct LokalTransferResolvedCleanup: Encodable, Equatable, Sendable {
  let id: String
  let revision: Int
  let songID: Int64
  let resolution: LokalTransferImportResolution
}

struct LokalTransferOrphanCleanupClaim: Encodable, Sendable {
  let permission = "orphanCleanup"
  let id: String
  let revision: Int
  let songID: Int64
  let leaseID, clientID: String
  let currentJob: LokalTransferJob
}

struct LokalTransferImportWork: Encodable, Sendable {
  let job: LokalTransferJob
  let songID: Int64
  let targetRelativePath: String
  let publicationRecorded: Bool
  let currentRevision: Int?
  let currentPhase: LokalTransferPhase?
}

struct LokalTransferImportWorkPage: Encodable, Sendable {
  let generation: Int
  let entries: [LokalTransferImportWork]
  let nextCursor: String?
}

struct LokalTransferImportCandidatePage: Encodable, Sendable {
  let generation: Int
  let entries: [LokalTransferJob]
  let nextCursor: String?
}

struct LokalTransferUploadSourceContext: Encodable, Sendable {
  let contextID: String
  let rootPath: String
  let canonicalRootPath: String
  let pairing: LokalTransferPairing
}
struct LokalTransferUploadSourceGrant: Encodable, Sendable {
  let grantID: String
  let songID: String
  let bytes: Int64
  let sha256: String
}

/// One serial native owner survives Flutter lifecycle changes. Networking can
/// finish before Flutter starts; native events are committed before the system
/// background completion is acknowledged. Import remains an application task.
class LokalTransferRuntime: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private struct Original: Hashable {
    let direction: String
    let desktopUserID: String?
    let desktopID: String
    let origin: String
    let pairingID: String?
    let sourceID: String
  }

  private func original(_ job: LokalTransferJob) throws -> Original {
    let recording: String
    if job.direction == .upload {
      guard let song = job.identity.localSongID, let hash = job.expectedSHA256, let bytes = job.expectedBytes else {
        throw LokalTransferError.invalidRecord
      }
      recording = "song:" + song + ":" + hash + ":" + String(bytes)
    } else { recording = job.identity.sourceID }
    return Original(direction: job.direction.rawValue, desktopUserID: job.identity.desktopUserID,
      desktopID: job.identity.desktopID,
      origin: try LokalTransferRequest.originKey(job.identity.origin),
      pairingID: job.identity.pairingID, sourceID: recording)
  }

  private let queue = DispatchQueue(label: "app.lokal.mobile.transfers", qos: .utility)
  private let fileQueue = DispatchQueue(label: "app.lokal.mobile.transfer-validation", qos: .utility)
  private let journal: LokalTransferJournal
  private let files: LokalTransferFiles
  private let importOwnership: LokalTransferImportOwnership
  private let library: @Sendable () throws -> LokalTransferLibrary
  private let credentials: @Sendable () throws -> LokalTransferAuthorization?
  private var session: URLSession!
  private var jobs: [String: LokalTransferJob]
  private var order: [String]
  private var generation: Int
  private var pauses: [LokalTransferScope: LokalTransferFailure]
  private var tasks: [Int: URLSessionTask] = [:]
  // Reconciliation also cancels stale daemon tasks whose revision is already
  // retired. Track their callbacks until the native unlink barrier drains.
  private var staleScopeTasks: [Int: LokalTransferScope] = [:]
  private var unknownTasks = Set<Int>()
  private var progress: [String: LokalTransferProgress] = [:]
  private var uploadResponses: [Int: Data] = [:]
  private var preparingUploads: [String: LokalTransferJob] = [:]
  private var uploadPreparationCancellation: [String: LokalTransferCopyCancellation] = [:]
  private struct UploadMatch {
    let job: LokalTransferJob
    let probe: LokalTransferUploadMatchProbe
  }
  private var uploadMatches: [String: UploadMatch] = [:]
  private struct SourceContext {
    let value: LokalTransferUploadSourceContext
    let reader: LokalTransferUploadSourceReader
    let ticket: LokalTransferImportOwnership.SubmissionTicket
    let expires: TimeInterval
  }
  private struct SourceGrant {
    let value: LokalTransferUploadSourceGrant
    let context: SourceContext
    let file: LokalTransferUploadSourceFile
  }
  private var sourceContexts: [String: SourceContext] = [:]
  private var sourceGrants: [String: SourceGrant] = [:]
  private var sourceReads: [String: LokalTransferCopyCancellation] = [:]
  private var networkSessionFinished = false
  private var reconciled = false
  private var persistenceFailed = false {
    didSet { if persistenceFailed { importOwnership.revokeAll() } }
  }
  private var storageEnumerationPending = false
  private var storageWorkerPending = false
  private var recovering = false, recoveryReadStarted = false
  private var recoveryReplies: [LokalTransferCompletion<LokalTransferSummary>] = []
  private var observer: (id: String, callback: @Sendable () -> Void)?
  private var notificationScheduled = false
  private var shutdownReplies: [@Sendable () -> Void] = []
  private var shutdownFinished = false
  private var backgroundReplies: [BackgroundReply] = []
  private var backgroundEventsFinished = false
  private var shuttingDown = false
  private struct PendingNetworkRetirement {
    let scope: LokalTransferScope
    let ticket: LokalTransferImportOwnership.RetirementTicket
    var taskIDs: Set<Int>
    var matchIDs: Set<String>
    let reply: LokalTransferCompletion<LokalTransferSummary>
  }
  private var pendingNetworkRetirements: [PendingNetworkRetirement] = []
  private var verifications: [String: [LokalTransferCompletion<LokalTransferJob>]] = [:]
  private var cleanupResolutions: [String: (mode: LokalTransferImportResolution.Mode,
    replies: [LokalTransferCompletion<LokalTransferResolvedCleanup>])] = [:]

  private final class BackgroundReply: @unchecked Sendable {
    private let callback: () -> Void
    init(_ callback: @escaping () -> Void) { self.callback = callback }
    func send() { DispatchQueue.main.async { self.callback() } }
  }

  static var sessionIdentifier: String {
    (Bundle.main.bundleIdentifier ?? "app.lokal.mobile") + ".background-transfers.v1"
  }

  init(container: URL, configuration supplied: URLSessionConfiguration? = nil,
       importOwnership: LokalTransferImportOwnership = LokalTransferImportOwnership(),
       library: @escaping @Sendable () throws -> LokalTransferLibrary = { try applicationMusicLibrary() },
       credentials: @escaping @Sendable () throws -> LokalTransferAuthorization?) throws {
    journal = try LokalTransferJournal(container: container)
    files = try LokalTransferFiles(container: container)
    self.credentials = credentials
    self.importOwnership = importOwnership
    self.library = library
    let initial = try journal.snapshot()
    jobs = Dictionary(uniqueKeysWithValues: initial.jobs.map { ($0.id, $0) })
    order = initial.jobs.map(\.id)
    generation = initial.generation
    pauses = Dictionary(uniqueKeysWithValues: initial.pauses.map { ($0.scope, $0.reason) })
    super.init()
    let configuration: URLSessionConfiguration
    if let supplied { configuration = supplied }
    else {
      #if os(iOS)
      configuration = .background(withIdentifier: Self.sessionIdentifier)
      configuration.isDiscretionary = false
      configuration.sessionSendsLaunchEvents = true
      #else
      // Portable delegate/HTTP contracts do not claim OS background execution.
      configuration = .ephemeral
      #endif
    }
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpMaximumConnectionsPerHost = 2
    configuration.allowsCellularAccess = false
    configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
    #if !os(Linux)
    configuration.waitsForConnectivity = true
    configuration.allowsExpensiveNetworkAccess = false
    configuration.allowsConstrainedNetworkAccess = false
    #endif
    let delegates = OperationQueue()
    delegates.maxConcurrentOperationCount = 1
    delegates.underlyingQueue = queue
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegates)
    queue.async {
      self.session.getAllTasks { tasks in
        self.queue.async {
          if self.persistenceFailed { for task in tasks { task.cancel() } }
          else { self.reconcile(tasks) }
        }
      }
    }
  }

  private static func now() -> Int64 {
    Int64(min(4_102_444_800_000, max(0, Date().timeIntervalSince1970 * 1000)))
  }

  /// Only native code selects the existing application's Documents/Music root.
  /// Do not follow a replaced Music symlink or accept a Flutter destination.
  static func applicationMusicLibrary() throws -> LokalTransferLibrary {
    let documents = try FileManager.default.url(for: .documentDirectory,
      in: .userDomainMask, appropriateFor: nil, create: true)
    let parent = open(documents.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw LokalTransferError.posix("open_music_parent", errno) }
    defer { close(parent) }
    if mkdirat(parent, "Music", 0o700) != 0 && errno != EEXIST {
      throw LokalTransferError.posix("create_music_root", errno)
    }
    guard fsync(parent) == 0 else { throw LokalTransferError.posix("sync_music_parent", errno) }
    return try LokalTransferLibrary(root: documents.appendingPathComponent("Music", isDirectory: true))
  }

  private func scope(_ job: LokalTransferJob) -> LokalTransferScope {
    LokalTransferScope(desktopID: job.identity.desktopID, origin: job.identity.origin, pairingID: job.identity.pairingID)
  }

  private func notify() {
    guard observer != nil, !notificationScheduled else { return }
    notificationScheduled = true
    queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
      self?.notificationScheduled = false
      self?.observer?.callback()
    }
  }

  func observe(id: String, when current: @escaping @Sendable () -> Bool = { true },
               callback: @escaping @Sendable () -> Void) {
    queue.async { if current() { self.observer = (id, callback) } }
  }

  func stopObserving(id: String) {
    queue.async { if self.observer?.id == id { self.observer = nil } }
  }

  private func summaryValue() -> LokalTransferSummary {
    var counts: [String: Int] = [:]
    for job in jobs.values { counts[job.phase.rawValue, default: 0] += 1 }
    return LokalTransferSummary(generation: generation, total: jobs.count, counts: counts,
      progress: progress.values.sorted { $0.id < $1.id },
      pauses: pauses.map { LokalTransferPause(scope: $0.key, reason: $0.value) }
        .sorted { $0.scope.desktopID + $0.scope.origin < $1.scope.desktopID + $1.scope.origin },
      persistenceFailed: persistenceFailed)
  }

  func summary(_ reply: @escaping LokalTransferCompletion<LokalTransferSummary>) {
    queue.async { reply(.success(self.summaryValue())) }
  }

  /// Public pairing identity only. Bearer values never cross the Flutter bridge.
  func currentPairing(_ reply: @escaping LokalTransferCompletion<LokalTransferPairing?>) {
    queue.async {
      do {
        guard !self.shuttingDown else { throw LokalTransferError.invalidTransition }
        let authorization = try self.credentials()
        reply(.success(authorization.map {
          LokalTransferPairing(scope: LokalTransferScope(desktopID: $0.desktopID,
            origin: $0.origin, pairingID: $0.pairingID), desktopUserID: $0.desktopUserID)
        }))
      } catch { reply(.failure(error)) }
    }
  }

  func page(offset: Int, limit: Int, reply: @escaping LokalTransferCompletion<[LokalTransferJob]>) {
    queue.async {
      guard offset >= 0, limit > 0, limit <= 100 else { reply(.failure(LokalTransferError.invalidRecord)); return }
      reply(.success(self.order.dropFirst(offset).prefix(limit).compactMap { self.jobs[$0] }))
    }
  }

  /// Drain prior native file work even when a revoked lease can no longer be
  /// released. Current root identity is required; this grants no new file write.
  func drainImports(ticket: LokalTransferImportOwnership.Ticket,
                    reply: @escaping LokalTransferCompletion<Bool>) {
    queue.async {
      do {
        guard !self.shuttingDown else { throw LokalTransferError.invalidTransition }
        try self.importOwnership.validateTicket(ticket)
        self.fileQueue.async {
          self.queue.async {
            do { try self.importOwnership.validateTicket(ticket); reply(.success(true)) }
            catch { reply(.failure(error)) }
          }
        }
      } catch { reply(.failure(error)) }
    }
  }

  /// Only ready app work crosses the channel; queued/progress/history rows do
  /// not make every foreground event serialize a library-sized job list.
  func importCandidatesPage(_ request: LokalTransferProtocol.ImportWorkPage,
                            ticket: LokalTransferImportOwnership.Ticket,
                            reply: @escaping LokalTransferCompletion<LokalTransferImportCandidatePage>) {
    queue.async {
      do {
        guard request.clientID == ticket.owner.clientID, (1...100).contains(request.limit),
              request.after == nil || LokalTransferTaskBinding(request.after!) != nil,
              !self.shuttingDown, !self.persistenceFailed else { throw LokalTransferError.invalidRecord }
        try self.importOwnership.validateTicket(ticket)
        let cursor = request.after.flatMap(LokalTransferTaskBinding.init)
        let ready = self.jobs.values.filter { job in
          guard job.direction == .download,
                [.downloaded, .staged, .validating, .importing].contains(job.phase) else { return false }
          guard let cursor else { return true }
          return job.id > cursor.id || (job.id == cursor.id && job.revision > cursor.revision)
        }.sorted { $0.id == $1.id ? $0.revision < $1.revision : $0.id < $1.id }
        let entries = Array(ready.prefix(request.limit))
        let next = ready.count > entries.count ? entries.last.map { $0.id + ":" + String($0.revision) } : nil
        try self.importOwnership.validateTicket(ticket)
        reply(.success(LokalTransferImportCandidatePage(generation: self.generation,
          entries: entries, nextCursor: next)))
      } catch { reply(.failure(error)) }
    }
  }

  /// Frozen work remains available even after a live revision is cancelled.
  func importWorkPage(_ request: LokalTransferProtocol.ImportWorkPage,
                      ticket: LokalTransferImportOwnership.Ticket,
                      reply: @escaping LokalTransferCompletion<LokalTransferImportWorkPage>) {
    queue.async {
      do {
        guard request.clientID == ticket.owner.clientID, !self.shuttingDown,
              !self.persistenceFailed else { throw LokalTransferError.staleRevision }
        try self.importOwnership.validateTicket(ticket)
        let page = try self.journal.custodyPage(after: request.after, limit: request.limit)
        let entries = try page.values.compactMap { work -> LokalTransferImportWork? in
          let current = self.jobs[work.job.id]
          if work.stagingRetired == true {
            guard current?.phase == .complete, current?.revision == work.job.revision else {
              throw LokalTransferError.invalidRecord
            }
            return nil
          }
          return LokalTransferImportWork(job: work.job, songID: work.songID,
            targetRelativePath: LokalTransferLibrary.directoryName + "/" + (try LokalTransferLibrary.fileName(work.job)),
            publicationRecorded: work.publication != nil,
            currentRevision: current?.revision, currentPhase: current?.phase)
        }
        try self.importOwnership.validateTicket(ticket)
        reply(.success(LokalTransferImportWorkPage(generation: page.generation,
          entries: entries, nextCursor: page.nextCursor)))
      } catch { reply(.failure(error)) }
    }
  }

  /// Keep the newest completed imports in visible history. Older records are
  /// eligible only after successful app acknowledgement and private staging drain.
  func completedHistoryPage(_ request: LokalTransferProtocol.ImportWorkPage,
                            ticket: LokalTransferImportOwnership.Ticket,
                            reply: @escaping LokalTransferCompletion<LokalTransferImportWorkPage>) {
    queue.async {
      do {
        guard request.clientID == ticket.owner.clientID, (1...100).contains(request.limit),
              request.after == nil || LokalTransferTaskBinding(request.after!) != nil, self.reconciled,
              !self.shuttingDown, !self.persistenceFailed else { throw LokalTransferError.staleRevision }
        try self.importOwnership.validateTicket(ticket)
        let completed = self.jobs.values.filter { $0.direction == .download && $0.phase == .complete }
          .sorted { $0.updatedMs == $1.updatedMs ? $0.id < $1.id : $0.updatedMs > $1.updatedMs }
        guard completed.count > LokalTransferJournal.retainedCompletedImports else {
          reply(.success(LokalTransferImportWorkPage(generation: self.generation, entries: [], nextCursor: nil)))
          return
        }
        let retained = Set(completed.prefix(LokalTransferJournal.retainedCompletedImports).map(\.id))
        let page = try self.journal.custodyPage(after: request.after, limit: request.limit)
        let entries = try page.values.compactMap { work -> LokalTransferImportWork? in
          guard !retained.contains(work.job.id), let current = self.jobs[work.job.id],
                current.phase == .complete, work.matches(current), work.stagingRetired == true,
                work.publication != nil, work.resolution == nil else { return nil }
          return LokalTransferImportWork(job: work.job, songID: work.songID,
            targetRelativePath: LokalTransferLibrary.directoryName + "/" + (try LokalTransferLibrary.fileName(work.job)),
            publicationRecorded: true, currentRevision: current.revision, currentPhase: current.phase)
        }
        try self.importOwnership.validateTicket(ticket)
        reply(.success(LokalTransferImportWorkPage(generation: page.generation,
          entries: entries, nextCursor: page.nextCursor)))
      } catch { reply(.failure(error)) }
    }
  }

  /// Root attests its matching committed Isar receipt under a reconciliation
  /// lease. Drain prior native file callbacks and reject any remaining OS task.
  /// Compaction opens no public file and retains idempotent-submission proof.
  func compactCompletedImport(_ request: LokalTransferProtocol.ImportPublication,
                              owner: LokalTransferImportOwnership.Owner,
                              reply: @escaping LokalTransferCompletion<Bool>) {
    queue.async {
      do {
        guard request.clientID == owner.clientID else { throw LokalTransferError.staleRevision }
        try self.importOwnership.validateHistory(owner, jobID: request.id, revision: request.revision,
          leaseID: request.leaseID)
        guard self.reconciled, !self.shuttingDown, !self.persistenceFailed else { throw LokalTransferError.invalidTransition }
        self.fileQueue.async {
          self.session.getAllTasks { actual in
            self.queue.async {
              do {
                try self.importOwnership.validateHistory(owner, jobID: request.id, revision: request.revision,
                  leaseID: request.leaseID)
                guard self.reconciled, !self.shuttingDown, !self.persistenceFailed,
                      !actual.contains(where: { LokalTransferTaskBinding($0.taskDescription)?.id == request.id }),
                      !self.tasks.values.contains(where: { LokalTransferTaskBinding($0.taskDescription)?.id == request.id }) else {
                  throw LokalTransferError.invalidTransition
                }
                if self.jobs[request.id] == nil {
                  guard try self.journal.importHistoryWasCompacted(id: request.id,
                    revision: request.revision, songID: request.songID) else { throw LokalTransferError.missingJob }
                  reply(.success(true)); return
                }
                guard let job = self.jobs[request.id], job.revision == request.revision,
                      job.phase == .complete, job.direction == .download,
                      let work = try self.journal.importCustody(id: request.id, revision: request.revision),
                      work.songID == request.songID, work.matches(job), work.stagingRetired == true,
                      work.publication != nil, work.resolution == nil else { throw LokalTransferError.invalidTransition }
                do { try self.journal.compactCompletedImport(job, songID: request.songID) }
                catch { self.storageFailed(error); self.notify(); throw error }
                self.jobs.removeValue(forKey: request.id)
                self.order.removeAll { $0 == request.id }
                self.progress.removeValue(forKey: request.id)
                self.generation += 1; self.notify()
                reply(.success(true))
              } catch { reply(.failure(error)) }
            }
          }
        }
      } catch { reply(.failure(error)) }
    }
  }

  /// Reopen committed truth after a failed acknowledgement or app reattachment.
  /// Do not accept new network work until task identities have been reconciled.
  func recover(_ reply: @escaping LokalTransferCompletion<LokalTransferSummary>) {
    importOwnership.revokeAll()
    queue.async {
      guard !self.shuttingDown, self.recoveryReplies.count < 16 else {
        reply(.failure(LokalTransferError.invalidTransition)); return
      }
      self.recoveryReplies.append(reply)
      if !self.recovering {
        self.recovering = true
        self.reconciled = false
        self.pruneUploadSources()
        for read in self.sourceReads.values { read.cancel() }
        for match in self.uploadMatches.values { match.probe.cancel() }
      }
      self.performRecoveryWhenReady()
    }
  }

  private var storageDrained: Bool {
    !storageEnumerationPending && !storageWorkerPending && tasks.isEmpty &&
      preparingUploads.isEmpty && sourceReads.isEmpty && uploadMatches.isEmpty && verifications.isEmpty
  }

  /// Never keep sending or publishing against a journal whose last durable
  /// outcome is unknown. Preserve every owned body/receipt and cancel the OS
  /// work; only an explicit drained recovery may reload durable truth.
  private func storageFailed(_ error: Error) {
    guard !persistenceFailed else { notify(); return }
    persistenceFailed = true
    sourceGrants.removeAll(); sourceContexts.removeAll(); progress.removeAll()
    for read in sourceReads.values { read.cancel() }
    for preparation in uploadPreparationCancellation.values { preparation.cancel() }
    for match in uploadMatches.values { match.probe.cancel() }
    failNetworkRetirements(error)
    for task in tasks.values { task.cancel() }
    storageEnumerationPending = true
    storageWorkerPending = true
    fileQueue.async { self.queue.async {
      self.storageWorkerPending = false
      self.finishStorageDrain()
    } }
    guard let session else {
      storageEnumerationPending = false
      finishStorageDrain(); notify(); return
    }
    session.getAllTasks { actual in
      self.queue.async {
        for task in actual where task.state != .completed {
          self.tasks[task.taskIdentifier] = task
          if let binding = LokalTransferTaskBinding(task.taskDescription), let job = self.jobs[binding.id] {
            self.staleScopeTasks[task.taskIdentifier] = self.scope(job)
          } else { self.unknownTasks.insert(task.taskIdentifier) }
          task.cancel()
        }
        self.storageEnumerationPending = false
        self.finishStorageDrain()
      }
    }
    notify()
  }

  private func finishStorageDrain() {
    guard persistenceFailed, storageDrained else { return }
    flushBackgroundReplies()
    performRecoveryWhenReady()
  }

  private func performRecoveryWhenReady() {
    guard recovering, !recoveryReadStarted, !shuttingDown,
          !persistenceFailed || storageDrained else { return }
    recoveryReadStarted = true
    session.getAllTasks { actual in
      self.queue.async {
        guard !self.shuttingDown else {
          self.finishRecovery(.failure(LokalTransferError.invalidTransition)); return
        }
        if self.persistenceFailed && !self.storageDrained {
          self.recoveryReadStarted = false
          return // The drain callback starts a fresh OS-task snapshot.
        }
        self.reconcile(actual)
        if self.persistenceFailed { self.finishRecovery(.failure(LokalTransferError.invalidRecord)) }
        else { self.finishRecovery(.success(self.summaryValue())) }
      }
    }
  }

  private func finishRecovery(_ result: Result<LokalTransferSummary, Error>) {
    let replies = recoveryReplies
    recoveryReplies.removeAll(); recovering = false; recoveryReadStarted = false
    for reply in replies { reply(result) }
  }

  private func update(_ job: LokalTransferJob, pause: LokalTransferPause? = nil,
                      acknowledging custody: LokalTransferImportCustody? = nil,
                      retiring prepared: LokalTransferImportCustody? = nil,
                      retainingCleanup cleanup: (owner: LokalTransferImportOwnership.Owner, leaseID: String)? = nil,
                      _ operation: (inout LokalTransferJob) throws -> Void) throws -> LokalTransferJob {
    let next: LokalTransferJob
    do {
      guard (prepared == nil) == (cleanup == nil) else { throw LokalTransferError.invalidTransition }
      if let cleanup {
        guard custody == nil else { throw LokalTransferError.invalidTransition }
        try importOwnership.validateCleanup(cleanup.owner, jobID: job.id,
          revision: job.revision, leaseID: cleanup.leaseID)
      }
      next = try journal.update(id: job.id, revision: job.revision, pausingScope: pause,
                                acknowledging: custody, retiring: prepared, operation)
    }
    catch {
      importOwnership.revoke(jobID: job.id, revision: job.revision)
      if let failure = error as? LokalTransferError {
        switch failure {
        case .database, .posix, .unsafeFile, .invalidRecord, .unsupportedSchema:
          storageFailed(error)
          notify()
        default: break
        }
      }
      throw error
    }
    if cleanup == nil && (job.revision != next.revision ||
        ([.validating, .importing].contains(job.phase) && ![.validating, .importing].contains(next.phase))) {
      importOwnership.revoke(jobID: job.id, revision: job.revision)
    }
    jobs[next.id] = next
    generation += 1
    if let pause { pauses[pause.scope] = pause.reason }
    notify()
    return next
  }

  /// Submission is idempotent for the same frozen intent ID, including when
  /// a Flutter reply was lost after native persistence or task creation.
  func enqueue(_ requested: [LokalTransferJob],
               submission: LokalTransferImportOwnership.SubmissionTicket? = nil,
               reply: @escaping LokalTransferCompletion<LokalTransferSummary>) {
    queue.async {
      do {
        guard !self.shuttingDown, !self.persistenceFailed else { throw LokalTransferError.invalidTransition }
        if let submission { try self.importOwnership.validateSubmission(submission) }
        guard let authorization = try self.credentials() else { throw LokalTransferError.invalidRecord }
        var new: [LokalTransferJob] = []
        guard !requested.isEmpty, requested.count <= LokalTransferJournal.maximumJobs,
              Set(requested.map(\.id)).count == requested.count else { throw LokalTransferError.invalidRecord }
        var reserved = try Set(self.jobs.values.filter { !$0.phase.isTerminal }.map(self.original))
        for job in requested {
          try job.validate()
          _ = try authorization.downloadRequest(for: job)
          guard job.direction == .download, job.phase == .queued, job.revision == 1,
                self.pauses[self.scope(job)] == nil,
                job.expectedBytes == nil || job.expectedBytes! <= LokalTransferFiles.maximumBytes else {
            throw LokalTransferError.invalidRecord
          }
          if let existing = self.jobs[job.id] {
            guard existing.identity == job.identity, existing.metadata == job.metadata,
                  existing.direction == job.direction, existing.createdMs == job.createdMs,
                  existing.expectedBytes == job.expectedBytes, existing.expectedSHA256 == job.expectedSHA256 else {
              throw LokalTransferError.duplicateJob
            }
          } else if try self.journal.archivedSubmissionMatches(job) {
            // Completion may outlive the visible history. A lost enqueue reply
            // must not turn a restored frozen plan into another download.
            continue
          } else {
            // A restored Flutter plan can create a fresh intent UUID before it
            // learns about an already queued original. Never start two copies
            // of that recording for the same pairing, even across callers.
            guard try reserved.insert(self.original(job)).inserted else { throw LokalTransferError.duplicateJob }
            new.append(job)
          }
        }
        if !new.isEmpty {
          if let submission { try self.importOwnership.validateSubmission(submission) }
          try self.journal.create(new)
          for job in new { self.jobs[job.id] = job; self.order.append(job.id) }
          self.generation += 1
        }
        if let submission { try self.importOwnership.validateSubmission(submission) }
        self.pump()
        self.notify()
        reply(.success(self.summaryValue()))
      } catch { reply(.failure(error)) }
    }
  }

  private func pruneUploadSources() {
    sourceContexts = sourceContexts.filter {
      $0.value.expires > ProcessInfo.processInfo.systemUptime &&
        (try? importOwnership.validateSubmission($0.value.ticket)) != nil
    }
    sourceGrants = sourceGrants.filter { sourceContexts[$0.value.context.value.contextID] != nil }
  }

  /// Called after the bridge retires admission consent. A worker barrier closes
  /// stale grants/reads before a root mutation can discard its source records.
  func drainUploadSources(_ reply: @escaping LokalTransferCompletion<Bool>) {
    queue.async {
      self.pruneUploadSources()
      for read in self.sourceReads.values { read.cancel() }
      self.fileQueue.async { self.queue.async { reply(.success(true)) } }
    }
  }

  func uploadSourceContext(submission: LokalTransferImportOwnership.SubmissionTicket,
                           reply: @escaping LokalTransferCompletion<LokalTransferUploadSourceContext>) {
    queue.async {
      do {
        try self.importOwnership.validateSubmission(submission)
        self.pruneUploadSources()
        guard self.reconciled, !self.shuttingDown, !self.persistenceFailed,
              self.sourceContexts.count < 4, let auth = try self.credentials(), auth.pairingID != nil else {
          throw LokalTransferError.invalidTransition
        }
        let root = try self.library().uploadSourceRoot()
        let reader = try LokalTransferUploadSourceReader(root: root)
        try self.importOwnership.validateSubmission(submission)
        let value = LokalTransferUploadSourceContext(contextID: UUID().uuidString.lowercased(), rootPath: root.path, canonicalRootPath: reader.canonicalPath,
          pairing: LokalTransferPairing(scope: LokalTransferScope(desktopID: auth.desktopID,
            origin: auth.origin, pairingID: auth.pairingID), desktopUserID: auth.desktopUserID))
        self.sourceContexts[value.contextID] = SourceContext(value: value, reader: reader,
          ticket: submission, expires: ProcessInfo.processInfo.systemUptime + 300)
        self.queue.asyncAfter(deadline: .now() + 301) { [weak self] in self?.pruneUploadSources() }
        reply(.success(value))
      } catch { reply(.failure(error)) }
    }
  }

  func authorizeUploadSource(contextID: String, relativePath: String, songID: String,
                     submission: LokalTransferImportOwnership.SubmissionTicket,
                     reply: @escaping LokalTransferCompletion<LokalTransferUploadSourceGrant>) {
    queue.async {
      do {
        self.pruneUploadSources()
        try self.importOwnership.validateSubmission(submission)
        guard !self.shuttingDown, !self.persistenceFailed, let numeric = Int64(songID), numeric > 0,
              String(numeric) == songID, let context = self.sourceContexts[contextID],
              self.sourceGrants.count + self.sourceReads.count < 4 else { throw LokalTransferError.invalidRecord }
        try self.importOwnership.validateSubmission(context.ticket)
        _ = try LokalTransferUploadSourceReader.components(relativePath)
        let readID = UUID().uuidString.lowercased(), cancellation = LokalTransferCopyCancellation()
        self.sourceReads[readID] = cancellation
        self.fileQueue.async {
          let result: Result<LokalTransferUploadSourceFile, Error> = Result {
            try LokalTransferUploadSourceFile(reader: context.reader, relativePath: relativePath) {
              try cancellation.check()
              try self.importOwnership.validateSubmission(context.ticket)
              try self.importOwnership.validateSubmission(submission)
            }
          }
          self.queue.async {
            self.sourceReads.removeValue(forKey: readID)
            defer { self.finishStorageDrain() }
            do {
              let file = try result.get()
              self.pruneUploadSources()
              try self.importOwnership.validateSubmission(submission)
              try self.importOwnership.validateSubmission(context.ticket)
              guard self.sourceContexts[contextID] != nil else { throw LokalTransferError.staleRevision }
              let value = LokalTransferUploadSourceGrant(grantID: UUID().uuidString.lowercased(), songID: songID,
                bytes: file.receipt.bytes, sha256: file.receipt.sha256)
              self.sourceGrants[value.grantID] = SourceGrant(value: value, context: context, file: file)
              reply(.success(value))
            } catch { reply(.failure(error)) }
          }
        }
      } catch { reply(.failure(error)) }
    }
  }

  func releaseUploadSource(_ id: String, reply: @escaping LokalTransferCompletion<Bool>) {
    queue.async {
      self.sourceGrants.removeValue(forKey: id); self.sourceContexts.removeValue(forKey: id)
      self.pruneUploadSources()
      reply(.success(true))
    }
  }

  func enqueueAuthorizedUpload(_ job: LokalTransferJob, grantID: String?,
                     submission: LokalTransferImportOwnership.SubmissionTicket,
                     reply: @escaping LokalTransferCompletion<LokalTransferSummary>) {
    queue.async {
      do {
        self.pruneUploadSources()
        try self.importOwnership.validateSubmission(submission)
        if let grantID {
          guard let grant = self.sourceGrants[grantID], job.identity.localSongID == grant.value.songID,
                job.expectedBytes == grant.value.bytes, job.expectedSHA256 == grant.value.sha256,
                self.scope(job) == grant.context.value.pairing.scope,
                job.identity.desktopUserID == grant.context.value.pairing.desktopUserID else {
            throw LokalTransferError.invalidRecord
          }
          try self.importOwnership.validateSubmission(grant.context.ticket)
          try grant.file.validate()
          self.sourceGrants.removeValue(forKey: grantID)
          self.enqueueUpload(job, source: grant.file.descriptor, submission: submission,
            validateSource: { try grant.file.validate() }, reply: reply)
        } else {
          // Read-only replay or recovery of an already-owned snapshot only.
          self.enqueueUpload(job, submission: submission, reply: reply)
        }
      } catch { reply(.failure(error)) }
    }
  }

  /// Native-only admission: caller supplies already-authorized source access
  /// and consent captured before dispatch. A nil source recovers an existing
  /// verified private snapshot; it can never manufacture bytes or consent.
  /// Only queued never-started intent can resume. Ambiguous POSTs cannot enter
  /// this path under a new revision or a fresh UUID for the same recording.
  func enqueueUpload(_ requested: LokalTransferJob, source: Int32? = nil,
                     submission: LokalTransferImportOwnership.SubmissionTicket,
                     validateSource: @escaping @Sendable () throws -> Void = {},
                     reply: @escaping LokalTransferCompletion<LokalTransferSummary>) {
    let owned = source.map { fcntl($0, F_DUPFD_CLOEXEC, 0) } ?? -1
    if source != nil && owned < 0 {
      reply(.failure(LokalTransferError.unsafeFile)); return
    }
    queue.async {
      do {
        try self.validateUploadAdmission(requested, submission: submission)
        if let existing = self.jobs[requested.id], [.transferring, .complete].contains(existing.phase) {
          if owned >= 0 { close(owned) }
          reply(.success(self.summaryValue())); return
        }
        guard self.tasks.count + self.preparingUploads.count < 2,
              self.preparingUploads[requested.id] == nil, self.unknownTasks.isEmpty,
              !self.tasks.values.contains(where: { LokalTransferTaskBinding($0.taskDescription)?.id == requested.id }) else { throw LokalTransferError.limitExceeded }
        guard owned >= 0 || self.jobs[requested.id] != nil else { throw LokalTransferError.unsafeFile }
        try validateSource()
        try self.files.canPrepareUpload(requested, source: owned, requireAbsent: self.jobs[requested.id] == nil)
        try self.importOwnership.validateSubmission(submission)
        if self.jobs[requested.id] == nil {
          do { try self.journal.create([requested]) }
          catch { self.storageFailed(error); self.notify(); throw error }
          self.jobs[requested.id] = requested; self.order.append(requested.id); self.generation += 1
        }
        let cancellation = LokalTransferCopyCancellation()
        self.uploadPreparationCancellation[requested.id] = cancellation
        self.preparingUploads[requested.id] = requested
        let durable = self.jobs[requested.id]!
        self.fileQueue.async {
          let prepared: Result<URL, Error> = Result {
            defer { if owned >= 0 { close(owned) } }
            guard try self.journal.currentJob(requested.id) == durable else { throw LokalTransferError.staleRevision }
            if owned >= 0 {
              try self.files.resetUnsentUpload(durable) {
                try self.importOwnership.validateSubmission(submission)
                try cancellation.check()
              }
            }
            _ = try self.files.stageUpload(from: owned, for: requested) {
              try self.importOwnership.validateSubmission(submission)
              try cancellation.check()
              try validateSource()
            }
            return try self.files.uploadURL(requested) {
              try self.importOwnership.validateSubmission(submission)
              try cancellation.check()
              try validateSource()
            }
          }
          self.queue.async {
            defer {
              self.preparingUploads.removeValue(forKey: requested.id)
              self.uploadPreparationCancellation.removeValue(forKey: requested.id)
              self.finishStorageDrain()
              self.pump()
            }
            if case .failure(let error) = prepared {
              do {
                if !self.persistenceFailed, let current = self.jobs[requested.id], [.queued, .waiting].contains(current.phase) {
                  _ = try self.update(current) { try $0.waitForUploadSource(
                    (error as? LokalTransferError) == .checksumMismatch ? .checksum : .storage, nowMs: Self.now()) }
                }
              } catch { self.storageFailed(error); self.notify() }
              reply(.failure(error)); return
            }
            do {
              let body = try prepared.get()
              try self.validateUploadAdmission(requested, submission: submission)
              guard self.tasks.count < 2, let authorization = try self.credentials() else {
                throw LokalTransferError.invalidTransition
              }
              let request = try authorization.uploadRequest(for: requested)
              try self.importOwnership.validateSubmission(submission)
              guard let current = self.jobs[requested.id], [.queued, .waiting].contains(current.phase) else {
                throw LokalTransferError.invalidTransition
              }
              let task = self.session.uploadTask(with: request, fromFile: body)
              task.taskDescription = current.taskBinding
              do {
                try self.importOwnership.validateSubmission(submission)
                _ = try self.update(current) { try $0.bind(taskID: task.taskIdentifier, nowMs: Self.now()) }
                self.tasks[task.taskIdentifier] = task
                try self.importOwnership.validateSubmission(submission)
                task.resume()
              } catch {
                self.tasks[task.taskIdentifier] = task
                self.staleScopeTasks[task.taskIdentifier] = self.scope(current)
                task.cancel(); throw error
              }
              self.notify()
              reply(.success(self.summaryValue()))
            } catch { reply(.failure(error)) }
          }
        }
      } catch {
        if owned >= 0 { close(owned) }
        reply(.failure(error))
      }
    }
  }

  private func validateUploadAdmission(_ job: LokalTransferJob,
                    submission: LokalTransferImportOwnership.SubmissionTicket) throws {
    guard reconciled, !shuttingDown, !persistenceFailed,
          job.phase == .queued, job.revision == 1, pauses[scope(job)] == nil,
          let authorization = try credentials() else { throw LokalTransferError.invalidTransition }
    try importOwnership.validateSubmission(submission)
    _ = try authorization.uploadRequest(for: job)
    if let existing = jobs[job.id] {
      guard try existing.intentFingerprint() == job.intentFingerprint() else { throw LokalTransferError.duplicateJob }
      guard [.queued, .waiting, .transferring, .complete].contains(existing.phase) else { throw LokalTransferError.invalidTransition }
    }
    let key = try original(job)
    for other in Array(jobs.values) + Array(preparingUploads.values) where other.id != job.id {
      guard try original(other) != key else { throw LokalTransferError.duplicateJob }
    }
  }

  /// Foreground recovery query. Positive content equality can acknowledge an
  /// uncertain POST; a miss is not permission to send the audio again.
  func matchUploadedOriginal(id: String, revision: Int,
                     submission: LokalTransferImportOwnership.SubmissionTicket,
                     reply: @escaping LokalTransferCompletion<LokalTransferJob?>) {
    queue.async {
      do {
        try self.importOwnership.validateSubmission(submission)
        guard self.reconciled, !self.shuttingDown, !self.persistenceFailed,
              let job = self.jobs[id], job.direction == .upload, job.revision == revision,
              self.pauses[self.scope(job)] == nil, let authorization = try self.credentials() else {
          throw LokalTransferError.invalidTransition
        }
        let request = try authorization.uploadMatchRequest(for: job)
        try self.importOwnership.validateSubmission(submission)
        if job.phase == .complete { reply(.success(job)); return }
        guard [.interrupted, .failed].contains(job.phase), self.uploadMatches.count < 2,
              !self.uploadMatches.values.contains(where: { $0.job.id == id }) else {
          throw LokalTransferError.invalidTransition
        }
        let queryID = UUID().uuidString.lowercased()
        let probe = LokalTransferUploadMatchProbe(request: request, queue: self.queue) { result in
          self.uploadMatches.removeValue(forKey: queryID)
          for index in self.pendingNetworkRetirements.indices {
            self.pendingNetworkRetirements[index].matchIDs.remove(queryID)
          }
          do {
            let originalID = try result.get()
            try self.importOwnership.validateSubmission(submission)
            guard self.reconciled, !self.shuttingDown, !self.persistenceFailed,
                  self.jobs[id] == job, self.pauses[self.scope(job)] == nil,
                  let current = try self.credentials(),
                  try current.uploadMatchRequest(for: job).allHTTPHeaderFields == request.allHTTPHeaderFields else {
              throw LokalTransferError.staleRevision
            }
            try self.importOwnership.validateSubmission(submission)
            if let originalID {
              let completed = try self.update(job) { try $0.acknowledgeMatchedUpload(originalID: originalID, nowMs: Self.now()) }
              reply(.success(completed))
            } else { reply(.success(nil)) }
          } catch { reply(.failure(error)) }
          self.finishNetworkRetirements()
          self.finishShutdownIfReady()
          self.finishStorageDrain()
        }
        self.uploadMatches[queryID] = UploadMatch(job: job, probe: probe)
        probe.start()
      } catch { reply(.failure(error)) }
    }
  }

  /// Replay-safe private-body cleanup. Terminal intent must still be durable;
  /// no matching or unattributed OS task may hold a body, and the worker queue
  /// must have drained preparation before the exact private name is unlinked.
  func cleanupUploadBody(id: String, revision: Int, reply: @escaping LokalTransferCompletion<Bool>) {
    queue.async {
      do {
        guard self.reconciled, !self.shuttingDown, !self.persistenceFailed,
              let job = self.jobs[id], job.direction == .upload, job.revision == revision,
              [.complete, .cancelled].contains(job.phase), self.preparingUploads[id] == nil else {
          throw LokalTransferError.invalidTransition
        }
        self.session.getAllTasks { actual in
          self.queue.async {
            do {
              guard self.jobs[id] == job, !self.shuttingDown, !self.persistenceFailed,
                    !actual.contains(where: {
                      guard let binding = LokalTransferTaskBinding($0.taskDescription) else { return true }
                      return binding.id == id
                    }), !self.tasks.values.contains(where: { LokalTransferTaskBinding($0.taskDescription)?.id == id }) else {
                throw LokalTransferError.invalidTransition
              }
              self.fileQueue.async {
                let cleaned: Result<Bool, Error> = Result {
                  guard try self.journal.currentJob(id) == job else { throw LokalTransferError.staleRevision }
                  try self.files.discardTerminalUpload(job)
                  return true
                }
                self.queue.async { reply(cleaned) }
              }
            } catch { reply(.failure(error)) }
          }
        }
      } catch { reply(.failure(error)) }
    }
  }

  private func pump() {
    guard reconciled, !shuttingDown, !persistenceFailed, tasks.count + preparingUploads.count < 2 else { return }
    let authorization: LokalTransferAuthorization?
    do { authorization = try credentials() }
    catch { return }
    guard let authorization else { return }
    for id in order {
      guard tasks.count + preparingUploads.count < 2 else { return }
      guard let job = jobs[id], job.direction == .download,
            job.phase == .queued || job.phase == .waiting, pauses[scope(job)] == nil else { continue }
      let request: URLRequest
      do { request = try authorization.downloadRequest(for: job) }
      catch { continue } // A different/currently unavailable pairing never inherits the token.
      let task = session.downloadTask(with: request)
      task.taskDescription = job.taskBinding
      do {
        _ = try update(job) { try $0.bind(taskID: task.taskIdentifier, nowMs: Self.now()) }
        tasks[task.taskIdentifier] = task
        task.resume()
      } catch {
        task.cancel()
        storageFailed(error)
        notify()
        return
      }
    }
  }

  private func reconcile(_ actual: [URLSessionTask]) {
    guard !shuttingDown else { return }
    do {
      // A prior COMMIT can succeed even if its acknowledgement was lost.
      // Reload durable truth before deciding which OS bindings are current.
      let durable = try journal.snapshot()
      jobs = Dictionary(uniqueKeysWithValues: durable.jobs.map { ($0.id, $0) })
      order = durable.jobs.map(\.id)
      generation = durable.generation
      pauses = Dictionary(uniqueKeysWithValues: durable.pauses.map { ($0.scope, $0.reason) })
      tasks.removeAll()
      let actualIDs = Set(actual.map(\.taskIdentifier))
      uploadResponses = uploadResponses.filter { actualIDs.contains($0.key) }
      staleScopeTasks = staleScopeTasks.filter { actualIDs.contains($0.key) }
      unknownTasks.formIntersection(actualIDs)
      progress = progress.filter { id, value in
        jobs[id]?.revision == value.revision && jobs[id]?.phase == .transferring
      }
      for task in actual {
        guard let binding = LokalTransferTaskBinding(task.taskDescription), let job = jobs[binding.id],
              job.revision == binding.revision, job.taskID == task.taskIdentifier,
              [.transferring, .received].contains(job.phase), try taskMatches(job, task: task) else {
          if let binding = LokalTransferTaskBinding(task.taskDescription),
             let job = jobs[binding.id] {
            staleScopeTasks[task.taskIdentifier] = scope(job)
          } else { unknownTasks.insert(task.taskIdentifier) }
          tasks[task.taskIdentifier] = task
          task.cancel(); continue
        }
        tasks[task.taskIdentifier] = task
      }
      for id in order {
        guard let job = jobs[id],
              [.transferring, .received].contains(job.phase), let taskID = job.taskID,
              tasks[taskID] == nil else { continue }
        // Without a live task/final acknowledgement, retain the owned bytes
        // for explicit recovery; never infer a successful request from a file.
        _ = try update(job) { try $0.fail(.network, retryable: true, nowMs: Self.now()) }
      }
      reconciled = true
      persistenceFailed = false
      // A second recovery can observe tasks that disappeared after cancel,
      // even if the old delegate callback was lost across an engine reset.
      for index in pendingNetworkRetirements.indices {
        pendingNetworkRetirements[index].taskIDs.formIntersection(actualIDs)
      }
      finishNetworkRetirements()
      pump()
      flushBackgroundReplies()
      notify()
    } catch {
      storageFailed(error)
      failNetworkRetirements(error)
      notify()
    }
  }

  private func taskMatches(_ job: LokalTransferJob, task: URLSessionTask) throws -> Bool {
    if job.direction == .download {
      let expected = try LokalTransferRequest.downloadURL(job)
      return task is URLSessionDownloadTask && task.originalRequest?.url == expected
    }
    guard task is URLSessionUploadTask, let authorization = try? credentials(),
          let expected = try? authorization.uploadRequest(for: job) else { return false }
    return task.originalRequest?.url == expected.url && task.originalRequest?.httpMethod == "POST"
      && task.originalRequest?.value(forHTTPHeaderField: "x-remote-token") == expected.value(forHTTPHeaderField: "x-remote-token")
      && task.originalRequest?.value(forHTTPHeaderField: "x-api-key") == expected.value(forHTTPHeaderField: "x-api-key")
      && task.originalRequest?.value(forHTTPHeaderField: "x-link-metadata") == expected.value(forHTTPHeaderField: "x-link-metadata")
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                  didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    guard let job = current(dataTask), job.direction == .upload,
          let response = response as? HTTPURLResponse else { completionHandler(.cancel); return }
    do {
      try LokalTransferRequest.checkUploadResponse(response, job: job)
      uploadResponses[dataTask.taskIdentifier] = Data()
      completionHandler(.allow)
    } catch {
      failed(dataTask, reason: [401, 403].contains(response.statusCode) ? .unauthorized : .invalidResponse, retryable: false)
      completionHandler(.cancel)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard let job = current(dataTask), job.direction == .upload else { return }
    guard var body = uploadResponses[dataTask.taskIdentifier],
          data.count <= LokalTransferRequest.maximumUploadResponseBytes - body.count else {
      failed(dataTask, reason: .invalidResponse, retryable: false); dataTask.cancel(); return
    }
    body.append(data)
    uploadResponses[dataTask.taskIdentifier] = body
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                  totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
    guard let job = current(task), job.direction == .upload, let expected = job.expectedBytes else { return }
    guard totalBytesSent >= 0, totalBytesSent <= expected else {
      failed(task, reason: .checksum, retryable: false); task.cancel(); return
    }
    progress[job.id] = LokalTransferProgress(id: job.id, revision: job.revision, bytes: totalBytesSent,
      expectedBytes: expected, waitingForConnectivity: false)
    notify()
  }

  private func current(_ task: URLSessionTask) -> LokalTransferJob? {
    guard !persistenceFailed, let binding = LokalTransferTaskBinding(task.taskDescription), let job = jobs[binding.id],
          job.revision == binding.revision, job.taskID == task.taskIdentifier, job.phase == .transferring else { return nil }
    return job
  }

  private func failed(_ task: URLSessionTask, reason: LokalTransferFailure, retryable: Bool) {
    guard let job = current(task) else { return }
    // A failure retires the durable task ID before URLSession's final callback.
    // Keep that OS binding in the drainage set throughout the intervening gap.
    staleScopeTasks[task.taskIdentifier] = scope(job)
    do {
      let pause = reason == .unauthorized ? LokalTransferPause(scope: scope(job), reason: reason) : nil
      _ = try update(job, pause: pause) { try $0.fail(reason, retryable: retryable, nowMs: Self.now()) }
      if pause != nil {
        for other in tasks.values where other.taskIdentifier != task.taskIdentifier {
          if let active = current(other), scope(active) == scope(job) { other.cancel() }
        }
      }
    } catch { storageFailed(error); notify() }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                  didFinishDownloadingTo location: URL) {
    guard var job = current(downloadTask) else { return }
    do {
      guard let response = downloadTask.response as? HTTPURLResponse else { throw LokalTransferError.invalidRecord }
      if response.statusCode == 401 || response.statusCode == 403 {
        failed(downloadTask, reason: .unauthorized, retryable: false); return
      }
      let size = try LokalTransferFiles.temporaryDownloadSize(location)
      let metadata = try LokalTransferRequest.checkResponse(response, job: job, fileBytes: size)
      job = try update(job) {
        try $0.rememberDownloadResponse(taskID: downloadTask.taskIdentifier,
          bytes: metadata.bytes, sha256: metadata.sha256, nowMs: Self.now())
      }
      let bytes = try files.retainedSize(job) ?? files.retainTemporaryDownload(location, for: job)
      _ = try update(job) { try $0.retainedDownload(taskID: downloadTask.taskIdentifier, bytes: bytes, nowMs: Self.now()) }
    } catch LokalTransferError.checksumMismatch {
      failed(downloadTask, reason: .checksum, retryable: false)
    } catch {
      failed(downloadTask, reason: .invalidResponse, retryable: false)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let job = current(task), job.direction == .upload {
      do {
        if let error { throw error }
        guard try taskMatches(job, task: task),
              let response = task.response as? HTTPURLResponse,
              let body = uploadResponses[task.taskIdentifier] else { throw LokalTransferError.invalidRecord }
        let originalID = try LokalTransferRequest.uploadOriginalID(body, response: response, job: job)
        _ = try update(job) { try $0.acknowledgeUpload(taskID: task.taskIdentifier, originalID: originalID, nowMs: Self.now()) }
      } catch {
        // The peer may have committed before a response was lost. Retain the
        // snapshot and pause. Neither retry() nor pump() may POST it again.
        failed(task, reason: error is URLError ? .network : .invalidResponse, retryable: true)
      }
    } else if !persistenceFailed, let binding = LokalTransferTaskBinding(task.taskDescription), let job = jobs[binding.id],
       job.revision == binding.revision, job.taskID == task.taskIdentifier, job.phase == .received {
      do {
        _ = try update(job) {
          if error == nil { try $0.acknowledgeDownload(taskID: task.taskIdentifier, nowMs: Self.now()) }
          else { try $0.fail(.network, retryable: true, nowMs: Self.now()) }
        }
      } catch { storageFailed(error); notify() }
    } else if current(task) != nil {
      let status = (task.response as? HTTPURLResponse)?.statusCode
      if status == 401 || status == 403 { failed(task, reason: .unauthorized, retryable: false) }
      else if error == nil { failed(task, reason: .invalidResponse, retryable: false) }
      else { failed(task, reason: .network, retryable: true) }
    }
    uploadResponses.removeValue(forKey: task.taskIdentifier)
    tasks.removeValue(forKey: task.taskIdentifier)
    staleScopeTasks.removeValue(forKey: task.taskIdentifier)
    unknownTasks.remove(task.taskIdentifier)
    for index in pendingNetworkRetirements.indices {
      pendingNetworkRetirements[index].taskIDs.remove(task.taskIdentifier)
    }
    finishNetworkRetirements()
    finishStorageDrain()
    if let binding = LokalTransferTaskBinding(task.taskDescription),
       progress[binding.id]?.revision == binding.revision { progress.removeValue(forKey: binding.id) }
    pump()
    notify()
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                  didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                  totalBytesExpectedToWrite: Int64) {
    guard let job = current(downloadTask) else { return }
    if totalBytesWritten > LokalTransferFiles.maximumBytes || totalBytesExpectedToWrite > LokalTransferFiles.maximumBytes {
      failed(downloadTask, reason: .storage, retryable: false)
      downloadTask.cancel()
      return
    }
    progress[job.id] = LokalTransferProgress(id: job.id, revision: job.revision, bytes: max(0, totalBytesWritten),
      expectedBytes: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil, waitingForConnectivity: false)
    notify()
  }

  func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
    guard let job = current(task) else { return }
    let bytes = job.direction == .upload ? task.countOfBytesSent : task.countOfBytesReceived
    let expected = job.direction == .upload ? job.expectedBytes
      : (task.countOfBytesExpectedToReceive > 0 ? task.countOfBytesExpectedToReceive : nil)
    progress[job.id] = LokalTransferProgress(id: job.id, revision: job.revision, bytes: max(0, bytes),
      expectedBytes: expected, waitingForConnectivity: true)
    notify()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    backgroundEventsFinished = true
    flushBackgroundReplies()
  }

  func handleBackgroundEvents(completion: @escaping () -> Void) {
    let reply = BackgroundReply(completion)
    queue.async { self.backgroundReplies.append(reply); self.flushBackgroundReplies() }
  }

  private func flushBackgroundReplies() {
    guard backgroundEventsFinished, !backgroundReplies.isEmpty,
          persistenceFailed ? storageDrained : reconciled else { return }
    let replies = backgroundReplies
    backgroundReplies.removeAll()
    backgroundEventsFinished = false
    for reply in replies { reply.send() }
  }

  func shutdown(_ reply: @escaping @Sendable () -> Void) {
    importOwnership.revokeAll()
    queue.async {
      if self.shutdownFinished { reply(); return }
      self.shutdownReplies.append(reply)
      guard !self.shuttingDown else { return }
      self.shuttingDown = true
      self.finishRecovery(.failure(LokalTransferError.invalidTransition))
      self.sourceGrants.removeAll(); self.sourceContexts.removeAll()
      for read in self.sourceReads.values { read.cancel() }
      self.observer = nil
      self.failNetworkRetirements(LokalTransferError.invalidTransition)
      for cancellation in self.uploadPreparationCancellation.values { cancellation.cancel() }
      for match in self.uploadMatches.values { match.probe.cancel() }
      self.session.invalidateAndCancel()
    }
  }

  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
    shuttingDown = true
    finishRecovery(.failure(LokalTransferError.invalidTransition))
    sourceGrants.removeAll(); sourceContexts.removeAll()
    for read in sourceReads.values { read.cancel() }
    for cancellation in uploadPreparationCancellation.values { cancellation.cancel() }
    for match in uploadMatches.values { match.probe.cancel() }
    self.session = nil
    fileQueue.async {
      self.queue.async {
        self.networkSessionFinished = true
        self.finishShutdownIfReady()
      }
    }
  }

  private func finishShutdownIfReady() {
    guard networkSessionFinished, uploadMatches.isEmpty, !shutdownFinished else { return }
    shutdownFinished = true
    let replies = shutdownReplies
    shutdownReplies.removeAll()
    for reply in replies { reply() }
  }

  func cancel(id: String, revision: Int,
              submission: LokalTransferImportOwnership.SubmissionTicket? = nil, reply: @escaping LokalTransferCompletion<LokalTransferJob>) {
    if let submission {
      do { try importOwnership.validateSubmission(submission) }
      catch { reply(.failure(error)); return }
    }
    importOwnership.revoke(jobID: id, revision: revision)
    queue.async {
      do {
        if let submission { try self.importOwnership.validateSubmission(submission) }
        guard !self.shuttingDown, !self.persistenceFailed else { throw LokalTransferError.invalidTransition }
        guard let job = self.jobs[id] else { throw LokalTransferError.missingJob }
        guard job.revision == revision else { throw LokalTransferError.staleRevision }
        let cancelled = try self.update(job) { try $0.cancel(nowMs: Self.now()) }
        self.uploadPreparationCancellation[id]?.cancel()
        for match in self.uploadMatches.values where match.job.id == id { match.probe.cancel() }
        if let taskID = job.taskID, let task = self.tasks[taskID] {
          self.staleScopeTasks[taskID] = self.scope(job)
          task.cancel()
        }
        if self.progress[id]?.revision == revision { self.progress.removeValue(forKey: id) }
        if job.direction == .download { self.fileQueue.async { try? self.files.discard(job) } }
        reply(.success(cancelled))
      } catch { reply(.failure(error)) }
    }
  }

  /// All durable revisions for one exact pairing are retired as one SQLite
  /// transaction *before* any matching URLSession task is cancelled. Await
  /// delegate completion and the native file-worker barrier before telling
  /// the app it may discard that pairing. The frozen Isar custody remains for
  /// later cleanup; an importing row refuses this operation atomically.
  func retireNetworkScope(_ scope: LokalTransferScope,
                          ticket: LokalTransferImportOwnership.RetirementTicket,
                          retirePairing: Bool = true,
                          reply: @escaping LokalTransferCompletion<LokalTransferSummary>) {
    queue.async {
      do {
        guard self.reconciled, !self.shuttingDown, !self.persistenceFailed else {
          throw LokalTransferError.invalidTransition
        }
        try self.importOwnership.validateRetirement(ticket, scope: scope)
        self.pruneUploadSources()
        self.sourceGrants = self.sourceGrants.filter { $0.value.context.value.pairing.scope != scope }
        self.sourceContexts = self.sourceContexts.filter { $0.value.value.pairing.scope != scope }
        let changes = try self.journal.retireNetworkScope(scope, nowMs: Self.now(), retirePairing: retirePairing)
        for change in changes {
          self.importOwnership.revoke(jobID: change.previous.id, revision: change.previous.revision)
          self.jobs[change.retired.id] = change.retired
          if self.progress[change.previous.id]?.revision == change.previous.revision {
            self.progress.removeValue(forKey: change.previous.id)
          }
        }
        self.generation += 1
        if retirePairing { self.pauses[scope] = .pairingChanged }
        let activeIDs = changes.compactMap { change -> Int? in
          guard let taskID = change.previous.taskID, self.tasks[taskID] != nil else { return nil }
          return taskID
        }
        // A second unlink must wait for the first cancellation, even if the
        // journal already contains only cancelled revisions. Include stale
        // daemon tasks discovered during relaunch reconciliation as well.
        let pending = Set(activeIDs).union(self.unknownTasks)
          .union(self.staleScopeTasks.compactMap { $0.value == scope ? $0.key : nil })
          .union(self.pendingNetworkRetirements.filter { $0.scope == scope }
            .flatMap { $0.taskIDs })
        self.pendingNetworkRetirements.append(PendingNetworkRetirement(
          scope: scope, ticket: ticket, taskIDs: pending,
          matchIDs: Set(self.uploadMatches.filter { self.scope($0.value.job) == scope }.map(\.key)), reply: reply))
        for id in pending { self.tasks[id]?.cancel() }
        for match in self.uploadMatches.values where self.scope(match.job) == scope { match.probe.cancel() }
        for change in changes { self.uploadPreparationCancellation[change.previous.id]?.cancel() }
        self.finishNetworkRetirements()
        self.notify()
      } catch {
        // A failed journal write must not be mistaken for a safe unlink.
        reply(.failure(error))
      }
    }
  }

  private func failNetworkRetirements(_ error: Error) {
    let waiting = pendingNetworkRetirements
    pendingNetworkRetirements.removeAll()
    for item in waiting { item.reply(.failure(error)) }
  }

  private func finishNetworkRetirements() {
    guard !pendingNetworkRetirements.isEmpty else { return }
    var waiting: [PendingNetworkRetirement] = []
    var finished: [PendingNetworkRetirement] = []
    for item in pendingNetworkRetirements {
      if item.taskIDs.isEmpty && item.matchIDs.isEmpty { finished.append(item) }
      else { waiting.append(item) }
    }
    pendingNetworkRetirements = waiting
    for item in finished {
      let retired = jobs.values.filter {
        self.scope($0) == item.scope && ($0.phase == .cancelled || ($0.direction == .upload && $0.phase == .complete))
      }
      fileQueue.async {
        let cleaned: Result<Void, Error> = Result {
          try self.importOwnership.validateRetirement(item.ticket, scope: item.scope)
          for job in retired {
            guard try self.journal.currentJob(job.id) == job else { throw LokalTransferError.staleRevision }
            if job.direction == .upload { try self.files.discardTerminalUpload(job) }
            else {
              let previous = try job.cancelledDownloadForCleanup()
              if try self.journal.importCustody(id: previous.id, revision: previous.revision) == nil {
                try self.files.discard(previous)
              }
            }
          }
        }
        self.queue.async {
          // Earlier file callbacks may have scheduled final private cleanup.
          // Cross their second file/runtime barrier before acknowledging.
          self.fileQueue.async {
            self.queue.async {
              do {
                try cleaned.get()
                try self.importOwnership.validateRetirement(item.ticket, scope: item.scope)
                guard self.reconciled, !self.shuttingDown, !self.persistenceFailed else {
                  throw LokalTransferError.invalidTransition
                }
                item.reply(.success(self.summaryValue()))
              } catch { item.reply(.failure(error)) }
            }
          }
        }
      }
    }
  }

  func retry(id: String, revision: Int,
             submission: LokalTransferImportOwnership.SubmissionTicket? = nil, reply: @escaping LokalTransferCompletion<LokalTransferJob>) {
    queue.async {
      do {
        if let submission { try self.importOwnership.validateSubmission(submission) }
        guard !self.shuttingDown, !self.persistenceFailed else { throw LokalTransferError.invalidTransition }
        guard let job = self.jobs[id], job.direction == .download else { throw LokalTransferError.missingJob }
        guard job.revision == revision, self.pauses[self.scope(job)] == nil,
              let authorization = try self.credentials() else {
          throw LokalTransferError.staleRevision
        }
        _ = try authorization.downloadRequest(for: job)
        let original = try self.original(job)
        guard try !self.jobs.values.contains(where: {
          guard $0.id != job.id, !$0.phase.isTerminal else { return false }
          return try self.original($0) == original
        }) else { throw LokalTransferError.duplicateJob }
        let pending = try self.update(job) { try $0.retry(nowMs: Self.now()) }
        self.fileQueue.async { try? self.files.discard(job) }
        self.pump()
        reply(.success(pending))
      } catch { reply(.failure(error)) }
    }
  }

  /// This is called only after the application's explicit pairing/reconnect
  /// check. A rejected background credential cannot drain the remaining queue.
  func resume(scope: LokalTransferScope,
              submission: LokalTransferImportOwnership.SubmissionTicket? = nil, reply: @escaping LokalTransferCompletion<LokalTransferSummary>) {
    queue.async {
      do {
        if let submission { try self.importOwnership.validateSubmission(submission) }
        guard !self.shuttingDown, !self.persistenceFailed else { throw LokalTransferError.invalidTransition }
        guard let authorization = try self.credentials(), authorization.desktopID == scope.desktopID,
              authorization.pairingID == scope.pairingID,
              try LokalTransferRequest.originKey(authorization.origin) == LokalTransferRequest.originKey(scope.origin) else {
          throw LokalTransferError.invalidRecord
        }
        // An explicit pairing retirement is a durable tombstone, not a
        // transient authentication pause that reconnect can silently lift.
        guard self.pauses[scope] != .pairingChanged else {
          throw LokalTransferError.invalidTransition
        }
        try self.journal.clearPause(scope)
        self.generation += 1
        self.pauses.removeValue(forKey: scope)
        self.pump()
        self.notify()
        reply(.success(self.summaryValue()))
      } catch { reply(.failure(error)) }
    }
  }

  /// Private integration API. This does not enable product library import.
  /// Ticket was captured at the bridge before either utility queue was entered.
  func claimImport(_ request: LokalTransferProtocol.ImportClaim,
                   ticket: LokalTransferImportOwnership.Ticket,
                   reply: @escaping LokalTransferCompletion<LokalTransferImportClaim>) {
    queue.async {
      do {
        guard request.clientID == ticket.owner.clientID else { throw LokalTransferError.staleRevision }
        try self.importOwnership.validateTicket(ticket)
        guard self.reconciled, !self.shuttingDown, !self.persistenceFailed else {
          throw LokalTransferError.invalidTransition
        }
        guard var job = self.jobs[request.id], job.direction == .download else {
          throw LokalTransferError.missingJob
        }
        guard job.revision == request.revision else { throw LokalTransferError.staleRevision }
        if request.reconcileOnly {
          guard [.validating, .importing, .complete].contains(job.phase) else {
            throw LokalTransferError.invalidTransition
          }
        } else {
          guard [.staged, .validating, .importing].contains(job.phase) else {
            throw LokalTransferError.invalidTransition
          }
          // Recheck the account and pairing; no bearer or caller path enters
          // this document. A re-paired desktop never inherits old authority.
          do {
            guard let authorization = try self.credentials() else { throw LokalTransferError.invalidTransition }
            _ = try authorization.downloadRequest(for: job)
          } catch {
            self.importOwnership.revoke(jobID: job.id, revision: job.revision)
            throw error
          }
          try self.importOwnership.validateTicket(ticket)
          if job.phase == .staged {
            job = try self.update(job) { try $0.transition(to: .validating, nowMs: Self.now()) }
          }
        }
        let lease = try self.importOwnership.claim(ticket, job: job,
          permission: request.reconcileOnly ? .reconcileOnly : .write)
        do {
          let path: String?
          if request.reconcileOnly { path = nil }
          else {
            do { path = try self.files.importURL(job).path }
            catch LokalTransferError.posix(_, ENOENT) { path = nil }
          }
          try lease.cancellation.check()
          let target = LokalTransferLibrary.directoryName + "/" + (try LokalTransferLibrary.fileName(job))
          reply(.success(LokalTransferImportClaim(job: job, leaseID: lease.id,
            reconcileOnly: request.reconcileOnly, targetRelativePath: target, sourcePath: path,
            clientID: request.clientID)))
        } catch {
          // No import file work is submitted by claim. Release only this exact
          // lease; a simultaneous engine handoff must keep its replacement.
          try? self.importOwnership.release(ticket.owner, jobID: job.id,
            revision: job.revision, leaseID: lease.id)
          throw error
        }
      } catch { reply(.failure(error)) }
    }
  }

  /// Bridge has already fenced old/new publication synchronously. Grant this
  /// separate permission only after prior file work and its runtime callbacks
  /// have drained. Claim never mutates public/private files or Isar.
  func claimImportCleanup(_ request: LokalTransferProtocol.ImportCleanupClaim,
                          ticket: LokalTransferImportOwnership.Ticket,
                          reply: @escaping LokalTransferCompletion<LokalTransferImportCleanupClaim>) {
    queue.async {
      do {
        guard request.clientID == ticket.owner.clientID,
              self.reconciled, !self.shuttingDown, !self.persistenceFailed else {
          throw LokalTransferError.invalidTransition
        }
        try self.importOwnership.validateTicket(ticket)
        self.fileQueue.async {
          self.queue.async {
            do {
              try self.importOwnership.validateTicket(ticket)
              guard self.reconciled, !self.shuttingDown, !self.persistenceFailed,
                    let work = try self.journal.importCustody(id: request.id, revision: request.revision),
                    let current = self.jobs[request.id], current.revision >= request.revision,
                    current.direction == work.job.direction, current.identity == work.job.identity,
                    current.metadata == work.job.metadata, current.createdMs == work.job.createdMs,
                    current.expectedBytes == work.job.expectedBytes,
                    current.expectedSHA256 == work.job.expectedSHA256 else {
                throw LokalTransferError.staleRevision
              }
              if current.revision == request.revision {
                guard work.matches(current), [.validating, .importing, .complete].contains(current.phase) else {
                  throw LokalTransferError.invalidTransition
                }
              }
              let lease = try self.importOwnership.claim(ticket, job: work.job, permission: .cleanup)
              let target = LokalTransferLibrary.directoryName + "/" + (try LokalTransferLibrary.fileName(work.job))
              reply(.success(LokalTransferImportCleanupClaim(job: work.job, songID: work.songID,
                leaseID: lease.id, clientID: request.clientID, targetRelativePath: target,
                currentRevision: current.revision, currentPhase: current.phase,
                publicationRecorded: work.publication != nil, resolution: work.resolution)))
            } catch {
              self.importOwnership.abortCleanup(ticket)
              reply(.failure(error))
            }
          }
        }
      } catch {
        self.importOwnership.abortCleanup(ticket)
        reply(.failure(error))
      }
    }
  }

  /// Absence is bookkeeping evidence only, after the publication fence and
  /// file/runtime callback barrier. No missing-job assumption or file deletion.
  func claimOrphanCleanup(_ request: LokalTransferProtocol.ImportOrphanClaim,
                          ticket: LokalTransferImportOwnership.Ticket,
                          reply: @escaping LokalTransferCompletion<LokalTransferOrphanCleanupClaim>) {
    queue.async {
      do {
        guard request.clientID == ticket.owner.clientID, request.songID > 0,
              request.songID < Int64.max, self.reconciled,
              !self.shuttingDown, !self.persistenceFailed else { throw LokalTransferError.invalidTransition }
        try self.importOwnership.validateTicket(ticket)
        self.fileQueue.async {
          self.queue.async {
            do {
              try self.importOwnership.validateTicket(ticket)
              guard self.reconciled, !self.shuttingDown, !self.persistenceFailed,
                    let current = self.jobs[request.id], current.revision > request.revision,
                    current.direction == .download,
                    current.identity.localSongID == nil || current.identity.localSongID == String(request.songID),
                    try self.journal.importCustody(id: request.id, revision: request.revision) == nil else {
                throw LokalTransferError.staleRevision
              }
              let lease = try self.importOwnership.claimOrphanCleanup(ticket, current: current,
                retiringRevision: request.revision)
              reply(.success(LokalTransferOrphanCleanupClaim(id: request.id, revision: request.revision,
                songID: request.songID, leaseID: lease.id, clientID: request.clientID, currentJob: current)))
            } catch {
              self.importOwnership.abortCleanup(ticket)
              reply(.failure(error))
            }
          }
        }
      } catch {
        self.importOwnership.abortCleanup(ticket)
        reply(.failure(error))
      }
    }
  }

  /// Restrict file handling before an app metadata mutation. This is neither
  /// a receipt attestation nor permission to touch public files.
  func preserveImportPublicFile(_ request: LokalTransferProtocol.ImportLease,
                                owner: LokalTransferImportOwnership.Owner,
                                reply: @escaping LokalTransferCompletion<Bool>) {
    queue.async {
      do {
        guard request.clientID == owner.clientID, self.reconciled,
              !self.shuttingDown, !self.persistenceFailed else { throw LokalTransferError.invalidTransition }
        try self.importOwnership.validateCleanup(owner, jobID: request.id,
          revision: request.revision, leaseID: request.leaseID)
        guard let work = try self.journal.importCustody(id: request.id, revision: request.revision) else {
          throw LokalTransferError.staleRevision
        }
        _ = try self.journal.preserveImportPublicFile(work)
        if work.preservePublicFile != true { self.generation += 1; self.notify() }
        reply(.success(true))
      } catch { reply(.failure(error)) }
    }
  }

  /// App attests its actual Isar retiring/committed receipt. This driver never
  /// opens Isar. Cleanup permission alone cannot make this decision, and the
  /// native work remains until the app acknowledges durable Isar finalization.
  func resolveImportCleanup(_ request: LokalTransferProtocol.ImportCleanupDecision,
                            owner: LokalTransferImportOwnership.Owner,
                            reply: @escaping LokalTransferCompletion<LokalTransferResolvedCleanup>) {
    let cancellation: LokalTransferCopyCancellation
    do {
      guard request.clientID == owner.clientID,
            request.isarState == (request.mode == .abandoned ? "retiring" : "committed") else {
        throw LokalTransferError.invalidRecord
      }
      cancellation = try importOwnership.cleanupCancellation(owner, jobID: request.id,
        revision: request.revision, leaseID: request.leaseID)
    } catch { reply(.failure(error)); return }
    queue.async {
      do {
        guard self.reconciled, !self.shuttingDown, !self.persistenceFailed,
              let work = try self.journal.importCustody(id: request.id, revision: request.revision),
              work.songID == request.songID, let current = self.jobs[request.id] else {
          throw LokalTransferError.staleRevision
        }
        try self.importOwnership.validateCleanup(owner, jobID: request.id,
          revision: request.revision, leaseID: request.leaseID)
        guard request.mode != .committed || work.publication != nil else {
          throw LokalTransferError.invalidTransition
        }
        if let recorded = work.resolution {
          guard recorded.mode == request.mode, current.revision > request.revision else {
            throw LokalTransferError.invalidTransition
          }
          reply(.success(LokalTransferResolvedCleanup(id: request.id, revision: request.revision,
            songID: request.songID, resolution: recorded)))
          return
        }
        if let pending = self.cleanupResolutions[request.leaseID] {
          guard pending.mode == request.mode else { throw LokalTransferError.invalidTransition }
          self.cleanupResolutions[request.leaseID]?.replies.append(reply)
          return
        }
        if current.revision == request.revision {
          // Committed current-revision history uses the existing receipt-only
          // acknowledgement path, preserving the native completion semantics.
          guard request.mode == .abandoned else { throw LokalTransferError.invalidTransition }
          _ = try self.update(current, retiring: work,
            retainingCleanup: (owner, request.leaseID)) { try $0.retirePreparedImportAfterBarrier(nowMs: Self.now()) }
        }
        try self.journal.validateAbandonment(work)
        try cancellation.check()
        self.cleanupResolutions[request.leaseID] = (request.mode, [reply])
        self.fileQueue.async {
          let handled = Result { () throws -> LokalTransferImportResolution in
            let validate = { @Sendable in
              try self.importOwnership.validateCleanup(owner, jobID: request.id,
                revision: request.revision, leaseID: request.leaseID)
            }
            try validate(); try cancellation.check()
            let publicResult: LokalTransferLibraryAbandonment?
            if request.mode == .abandoned {
              publicResult = try self.library().abandonTracked(work, journal: self.journal,
                files: self.files, cancellation: cancellation, validateCleanupAuthority: validate)
            } else { publicResult = nil }
            try validate(); try cancellation.check()
            try self.files.discardPrivateLibraryPart(work, cancellation: cancellation, validateCleanupAuthority: validate)
            try cancellation.check()
            try self.files.discard(work.job)
            try cancellation.check()
            return LokalTransferImportResolution(mode: request.mode, abandonment: publicResult)
          }
          self.queue.async {
            let result: Result<LokalTransferResolvedCleanup, Error>
            do {
              let resolution = try handled.get()
              try self.importOwnership.validateCleanup(owner, jobID: request.id,
                revision: request.revision, leaseID: request.leaseID)
              _ = try self.journal.recordImportResolution(work, resolution: resolution)
              self.generation += 1; self.notify()
              result = .success(LokalTransferResolvedCleanup(id: request.id, revision: request.revision,
                songID: request.songID, resolution: resolution))
            } catch { result = .failure(error) }
            let waiting = self.cleanupResolutions.removeValue(forKey: request.leaseID)?.replies ?? []
            for callback in waiting { callback(result) }
          self.finishStorageDrain()
          }
        }
      } catch { reply(.failure(error)) }
    }
  }

  /// The app has now finalized its actual Isar receipt. Remove only the native
  /// resolved bookkeeping, never any file or Song. Keep the cleanup permission
  /// until the caller releases it, including after a lost finalization reply.
  func finalizeImportCleanup(_ request: LokalTransferProtocol.ImportCleanupDecision,
                             owner: LokalTransferImportOwnership.Owner,
                             reply: @escaping LokalTransferCompletion<Bool>) {
    queue.async {
      do {
        guard request.clientID == owner.clientID,
              request.isarState == (request.mode == .abandoned ? "retired" : "committed"),
              self.reconciled, !self.shuttingDown, !self.persistenceFailed,
              let current = self.jobs[request.id], current.revision > request.revision else {
          throw LokalTransferError.invalidTransition
        }
        try self.importOwnership.validateCleanup(owner, jobID: request.id,
          revision: request.revision, leaseID: request.leaseID)
        guard let work = try self.journal.importCustody(id: request.id, revision: request.revision) else {
          reply(.success(true)); return
        }
        guard work.songID == request.songID, work.resolution?.mode == request.mode,
              current.direction == work.job.direction, current.identity == work.job.identity,
              current.metadata == work.job.metadata, current.createdMs == work.job.createdMs,
              current.expectedBytes == work.job.expectedBytes,
              current.expectedSHA256 == work.job.expectedSHA256 else {
          throw LokalTransferError.staleRevision
        }
        try self.journal.removeImportCustody(work)
        self.generation += 1; self.notify()
        reply(.success(true))
      } catch { reply(.failure(error)) }
    }
  }

  /// Private publication foundation, still disabled as a product capability.
  /// The caller first prepares its Isar reservation. No media/Isar completion
  /// is inferred here: importing is the explicit uncertain-commit boundary.
  func publishImport(_ request: LokalTransferProtocol.ImportPublication,
                     owner: LokalTransferImportOwnership.Owner,
                     reply: @escaping LokalTransferCompletion<LokalTransferPublishedImport>) {
    let cancellation: LokalTransferCopyCancellation
    do {
      guard request.clientID == owner.clientID, request.songID > 0 else {
        throw LokalTransferError.staleRevision
      }
      cancellation = try importOwnership.writerCancellation(owner, jobID: request.id,
        revision: request.revision, leaseID: request.leaseID)
    } catch { reply(.failure(error)); return }
    queue.async {
      do {
        guard self.reconciled, !self.shuttingDown, !self.persistenceFailed,
              let job = self.jobs[request.id], job.revision == request.revision,
              [.validating, .importing].contains(job.phase) else { throw LokalTransferError.staleRevision }
        guard let authorization = try self.credentials() else { throw LokalTransferError.invalidTransition }
        _ = try authorization.downloadRequest(for: job)
        try cancellation.check()
        self.fileQueue.async {
          let published = Result {
            try self.library().installTracked(job, songID: request.songID, journal: self.journal,
              files: self.files, cancellation: cancellation, validateOwnership: {
                try self.importOwnership.validate(owner, jobID: request.id,
                  revision: request.revision, leaseID: request.leaseID, requiresWrite: true)
              })
          }
          self.queue.async {
            do {
              let receipt = try published.get()
              try self.importOwnership.validate(owner, jobID: request.id,
                revision: request.revision, leaseID: request.leaseID, requiresWrite: true)
              guard !self.shuttingDown, !self.persistenceFailed,
                    let current = self.jobs[request.id], current.revision == request.revision,
                    [.validating, .importing].contains(current.phase) else { throw LokalTransferError.staleRevision }
              let importing = current.phase == .importing ? current : try self.update(current) {
                try $0.transition(to: .importing, nowMs: Self.now())
              }
              try self.importOwnership.validate(owner, jobID: request.id,
                revision: request.revision, leaseID: request.leaseID, requiresWrite: true)
              reply(.success(LokalTransferPublishedImport(job: importing, songID: request.songID, receipt: receipt)))
            } catch { reply(.failure(error)) }
          }
        }
      } catch { reply(.failure(error)) }
    }
  }

  /// Root must first read its durable committed Isar receipt and exact Song ID.
  /// This is its private acknowledgement, not independent proof of an Isar
  /// commit. Completion retains frozen native custody for lost-reply recovery.
  /// Cleanup touches only app-private retained staging, never public Music.
  func acknowledgeImport(_ request: LokalTransferProtocol.ImportPublication,
                         owner: LokalTransferImportOwnership.Owner,
                         reply: @escaping LokalTransferCompletion<LokalTransferJob>) {
    queue.async {
      do {
        guard request.clientID == owner.clientID else { throw LokalTransferError.staleRevision }
        try self.importOwnership.validate(owner, jobID: request.id,
          revision: request.revision, leaseID: request.leaseID, requiresWrite: false)
        guard self.reconciled, !self.shuttingDown, !self.persistenceFailed,
              let job = self.jobs[request.id], job.revision == request.revision,
              [.importing, .complete].contains(job.phase),
              let work = try self.journal.importCustody(id: request.id, revision: request.revision),
              work.songID == request.songID, work.matches(job), work.publication != nil else {
          throw LokalTransferError.staleRevision
        }
        // Repeated completion must not emit another mutation/change event:
        // event-driven recovery could otherwise acknowledge history forever.
        let completed = job.phase == .complete ? job : try self.update(job, acknowledging: work) {
          if $0.phase != .complete { try $0.transition(to: .complete, nowMs: Self.now()) }
        }
        if work.stagingRetired == true { reply(.success(completed)); return }
        self.fileQueue.async {
          let cleanup = Result { try self.files.discard(work.job) }
          self.queue.async {
            do {
              try cleanup.get()
              guard let current = try self.journal.importCustody(id: request.id, revision: request.revision),
                    current.job == work.job, current.songID == work.songID,
                    current.publication == work.publication, current.location == work.location else {
                throw LokalTransferError.staleRevision
              }
              if current.stagingRetired != true {
                _ = try self.journal.recordImportStagingRetired(current)
                self.generation += 1; self.notify()
              }
              reply(.success(completed))
            }
            catch { reply(.failure(error)) }
          }
        }
      } catch { reply(.failure(error)) }
    }
  }

  /// Publication stops immediately; release is acknowledged only after all
  /// earlier file work has drained. The direct Isar guard never queues here.
  func releaseImport(_ request: LokalTransferProtocol.ImportLease,
                     owner: LokalTransferImportOwnership.Owner,
                     reply: @escaping LokalTransferCompletion<Bool>) {
    do {
      guard request.clientID == owner.clientID else { throw LokalTransferError.staleRevision }
      try importOwnership.cancel(owner, jobID: request.id, revision: request.revision, leaseID: request.leaseID)
    } catch { reply(.failure(error)); return }
    queue.async {
      self.fileQueue.async {
        self.queue.async {
          do {
            try self.importOwnership.release(owner, jobID: request.id,
              revision: request.revision, leaseID: request.leaseID)
            reply(.success(true))
          } catch { reply(.failure(error)) }
        }
      }
    }
  }

  func verify(id: String, revision: Int, reply: @escaping LokalTransferCompletion<LokalTransferJob>) {
    queue.async {
      guard !self.shuttingDown, !self.persistenceFailed,
            let job = self.jobs[id], job.revision == revision, job.phase == .downloaded else {
        reply(.failure(LokalTransferError.staleRevision)); return
      }
      let binding = job.taskBinding
      if self.verifications[binding] != nil {
        self.verifications[binding]?.append(reply)
        return
      }
      self.verifications[binding] = [reply]
      self.fileQueue.async {
        let inspected = Result { try self.files.inspect(job) }
        self.queue.async {
          let result: Result<LokalTransferJob, Error>
          do {
            guard !self.persistenceFailed, let current = self.jobs[id], current.revision == revision, current.phase == .downloaded else {
              throw LokalTransferError.staleRevision
            }
            let receipt = try inspected.get()
            let verified = try self.update(current) {
              try $0.verifiedDownload(bytes: receipt.bytes, sha256: receipt.sha256, nowMs: Self.now())
            }
            result = .success(verified)
          } catch {
            if !self.persistenceFailed, let current = self.jobs[id], current.revision == revision, current.phase == .downloaded {
              do {
                let reason: LokalTransferFailure = (error as? LokalTransferError) == .checksumMismatch ? .checksum : .storage
                _ = try self.update(current) { try $0.fail(reason, retryable: false, nowMs: Self.now()) }
              } catch { self.storageFailed(error); self.notify() }
            }
            result = .failure(error)
          }
          let waiting = self.verifications.removeValue(forKey: binding) ?? []
          for callback in waiting { callback(result) }
          self.finishStorageDrain()
        }
      }
    }
  }
}


#if !os(Linux)
extension LokalTransferRuntime: URLSessionDataDelegate {}
#endif
