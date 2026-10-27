import Foundation
import Darwin
import Dispatch
import CoreGraphics
import CryptoKit
import ImageIO

enum Failure: Error { case check(String) }
func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw Failure.check(message) }
}
func rejects(_ work: () throws -> Void, _ message: String) throws {
  do { try work() } catch { return }
  throw Failure.check(message)
}
func candidate(_ revision: Int, art: String? = nil, title: String = "Generated song") -> LokalWidgetSnapshot {
  LokalWidgetSnapshot(raw: [
    "schemaVersion": 1, "revision": revision, "updatedAtMs": 1_793_059_200_000,
    "current": ["id": String(repeating: "a", count: 64), "title": title, "artist": "Fixture", "artwork": art as Any? ?? NSNull()],
    "isPlaying": false, "positionMs": 500, "durationMs": 12_000,
  ])
}
func revision(_ store: LokalWidgetStore) throws -> Int {
  try store.readSnapshot()?.json["revision"] as? Int ?? 0
}
func png(_ seed: Int, width: Int = 16, height: Int = 8) throws -> Data {
  guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    throw Failure.check("Cannot create generated image")
  }
  context.setFillColor(red: CGFloat(seed % 7) / 7, green: 0.25, blue: CGFloat(seed % 11) / 11, alpha: 0.75)
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  guard let image = context.makeImage() else { throw Failure.check("Missing generated pixels") }
  let bytes = NSMutableData()
  guard let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil) else {
    throw Failure.check("Cannot encode generated image")
  }
  CGImageDestinationAddImage(destination, image, [
    kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGAuthor: "PRIVATE_FIXTURE_METADATA"],
  ] as CFDictionary)
  guard CGImageDestinationFinalize(destination) else { throw Failure.check("PNG encoding failed") }
  return bytes as Data
}
final class Errors: @unchecked Sendable {
  private let lock = NSLock()
  private var messages: [String] = []
  func add(_ error: Error) { lock.lock(); defer { lock.unlock() }; messages.append(String(describing: error)) }
  var empty: Bool { lock.lock(); defer { lock.unlock() }; return messages.isEmpty }
  var summary: String { lock.lock(); defer { lock.unlock() }; return messages.joined(separator: "; ") }
}

/// Force an actual writer rename after another store has opened snapshot.json
/// and before its first fstat. No timing assumption or scheduler luck required.
final class ReplaceAfterOpen: @unchecked Sendable {
  private let lock = NSLock()
  private let writer: LokalWidgetStore
  private var replaced = false
  let errors = Errors()
  init(writer: LokalWidgetStore) { self.writer = writer }
  func opened(_ name: String) {
    lock.lock()
    defer { lock.unlock() }
    guard name == "snapshot.json", !replaced else { return }
    replaced = true
    do { try writer.publish(candidate(2, title: "New complete snapshot")) }
    catch { errors.add(error) }
  }
}

// An actual independent process participates in the same writer lock.
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--publish",
   let number = Int(CommandLine.arguments[3]) {
  do {
    let store = try LokalWidgetStore(container: URL(fileURLWithPath: CommandLine.arguments[2]), createIfMissing: true)
    try store.publish(candidate(number))
    exit(0)
  } catch LokalWidgetStoreError.staleRevision { exit(3) }
  catch { exit(1) }
}

