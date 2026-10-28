import Foundation

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
  print("Native library-file contracts passed: actual hashes, idempotent no-overwrite promotion, three crash boundaries, six process writers and unsafe-file refusal. No media/Isar/import acceptance claim.")
}
