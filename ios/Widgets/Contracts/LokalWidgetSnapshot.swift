import Foundation
import CoreFoundation

/// Metadata reader shared by the future optional WidgetKit target. No network,
/// player, App Group entitlement or extension is enabled by this contract.
struct LokalWidgetSnapshot {
  static let maximumBytes = 65_536
  static let maximumMediaMs = 604_800_000
  static let maximumTimestampMs = 4_102_444_800_000
  static let staleAfterMs = 15 * 60 * 1000
  static let futureToleranceMs = 5 * 60 * 1000

  private let fields: [String: Any]

  init(document: Data) {
    if document.count <= Self.maximumBytes,
       Self.boundedNesting(document),
       let raw = try? JSONSerialization.jsonObject(with: document) {
      self.init(raw: raw)
    } else {
      self.init(raw: nil)
    }
  }

  init(raw: Any?) {
    let input = raw as? [String: Any] ?? [:]
    let data = Self.integer(input["schemaVersion"], minimum: 1, maximum: 1) == 1 ? input : [:]
    let current = Self.track(data["current"])
    var recommendations: [[String: Any]] = []
    var seen = Set<String>()
    if let rows = data["recommendations"] as? [Any] {
      for raw in rows.prefix(48) {
        if let row = Self.track(raw), let id = row["id"] as? String,
           seen.insert(id).inserted {
          recommendations.append(row)
          if recommendations.count == 12 { break }
        }
      }
    }
    let duration = current == nil ? 0 : Self.integer(data["durationMs"], minimum: 0, maximum: Self.maximumMediaMs) ?? 0
    let position = current == nil ? 0 : Self.integer(data["positionMs"], minimum: 0, maximum: Self.maximumMediaMs) ?? 0
    let rawColor = Self.integer(data["accentArgb"], minimum: -2_147_483_648, maximum: 4_294_967_295) ?? 0
    // Validate before conversion. NSNumber may contain legacy wide integers or
    // doubles; unchecked Int32/UInt32 initializers can trap in an extension.
    let color = rawColor > Int(Int32.max) ? rawColor - 4_294_967_296 : rawColor
    let rawRate = Self.number(data["playbackRate"])
    let rate = rawRate.flatMap { $0 >= 0.25 && $0 <= 4 ? $0 : nil } ?? 1.0
    let kind = data["flowKind"] as? String
    let lastArtwork = Self.artwork(current?["artwork"]) ?? Self.artwork(data["lastArtwork"])
    fields = [
      "schemaVersion": 1,
      "revision": Self.integer(data["revision"], minimum: 0, maximum: 9_007_199_254_740_991) ?? 0,
      "updatedAtMs": Self.integer(data["updatedAtMs"], minimum: 1, maximum: Self.maximumTimestampMs) ?? 0,
      "current": current as Any? ?? NSNull(),
      "lastArtwork": lastArtwork as Any? ?? NSNull(),
      "isPlaying": current != nil && Self.boolean(data["isPlaying"]),
      "positionMs": duration > 0 ? min(position, duration) : position,
      "durationMs": duration,
      "playbackRate": rate,
      "queueCount": Self.integer(data["queueCount"], minimum: 0, maximum: 1_000_000) ?? 0,
      "accentArgb": color,
      "flowKind": kind == "flow" || kind == "radio" ? kind! : "none",
      "flowStatus": Self.text(data["flowStatus"]),
      "recommendations": recommendations,
    ]
  }

  var json: [String: Any] { fields }

  func isStale(at nowMs: Int) -> Bool {
    let updated = fields["updatedAtMs"] as? Int ?? 0
    // Check range before subtraction so Int.min/max input cannot overflow.
    if updated == 0 || nowMs < 1 || nowMs > Self.maximumTimestampMs { return true }
    return updated - nowMs > Self.futureToleranceMs || nowMs - updated > Self.staleAfterMs
  }

  func projectedPosition(at nowMs: Int) -> Int {
    let position = fields["positionMs"] as? Int ?? 0
    let duration = fields["durationMs"] as? Int ?? 0
    guard duration > 0, fields["isPlaying"] as? Bool == true, !isStale(at: nowMs) else { return position }
    let updated = fields["updatedAtMs"] as? Int ?? 0
    let elapsed = min(max(nowMs - updated, 0), Self.staleAfterMs)
    let rate = fields["playbackRate"] as? Double ?? 1.0
    return min(position + Int((Double(elapsed) * rate).rounded(.down)), duration)
  }

  private static func boolean(_ raw: Any?) -> Bool {
    guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
    return value.boolValue
  }

  private static func number(_ raw: Any?) -> Double? {
    guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
    let result = value.doubleValue
    return result.isFinite ? result : nil
  }

  private static func integer(_ raw: Any?, minimum: Int, maximum: Int) -> Int? {
    guard let value = number(raw), value >= Double(minimum), value <= Double(maximum),
          value.rounded(.towardZero) == value else { return nil }
    return Int(value)
  }

  private static func track(_ raw: Any?) -> [String: Any]? {
    guard let data = raw as? [String: Any], let id = data["id"] as? String,
          id.utf8.count == 64, id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return nil }
    return [
      "id": id, "title": text(data["title"]), "artist": text(data["artist"]),
      "album": text(data["album"]), "artwork": artwork(data["artwork"]) as Any? ?? NSNull(),
    ]
  }

  private static func artwork(_ raw: Any?) -> String? {
    guard let value = raw as? String, value.utf8.count == 68,
          value.range(of: "^[a-f0-9]{64}\\.(jpg|png)$", options: .regularExpression) != nil else { return nil }
    return value
  }

  private static func text(_ raw: Any?) -> String {
    guard let raw = raw as? String else { return "" }
    var result = String.UnicodeScalarView()
    var bytes = 0
    for scalar in raw.unicodeScalars.prefix(1024) {
      let value = scalar.value
      if value < 32 || value == 127 || (value >= 0xD800 && value <= 0xDFFF) { continue }
      let width = value <= 0x7F ? 1 : value <= 0x7FF ? 2 : value <= 0xFFFF ? 3 : 4
      if result.count == 256 || bytes + width > 1024 { break }
      result.append(scalar)
      bytes += width
    }
    return String(result).trimmingCharacters(in: CharacterSet(charactersIn: " "))
  }

  private static func boundedNesting(_ data: Data) -> Bool {
    var depth = 0
    var inString = false
    var escaped = false
    for byte in data {
      if inString {
        if escaped { escaped = false }
        else if byte == 92 { escaped = true }
        else if byte == 34 { inString = false }
      } else if byte == 34 { inString = true }
      else if byte == 91 || byte == 123 {
        depth += 1
        if depth > 8 { return false }
      } else if byte == 93 || byte == 125 {
        depth -= 1
        if depth < 0 { return false }
      }
    }
    return !inString && depth == 0
  }
}
