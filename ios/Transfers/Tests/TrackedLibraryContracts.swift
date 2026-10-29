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

  let concurrent = try fixture("concurrent")
  let children = try (0..<6).map { _ in try child(concurrent) }
  for process in children { process.waitUntilExit() }
  try require(children.allSatisfy { $0.terminationStatus == 0 }, "six tracked process writers finish")
  try require(concurrent.journal.snapshot().custodies.count == 1 && concurrent.privateParts().isEmpty,
    "six writers coalesce one durable work record and physical copy")
  try require(Data(contentsOf: concurrent.target()) == payload, "concurrent tracked publication keeps complete bytes")
  print("Tracked library contracts passed: real native marker/inode proof, private parts, five process-exit boundaries, six process writers, cancellation, lost staging/acknowledgement, same-byte replacement/modified-file refusal and importing no-recreation. Media, Isar coordinator and public-file cleanup remain unqualified.")
}