do {
  let manager = FileManager.default
  let suite = manager.temporaryDirectory.appendingPathComponent("lokal-widget-store-" + UUID().uuidString, isDirectory: true)
  try manager.createDirectory(at: suite, withIntermediateDirectories: false)
  defer { try? manager.removeItem(at: suite) }
  var checks = 0
  func folder(_ name: String) throws -> URL {
    let root = suite.appendingPathComponent(name, isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: false)
    return root
  }
  func check(_ name: String, _ work: () throws -> Void) throws {
    try work()
    checks += 1
    print("PASS \(name)")
  }
  func owned(_ root: URL) -> URL { root.appendingPathComponent(LokalWidgetStore.directoryName, isDirectory: true) }

  try check("read-only construction never creates missing storage") {
    let root = try folder("missing")
    try rejects({ _ = try LokalWidgetStore(container: root) }, "Reader created a missing store")
    try require(!manager.fileExists(atPath: owned(root).path), "Reader changed the container")
  }
  try check("complete snapshots survive a fresh reader and reject stale revisions") {
    let root = try folder("roundtrip")
    let store = try LokalWidgetStore(container: root, createIfMissing: true)
    try require(try store.readSnapshot() == nil, "Fresh store is not empty")
    try require(try store.publish(candidate(2)) == 2, "Wrong acknowledged revision")
    let reader = try LokalWidgetStore(container: root)
    try require(try revision(reader) == 2, "Fresh reader did not see committed data")
    for number in [0, 1, 2] {
      try rejects({ try store.publish(candidate(number)) }, "Accepted stale/invalid revision")
    }
    try require(try revision(reader) == 2, "Rejected candidate replaced current state")
  }
  try check("separate instances serialize concurrent publishers and atomic readers") {
    let root = try folder("concurrent")
    _ = try LokalWidgetStore(container: root, createIfMissing: true)
    let errors = Errors()
    DispatchQueue.concurrentPerform(iterations: 24) { index in
      do {
        let store = try LokalWidgetStore(container: root)
        do { try store.publish(candidate(index + 1, title: String(repeating: "x", count: 256))) }
        catch LokalWidgetStoreError.staleRevision {}
        if let snapshot = try store.readSnapshot() {
          let title = (snapshot.json["current"] as? [String: Any])?["title"] as? String
          try require(title == String(repeating: "x", count: 256), "Reader observed torn metadata")
        }
      } catch { errors.add(error) }
    }
    try require(errors.empty, "Concurrent publication failed: " + errors.summary)
    try require(try revision(LokalWidgetStore(container: root)) == 24, "Highest revision did not win")
  }
  try check("an atomically replaced snapshot remains readable through its held old descriptor") {
    let root = try folder("read-replaced-inode")
    let writer = try LokalWidgetStore(container: root, createIfMissing: true)
    try writer.publish(candidate(1, title: "Old complete snapshot"))
    let replacement = ReplaceAfterOpen(writer: writer)
    let reader = try LokalWidgetStore(container: root,
        afterReadOpenForTesting: { replacement.opened($0) })
    let old = try reader.readSnapshot()!.json
    try require(replacement.errors.empty, "Controlled replacement failed: " + replacement.errors.summary)
    try require(old["revision"] as? Int == 1, "Held descriptor did not retain old revision")
    try require((old["current"] as? [String: Any])?["title"] as? String == "Old complete snapshot", "Old read was torn")
    let latest = try reader.readSnapshot()!.json
    try require(latest["revision"] as? Int == 2, "Subsequent read missed new revision")
    try require((latest["current"] as? [String: Any])?["title"] as? String == "New complete snapshot", "New read was torn")
  }
  try check("independent native processes honor the same revision lock") {
    let root = try folder("processes")
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let processes = try [11, 8, 13, 9].map { number -> Process in
      let child = Process()
      child.executableURL = executable
      child.arguments = ["--publish", root.path, String(number)]
      try child.run()
      return child
    }
    for child in processes { child.waitUntilExit(); try require([0, 3].contains(child.terminationStatus), "Native child failed") }
    try require(try revision(LokalWidgetStore(container: root)) == 13, "Cross-process revision was overwritten")
  }
  try check("owned directory and metadata symlinks cannot escape the container") {
    let outside = try folder("outside")
    let sentinel = outside.appendingPathComponent("sentinel")
    try Data("unchanged".utf8).write(to: sentinel)
    let linked = try folder("linked")
    try manager.createSymbolicLink(at: owned(linked), withDestinationURL: outside)
    try rejects({ _ = try LokalWidgetStore(container: linked, createIfMissing: true) }, "Followed owned-directory symlink")
    let root = try folder("snapshot-link")
    let store = try LokalWidgetStore(container: root, createIfMissing: true)
    try manager.createSymbolicLink(at: owned(root).appendingPathComponent("snapshot.json"), withDestinationURL: sentinel)
    try rejects({ _ = try store.readSnapshot() }, "Followed snapshot symlink")
    try rejects({ try store.publish(candidate(1)) }, "Replaced a symlink target")
    try require(try String(contentsOf: sentinel, encoding: .utf8) == "unchanged", "Outside data changed")
  }
  try check("held directory descriptors survive replacement of the original path") {
    let root = try folder("descriptor")
    let store = try LokalWidgetStore(container: root, createIfMissing: true)
    try store.publish(candidate(1))
    let moved = suite.appendingPathComponent("moved-descriptor")
    try manager.moveItem(at: root, to: moved)
    let outside = try folder("replacement-outside")
    try manager.createSymbolicLink(at: root, withDestinationURL: outside)
    try store.publish(candidate(2))
    try require(try revision(LokalWidgetStore(container: moved)) == 2, "Write did not stay with the owned descriptor")
    try require(!manager.fileExists(atPath: owned(outside).path), "Write escaped via replaced path")
  }
  try check("FIFO and hard-link metadata are refused without blocking") {
    let root = try folder("fifo")
    let store = try LokalWidgetStore(container: root, createIfMissing: true)
    let path = owned(root).appendingPathComponent("snapshot.json").path
    try require(mkfifo(path, 0o600) == 0, "Cannot create fixture FIFO")
    try rejects({ _ = try store.readSnapshot() }, "Reader opened a FIFO")
    try manager.removeItem(atPath: path)
    let external = root.appendingPathComponent("other.json")
    try Data("{}".utf8).write(to: external)
    try manager.linkItem(at: external, to: URL(fileURLWithPath: path))
    try rejects({ _ = try store.readSnapshot() }, "Reader accepted a multiply linked file")
  }
  try check("oversized, malformed and unknown-schema files fail explicitly") {
    for (index, bytes) in [Data(repeating: 32, count: 65_537), Data("broken".utf8), Data("{\"schemaVersion\":2,\"revision\":99}".utf8)].enumerated() {
      let root = try folder("corrupt-\(index)")
      let store = try LokalWidgetStore(container: root, createIfMissing: true)
      try bytes.write(to: owned(root).appendingPathComponent("snapshot.json"))
      try rejects({ _ = try store.readSnapshot() }, "Accepted invalid stored metadata")
      try rejects({ try store.publish(candidate(100)) }, "Silently overwrote corrupt/future-schema data")
    }
  }
  try check("a real denied write leaves the previous complete snapshot intact") {
    try require(getuid() != 0, "Permission-denial acceptance requires a non-root runner")
    let root = try folder("denied")
    let store = try LokalWidgetStore(container: root, createIfMissing: true)
    try store.publish(candidate(1))
    try require(chmod(owned(root).path, 0o500) == 0, "Cannot restrict fixture directory")
    defer { chmod(owned(root).path, 0o700) }
    try rejects({ try store.publish(candidate(2)) }, "Denied write reported success")
    try require(try revision(store) == 1, "Failed write damaged prior snapshot")
  }
  try check("actual image decoding bounds pixels and strips source metadata") {
    let root = try folder("artwork")
    let store = try LokalWidgetStore(container: root, createIfMissing: true)
    let original = try png(3, width: 1200, height: 800)
    guard let originalSource = CGImageSourceCreateWithData(original as CFData, nil),
          let originalProperties = CGImageSourceCopyPropertiesAtIndex(originalSource, 0, nil) as? [CFString: Any],
          let originalPNG = originalProperties[kCGImagePropertyPNGDictionary] as? [CFString: Any] else {
      throw Failure.check("Generated source metadata is unavailable")
    }
    try require(originalPNG[kCGImagePropertyPNGAuthor] as? String == "PRIVATE_FIXTURE_METADATA", "Fixture does not actually contain private metadata")
    let art = try LokalWidgetStore.prepareArtwork(original)
    try store.publish(candidate(1, art: art.name), artwork: [art])
    let bytes = try store.readArtwork(named: art.name)
    try require(art.name == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() + ".png", "Artwork filename is not its content hash")
    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
      throw Failure.check("Stored artwork cannot decode")
    }
    try require((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 600, "Thumbnail width not bounded")
    try require((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 400, "Aspect ratio changed")
    try require(!String(decoding: bytes, as: UTF8.self).contains("PRIVATE_FIXTURE_METADATA"), "Source metadata leaked")
    try rejects({ _ = try store.readArtwork(named: "../outside.png") }, "Unsafe artwork filename accepted")
  }
  try check("invalid and oversized image inputs never become owned artwork") {
    for data in [Data(), Data("not an image".utf8), Data(repeating: 0, count: LokalWidgetStore.maximumInputImageBytes + 1)] {
      try rejects({ _ = try LokalWidgetStore.prepareArtwork(data) }, "Invalid artwork accepted")
    }
    let overwide = try png(1, width: 12_001, height: 1)
    try rejects({ _ = try LokalWidgetStore.prepareArtwork(overwide) }, "Oversized image dimensions accepted")
  }
  try check("missing/corrupt artwork cannot acknowledge a new snapshot") {
    let root = try folder("bad-art")
    let store = try LokalWidgetStore(container: root, createIfMissing: true)
    try store.publish(candidate(1))
    let art = try LokalWidgetStore.prepareArtwork(png(2))
    try rejects({ try store.publish(candidate(2, art: art.name)) }, "Missing artwork acknowledged")
    try require(try revision(store) == 1, "Missing art replaced current snapshot")
    try store.publish(candidate(2, art: art.name), artwork: [art])
    try Data("corrupt".utf8).write(to: owned(root).appendingPathComponent(art.name))
    try rejects({ _ = try store.readArtwork(named: art.name) }, "Hash mismatch accepted")
    try rejects({ try store.publish(candidate(3, art: art.name)) }, "Corrupt art acknowledged")
    try require(try revision(store) == 2, "Corrupt art replaced current snapshot")
    try store.publish(candidate(3, art: art.name), artwork: [art])
    _ = try store.readArtwork(named: art.name)
  }
  try check("unused/duplicate prepared images are rejected before publication") {
    let root = try folder("unused-art")
    let store = try LokalWidgetStore(container: root, createIfMissing: true)
    let art = try LokalWidgetStore.prepareArtwork(png(5))
    try rejects({ try store.publish(candidate(1), artwork: [art]) }, "Unused prepared asset accepted")
    try rejects({ try store.publish(candidate(1, art: art.name), artwork: [art, art]) }, "Duplicate prepared asset accepted")
    try require(try store.readSnapshot() == nil, "Invalid candidate created a snapshot")
  }
  try check("partial asset staging cannot publish a missing recommendation cover") {
    let root = try folder("partial-assets")
    let store = try LokalWidgetStore(container: root, createIfMissing: true)
    try store.publish(candidate(1))
    let art = try LokalWidgetStore.prepareArtwork(png(2))
    var fields = candidate(2, art: art.name).json
    fields["recommendations"] = [[
      "id": String(repeating: "b", count: 64), "title": "Missing cover",
      "artwork": String(repeating: "c", count: 64) + ".png",
    ]]
    try rejects({ try store.publish(LokalWidgetSnapshot(raw: fields), artwork: [art]) }, "Partial asset set acknowledged")
    try require(try revision(store) == 1, "Partial asset staging changed the current snapshot")
    try store.publish(candidate(2, art: art.name))
    try require(try revision(store) == 2, "Verified staged cover could not be reused")
  }
  try check("artwork symlinks cannot read or overwrite unrelated files") {
    let root = try folder("art-link")
    let store = try LokalWidgetStore(container: root, createIfMissing: true)
    try store.publish(candidate(1))
    let sentinel = root.appendingPathComponent("outside-art")
    try Data("unchanged".utf8).write(to: sentinel)
    let art = try LokalWidgetStore.prepareArtwork(png(1))
    try manager.createSymbolicLink(at: owned(root).appendingPathComponent(art.name), withDestinationURL: sentinel)
    try rejects({ _ = try store.readArtwork(named: art.name) }, "Artwork symlink was followed")
    try rejects({ try store.publish(candidate(2, art: art.name), artwork: [art]) }, "Artwork symlink was overwritten")
    try require(try String(contentsOf: sentinel, encoding: .utf8) == "unchanged", "Artwork escaped its owned directory")
  }
  try check("current/previous/recent assets survive pruning; old unreferenced art does not") {
    let root = try folder("retention")
    let store = try LokalWidgetStore(container: root, createIfMissing: true)
    let images = try (1...4).map { try LokalWidgetStore.prepareArtwork(png($0)) }
    for index in 0..<3 {
      try store.publish(candidate(index + 1, art: images[index].name), artwork: [images[index]])
      try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: owned(root).appendingPathComponent(images[index].name).path)
    }
    let recentData = try png(6)
    let recentName = SHA256.hash(data: recentData).map { String(format: "%02x", $0) }.joined() + ".png"
    try recentData.write(to: owned(root).appendingPathComponent(recentName))
    let unrelated = owned(root).appendingPathComponent("unrelated.txt")
    try Data("keep".utf8).write(to: unrelated)
    try store.publish(candidate(4, art: images[3].name), artwork: [images[3]])
    try require(!manager.fileExists(atPath: owned(root).appendingPathComponent(images[0].name).path), "Old unreferenced cover was not pruned")
    for image in images.dropFirst() { _ = try store.readArtwork(named: image.name) }
    try require(manager.fileExists(atPath: owned(root).appendingPathComponent(recentName).path), "Recent reader grace was not retained")
    try require(manager.fileExists(atPath: unrelated.path), "Unrelated file was deleted")
  }
  try check("a dead writer's orphan temporary is reclaimed under the writer lock") {
    let root = try folder("orphan")
    let store = try LokalWidgetStore(container: root, createIfMissing: true)
    let pending = owned(root).appendingPathComponent("pending-" + UUID().uuidString)
    try Data("unfinished".utf8).write(to: pending)
    try store.publish(candidate(1))
    try require(!manager.fileExists(atPath: pending.path), "Orphan temporary remained")
  }
  try check("cache count limits preserve old data and allow a metadata-only update") {
    let root = try folder("count-limit")
    let store = try LokalWidgetStore(container: root, createIfMissing: true)
    try store.publish(candidate(1))
    for index in 0..<32 {
      let name = String(repeating: "0", count: 62) + String(format: "%02x", index) + ".png"
      try Data([1]).write(to: owned(root).appendingPathComponent(name))
    }
    let art = try LokalWidgetStore.prepareArtwork(png(5))
    try rejects({ try store.publish(candidate(2, art: art.name), artwork: [art]) }, "Cache count overflow acknowledged")
    try require(try revision(store) == 1, "Cache overflow changed metadata")
    try store.publish(candidate(2, title: "Updated without new artwork"))
    try require(try revision(store) == 2, "Full artwork cache blocked metadata-only publication")
  }
  try check("cache byte limits prevent unbounded disk use") {
    let root = try folder("byte-limit")
    let store = try LokalWidgetStore(container: root, createIfMissing: true)
    try store.publish(candidate(1))
    let chunk = Data(repeating: 1, count: LokalWidgetStore.maximumArtworkBytes)
    for index in 0..<8 {
      let name = String(repeating: "0", count: 62) + String(format: "%02x", index) + ".png"
      try chunk.write(to: owned(root).appendingPathComponent(name))
    }
    let art = try LokalWidgetStore.prepareArtwork(png(4))
    try rejects({ try store.publish(candidate(2, art: art.name), artwork: [art]) }, "Cache byte overflow acknowledged")
    try require(try revision(store) == 1, "Byte overflow replaced metadata")
  }
  print("Widget store contracts passed: \(checks) actual filesystem/image/process cases; App Group entitlement/device acceptance remains pending")
} catch {
  FileHandle.standardError.write(Data("Widget store contract failed: \(error)\n".utf8))
  exit(1)
}
