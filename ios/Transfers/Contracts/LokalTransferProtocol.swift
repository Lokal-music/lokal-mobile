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
  struct ImportWorkPage: Decodable, Sendable {
    let after: String?
    let limit: Int
    let clientID: String
  }
  struct ImportClaim: Decodable, Sendable {
    let id: String
    let revision: Int
    let reconcileOnly: Bool
    let clientID: String
  }
  struct ImportLease: Decodable, Sendable {
    let id: String
    let revision: Int
    let leaseID: String
    let clientID: String
  }
  struct ImportCleanupClaim: Decodable, Sendable {
    let id: String
    let revision: Int
    let clientID: String
  }
  struct ImportOrphanClaim: Decodable, Sendable {
    let id: String
    let revision: Int
    let songID: Int64
    let clientID: String
  }
  struct ImportPublication: Decodable, Sendable {
    let id: String
    let revision: Int
    let leaseID: String
    let clientID: String
    let songID: Int64

    var lease: ImportLease {
      ImportLease(id: id, revision: revision, leaseID: leaseID, clientID: clientID)
    }
  }
  struct ImportCleanupDecision: Decodable, Sendable {
    let id: String
    let revision: Int
    let leaseID, clientID: String
    let songID: Int64
    let mode: LokalTransferImportResolution.Mode
    let isarState: String
    var lease: ImportLease {
      ImportLease(id: id, revision: revision, leaseID: leaseID, clientID: clientID)
    }
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

  static func importClaim(_ data: Data) throws -> ImportClaim {
    let value = try object(ImportClaim.self, data, keys: ["id", "revision", "reconcileOnly", "clientID"])
    guard LokalTransferTaskBinding(value.id + ":" + String(value.revision)) != nil,
          UUID(uuidString: value.clientID)?.uuidString.lowercased() == value.clientID else {
      throw LokalTransferError.invalidRecord
    }
    return value
  }

  static func importCleanupClaim(_ data: Data) throws -> ImportCleanupClaim {
    let value = try object(ImportCleanupClaim.self, data, keys: ["id", "revision", "clientID"])
    guard LokalTransferTaskBinding(value.id + ":" + String(value.revision)) != nil,
          UUID(uuidString: value.clientID)?.uuidString.lowercased() == value.clientID else {
      throw LokalTransferError.invalidRecord
    }
    return value
  }

  static func importWorkPage(_ data: Data) throws -> ImportWorkPage {
    let value = try object(ImportWorkPage.self, data, keys: ["after", "limit", "clientID"])
    guard (1...100).contains(value.limit),
          value.after == nil || LokalTransferTaskBinding(value.after!) != nil,
          UUID(uuidString: value.clientID)?.uuidString.lowercased() == value.clientID else {
      throw LokalTransferError.invalidRecord
    }
    return value
  }

  static func importOrphanClaim(_ data: Data) throws -> ImportOrphanClaim {
    let value = try object(ImportOrphanClaim.self, data, keys: ["id", "revision", "songID", "clientID"])
    guard LokalTransferTaskBinding(value.id + ":" + String(value.revision)) != nil,
          value.songID > 0, value.songID < Int64.max,
          UUID(uuidString: value.clientID)?.uuidString.lowercased() == value.clientID else {
      throw LokalTransferError.invalidRecord
    }
    return value
  }

  static func importLease(_ data: Data) throws -> ImportLease {
    let value = try object(ImportLease.self, data, keys: ["id", "revision", "leaseID", "clientID"])
    try validateImportLease(value)
    return value
  }

  private static func validateImportLease(_ value: ImportLease) throws {
    guard LokalTransferTaskBinding(value.id + ":" + String(value.revision)) != nil,
          UUID(uuidString: value.leaseID)?.uuidString.lowercased() == value.leaseID,
          UUID(uuidString: value.clientID)?.uuidString.lowercased() == value.clientID else {
      throw LokalTransferError.invalidRecord
    }
  }

  static func importPublication(_ data: Data) throws -> ImportPublication {
    let value = try object(ImportPublication.self, data,
      keys: ["id", "revision", "leaseID", "clientID", "songID"])
    try validateImportLease(value.lease)
    guard value.songID > 0 else { throw LokalTransferError.invalidRecord }
    return value
  }

  static func importCleanupDecision(_ data: Data, finalized: Bool = false) throws -> ImportCleanupDecision {
    let value = try object(ImportCleanupDecision.self, data,
      keys: ["id", "revision", "leaseID", "clientID", "songID", "mode", "isarState"])
    try validateImportLease(value.lease)
    guard value.songID > 0,
          value.isarState == (value.mode == .abandoned ? (finalized ? "retired" : "retiring") : "committed") else {
      throw LokalTransferError.invalidRecord
    }
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

  /// The app submits consent under one current root client. Array-only plans
  /// are no longer accepted at the bridge; native contracts may use intents().
  static func submission(_ data: Data) throws -> (clientID: String, jobs: [LokalTransferJob]) {
    guard !data.isEmpty, data.count <= maximumPayloadBytes,
          let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(row.keys) == ["clientID", "intents"],
          let clientID = row["clientID"] as? String,
          UUID(uuidString: clientID)?.uuidString.lowercased() == clientID,
          let rows = row["intents"] as? [[String: Any]] else { throw LokalTransferError.invalidRecord }
    return (clientID, try intents(JSONSerialization.data(withJSONObject: rows)))
  }
}
