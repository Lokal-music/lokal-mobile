import Foundation
import CoreGraphics
import ImageIO

enum PresentationFailure: Error { case failed(String) }
func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw PresentationFailure.failed(message) }
}
let nowMs = 1_793_102_400_000
let now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
let alias = String(repeating: "a", count: 64)
let image = String(repeating: "b", count: 64) + ".png"
func snapshot(_ overrides: [String: Any] = [:]) -> LokalWidgetSnapshot {
  var raw: [String: Any] = [
    "schemaVersion": 1, "revision": 4, "updatedAtMs": nowMs,
    "current": ["id": alias, "title": "Current", "artist": "Artist", "artwork": image],
    "isPlaying": true, "positionMs": 1000, "durationMs": 10000, "playbackRate": 1.0,
  ]
  raw.merge(overrides) { _, new in new }
  return LokalWidgetSnapshot(raw: raw)
}
var checks = 0
@MainActor func check(_ name: String, _ run: () throws -> Void) throws {
  try run()
  checks += 1
  print("PASS: \(name)")
}

func generatedImage(width: Int, type: String = "public.png") throws -> Data {
  guard let context = CGContext(data: nil, width: width, height: 8,
      bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        let image = context.makeImage() else {
    throw PresentationFailure.failed("Cannot create display fixture")
  }
  let output = NSMutableData()
  guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else {
    throw PresentationFailure.failed("Cannot create image encoder")
  }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else {
    throw PresentationFailure.failed("Cannot encode display fixture")
  }
  return output as Data
}

do {
  try check("all shared malformed/legacy/clock cases retain reader projection") {
    guard CommandLine.arguments.count == 2 else {
      throw PresentationFailure.failed("Pass the shared corpus path")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let corpus = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let rows = corpus?["cases"] as? [[String: Any]] ?? []
    try require(rows.count >= 48, "Missing shared cases")
    for row in rows {
      let document: Data
      if let text = row["document"] as? String { document = Data(text.utf8) }
      else { document = try JSONSerialization.data(withJSONObject: row["input"] ?? NSNull(), options: [.fragmentsAllowed]) }
      let reader = LokalWidgetSnapshot(document: document)
      let sourceMs = row["nowMs"] as? Int ?? 0
      let date = Date(timeIntervalSince1970: Double(sourceMs) / 1000)
      let model = LokalWidgetPresentation(snapshot: reader, at: date)
      if let representedMs = LokalWidgetPresentation.milliseconds(date) {
        try require(model.positionMs == reader.projectedPosition(at: representedMs), "Projection differs: \(row["name"] ?? "")")
      } else {
        try require(model.progressInterval == nil, "Invalid date starts progress")
      }
      try require(model.artworkNames.count <= 4, "Unbounded displayed art")
      let plan = LokalWidgetTimelinePlan(snapshot: reader, now: date)
      try require(!plan.dates.isEmpty && plan.dates.count <= 4, "Unbounded/empty timeline")
      try require(plan.dates == Array(Set(plan.dates)).sorted(), "Duplicate/unsorted timeline")
    }
  }
  try check("2x progress uses a scaled five-second interval") {
    let model = LokalWidgetPresentation(snapshot: snapshot(["playbackRate": 2.0]), at: now)
    let interval = model.progressInterval
    try require(interval != nil, "Missing active progress")
    try require(abs(interval!.upperBound.timeIntervalSince(interval!.lowerBound) - 5) < 0.001, "Incorrect scaled duration")
    try require(abs(now.timeIntervalSince(interval!.lowerBound) - 0.5) < 0.001, "Incorrect scaled position")
  }
  try check("slow progress retains the normalized fraction") {
    let model = LokalWidgetPresentation(snapshot: snapshot(["playbackRate": 0.5]), at: now)
    let interval = model.progressInterval!
    try require(abs(interval.upperBound.timeIntervalSince(interval.lowerBound) - 20) < 0.001, "Incorrect slow duration")
  }
  for (name, overrides) in [
    ("paused", ["isPlaying": false] as [String: Any]),
    ("buffering", ["isBuffering": true] as [String: Any]),
    ("stale", ["updatedAtMs": nowMs - LokalWidgetSnapshot.staleAfterMs - 1] as [String: Any]),
    ("future skew", ["updatedAtMs": nowMs + LokalWidgetSnapshot.futureToleranceMs + 1] as [String: Any]),
  ] {
    try check("\(name) cannot animate or request recurring refresh") {
      let reader = snapshot(overrides)
      let model = LokalWidgetPresentation(snapshot: reader, at: now)
      let plan = LokalWidgetTimelinePlan(snapshot: reader, now: now)
      try require(model.progressInterval == nil, "Unexpected progress animation")
      try require(plan.dates == [now] && plan.refreshAfter == nil, "Unexpected reread")
    }
  }
  try check("unknown duration has no fake progress") {
    let model = LokalWidgetPresentation(snapshot: snapshot(["durationMs": 0]), at: now)
    try require(model.progressInterval == nil && model.durationMs == 0, "Invented duration")
  }
  try check("end-of-recording entry stops the system progress interval") {
    let reader = snapshot()
    let plan = LokalWidgetTimelinePlan(snapshot: reader, now: now)
    let end = now.addingTimeInterval(9)
    try require(plan.dates.contains(end), "Missing end entry")
    try require(LokalWidgetPresentation(snapshot: reader, at: end).progressInterval == nil, "Completed bar keeps advancing")
  }
  try check("freshness-expiry entry freezes progress before a deferred reread") {
    let reader = snapshot(["durationMs": 3_600_000])
    let plan = LokalWidgetTimelinePlan(snapshot: reader, now: now)
    let expiry = plan.dates.last!
    let model = LokalWidgetPresentation(snapshot: reader, at: expiry)
    try require(model.availability == .stale && model.progressInterval == nil, "Expiry did not freeze")
    try require(plan.refreshAfter == expiry, "Reread not bounded to freshness window")
    try require(expiry.timeIntervalSince(now) >= 900, "Excessive refresh requests")
  }
  try check("valid future source time remains frozen until its timestamp") {
    let reader = snapshot(["updatedAtMs": nowMs + 60_000])
    let plan = LokalWidgetTimelinePlan(snapshot: reader, now: now)
    let start = now.addingTimeInterval(60)
    try require(plan.dates.contains(start), "Missing future start")
    try require(LokalWidgetPresentation(snapshot: reader, at: now).progressInterval == nil, "Future source already advances")
    try require(LokalWidgetPresentation(snapshot: reader, at: start).progressInterval != nil, "Future source never starts")
  }
  try check("unavailable and empty are explicit display states") {
    let empty = LokalWidgetPresentation(snapshot: nil, at: now)
    let unavailable = LokalWidgetPresentation(snapshot: snapshot(), at: now, unavailable: true)
    try require(empty.availability == .empty, "Empty confused with unavailable")
    try require(unavailable.availability == .unavailable && unavailable.progressInterval == nil, "Unavailable starts progress")
  }
  try check("current plus three normalized recommendations bound art reads") {
    let recs = (0..<12).map { n in
      ["id": String(repeating: String(n, radix: 16), count: 64), "title": "R\(n)",
       "artwork": String(repeating: String(n, radix: 16), count: 64) + ".png"]
    }
    let model = LokalWidgetPresentation(snapshot: snapshot(["recommendations": recs]), at: now)
    try require(model.recommendations.count == 3 && model.artworkNames.count == 4, "Unbounded native recommendation views")
    let duplicate = LokalWidgetPresentation(snapshot: snapshot(["recommendations": [
      ["id": String(repeating: "c", count: 64), "artwork": image],
    ]]), at: now)
    try require(duplicate.artworkNames == [image], "Repeated art read twice")
  }
  try check("no synthetic recommendation or Flow ownership is inferred") {
    let model = LokalWidgetPresentation(snapshot: snapshot(["queueCount": 12]), at: now)
    try require(model.recommendations.isEmpty && model.flowKind == "none", "Queue mislabeled as recommendations")
  }
  try check("invalid dates cannot trap native conversion or animate") {
    for interval in [Double.infinity, -Double.infinity, Double.nan, -1, Double.greatestFiniteMagnitude] {
      let date = Date(timeIntervalSince1970: interval)
      try require(LokalWidgetPresentation.milliseconds(date) == nil, "Invalid date accepted")
      try require(LokalWidgetPresentation(snapshot: snapshot(), at: date).progressInterval == nil, "Invalid date animates")
    }
  }
  try check("upper timestamp boundary schedules a stale entry without overflow") {
    let last = LokalWidgetSnapshot.maximumTimestampMs
    let date = Date(timeIntervalSince1970: Double(last) / 1000)
    let reader = snapshot(["updatedAtMs": last, "durationMs": 3_600_000])
    let plan = LokalWidgetTimelinePlan(snapshot: reader, now: date)
    let expired = LokalWidgetPresentation(snapshot: reader, at: plan.dates.last!)
    try require(expired.availability == .stale && expired.progressInterval == nil, "Upper-bound freshness never expires")
  }
  try check("actual display images accept only canonical bounded dimensions") {
    try require(LokalWidgetDisplayArtwork.validate(try generatedImage(width: 600)), "Canonical image rejected")
    try require(!LokalWidgetDisplayArtwork.validate(try generatedImage(width: 601)), "Oversized decoded surface accepted")
    try require(!LokalWidgetDisplayArtwork.validate(try generatedImage(width: 16, type: "com.compuserve.gif")), "Noncanonical type accepted")
  }
  try check("truncated, empty and oversized compressed display images fail independently") {
    let valid = try generatedImage(width: 16)
    try require(!LokalWidgetDisplayArtwork.validate(Data()), "Empty image accepted")
    try require(!LokalWidgetDisplayArtwork.validate(Data(valid.prefix(20))), "Truncated image accepted")
    try require(!LokalWidgetDisplayArtwork.validate(Data(repeating: 0, count: LokalWidgetStore.maximumArtworkBytes + 1)), "Compressed byte budget ignored")
  }
  print("PASS: \(checks) widget presentation/timeline cases plus shared corpus")
} catch {
  fatalError("Widget presentation contract failed: \(error)")
}
