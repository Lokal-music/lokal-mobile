import Foundation

/// Bounded private app protocol. The native side creates revision/phase/task
/// state; Flutter submits only frozen user intent and public source identity.
enum LokalTransferProtocol {
  static let version = 1
  // Persist one explicit copy plan atomically, rather than losing unsent chunks
  // if Flutter is suspended between a sequence of small submissions.
  static let maximumBatch = LokalTransferJournal.maximumJobs
  static let maximumPayloadBytes = LokalTransferJournal.maximumBytes

  struct Control: Decodable, Sendable {
    let id: String
    let revision: Int
  }
  struct Page: Decodable, Sendable {
    let offset: Int
    let limit: Int
  }
  struct Client: Decodable, Sendable {
    let clientID: String
  }

  private static func object<T: Decodable>(_ type: T.Type, _ data: Data,
                                           keys: Set<String>) throws -> T {
    guard !data.isEmpty, data.count <= 8192,
          let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(row.keys).isSubset(of: keys) else { throw LokalTransferError.invalidRecord }
    return try JSONDecoder().decode(type, from: data)
  }

  static func control(_ data: Data) throws -> Control {
    let value = try object(Control.self, data, keys: ["id", "revision"])
    guard LokalTransferTaskBinding(value.id + ":" + String(value.revision)) != nil else {
      throw LokalTransferError.invalidRecord
    }
    return value
  }

  static func page(_ data: Data) throws -> Page {
    let value = try object(Page.self, data, keys: ["offset", "limit"])
    guard value.offset >= 0, value.offset <= LokalTransferJournal.maximumJobs,
          value.limit > 0, value.limit <= 100 else { throw LokalTransferError.invalidRecord }
    return value
  }

  static func client(_ data: Data) throws -> Client {
    let value = try object(Client.self, data, keys: ["clientID"])
    guard UUID(uuidString: value.clientID)?.uuidString.lowercased() == value.clientID else {
      throw LokalTransferError.invalidRecord
    }
    return value
  }

  static func scope(_ data: Data) throws -> LokalTransferScope {
    let value = try object(LokalTransferScope.self, data, keys: ["desktopID", "origin", "pairingID"])
    try value.validate()
    return value
  }

  static func intents(_ data: Data) throws -> [LokalTransferJob] {
    guard !data.isEmpty, data.count <= maximumPayloadBytes,
          let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
          !rows.isEmpty, rows.count <= maximumBatch else { throw LokalTransferError.invalidRecord }
    let allowed: Set<String> = ["id", "identity", "metadata", "createdMs", "expectedBytes", "expectedSHA256"]
    var ids = Set<String>()
    return try rows.map { row in
      guard Set(row.keys).isSubset(of: allowed) else { throw LokalTransferError.invalidRecord }
      var document = row
      document["revision"] = 1
      document["direction"] = "download"
      document["phase"] = "queued"
      document["updatedMs"] = row["createdMs"]
      let job = try LokalTransferJob.decodeDocument(JSONSerialization.data(withJSONObject: document))
      guard job.identity.pairingID != nil, job.identity.localServerID != nil else {
        throw LokalTransferError.invalidRecord
      }
      guard ids.insert(job.id).inserted else { throw LokalTransferError.duplicateJob }
      return job
    }
  }
}
