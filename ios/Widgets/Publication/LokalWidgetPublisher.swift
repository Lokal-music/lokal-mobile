import Foundation

struct LokalWidgetPublication: Sendable {
  let revision: Int
  let artworkByAlias: [String: String]
  let lastArtwork: String?
  let artworkDegraded: Bool
}

/// Host-side publication policy. Call on a utility queue: image preparation and
/// durable file I/O never belong on the main/UI queue. The optional App Group
/// is resolved by the host adapter; no container or player is invented here.
final class LokalWidgetPublisher: @unchecked Sendable {
  static let maximumArtworkInputs = 13 // current + twelve recommendations
  static let maximumTotalInputBytes = 12 * 1024 * 1024
  private let store: LokalWidgetStore
  private let mutex = NSLock()

  init(store: LokalWidgetStore) { self.store = store }

  func committedRevision() throws -> Int {
    mutex.lock()
    defer { mutex.unlock() }
    return try store.readSnapshot()?.json["revision"] as? Int ?? 0
  }

  func publish(metadata: Data, artworkByAlias input: [String: Data] = [:]) throws -> LokalWidgetPublication {
    mutex.lock()
    defer { mutex.unlock() }
    guard metadata.count <= LokalWidgetSnapshot.maximumBytes,
          input.count <= Self.maximumArtworkInputs else {
      throw LokalWidgetStoreError.limitExceeded
    }
    let candidate = LokalWidgetSnapshot(document: metadata)
    let fields = candidate.json
    let revision = fields["revision"] as? Int ?? 0
    guard revision > 0, fields["updatedAtMs"] as? Int ?? 0 > 0 else {
      throw LokalWidgetStoreError.invalidSnapshot
    }
    let previous = try store.readSnapshot()
    let priorRevision = previous?.json["revision"] as? Int ?? 0
    guard revision > priorRevision else {
      throw LokalWidgetStoreError.staleRevision
    }
    let rows = Self.rows(candidate)
    let aliases = Set(rows.compactMap { $0["id"] as? String })
    guard input.keys.allSatisfy({ aliases.contains($0) }) else {
      throw LokalWidgetStoreError.invalidSnapshot
    }
    var total = 0
    for data in input.values {
      guard data.count <= Self.maximumTotalInputBytes,
            total <= Self.maximumTotalInputBytes - data.count else {
        throw LokalWidgetStoreError.limitExceeded
      }
      total += data.count
    }

    var degraded = false
    for row in rows {
      if let name = row["artwork"] as? String,
         (try? store.readArtwork(named: name)) == nil {
        degraded = true
      }
    }
    // A valid owned cover can be reused only for that same opaque track alias.
    // Last-good background art is retained separately, never assigned as the
    // new recording's cover merely because its image failed to load.
    var reusable: [String: String] = [:]
    for row in Self.rows(previous) + rows {
      if let alias = row["id"] as? String, let name = row["artwork"] as? String,
         (try? store.readArtwork(named: name)) != nil {
        reusable[alias] = name
      }
    }
    var selected = reusable.filter { aliases.contains($0.key) }
    var preparedByName: [String: LokalWidgetArtwork] = [:]
    for alias in input.keys.sorted() {
      do {
        let image = try LokalWidgetStore.prepareArtwork(input[alias]!)
        selected[alias] = image.name
        preparedByName[image.name] = image
      } catch LokalWidgetStoreError.invalidImage {
        degraded = true
      } catch LokalWidgetStoreError.limitExceeded {
        degraded = true
      }
    }

    let previousLast = previous?.json["lastArtwork"] as? String
    let requestedLast = fields["lastArtwork"] as? String
    let last = [requestedLast, previousLast].compactMap { $0 }.first {
      (try? store.readArtwork(named: $0)) != nil
    }
    func snapshot(_ names: [String: String]) -> LokalWidgetSnapshot {
      var value = fields
      if var current = fields["current"] as? [String: Any], let id = current["id"] as? String {
        current["artwork"] = names[id] as Any? ?? NSNull()
        value["current"] = current
        value["lastArtwork"] = names[id] as Any? ?? last as Any? ?? NSNull()
      } else {
        value["lastArtwork"] = last as Any? ?? NSNull()
      }
      value["recommendations"] = (fields["recommendations"] as? [[String: Any]] ?? []).map { row in
        var updated = row
        updated["artwork"] = (row["id"] as? String).flatMap { names[$0] } as Any? ?? NSNull()
        return updated
      }
      return LokalWidgetSnapshot(raw: value)
    }

    var committed = snapshot(selected)
    // Two aliases may share one content-addressed cover. The store receives
    // one prepared image per filename, and only actually referenced files.
    let referenced = Set(selected.values)
    let prepared = preparedByName.values.filter { referenced.contains($0.name) }
    do {
      try store.publish(committed, artwork: Array(prepared))
    } catch LokalWidgetStoreError.limitExceeded {
      // Quota exhaustion must not freeze title, pause state or seek position.
      // Keep verified old assets, and commit metadata without any new image.
      degraded = true
      selected = reusable.filter { aliases.contains($0.key) }
      committed = snapshot(selected)
      try store.publish(committed)
    }
    return LokalWidgetPublication(
      revision: revision,
      artworkByAlias: selected,
      lastArtwork: committed.json["lastArtwork"] as? String,
      artworkDegraded: degraded
    )
  }

  private static func rows(_ snapshot: LokalWidgetSnapshot?) -> [[String: Any]] {
    guard let fields = snapshot?.json else { return [] }
    var result = fields["recommendations"] as? [[String: Any]] ?? []
    if let current = fields["current"] as? [String: Any] { result.insert(current, at: 0) }
    return result
  }
}
