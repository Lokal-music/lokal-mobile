import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct TrackedFixture {
  let root, music: URL
  let journal: LokalTransferJournal
  let files: LokalTransferFiles
  let job: LokalTransferJob
  func target() throws -> URL {
    music.appendingPathComponent(LokalTransferLibrary.directoryName)
      .appendingPathComponent(try LokalTransferLibrary.fileName(job))
  }
  func install(_ library: LokalTransferLibrary? = nil,
               cancellation: LokalTransferCopyCancellation = LokalTransferCopyCancellation()) throws -> LokalTransferLibraryReceipt {
    try (library ?? LokalTransferLibrary(root: music)).installTracked(job, songID: 42,
      journal: journal, files: files, cancellation: cancellation, validateOwnership: {})
  }
  func work() throws -> LokalTransferImportCustody {
    guard let value = try journal.importCustody(id: job.id, revision: job.revision) else {
      throw TestFailure.failed("missing tracked work")
    }
    return value
  }
  func privateParts() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(LokalTransferJournal.directoryName).path)
      .filter { $0.hasSuffix(".import-part") }
  }
}

/// Actual descriptor/xattr/hash/SQLite/cross-directory links and process exits.
/// Three-byte data is a custody fixture, not media or app import acceptance.
func runTrackedLibraryContracts(container: URL, template: LokalTransferJob) throws {
  let manager = FileManager.default
  let payload = Data("abc".utf8)
  func fixture(_ name: String) throws -> TrackedFixture {
    let root = container.appendingPathComponent("tracked-" + name)
    let music = root.appendingPathComponent("Music")
    try manager.createDirectory(at: music, withIntermediateDirectories: true)
    let journal = try LokalTransferJournal(container: root)
    let files = try LokalTransferFiles(container: root)
    let queued = try LokalTransferJob(direction: .download, identity: template.identity,
      metadata: template.metadata, nowMs: 1000, expectedBytes: template.receivedBytes,
      expectedSHA256: template.receivedSHA256)
    try journal.create([queued])
    var job = try journal.update(id: queued.id, revision: 1) { try $0.bind(taskID: 1, nowMs: 1010) }
    let download = root.appendingPathComponent("temporary-download")
    try payload.write(to: download)
    _ = try files.retainTemporaryDownload(download, for: job)
    job = try journal.update(id: job.id, revision: 1) {
      try $0.retainDownload(taskID: 1, bytes: 3, sha256: template.receivedSHA256!, nowMs: 1020)
    }
    job = try journal.update(id: job.id, revision: 1) { try $0.transition(to: .validating, nowMs: 1030) }
    return TrackedFixture(root: root, music: music, journal: journal, files: files, job: job)
  }
  func child(_ fixture: TrackedFixture, boundary: String = "none") throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--tracked-copy", fixture.root.path, fixture.music.path, fixture.job.id, boundary]
    try process.run()
    return process
  }

  for edge in ["beforeCommit", "afterCommit"] {
    let retained = try fixture("preserve-crash-" + edge)
    _ = try retained.install()
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["--preserve-import", retained.root.path, retained.job.id, edge]
    try child.run(); child.waitUntilExit()
    try require(child.terminationStatus == 97, "preservation child exits at exact transaction edge")
    let reopened = try LokalTransferJournal(container: retained.root)
    try require(reopened.importCustody(id: retained.job.id, revision: 1)?.preservePublicFile ==
      (edge == "afterCommit" ? true : nil), "preserve intent is atomic across process exit")
    try require(Data(contentsOf: retained.target()) == payload, "policy crash never changes public bytes")
  }
  for mode in ["owned", "missing", "edited", "unpublished"] {
    let retained = try fixture("preserve-" + mode)
    if mode != "unpublished" { _ = try retained.install() }
    else { _ = try retained.journal.reserveImport(id: retained.job.id, revision: 1, songID: 42) }
    let original = try retained.work()
    let kept = try retained.journal.preserveImportPublicFile(original)
    let generation = try retained.journal.snapshot().generation
    try require(retained.journal.preserveImportPublicFile(original) == kept &&
      retained.journal.snapshot().generation == generation, "lost preservation reply is read-only/idempotent")
    try rejects("retained work cannot resume publication") { _ = try retained.install() }
    let destination = try retained.target()
    if mode == "missing" { try manager.removeItem(at: destination) }
    if mode == "edited" { try Data("user edit".utf8).write(to: destination) }
    _ = try retained.journal.update(id: retained.job.id, revision: 1) { try $0.cancel(nowMs: 1060) }
    try rejects("pre-policy custody cannot authorize later abandonment") {
      try retained.journal.validateAbandonment(original)
    }
    let result = try LokalTransferLibrary(root: retained.music).abandonTracked(kept,
      journal: retained.journal, files: retained.files, cancellation: LokalTransferCopyCancellation(),
      validateCleanupAuthority: {})
    try require(result == .preservedByRequest, "explicit preservation does no public file handling")
    if mode == "owned" { try require(Data(contentsOf: destination) == payload, "owned public bytes preserved") }
    if mode == "edited" { try require(Data(contentsOf: destination) == Data("user edit".utf8), "edited bytes preserved") }
    if mode == "missing" || mode == "unpublished" {
      try require(!manager.fileExists(atPath: destination.path), "preservation never recreates missing bytes")
    }
    let saved = try retained.journal.recordImportResolution(kept,
      resolution: LokalTransferImportResolution(mode: .abandoned, abandonment: .preservedByRequest))
    try require(saved.preservePublicFile == true && saved.resolution?.mode == .abandoned,
      "preservation keeps truthful uncommitted cleanup outcome and custody")
  }
  print("Durable public-file preservation passed: two process-exit edges, owned/missing/edited/unpublished bytes, stale-policy refusal and no publication restart. Mutation integration remains gated.")

  let forgotten = try fixture("forget-preserves-public")
  _ = try forgotten.install()
  let beforeForget = try forgotten.journal.snapshot()
  let forgottenScope = LokalTransferScope(desktopID: forgotten.job.identity.desktopID,
    origin: forgotten.job.identity.origin, pairingID: forgotten.job.identity.pairingID)
  let changes = try forgotten.journal.retireNetworkScope(forgottenScope, nowMs: 1070)
  let afterForget = try forgotten.journal.snapshot()
  let retainedForget = try forgotten.work()
  try require(changes.count == 1 && retainedForget.preservePublicFile == true &&
    afterForget.generation == beforeForget.generation + 1 &&
    afterForget.pauses == [LokalTransferPause(scope: forgottenScope, reason: .pairingChanged)],
    "Forget preservation, cancellation and tombstone share one native transaction")
  try require(LokalTransferLibrary(root: forgotten.music).abandonTracked(retainedForget,
    journal: forgotten.journal, files: forgotten.files, cancellation: LokalTransferCopyCancellation(),
    validateCleanupAuthority: {}) == .preservedByRequest &&
    Data(contentsOf: forgotten.target()) == payload,
    "actual scope retirement cannot turn later app cleanup into public deletion")

  let first = try fixture("identity")
  let unbound = try first.journal.reserveImport(id: first.job.id, revision: 1, songID: 42)
  let receipt = try first.install()
  let target = try first.target()
  let work = try first.work()
  try require(work.location != nil && work.copyNonce != nil && work.publication != nil,
    "real publication retains native root, marker and descriptor proof")
  try require(Data(contentsOf: target) == payload && first.privateParts().isEmpty,
    "publication retains actual bytes and retires the private part")
  try require(!manager.contentsOfDirectory(atPath: target.deletingLastPathComponent().path).contains { $0.hasSuffix(".part") },
    "public Music never receives an incomplete part")
  let document = try JSONEncoder().encode(work)
  try require(!String(decoding: document, as: UTF8.self).contains(first.root.path),
    "durable publication contains no sandbox path")
  let inode = try manager.attributesOfItem(atPath: target.path)[.systemFileNumber] as! NSNumber
  try first.files.discard(first.job)
  try require(first.install() == receipt &&
    (manager.attributesOfItem(atPath: target.path)[.systemFileNumber] as! NSNumber) == inode,
    "lost acknowledgement verifies one tracked file without staging or replacement")
  try rejects("stale unbound work cannot retire a newer published proof") { try first.journal.removeImportCustody(unbound) }

  let anotherRoot = first.root.appendingPathComponent("Other Music")
  try manager.createDirectory(at: anotherRoot, withIntermediateDirectories: false)
  try rejects("one frozen operation cannot bind to another Music root") {
    _ = try first.install(LokalTransferLibrary(root: anotherRoot))
  }
  try require(Data(contentsOf: target) == payload, "wrong-root attempt preserves the original copy")

  let preserved = first.root.appendingPathComponent("retired-copy")
  try manager.moveItem(at: target, to: preserved)
  try manager.copyItem(at: preserved, to: target)
  try rejects("matching-byte replacement is not adopted, even when copied attributes survive") { _ = try first.install() }
  try require(Data(contentsOf: target) == payload && Data(contentsOf: preserved) == payload,
    "both matching-byte files remain untouched")

  let modified = try fixture("modified")
  _ = try modified.install()
  try Data("def".utf8).write(to: modified.target())
  try rejects("modified tracked public bytes are refused") { _ = try modified.install() }
  try require(Data(contentsOf: modified.target()) == Data("def".utf8), "modified user file is preserved")

  let preexisting = try fixture("preexisting")
  _ = try LokalTransferLibrary(root: preexisting.music)
  try payload.write(to: preexisting.target())
  try rejects("matching bytes with no native publication proof are not import authority") { _ = try preexisting.install() }
  try require(preexisting.work().publication == nil && Data(contentsOf: preexisting.target()) == payload,
    "unproven existing file is never stamped, overwritten or claimed")

  for boundary in ["trackedCopyCheckpoint", "trackedProofCommitted", "afterTrackedPublication",
                   "afterTrackedDirectorySync", "afterTrackedVerification"] {
    let current = try fixture("crash-" + boundary)
    let process = try child(current, boundary: boundary)
    process.waitUntilExit()
    try require(process.terminationStatus == 98, "tracked child exits at exact copy/publication boundary")
    let beforeRecovery = try current.work()
    if boundary == "trackedCopyCheckpoint" {
      try require(beforeRecovery.publication == nil && !manager.fileExists(atPath: current.target().path),
        "interrupted copy has no public file or fabricated publication proof")
    }
    let result = try current.install()
    try require(result.sha256 == template.receivedSHA256 && Data(contentsOf: current.target()) == payload && current.privateParts().isEmpty,
      "each tracked boundary recovers one real complete copy without a public part")
    try require(current.journal.snapshot().custodies.count == 1 && current.work().songID == 42,
      "crash recovery retains one reserved Song identity")
  }

  for boundary in ["beforeTrackedPublication", "afterTrackedPublication"] {
    let current = try fixture("cancel-" + boundary)
    let token = LokalTransferCopyCancellation()
    let library = try LokalTransferLibrary(root: current.music, testingBoundary: { if $0 == boundary { token.cancel() } })
    try rejects("revocation cannot acknowledge a tracked import") { _ = try current.install(library, cancellation: token) }
    try require(current.privateParts().isEmpty, "cancelled copy drains its private part")
    try require(manager.fileExists(atPath: current.target().path) == (boundary == "afterTrackedPublication"),
      "only revocation before the atomic link prevents public publication")
    _ = try current.install()
    try require(Data(contentsOf: current.target()) == payload, "fresh authority reconciles or copies the actual frozen bytes")
  }

  for boundary in ["trackedCopyCheckpoint", "trackedProofCommitted", "afterTrackedPublication"] {
    let current = try fixture("private-cleanup-" + boundary)
    let process = try child(current, boundary: boundary)
    process.waitUntilExit()
    try require(process.terminationStatus == 98, "private cleanup starts after actual process exit")
    let work = try current.work()
    _ = try current.journal.update(id: current.job.id, revision: 1) { try $0.cancel(nowMs: 1060) }
    try current.journal.validateAbandonment(work)
    if boundary == "afterTrackedPublication" {
      try Data("user edited public bytes".utf8).write(to: current.target())
    }
    let token = LokalTransferCopyCancellation()
    token.cancel()
    let before = try current.privateParts()
    try rejects("revoked cleanup cannot remove a private copy link") {
      try current.files.discardPrivateLibraryPart(work, cancellation: token, validateCleanupAuthority: {})
    }
    try require(current.privateParts() == before, "revoked cleanup preserves private recovery state")
    try current.files.discardPrivateLibraryPart(work, cancellation: LokalTransferCopyCancellation(), validateCleanupAuthority: {})
    try current.files.discardPrivateLibraryPart(work, cancellation: LokalTransferCopyCancellation(), validateCleanupAuthority: {})
    try require(current.privateParts().isEmpty, "private partial/proven/two-link cleanup is idempotent")
    if boundary == "afterTrackedPublication" {
      try require(Data(contentsOf: current.target()) == Data("user edited public bytes".utf8),
        "private-link retirement never deletes or rewrites edited public audio")
    } else {
      try require(!manager.fileExists(atPath: current.target().path), "private cleanup never publishes incomplete bytes")
    }
    try require(current.work() == work, "private drainage retains provenance until durable resolution")
  }
  for mode in ["replacement", "symlink"] {
    let current = try fixture("private-cleanup-unsafe-" + mode)
    let process = try child(current, boundary: "trackedProofCommitted")
    process.waitUntilExit()
    try require(process.terminationStatus == 98, "unsafe-part test retains an actual stamped private copy")
    let work = try current.work()
    let partsRoot = current.root.appendingPathComponent(LokalTransferJournal.directoryName)
    let part = partsRoot.appendingPathComponent(try current.privateParts().first!)
    let retained = current.root.appendingPathComponent("retained-native-original")
    try manager.moveItem(at: part, to: retained)
    let user = current.root.appendingPathComponent("preserved-user-file")
    try payload.write(to: user)
    if mode == "symlink" { try manager.createSymbolicLink(at: part, withDestinationURL: user) }
    else { try payload.write(to: part) }
    try rejects("private cleanup refuses a replacement inode or symlink") {
      try current.files.discardPrivateLibraryPart(work, cancellation: LokalTransferCopyCancellation(),
        validateCleanupAuthority: {})
    }
    try require(Data(contentsOf: user) == payload && Data(contentsOf: retained) == payload &&
      manager.fileExists(atPath: part.path), "unsafe-part refusal preserves all existing bytes and names")
  }

  let importing = try fixture("importing-missing")
  _ = try importing.install()
  let retired = try importing.journal.update(id: importing.job.id, revision: 1) {
    try $0.transition(to: .importing, nowMs: 1040)
  }
  try manager.removeItem(at: importing.target())
  try rejects("importing missing bytes cannot be recreated across an uncertain Isar commit") {
    _ = try LokalTransferLibrary(root: importing.music).installTracked(retired, songID: 42,
      journal: importing.journal, files: importing.files, cancellation: LokalTransferCopyCancellation(), validateOwnership: {})
  }
  try require(!manager.fileExists(atPath: importing.target().path), "missing committing copy stays missing")

  let acknowledgement = try fixture("acknowledgement")
  let oldProof = try acknowledgement.journal.reserveImport(id: acknowledgement.job.id, revision: 1, songID: 42)
  _ = try acknowledgement.install()
  let publishedProof = try acknowledgement.work()
  let committing = try acknowledgement.journal.update(id: acknowledgement.job.id, revision: 1) {
    try $0.transition(to: .importing, nowMs: 1040)
  }
  try rejects("a stale/unpublished custody witness cannot acknowledge completion") {
    _ = try acknowledgement.journal.update(id: committing.id, revision: 1, acknowledging: oldProof) {
      try $0.transition(to: .complete, nowMs: 1050)
    }
  }
  try require(acknowledgement.journal.snapshot().jobs.first?.phase == .importing,
    "failed atomic custody comparison leaves the job importing")
  let completed = try acknowledgement.journal.update(id: committing.id, revision: 1, acknowledging: publishedProof) {
    try $0.transition(to: .complete, nowMs: 1050)
  }
  try require(completed.phase == .complete && acknowledgement.journal.snapshot().custodies == [publishedProof],
    "exact native completion and frozen publication retention share the journal transaction")

  try rejects("completed/current writable custody cannot authorize abandonment") {
    try acknowledgement.journal.validateAbandonment(publishedProof)
  }
  try rejects("live publication reservation is not cleanup authority") {
    try first.journal.validateAbandonment(first.work())
  }

  let preparedRetirement = try fixture("prepared-retirement")
  let staleRetirement = try preparedRetirement.journal.reserveImport(
    id: preparedRetirement.job.id, revision: 1, songID: 42)
  _ = try preparedRetirement.install()
  let frozenRetirement = try preparedRetirement.work()
  _ = try preparedRetirement.journal.update(id: preparedRetirement.job.id, revision: 1) {
    try $0.transition(to: .importing, nowMs: 1040)
  }
  try rejects("ordinary cancel still refuses the uncertain Isar commit boundary") {
    _ = try preparedRetirement.journal.update(id: preparedRetirement.job.id, revision: 1) { try $0.cancel(nowMs: 1050) }
  }
  try rejects("stale native custody cannot authorize prepared-import retirement") {
    _ = try preparedRetirement.journal.update(id: preparedRetirement.job.id, revision: 1, retiring: staleRetirement) {
      try $0.retirePreparedImportAfterBarrier(nowMs: 1050)
    }
  }
  try rejects("private retirement cannot bypass the journal's atomic custody comparison") {
    _ = try preparedRetirement.journal.update(id: preparedRetirement.job.id, revision: 1) {
      try $0.retirePreparedImportAfterBarrier(nowMs: 1050)
    }
  }
  // Actual Isar retirement and current cleanup authority are explicit fixtures
  // here; this checks the real atomic native transition/provenance only.
  let retiredPrepared = try preparedRetirement.journal.update(id: preparedRetirement.job.id,
    revision: 1, retiring: frozenRetirement) { try $0.retirePreparedImportAfterBarrier(nowMs: 1050) }
  try require(retiredPrepared.phase == .cancelled && retiredPrepared.revision == 2 &&
    retiredPrepared.receivedSHA256 == frozenRetirement.job.receivedSHA256 &&
    preparedRetirement.work() == frozenRetirement,
    "prepared-import retirement atomically fences the old revision and preserves exact custody")
  try preparedRetirement.journal.validateAbandonment(frozenRetirement)
  try require(Data(contentsOf: preparedRetirement.target()) == payload,
    "native retirement changes no public bytes before coordinated cleanup")

  #if canImport(Darwin)
  // These execute real Foundation NSFileCoordinator on macOS. Portable Linux
  // runs deliberately do not substitute a pretend public-deletion coordinator.
  for mode in ["owned", "missing", "modified", "replacement", "revoked", "raced-edit", "raced-replacement"] {
    let abandoned = try fixture("abandon-" + mode)
    _ = try abandoned.install()
    let frozen = try abandoned.work()
    _ = try abandoned.journal.update(id: abandoned.job.id, revision: 1) { try $0.cancel(nowMs: 1060) }
    let destination = try abandoned.target()
    if mode == "missing" { try manager.removeItem(at: destination) }
    if mode == "modified" { try Data("user changed audio".utf8).write(to: destination) }
    if mode == "replacement" {
      try manager.removeItem(at: destination)
      try payload.write(to: destination)
    }
    let token = LokalTransferCopyCancellation()
    let library = try LokalTransferLibrary(root: abandoned.music, testingBoundary: { edge in
      if edge == "beforeCoordinatedUnlink" {
        if mode == "revoked" { token.cancel() }
        if mode == "raced-edit" {
          try! Data("late user edit".utf8).write(to: destination)
        }
        if mode == "raced-replacement" {
          try! FileManager.default.removeItem(at: destination)
          try! payload.write(to: destination)
        }
      }
    })
    if mode == "revoked" {
      try rejects("revoked cleanup cannot unlink coordinated public bytes") {
        _ = try library.abandonTracked(frozen, journal: abandoned.journal,
          files: abandoned.files, cancellation: token, validateCleanupAuthority: {})
      }
      try require(Data(contentsOf: destination) == payload, "revoked cleanup preserves public copy")
    } else {
      let result = try library.abandonTracked(frozen, journal: abandoned.journal,
        files: abandoned.files, cancellation: token, validateCleanupAuthority: {})
      let expected: LokalTransferLibraryAbandonment = mode == "owned" ? .removedOwnedFile :
        (mode == "missing" ? .missingFile : .preservedUserFile)
      try require(result == expected, "actual coordinated abandonment distinguishes owned/missing/user bytes")
      if expected == .preservedUserFile {
        try require(manager.fileExists(atPath: destination.path), "user replacement/edit remains present")
      } else {
        try require(!manager.fileExists(atPath: destination.path), "owned deletion/missing never recreates bytes")
        try require(library.abandonTracked(frozen, journal: abandoned.journal, files: abandoned.files,
          cancellation: token, validateCleanupAuthority: {}) == .missingFile,
          "lost unlink reply recovers idempotently without fabricating a file")
      }
    }
    try require(abandoned.work() == frozen,
      "filesystem half never removes provenance before private cleanup and Isar retirement")
  }
  print("Actual Foundation coordinated abandonment passed: owned/missing/modified/replaced bytes, late edit/replacement and cancellation. Runtime cleanup authority/Isar integration remain pending.")
  #else
  let unsupported = try fixture("abandon-unsupported")
  _ = try unsupported.install()
  _ = try unsupported.journal.update(id: unsupported.job.id, revision: 1) { try $0.cancel(nowMs: 1060) }
  try rejects("portable host cannot pretend to provide Apple file coordination") {
    _ = try LokalTransferLibrary(root: unsupported.music).abandonTracked(unsupported.work(),
      journal: unsupported.journal, files: unsupported.files,
      cancellation: LokalTransferCopyCancellation(), validateCleanupAuthority: {})
  }
  try require(Data(contentsOf: unsupported.target()) == payload,
    "portable coordination refusal leaves real public bytes untouched")
  #endif

  for edge in ["none", "beforeCommit", "afterCommit", "wrongSong", "quota"] {
    let history = try fixture("history-" + edge)
    _ = try history.install()
    let work = try history.work()
    let published = try history.journal.snapshot().jobs.first!
    try rejects("importing work is never terminal history") {
      try history.journal.compactCompletedImport(published, songID: 42)
    }
    _ = try history.journal.update(id: published.id, revision: 1) { try $0.transition(to: .importing, nowMs: 1500) }
    let complete = try history.journal.update(id: published.id, revision: 1, acknowledging: work) {
      try $0.transition(to: .complete, nowMs: 2000)
    }
    try rejects("completion without private staging drainage is not compactable") {
      try history.journal.compactCompletedImport(complete, songID: 42)
    }
    try history.files.discard(work.job)
    _ = try history.journal.recordImportStagingRetired(work)
    let queued = try LokalTransferJob(id: complete.id, direction: complete.direction,
      identity: complete.identity, metadata: complete.metadata, nowMs: complete.createdMs,
      expectedBytes: complete.expectedBytes, expectedSHA256: complete.expectedSHA256)
    try require(queued.intentFingerprint() == complete.intentFingerprint(),
      "immutable fingerprint ignores live transfer progress and phases")
    if edge == "wrongSong" {
      try rejects("wrong application receipt identity cannot compact") {
        try history.journal.compactCompletedImport(complete, songID: 43)
      }
    } else if edge == "quota" {
      let disk = history.root.appendingPathComponent(LokalTransferJournal.directoryName)
        .appendingPathComponent(LokalTransferJournal.databaseName)
      try rawExecute(disk, "UPDATE metadata SET archived_count=\(LokalTransferJournal.maximumArchivedJobs)")
      try rejects("archive quota never evicts replay evidence or partial-deletes live history") {
        try history.journal.compactCompletedImport(complete, songID: 42)
      }
      try rawExecute(disk, "UPDATE metadata SET archived_count=0")
    } else if edge == "none" {
      try history.journal.compactCompletedImport(complete, songID: 42)
    } else {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      process.arguments = ["--compact-import", history.root.path, edge]
      try process.run(); process.waitUntilExit()
      try require(process.terminationStatus == 97, "history process exits at exact commit edge")
    }
    let reopened = try LokalTransferJournal(container: history.root)
    let compacted = ["none", "afterCommit"].contains(edge)
    try require(reopened.snapshot().jobs.isEmpty == compacted &&
      reopened.snapshot().custodies.isEmpty == compacted &&
      reopened.importHistoryWasCompacted(id: complete.id, revision: 1, songID: 42) == compacted,
      "job/custody removal and compact proof are atomic across rollback and process restart")
    try require(reopened.archivedSubmissionMatches(queued) == compacted,
      "replayed frozen intent is recognized after compaction/reopen")
    if compacted {
      try rejects("archived intent cannot be recreated as a writable journal job") { try reopened.create([queued]) }
      let changed = try LokalTransferJob(id: queued.id, direction: queued.direction,
        identity: queued.identity, metadata: LokalTransferMetadata(title: "Changed intent", artist: "Other", album: nil,
          fileExtension: "wav"), nowMs: queued.createdMs, expectedBytes: queued.expectedBytes,
        expectedSHA256: queued.expectedSHA256)
      try rejects("reusing archived UUID with changed intent is refused") { _ = try reopened.archivedSubmissionMatches(changed) }
      try rejects("another Song cannot adopt compacted identity") {
        _ = try reopened.importHistoryWasCompacted(id: queued.id, revision: 1, songID: 43)
      }
    }
    try require(Data(contentsOf: history.target()) == payload,
      "every history outcome preserves actual public audio bytes")
  }
  print("Completed import history passed: acknowledged/staging-drained-only compaction, two process-exit boundaries, atomic quota/identity refusal, durable intent fingerprint and unchanged public bytes.")

  let concurrent = try fixture("concurrent")
  let children = try (0..<6).map { _ in try child(concurrent) }
  for process in children { process.waitUntilExit() }
  try require(children.allSatisfy { $0.terminationStatus == 0 }, "six tracked process writers finish")
  try require(concurrent.journal.snapshot().custodies.count == 1 && concurrent.privateParts().isEmpty,
    "six writers coalesce one durable work record and physical copy")
  try require(Data(contentsOf: concurrent.target()) == payload, "concurrent tracked publication keeps complete bytes")
  print("Tracked library contracts passed: real native marker/inode proof, private parts, five process-exit boundaries, six process writers, cancellation, lost staging/acknowledgement, same-byte replacement/modified-file refusal and importing no-recreation. Media, Isar coordinator and public-file cleanup remain unqualified.")
}
