import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

func uploadFileJob(bytes: Data, id: String = UUID().uuidString.lowercased(),
                   hash: String = "3eec6f2df36b88a1a97c03224253e9d0c59f2696ff7b145203a5d43c736bc7e0") throws -> LokalTransferJob {
  try LokalTransferJob(id: id, direction: .upload,
    identity: LokalTransferIdentity(desktopID: "fixture-pc", sourceID: "phone-recording",
      localSongID: "42", origin: "http://127.0.0.1:5443",
      pairingID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", desktopUserID: "fixture-account"),
    metadata: LokalTransferMetadata(title: "Fixture", artist: "Fixture", album: nil, fileExtension: "wav"),
    nowMs: 1000, expectedBytes: Int64(bytes.count), expectedSHA256: hash)
}

func uploadCopyCrashChild(root: URL) throws {
  let job = try LokalTransferJob.decodeDocument(Data(contentsOf: root.appendingPathComponent("upload-job.json")))
  let source = open(root.appendingPathComponent("upload-source").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
  guard source >= 0 else { throw TestFailure.failed("open child upload source") }
  defer { close(source) }
  let files = try LokalTransferFiles(container: root)
  var checks = 0
  _ = try files.stageUpload(from: source, for: job) {
    checks += 1
    if checks == 4 { exit(98) } // One real bounded write, before copy completion.
  }
  throw TestFailure.failed("upload crash boundary not reached")
}

func runUploadFileContracts(container: URL) throws {
  let manager = FileManager.default
  let files = try LokalTransferFiles(container: container)
  // Frozen SHA-256 values independently generated with Python hashlib.
  let bytes = Data((0..<600_000).map { UInt8($0 % 251) })
  let sourcePath = container.appendingPathComponent("upload-source")
  try bytes.write(to: sourcePath)
  let source = open(sourcePath.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
  guard source >= 0 else { throw TestFailure.failed("open upload source") }
  defer { close(source) }
  try require(lseek(source, 17, SEEK_SET) == 17, "borrowed descriptor has nonzero offset")
  let job = try uploadFileJob(bytes: bytes)
  let receipt = try files.stageUpload(from: source, for: job)
  let body = try files.uploadURL(job)
  try require(receipt.bytes == Int64(bytes.count) && receipt.sha256 == job.expectedSHA256,
    "owned upload has frozen byte count and hash")
  try require(try Data(contentsOf: body) == bytes && Data(contentsOf: sourcePath) == bytes,
    "owned upload preserves source and every copied byte")
  try require(lseek(source, 0, SEEK_CUR) == 17, "upload does not reposition borrowed source")
  try require((try manager.attributesOfItem(atPath: body.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,
    "upload body is private")
  let replay = try files.stageUpload(from: -1, for: job)
  try require(replay.sha256 == receipt.sha256, "lost preparation reply reuses exact owned body without source")
  let reopened = try LokalTransferFiles(container: container)
  try require(try reopened.uploadURL(job) == body, "body survives reopening")
  try Data(repeating: 0, count: bytes.count).write(to: body)
  try rejects("changed body is not uploadable") { _ = try reopened.uploadURL(job) }
  try rejects("changed body is not silently overwritten") { _ = try files.stageUpload(from: source, for: job) }

  let mismatch = try uploadFileJob(bytes: Data(repeating: 3, count: bytes.count),
    hash: "d47b43b5c86531db6f8adfea728aa5512fc48939f4c1f6037e9eb4595ce3f689")
  try rejects("wrong source hash cleans new body") { _ = try files.stageUpload(from: source, for: mismatch) }
  let mismatchBody = container.appendingPathComponent(LokalTransferJournal.directoryName)
    .appendingPathComponent(mismatch.uploadName)
  try require(!manager.fileExists(atPath: mismatchBody.path), "hash failure retires only new private body")
  let cancelled = try uploadFileJob(bytes: bytes)
  var checks = 0
  try rejects("cancel during bounded copy") {
    _ = try files.stageUpload(from: source, for: cancelled) {
      checks += 1
      if checks == 4 { throw LokalTransferError.invalidTransition }
    }
  }
  let cancelledBody = mismatchBody.deletingLastPathComponent().appendingPathComponent(cancelled.uploadName)
  try require(!manager.fileExists(atPath: cancelledBody.path), "cancel removes its own partial body")

  let replaced = try uploadFileJob(bytes: bytes)
  let replacedBody = mismatchBody.deletingLastPathComponent().appendingPathComponent(replaced.uploadName)
  let displacedBody = container.appendingPathComponent("displaced-private-upload")
  var replaceChecks = 0
  try rejects("body name replaced during copy cannot be acknowledged") {
    _ = try files.stageUpload(from: source, for: replaced) {
      replaceChecks += 1
      if replaceChecks == 4 {
        try manager.moveItem(at: replacedBody, to: displacedBody)
        try Data("Substitute must survive".utf8).write(to: replacedBody)
      }
    }
  }
  try require(try String(contentsOf: replacedBody, encoding: .utf8) == "Substitute must survive",
    "failed snapshot cleanup does not delete a substituted node")
  let changed = try uploadFileJob(bytes: bytes)
  var sourceChecks = 0
  try rejects("source mutation during copy is refused") {
    _ = try files.stageUpload(from: source, for: changed) {
      sourceChecks += 1
      if sourceChecks == 2 { try Data(repeating: 7, count: bytes.count).write(to: sourcePath) }
    }
  }
  try bytes.write(to: sourcePath)
  // Replacing the source path does not grant authority over unrelated data:
  // the API reads the caller's already-open descriptor and checks its inode.
  let multiplyLinked = container.appendingPathComponent("upload-source-hardlink")
  try manager.linkItem(at: sourcePath, to: multiplyLinked)
  let hardlinkJob = try uploadFileJob(bytes: bytes)
  try rejects("multiply linked source is refused") { _ = try files.stageUpload(from: source, for: hardlinkJob) }
  try manager.removeItem(at: multiplyLinked)
  let linked = try uploadFileJob(bytes: bytes)
  let linkedBody = mismatchBody.deletingLastPathComponent().appendingPathComponent(linked.uploadName)
  try manager.createSymbolicLink(at: linkedBody, withDestinationURL: sourcePath)
  try rejects("existing upload symlink refused") { _ = try files.stageUpload(from: source, for: linked) }
  try rejects("upload URL never follows symlink") { _ = try files.uploadURL(linked) }
  try require(try Data(contentsOf: sourcePath) == bytes, "symlink target remains untouched")
  let directoryJob = try uploadFileJob(bytes: bytes)
  let directoryBody = linkedBody.deletingLastPathComponent().appendingPathComponent(directoryJob.uploadName)
  try manager.createDirectory(at: directoryBody, withIntermediateDirectories: false)
  try rejects("existing directory refused") { _ = try files.stageUpload(from: source, for: directoryJob) }
  let tooLarge = try LokalTransferJob(direction: .upload, identity: job.identity, metadata: job.metadata,
    nowMs: 1000, expectedBytes: LokalTransferFiles.maximumUploadBytes + 1, expectedSHA256: job.expectedSHA256)
  try rejects("desktop upload size cap enforced before copying") { _ = try files.stageUpload(from: source, for: tooLarge) }

  let interrupted = try uploadFileJob(bytes: bytes)
  try JSONEncoder().encode(interrupted).write(to: container.appendingPathComponent("upload-job.json"))
  let child = Process()
  child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
  child.arguments = ["--upload-copy-crash", container.path]
  try child.run(); child.waitUntilExit()
  try require(child.terminationStatus == 98, "process dies after actual partial upload copy")
  try rejects("partial body after crash cannot become an upload URL") { _ = try reopened.uploadURL(interrupted) }
  try rejects("partial body after crash is not overwritten without retirement") {
    _ = try reopened.stageUpload(from: source, for: interrupted)
  }
  try require(try Data(contentsOf: sourcePath) == bytes, "failure/crash never changes original")
  print("Owned upload files: bounded exact snapshot, borrowed offset, private permissions, replay/reopen, checksum refusal, cancel cleanup, symlink/directory/size refusal and actual process-exit partial preservation passed. Not native upload integration or Apple lifecycle acceptance.")
}
