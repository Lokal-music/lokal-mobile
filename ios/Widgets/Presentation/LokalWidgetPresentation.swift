import Foundation

/// Immutable display values may cross the provider completion boundary. The
/// untyped JSON reader and filesystem descriptor stay within the read operation.
struct LokalWidgetTrackPresentation: Sendable, Identifiable {
  let id: String
  let title: String
  let artist: String
  let artwork: String?

  init?(_ row: [String: Any]?) {
    guard let row, let id = row["id"] as? String else { return nil }
    self.id = id
    title = row["title"] as? String ?? ""
    artist = row["artist"] as? String ?? ""
    artwork = row["artwork"] as? String
  }
}

enum LokalWidgetAvailability: Sendable, Equatable {
  case available, empty, stale, unavailable
}

enum LokalWidgetConfiguration: String, CaseIterable, Sendable {
  case nowPlaying, flowRadio, coverFlow
}

struct LokalWidgetPresentation: Sendable {
  let availability: LokalWidgetAvailability
  let current: LokalWidgetTrackPresentation?
  let recommendations: [LokalWidgetTrackPresentation]
  let lastArtwork: String?
  let isPlaying: Bool
  let isBuffering: Bool
  let positionMs: Int
  let durationMs: Int
  let playbackRate: Double
  let accentArgb: Int
  let queueCount: Int
  let flowKind: String
  let flowStatus: String
  let progressInterval: ClosedRange<Date>?

  init(snapshot: LokalWidgetSnapshot?, at date: Date, unavailable: Bool = false) {
    let reader = snapshot ?? LokalWidgetSnapshot(raw: nil)
    let fields = reader.json
    current = LokalWidgetTrackPresentation(fields["current"] as? [String: Any])
    recommendations = (fields["recommendations"] as? [[String: Any]] ?? [])
      .prefix(3).compactMap { LokalWidgetTrackPresentation($0) }
    lastArtwork = fields["lastArtwork"] as? String
    isPlaying = fields["isPlaying"] as? Bool ?? false
    isBuffering = fields["isBuffering"] as? Bool ?? false
    durationMs = fields["durationMs"] as? Int ?? 0
    playbackRate = fields["playbackRate"] as? Double ?? 1
    accentArgb = fields["accentArgb"] as? Int ?? 0
    queueCount = fields["queueCount"] as? Int ?? 0
    flowKind = fields["flowKind"] as? String ?? "none"
    flowStatus = fields["flowStatus"] as? String ?? ""
    let now = Self.milliseconds(date)
    let stale = now.map { reader.isStale(at: $0) } ?? true
    positionMs = now.map { reader.projectedPosition(at: $0) }
      ?? (fields["positionMs"] as? Int ?? 0)
    if unavailable { availability = .unavailable }
    else if current == nil && recommendations.isEmpty { availability = .empty }
    else { availability = stale ? .stale : .available }

    let updated = fields["updatedAtMs"] as? Int ?? 0
    if !unavailable, !stale, isPlaying, !isBuffering, current != nil,
       durationMs > positionMs, let now, updated <= now {
      // Scaling both endpoints preserves the progress fraction at non-1x rates.
      // The label remains static; a wall-clock timer label would misstate audio
      // elapsed time at those rates. No extension timer or polling is created.
      let start = date.addingTimeInterval(-Double(positionMs) / 1000 / playbackRate)
      progressInterval = start...start.addingTimeInterval(Double(durationMs) / 1000 / playbackRate)
    } else { progressInterval = nil }
  }

  /// At most current + three recommendation images, already validated flat
  /// names. The provider applies an additional aggregate byte budget.
  var artworkNames: [String] {
    var seen = Set<String>()
    return ([current?.artwork ?? lastArtwork] + recommendations.map(\.artwork))
      .compactMap { $0 }.filter { seen.insert($0).inserted }
  }

  static func milliseconds(_ date: Date) -> Int? {
    let value = date.timeIntervalSince1970 * 1000
    guard value.isFinite, value >= 1,
          value <= Double(LokalWidgetSnapshot.maximumTimestampMs) else { return nil }
    return Int(value.rounded(.down))
  }
}

struct LokalWidgetTimelinePlan: Sendable {
  let dates: [Date]
  let refreshAfter: Date?

  init(snapshot: LokalWidgetSnapshot?, now: Date) {
    guard let snapshot, let nowMs = LokalWidgetPresentation.milliseconds(now),
          !snapshot.isStale(at: nowMs),
          snapshot.json["current"] is [String: Any],
          snapshot.json["isPlaying"] as? Bool == true,
          snapshot.json["isBuffering"] as? Bool != true else {
      dates = [now]
      refreshAfter = nil
      return
    }
    let fields = snapshot.json
    let updated = fields["updatedAtMs"] as? Int ?? 0
    let duration = fields["durationMs"] as? Int ?? 0
    let position = fields["positionMs"] as? Int ?? 0
    let rate = fields["playbackRate"] as? Double ?? 1
    // Strictly past the reader's inclusive freshness boundary. This scheduled
    // entry freezes progress even if the system defers the requested reread.
    let expiryMs = updated + LokalWidgetSnapshot.staleAfterMs + 1
    let expiry = Date(timeIntervalSince1970: Double(expiryMs) / 1000)
    var candidates = [now, expiry]
    if updated > nowMs {
      candidates.append(Date(timeIntervalSince1970: Double(updated) / 1000))
    }
    if duration > position {
      let end = Date(timeIntervalSince1970: Double(updated) / 1000
        + Double(duration - position) / 1000 / rate)
      if end > now && end < expiry { candidates.append(end) }
    }
    dates = Array(Set(candidates.filter { $0 >= now })).sorted()
    // Request at most one reread per freshness window, only while playing.
    // WidgetKit owns execution/budget; this is not a scheduling guarantee.
    refreshAfter = expiry > now ? expiry : nil
  }
}
