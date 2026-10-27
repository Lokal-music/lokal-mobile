import Foundation
import Darwin
import Dispatch
import CoreGraphics
import ImageIO

enum Failure: Error { case check(String) }
func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw Failure.check(message) }
}
func reject(_ expected: LokalWidgetStoreError, _ work: () throws -> Void) throws {
  do { try work() }
  catch let error as LokalWidgetStoreError {
    try require(error == expected, "Unexpected rejection: \(error)")
    return
  }
  throw Failure.check("Expected \(expected)")
}
let alias = String(repeating: "a", count: 64)
let otherAlias = String(repeating: "b", count: 64)
func document(_ revision: Int, id: String = alias, title: String = "Generated title",
              artwork: String? = nil, recommendations: [[String: Any]] = []) throws -> Data {
  try JSONSerialization.data(withJSONObject: [
    "schemaVersion": 1, "revision": revision, "updatedAtMs": 1_793_059_200_000,
    "current": ["id": id, "title": title, "artist": "Generated artist", "artwork": artwork as Any? ?? NSNull()],
    "isPlaying": false, "positionMs": 500, "durationMs": 12_000,
    "recommendations": recommendations,
  ])
}
func image(_ seed: Int) throws -> Data {
  guard let context = CGContext(data: nil, width: 16, height: 8, bitsPerComponent: 8,
      bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    throw Failure.check("Cannot create pixels")
  }
  context.setFillColor(red: CGFloat(seed % 7) / 7, green: 0.25,
      blue: CGFloat(seed % 11) / 11, alpha: 0.75)
  context.fill(CGRect(x: 0, y: 0, width: 16, height: 8))
  guard let pixels = context.makeImage() else { throw Failure.check("Missing pixels") }
  let data = NSMutableData()
  guard let target = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
    throw Failure.check("Cannot create PNG")
  }
  CGImageDestinationAddImage(target, pixels, nil)
  guard CGImageDestinationFinalize(target) else { throw Failure.check("Cannot encode PNG") }
  return data as Data
}
final class Errors: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  func add(_ error: Error) { lock.lock(); defer { lock.unlock() }; values.append(String(describing: error)) }
  var empty: Bool { lock.lock(); defer { lock.unlock() }; return values.isEmpty }
}

