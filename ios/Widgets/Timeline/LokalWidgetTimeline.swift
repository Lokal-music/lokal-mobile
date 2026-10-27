import Foundation
import WidgetKit

struct LokalWidgetEntry: TimelineEntry, Sendable {
  let date: Date
  let model: LokalWidgetPresentation
  let artwork: [String: Data]
}

/// Read-only filesystem boundary. Nothing here creates storage, publishes,
/// fetches an image, starts a player, or writes an action.
enum LokalWidgetEntryReader {
  static let maximumDisplayArtworkBytes = 8 * 1024 * 1024

  static func read(now: Date, groupIdentifier: String?) -> ([LokalWidgetEntry], Date?) {
    guard let groupIdentifier, groupIdentifier.utf8.count <= 255,
          groupIdentifier.range(of: "^group\\.[A-Za-z0-9][A-Za-z0-9.-]+$",
                                options: .regularExpression) != nil else {
      return unavailable(now)
    }
    do {
      let store = try LokalWidgetStore.provisioned(groupIdentifier: groupIdentifier)
      let snapshot = try store.readSnapshot()
      let plan = LokalWidgetTimelinePlan(snapshot: snapshot, now: now)
      let model = LokalWidgetPresentation(snapshot: snapshot, at: now)
      var images: [String: Data] = [:]
      var used = 0
      for name in model.artworkNames {
        guard let data = try? store.readArtwork(named: name),
              data.count <= maximumDisplayArtworkBytes - used,
              LokalWidgetDisplayArtwork.validate(data) else { continue }
        used += data.count
        images[name] = data
      }
      return (plan.dates.map {
        LokalWidgetEntry(date: $0, model: LokalWidgetPresentation(snapshot: snapshot, at: $0), artwork: images)
      }, plan.refreshAfter)
    } catch {
      return unavailable(now)
    }
  }

  private static func unavailable(_ now: Date) -> ([LokalWidgetEntry], Date?) {
    ([LokalWidgetEntry(date: now,
      model: LokalWidgetPresentation(snapshot: nil, at: now, unavailable: true), artwork: [:])], nil)
  }
}

struct LokalWidgetTimelineProvider: TimelineProvider {
  func placeholder(in context: Context) -> LokalWidgetEntry {
    let now = Date()
    return LokalWidgetEntry(date: now, model: LokalWidgetPresentation(snapshot: nil, at: now), artwork: [:])
  }

  func getSnapshot(in context: Context, completion: @escaping (LokalWidgetEntry) -> Void) {
    let now = Date()
    let result = LokalWidgetEntryReader.read(now: now, groupIdentifier: configuredGroup)
    completion(result.0[0])
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<LokalWidgetEntry>) -> Void) {
    let result = LokalWidgetEntryReader.read(now: Date(), groupIdentifier: configuredGroup)
    completion(Timeline(entries: result.0, policy: result.1.map { .after($0) } ?? .never))
  }

  private var configuredGroup: String? {
    Bundle.main.object(forInfoDictionaryKey: "LokalWidgetAppGroup") as? String
  }
}
