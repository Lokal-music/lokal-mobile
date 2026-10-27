import Foundation

enum ContractFailure: Error { case failed(String) }

func require(_ condition: Bool, _ reason: String) throws {
  if !condition { throw ContractFailure.failed(reason) }
}

do {
  guard CommandLine.arguments.count == 2 else {
    throw ContractFailure.failed("Pass the synthetic cross-language corpus path")
  }
  let corpusData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
  guard let corpus = try JSONSerialization.jsonObject(with: corpusData) as? [String: Any],
        let cases = corpus["cases"] as? [[String: Any]], !cases.isEmpty else {
    throw ContractFailure.failed("Invalid synthetic corpus")
  }
  for row in cases {
    let name = row["name"] as? String ?? "unnamed"
    let document: Data
    if let raw = row["document"] as? String {
      document = Data(raw.utf8)
    } else {
      document = try JSONSerialization.data(withJSONObject: row["input"] ?? NSNull(), options: [.fragmentsAllowed])
    }
    guard let expected = row["expected"] as? [String: Any],
          let now = row["nowMs"] as? Int,
          let projected = row["projectedPositionMs"] as? Int,
          let stale = row["stale"] as? Bool else {
      throw ContractFailure.failed("Missing expected fields: \(name)")
    }
    let snapshot = LokalWidgetSnapshot(document: document)
    try require(NSDictionary(dictionary: snapshot.json) == NSDictionary(dictionary: expected), "Normalized fields: \(name)")
    try require(snapshot.isStale(at: now) == stale, "Staleness: \(name)")
    try require(snapshot.projectedPosition(at: now) == projected, "Raw progress: \(name)")
    let encoded = try JSONSerialization.data(withJSONObject: snapshot.json, options: [.sortedKeys])
    try require(encoded.count <= LokalWidgetSnapshot.maximumBytes, "Wire budget: \(name)")
    let decoded = LokalWidgetSnapshot(document: encoded)
    try require(NSDictionary(dictionary: decoded.json) == NSDictionary(dictionary: snapshot.json), "Round-trip: \(name)")
    try require(snapshot.isStale(at: Int.min) && snapshot.isStale(at: Int.max), "Extreme clock range: \(name)")
  }

  for invalid in [Double.nan, Double.infinity, -Double.infinity, Double.greatestFiniteMagnitude] {
    let snapshot = LokalWidgetSnapshot(raw: [
      "schemaVersion": 1, "updatedAtMs": invalid, "accentArgb": invalid,
      "positionMs": invalid, "queueCount": invalid, "playbackRate": invalid,
    ])
    try require(snapshot.json["accentArgb"] as? Int == 0, "Invalid color conversion")
    try require(snapshot.json["queueCount"] as? Int == 0, "Invalid count conversion")
    try require(snapshot.json["updatedAtMs"] as? Int == 0, "Invalid timestamp conversion")
    try require(snapshot.json["playbackRate"] as? Double == 1, "Invalid rate conversion")
  }
  print("Widget snapshot Swift contracts passed: \(cases.count) shared cases plus native range guards; no extension/install acceptance claim")
} catch {
  FileHandle.standardError.write(Data("Widget snapshot contract failed: \(error)\n".utf8))
  exit(1)
}
