import Foundation

private final class CopyCheckpoint: @unchecked Sendable {
  private let lock = NSLock()
  private var checks = 0
  func next() -> Int {
    lock.lock()
    defer { lock.unlock() }
    checks += 1
    return checks
  }
}

/// Actual filesystem/process tests. Three-byte fixtures establish byte custody
/// and crash recovery only, never media decoding or committed library identity.
func runLibraryContracts(container: URL, job: LokalTransferJob, files: LokalTransferFiles) throws {
  let manager = FileManager.default
  let source = try files.importURL(job)
  let sourceBytes = try Data(contentsOf: source)
  let jobDocument = container.appendingPathComponent("library-test-job.json")
  try JSONEncoder().encode(job).write(to: jobDocument)
  func music(_ name: String) throws -> URL {
    let root = container.appendingPathComponent("music-" + name)
    try manager.createDirectory(at: root, withIntermediateDirectories: false)
    return root
  }
  func child(_ root: URL, boundary: String = "none") throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--library-copy", container.path, root.path, jobDocument.path, boundary]
    try process.run()
    return process
  }
  let root = try music("idempotent")
  let library = try LokalTransferLibrary(root: root)
  let receipt = try library.install(job, from: files)
  let destination = root.appendingPathComponent(receipt.relativePath)
  try require(receipt.bytes == job.receivedBytes && receipt.sha256 == job.receivedSHA256,
    "installed copy binds actual byte receipt to the frozen job")
  try require(Data(contentsOf: destination) == sourceBytes, "installed copy has the actual retained bytes")
  let firstInode = try manager.attributesOfItem(atPath: destination.path)[.systemFileNumber] as! NSNumber
  try require(library.install(job, from: files) == receipt, "lost acknowledgement reuses one deterministic receipt")
  try require((manager.attributesOfItem(atPath: destination.path)[.systemFileNumber] as! NSNumber) == firstInode,
    "repeated install does not replace the existing verified file")
  try files.discard(job)
  try require(library.install(job, from: files) == receipt,
    "already promoted bytes can reconcile even after staging cleanup")
  try sourceBytes.write(to: source)
  var stagedDocument = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
  stagedDocument["phase"] = "staged"
  let notClaimed = try LokalTransferJob.decodeDocument(JSONSerialization.data(withJSONObject: stagedDocument))
  try rejects("unclaimed staged bytes cannot become a library file") { _ = try library.install(notClaimed, from: files) }

  let cancelled = LokalTransferCopyCancellation()
  cancelled.cancel()
  try rejects("a revoked token cannot reuse or publish a receipt") {
    _ = try library.install(job, from: files, cancellation: cancelled)
  }
  for boundary in ["beforePublication", "afterPublication"] {
    let cancelledRoot = try music("cancel-" + boundary)
    let cancellation = LokalTransferCopyCancellation()
    let copying = try LokalTransferLibrary(root: cancelledRoot, testingBoundary: { stage in
      if stage == boundary { cancellation.cancel() }
    })
    try rejects("cancel at publication boundary cannot acknowledge import") {
      _ = try copying.install(job, from: files, cancellation: cancellation)
    }
    let names = try manager.contentsOfDirectory(atPath: cancelledRoot.appendingPathComponent(LokalTransferLibrary.directoryName).path)
    try require(!names.contains { $0.hasSuffix(".part") }, "cancel drains its exclusive part")
    let visible = names.filter { !$0.hasPrefix(".") }
    try require(visible.count == (boundary == "afterPublication" ? 1 : 0),
      "only cancellation that wins before publication prevents a visible file")
    if boundary == "afterPublication" {
      let recovered = try copying.install(job, from: files)
      try require(recovered.bytes == job.receivedBytes,
        "published bytes remain recoverable while their prepared reservation is retained")
    }
  }

  // Interrupt an actual 1 MiB copy after the first 256 KiB write. The boundary
  // observes real part bytes; this is not a timing-dependent cancellation race.
  let bigPayload = Data(repeating: 97, count: 1024 * 1024)
  let bigHash = "9bc1b2a288b26af7257a36277ae3816a7d4f16e89c1e7e77d0a5c48bad62b360"
  var bigDocument = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
  bigDocument["expectedBytes"] = bigPayload.count
  bigDocument["receivedBytes"] = bigPayload.count
  bigDocument["expectedSHA256"] = bigHash
  bigDocument["receivedSHA256"] = bigHash
  if bigDocument["responseBytes"] != nil { bigDocument["responseBytes"] = bigPayload.count }
  if bigDocument["responseSHA256"] != nil { bigDocument["responseSHA256"] = bigHash }
  let bigJob = try LokalTransferJob.decodeDocument(JSONSerialization.data(withJSONObject: bigDocument))
  try bigPayload.write(to: source)
  let midRoot = try music("cancel-mid-copy")
  let cancellation = LokalTransferCopyCancellation(), checkpoint = CopyCheckpoint()
  let midPart = midRoot.appendingPathComponent(LokalTransferLibrary.directoryName)
    .appendingPathComponent("." + (try LokalTransferLibrary.fileName(bigJob)) + ".part")
  let midLibrary = try LokalTransferLibrary(root: midRoot, testingBoundary: { stage in
    if stage == "copyCheckpoint", checkpoint.next() == 4,
       (try? Data(contentsOf: midPart)) == bigPayload.prefix(256 * 1024) {
      cancellation.cancel()
    }
  })
  try rejects("cancellation stops an actual partially written large copy") {
    _ = try midLibrary.install(bigJob, from: files, cancellation: cancellation)
  }
  let midNames = try manager.contentsOfDirectory(atPath: midRoot.appendingPathComponent(LokalTransferLibrary.directoryName).path)
  try require(midNames == [".lokal-import.lock"], "cancelled copy leaves neither a visible recording nor an owned part")
  let bigReceipt = try midLibrary.install(bigJob, from: files)
  try require(bigReceipt.sha256 == bigHash && bigReceipt.bytes == bigPayload.count,
    "a fresh uncancelled attempt publishes all actual bytes")
  let hashInput = try FileHandle(forReadingFrom: source)
  defer { try? hashInput.close() }
  var hashChecks = 0
  try rejects("cancellation stops actual hash input between bounded chunks") {
    _ = try LokalTransferFiles.digest(hashInput.fileDescriptor, checkCancellation: {
      hashChecks += 1
      if hashChecks == 3 { throw LokalTransferError.invalidTransition }
    })
  }
  try require(hashInput.offset() == 256 * 1024,
    "cancelled hash reads only its first actual 256 KiB chunk")
  try sourceBytes.write(to: source)

  // A user's changed file is retained even when its new length still matches.
  try Data("def".utf8).write(to: destination)
  try rejects("changed destination is not trusted by filename/length") { _ = try library.install(job, from: files) }
  try require(Data(contentsOf: destination) == Data("def".utf8), "existing destination is never overwritten")

  for boundary in ["beforePublication", "afterPublication", "afterPromotion"] {
    let root = try music(boundary)
    let process = try child(root, boundary: boundary)
    process.waitUntilExit()
    try require(process.terminationStatus == 96, "child dies at exact owned promotion boundary")
    let recovered = try LokalTransferLibrary(root: root).install(job, from: files)
    try require(Data(contentsOf: root.appendingPathComponent(recovered.relativePath)) == sourceBytes,
      "each promotion boundary recovers the same complete bytes")
    let names = try manager.contentsOfDirectory(atPath: root.appendingPathComponent(LokalTransferLibrary.directoryName).path)
    try require(names.filter { !$0.hasPrefix(".") }.count == 1 && !names.contains { $0.hasSuffix(".part") },
      "crash recovery has exactly one complete copy and no stranded part")
  }

  let concurrentRoot = try music("concurrent")
  let children = try (0..<6).map { _ in try child(concurrentRoot) }
  for process in children {
    process.waitUntilExit()
    try require(process.terminationStatus == 0, "concurrent promotion succeeds")
  }
  let concurrent = try LokalTransferLibrary(root: concurrentRoot).install(job, from: files)
  let names = try manager.contentsOfDirectory(atPath: concurrentRoot.appendingPathComponent(LokalTransferLibrary.directoryName).path)
  try require(names.filter { !$0.hasPrefix(".") } == [URL(fileURLWithPath: concurrent.relativePath).lastPathComponent],
    "six independent process promotions share one physical copy")

  let unsafeRoot = try music("unsafe")
  let unsafeLibrary = try LokalTransferLibrary(root: unsafeRoot)
  let name = try LokalTransferLibrary.fileName(job)
  let target = unsafeRoot.appendingPathComponent(LokalTransferLibrary.directoryName).appendingPathComponent(name)
  let userOriginal = container.appendingPathComponent("library-user-original")
  try Data("preserve user audio".utf8).write(to: userOriginal)
  try manager.createSymbolicLink(at: target, withDestinationURL: userOriginal)
  try rejects("symlink destination never receives bytes") { _ = try unsafeLibrary.install(job, from: files) }
  try manager.removeItem(at: target)
  try manager.linkItem(at: userOriginal, to: target)
  try rejects("unrelated hardlink destination never receives bytes") { _ = try unsafeLibrary.install(job, from: files) }
  try manager.removeItem(at: target)
  let partial = target.deletingLastPathComponent().appendingPathComponent("." + name + ".part")
  try manager.createSymbolicLink(at: partial, withDestinationURL: userOriginal)
  try rejects("symlink part is neither followed nor deleted") { _ = try unsafeLibrary.install(job, from: files) }
  try require(String(contentsOf: userOriginal, encoding: .utf8) == "preserve user audio", "user original remains untouched")
  try manager.removeItem(at: partial)
  try Data("def".utf8).write(to: source)
  try rejects("stale source bytes cannot be promoted") { _ = try unsafeLibrary.install(job, from: files) }
  try require(!manager.fileExists(atPath: target.path) && !manager.fileExists(atPath: partial.path),
    "failed byte verification leaves no playable destination/partial")
  try sourceBytes.write(to: source)

  let replaced = container.appendingPathComponent("retired-music")
  try manager.moveItem(at: unsafeRoot, to: replaced)
  try manager.createDirectory(at: unsafeRoot, withIntermediateDirectories: false)
  try rejects("replaced Music root cannot redirect an owned promotion") { _ = try unsafeLibrary.install(job, from: files) }
  try require(manager.contentsOfDirectory(atPath: unsafeRoot.path).isEmpty, "replacement root remains untouched")
  print("Native library-file contracts passed: actual hashes, idempotent no-overwrite promotion, cancellation during actual copy and around publication, three crash boundaries, six process writers and unsafe-file refusal. No media/Isar/import acceptance claim.")
}