do {
  let manager = FileManager.default
  let root = manager.temporaryDirectory.appendingPathComponent("lokal-widget-publication-" + UUID().uuidString)
  try manager.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? manager.removeItem(at: root) }
  var checks = 0
  func check(_ name: String, _ work: (LokalWidgetStore, LokalWidgetPublisher, URL) throws -> Void) throws {
    let folder = root.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: folder, withIntermediateDirectories: false)
    let store = try LokalWidgetStore(container: folder, createIfMissing: true)
    try work(store, LokalWidgetPublisher(store: store), folder)
    checks += 1
    print("PASS " + name)
  }
  try check("metadata acknowledgements and startup revisions reflect actual commits") { store, publisher, _ in
    try require(try publisher.committedRevision() == 0, "Invented initial revision")
    let ack = try publisher.publish(metadata: document(7))
    try require(ack.revision == 7 && ack.artworkByAlias.isEmpty && !ack.artworkDegraded, "Bad acknowledgement")
    try require(try LokalWidgetPublisher(store: store).committedRevision() == 7, "Restart lost committed revision")
  }
  try check("real artwork is owned, verified and associated with its track alias") { store, publisher, _ in
    let ack = try publisher.publish(metadata: document(1), artworkByAlias: [alias: image(1)])
    guard let name = ack.artworkByAlias[alias] else { throw Failure.check("Missing image acknowledgement") }
    let bytes = try store.readArtwork(named: name)
    try require(CGImageSourceCreateWithData(bytes as CFData, nil) != nil, "Not an actual image")
    let current = try store.readSnapshot()?.json["current"] as? [String: Any]
    try require(current?["artwork"] as? String == name && ack.lastArtwork == name, "Cover not committed")
  }
  try check("duplicate covers across current and recommendations publish one owned asset") { _, publisher, folder in
    let pixels = try image(2)
    let ack = try publisher.publish(metadata: document(1, recommendations: [["id": otherAlias, "title": "Next"]]),
        artworkByAlias: [alias: pixels, otherAlias: pixels])
    try require(ack.artworkByAlias[alias] == ack.artworkByAlias[otherAlias], "Identical covers diverged")
    let entries = try manager.contentsOfDirectory(atPath: folder.appendingPathComponent(LokalWidgetStore.directoryName).path)
    try require(entries.filter { $0.hasSuffix(".png") }.count == 1, "Duplicated cached image")
  }
  try check("invalid new artwork keeps a verified same-track cover and updates metadata") { store, publisher, _ in
    let first = try publisher.publish(metadata: document(1), artworkByAlias: [alias: image(3)])
    let ack = try publisher.publish(metadata: document(2, title: "Updated title"), artworkByAlias: [alias: Data([1, 2, 3])])
    try require(ack.artworkDegraded && ack.artworkByAlias == first.artworkByAlias, "Last-good cover lost")
    let current = try store.readSnapshot()?.json["current"] as? [String: Any]
    try require(current?["title"] as? String == "Updated title", "Artwork blocked title update")
  }
  try check("last-good background is not assigned as a different recording's cover") { store, publisher, _ in
    let first = try publisher.publish(metadata: document(1), artworkByAlias: [alias: image(4)])
    let ack = try publisher.publish(metadata: document(2, id: otherAlias), artworkByAlias: [otherAlias: Data()])
    let current = try store.readSnapshot()?.json["current"] as? [String: Any]
    try require(ack.artworkDegraded && ack.artworkByAlias[otherAlias] == nil, "Wrong recording inherited cover")
    try require(current?["artwork"] is NSNull && ack.lastArtwork == first.lastArtwork, "Last-good separation failed")
  }
  try check("stale writers cannot acknowledge or alter a newer snapshot") { store, publisher, _ in
    _ = try publisher.publish(metadata: document(9))
    try reject(.staleRevision) { _ = try publisher.publish(metadata: document(8), artworkByAlias: [alias: Data()]) }
    try require(try store.readSnapshot()?.json["revision"] as? Int == 9, "Stale metadata committed")
  }
  try check("unreferenced image inputs fail before any snapshot is committed") { _, publisher, _ in
    try reject(.invalidSnapshot) { _ = try publisher.publish(metadata: document(1), artworkByAlias: [otherAlias: image(5)]) }
    try require(try publisher.committedRevision() == 0, "Unreferenced input committed")
  }
  try check("aggregate raw artwork quota is bounded before decoding") { _, publisher, _ in
    try reject(.limitExceeded) {
      _ = try publisher.publish(metadata: document(1), artworkByAlias: [alias: Data(count: LokalWidgetPublisher.maximumTotalInputBytes + 1)])
    }
  }
  try check("oversized batches cannot bypass the current-plus-twelve bound") { _, publisher, _ in
    let batch = Dictionary(uniqueKeysWithValues: (0..<14).map { (String($0), Data()) })
    try reject(.limitExceeded) { _ = try publisher.publish(metadata: document(1), artworkByAlias: batch) }
  }
  try check("unknown schema and malformed documents never overwrite old metadata") { _, publisher, _ in
    _ = try publisher.publish(metadata: document(1))
    let unknown = try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "revision": 2])
    try reject(.invalidSnapshot) { _ = try publisher.publish(metadata: unknown) }
    try reject(.invalidSnapshot) { _ = try publisher.publish(metadata: Data("bad-json".utf8)) }
    try require(try publisher.committedRevision() == 1, "Malformed input overwrote metadata")
  }
  try check("oversized metadata fails without entering the JSON reader") { _, publisher, _ in
    try reject(.limitExceeded) { _ = try publisher.publish(metadata: Data(count: LokalWidgetSnapshot.maximumBytes + 1)) }
  }
  try check("normalization excludes unrelated source URLs and request headers") { store, publisher, _ in
    var raw = try JSONSerialization.jsonObject(with: document(1)) as! [String: Any]
    raw["sourceUrl"] = "https://fixture.invalid/private?token=NEVER_PERSIST"
    raw["headers"] = ["Authorization": "NEVER_PERSIST"]
    _ = try publisher.publish(metadata: JSONSerialization.data(withJSONObject: raw))
    let saved = try JSONSerialization.data(withJSONObject: store.readSnapshot()!.json)
    try require(!String(decoding: saved, as: UTF8.self).contains("NEVER_PERSIST"), "Unknown fields persisted")
  }
  try check("full artwork cache still accepts fresh metadata with its last-good cover") { store, publisher, _ in
    var previous: LokalWidgetPublication?
    for i in 0..<32 {
      previous = try publisher.publish(metadata: document(i + 1), artworkByAlias: [alias: image(i)])
    }
    let ack = try publisher.publish(metadata: document(33, title: "Metadata survived full cache"), artworkByAlias: [alias: image(33)])
    try require(ack.artworkDegraded && ack.artworkByAlias == previous?.artworkByAlias, "Quota fallback lost last-good art")
    let current = try store.readSnapshot()?.json["current"] as? [String: Any]
    try require(current?["title"] as? String == "Metadata survived full cache", "Cache quota froze metadata")
  }
  try check("concurrent publication ends at the highest revision without torn metadata") { store, publisher, _ in
    let failures = Errors()
    DispatchQueue.concurrentPerform(iterations: 12) { index in
      do { _ = try publisher.publish(metadata: document(index + 1, title: "Revision \(index + 1)")) }
      catch LokalWidgetStoreError.staleRevision {}
      catch { failures.add(error) }
    }
    try require(failures.empty, "Unexpected concurrent publication failure")
    let saved = try store.readSnapshot()!.json
    try require(saved["revision"] as? Int == 12, "Newest publication lost")
    try require((saved["current"] as? [String: Any])?["title"] as? String == "Revision 12", "Torn state")
  }
  print("Widget host publication contracts passed: \(checks) actual storage/image/policy cases; app wiring, entitlement and extension acceptance remain pending")
} catch {
  print("Widget host publication contracts failed: \(error)")
  exit(1)
}
