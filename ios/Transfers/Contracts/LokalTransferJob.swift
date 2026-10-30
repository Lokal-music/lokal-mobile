import Foundation

enum LokalTransferError: Error, Equatable {
  case invalidRecord
  case invalidTransition
  case staleRevision
  case missingJob
  case duplicateJob
  case unsupportedSchema
  case unsafeFile
  case limitExceeded
  case checksumMismatch
  case posix(String, Int32)
  case database(Int32)
}

enum LokalTransferDirection: String, Codable, Sendable {
  case download, upload
}

enum LokalTransferFailure: String, Codable, Sendable {
  case network, unauthorized, invalidResponse, checksum, storage, pairingChanged
}

struct LokalTransferScope: Codable, Hashable, Sendable {
  let desktopID: String
  let origin: String
  let pairingID: String?
  init(desktopID: String, origin: String, pairingID: String? = nil) {
    self.desktopID = desktopID; self.origin = origin; self.pairingID = pairingID
  }
  func validate() throws {
    try LokalTransferIdentity(desktopID: desktopID, sourceID: "scope", localSongID: nil,
      origin: origin, pairingID: pairingID).validate()
  }
}

struct LokalTransferPause: Codable, Equatable, Sendable {
  let scope: LokalTransferScope
  let reason: LokalTransferFailure
}

struct LokalTransferPairing: Codable, Sendable {
  let scope: LokalTransferScope
  let desktopUserID: String?
}

enum LokalTransferPhase: String, Codable, Sendable {
  case queued, waiting, transferring, received, downloaded, staged, validating, importing
  case complete, interrupted, cancelled, failed

  var isTerminal: Bool { self == .complete || self == .cancelled || self == .failed }
}

/// Deliberately contains no token, signed URL, headers or arbitrary payload map.
struct LokalTransferIdentity: Codable, Equatable, Sendable {
  let desktopID: String
  let sourceID: String
  let localSongID: String?
  let origin: String
  /// Public random grant identity, never a token or token hash. Re-pairing
  /// cannot authorize queued intent from an earlier pairing to the same PC.
  let pairingID: String?
  let desktopUserID: String?
  let localServerID: Int?

  init(desktopID: String, sourceID: String, localSongID: String?, origin: String,
       pairingID: String? = nil, desktopUserID: String? = nil, localServerID: Int? = nil) {
    self.desktopID = desktopID; self.sourceID = sourceID; self.localSongID = localSongID
    self.origin = origin; self.pairingID = pairingID
    self.desktopUserID = desktopUserID; self.localServerID = localServerID
  }

  func validate() throws {
    guard localServerID == nil || localServerID! > 0 else { throw LokalTransferError.invalidRecord }
    if let pairingID {
      guard UUID(uuidString: pairingID)?.uuidString.lowercased() == pairingID else {
        throw LokalTransferError.invalidRecord
      }
    }
    for value in [desktopID, sourceID] + (localSongID.map { [$0] } ?? []) + (desktopUserID.map { [$0] } ?? []) {
      guard !value.isEmpty, value.utf8.count <= 512,
            !value.contains("://"), !value.contains("?"), !value.contains("#"),
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw LokalTransferError.invalidRecord
      }
    }
    guard origin.utf8.count <= 4096, let url = URLComponents(string: origin),
          url.scheme == "https" || url.scheme == "http",
          let host = url.host, !host.isEmpty,
          url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
          url.path.isEmpty || url.path == "/",
          url.port == nil || (1...65535).contains(url.port!) else {
      throw LokalTransferError.invalidRecord
    }
  }
}

/// Durable source metadata only. Destination paths are owned, derived names.
struct LokalTransferMetadata: Codable, Equatable, Sendable {
  let title: String
  let artist: String
  let album: String?
  let fileExtension: String
  let albumArtist: String?
  let genre: String?
  let durationMs: Int?
  let sampleRate: Int?
  let bitDepth: Int?
  let bitrate: Int?
  let trackNumber: Int?
  let discNumber: Int?
  let year: Int?

  init(title: String, artist: String, album: String?, fileExtension: String,
       albumArtist: String? = nil, genre: String? = nil, durationMs: Int? = nil,
       sampleRate: Int? = nil, bitDepth: Int? = nil, bitrate: Int? = nil,
       trackNumber: Int? = nil, discNumber: Int? = nil, year: Int? = nil) {
    self.title = title; self.artist = artist; self.album = album; self.fileExtension = fileExtension
    self.albumArtist = albumArtist; self.genre = genre; self.durationMs = durationMs
    self.sampleRate = sampleRate; self.bitDepth = bitDepth; self.bitrate = bitrate
    self.trackNumber = trackNumber; self.discNumber = discNumber; self.year = year
  }

  func validate() throws {
    guard [title, artist, album ?? "", albumArtist ?? "", genre ?? ""].allSatisfy({ $0.utf8.count <= 4096 }),
          fileExtension.range(of: "^[a-z0-9]{1,8}$", options: .regularExpression) != nil else {
      throw LokalTransferError.invalidRecord
    }
    for (value, maximum) in [(durationMs, 31_622_400_000), (sampleRate, 1_000_000_000),
        (bitDepth, 1024), (bitrate, 1_000_000_000_000), (trackNumber, 1_000_000),
        (discNumber, 1_000_000), (year, 9999)] {
      guard value == nil || (0...maximum).contains(value!) else { throw LokalTransferError.invalidRecord }
    }
  }
}

/// A network callback must carry both the job ID and the revision it started.
/// Retry/cancel retire that binding before another OS task can be accepted.
struct LokalTransferJob: Codable, Equatable, Sendable {
  static let maximumJSONBytes = 32 * 1024
  let id: String
  private(set) var revision: Int
  let direction: LokalTransferDirection
  let identity: LokalTransferIdentity
  let metadata: LokalTransferMetadata
  let createdMs: Int64
  private(set) var updatedMs: Int64
  private(set) var phase: LokalTransferPhase
  private(set) var taskID: Int?
  let expectedBytes: Int64?
  let expectedSHA256: String?
  private(set) var receivedBytes: Int64?
  private(set) var receivedSHA256: String?
  private(set) var resultOriginalID: String?
  private(set) var responseBytes: Int64?
  private(set) var responseSHA256: String?
  private(set) var lastFailure: LokalTransferFailure?

  /// Shared strict document boundary for storage and the private app protocol.
  /// Unknown credential/header/path payloads are never silently accepted.
  static func decodeDocument(_ data: Data) throws -> LokalTransferJob {
    guard !data.isEmpty, data.count <= maximumJSONBytes,
          let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(row.keys).isSubset(of: ["id", "revision", "direction", "identity", "metadata", "createdMs", "updatedMs",
            "phase", "taskID", "expectedBytes", "expectedSHA256", "receivedBytes", "receivedSHA256", "resultOriginalID",
            "responseBytes", "responseSHA256", "lastFailure"]),
          let identity = row["identity"] as? [String: Any],
          Set(identity.keys).isSubset(of: ["desktopID", "sourceID", "localSongID", "origin", "pairingID", "desktopUserID", "localServerID"]),
          let metadata = row["metadata"] as? [String: Any],
          Set(metadata.keys).isSubset(of: ["title", "artist", "album", "fileExtension", "albumArtist", "genre",
            "durationMs", "sampleRate", "bitDepth", "bitrate", "trackNumber", "discNumber", "year"]) else {
      throw LokalTransferError.invalidRecord
    }
    let job = try JSONDecoder().decode(LokalTransferJob.self, from: data)
    try job.validate()
    return job
  }

  init(id: String = UUID().uuidString.lowercased(), direction: LokalTransferDirection,
       identity: LokalTransferIdentity, metadata: LokalTransferMetadata, nowMs: Int64,
       expectedBytes: Int64? = nil, expectedSHA256: String? = nil) throws {
    self.id = id
    revision = 1
    self.direction = direction
    self.identity = identity
    self.metadata = metadata
    createdMs = nowMs
    updatedMs = nowMs
    phase = .queued
    self.expectedBytes = expectedBytes
    self.expectedSHA256 = expectedSHA256
    try validate()
  }

  var taskBinding: String { id + ":" + String(revision) }
  var stagedName: String { id + "-" + String(revision) + ".download" }

  /// Cancellation advances the live revision while its private download keeps
  /// the old binding. This derives that exact binding, never a caller path.
  func cancelledDownloadForCleanup() throws -> Self {
    try validate()
    guard direction == .download, phase == .cancelled else { throw LokalTransferError.invalidTransition }
    var previous = self
    if previous.revision > 1 { previous.revision -= 1 }
    try previous.validate()
    return previous
  }
  var uploadName: String { id + "-" + String(revision) + ".upload" }

  func validate() throws {
    guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id,
          revision > 0, revision < Int.max,
          createdMs >= 0, updatedMs >= createdMs,
          updatedMs <= 4_102_444_800_000,
          expectedBytes == nil || expectedBytes! > 0,
          receivedBytes == nil || receivedBytes! > 0,
          taskID == nil || taskID! > 0 else { throw LokalTransferError.invalidRecord }
    for hash in [expectedSHA256, receivedSHA256, responseSHA256].compactMap({ $0 }) {
      guard hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
        throw LokalTransferError.invalidRecord
      }
    }
    guard [.transferring, .received].contains(phase) ? taskID != nil : taskID == nil else {
      throw LokalTransferError.invalidRecord
    }
    guard (receivedBytes == nil) == (receivedSHA256 == nil),
          ![.queued, .waiting, .transferring, .received, .downloaded].contains(phase) || receivedBytes == nil,
          direction == .upload || resultOriginalID == nil,
          phase == .complete || resultOriginalID == nil else { throw LokalTransferError.invalidRecord }
    guard lastFailure == nil || [.waiting, .failed, .interrupted, .cancelled].contains(phase) else {
      throw LokalTransferError.invalidRecord
    }
    guard responseBytes == nil || responseBytes! > 0 else { throw LokalTransferError.invalidRecord }
    if let bytes = receivedBytes, let hash = receivedSHA256 {
      guard expectedBytes == nil || bytes == expectedBytes,
            expectedSHA256 == nil || hash == expectedSHA256,
            responseBytes == nil || bytes == responseBytes,
            responseSHA256 == nil || hash == responseSHA256 else { throw LokalTransferError.invalidRecord }
    }
    if direction == .download && [.staged, .validating, .importing, .complete].contains(phase) {
      guard let bytes = receivedBytes, let hash = receivedSHA256,
            expectedBytes == nil || bytes == expectedBytes,
            expectedSHA256 == nil || hash == expectedSHA256 else {
        throw LokalTransferError.invalidRecord
      }
    }
    if direction == .upload {
      guard expectedBytes != nil, expectedSHA256 != nil,
            receivedBytes == nil,
            ![.received, .downloaded, .staged, .validating, .importing].contains(phase) else {
        throw LokalTransferError.invalidRecord
      }
      if phase == .complete {
        guard let receipt = resultOriginalID, !receipt.isEmpty, receipt.utf8.count <= 512 else {
          throw LokalTransferError.invalidRecord
        }
      }
    }
    try identity.validate()
    try metadata.validate()
  }

  private mutating func touch(_ nowMs: Int64) throws {
    guard nowMs >= 0, nowMs <= 4_102_444_800_000 else { throw LokalTransferError.invalidRecord }
    // Wall clocks can move backwards between callbacks; never regress history.
    updatedMs = max(updatedMs, nowMs)
  }

  mutating func bind(taskID: Int, nowMs: Int64) throws {
    guard phase == .queued || phase == .waiting, taskID > 0 else {
      throw LokalTransferError.invalidTransition
    }
    try touch(nowMs)
    self.taskID = taskID
    phase = .transferring
    lastFailure = nil
  }

  mutating func retainDownload(taskID: Int, bytes: Int64, sha256: String, nowMs: Int64) throws {
    guard direction == .download, phase == .transferring, self.taskID == taskID else {
      throw LokalTransferError.invalidTransition
    }
    guard bytes > 0, sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
          expectedBytes == nil || bytes == expectedBytes,
          expectedSHA256 == nil || sha256 == expectedSHA256 else {
      throw LokalTransferError.checksumMismatch
    }
    try touch(nowMs)
    receivedBytes = bytes
    receivedSHA256 = sha256
    self.taskID = nil
    phase = .staged
  }

  /// Commit response integrity metadata before moving the OS temporary file.
  /// A crash between file retention and the next journal write can reconcile
  /// the owned file against the same response, rather than losing its checksum.
  mutating func rememberDownloadResponse(taskID: Int, bytes: Int64?, sha256: String?, nowMs: Int64) throws {
    guard direction == .download, phase == .transferring, self.taskID == taskID,
          bytes == nil || bytes! > 0,
          sha256 == nil || sha256!.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
      throw LokalTransferError.invalidTransition
    }
    guard responseBytes == nil || responseBytes == bytes,
          responseSHA256 == nil || responseSHA256 == sha256 else { throw LokalTransferError.checksumMismatch }
    try touch(nowMs)
    responseBytes = bytes
    responseSHA256 = sha256
  }

  mutating func retainedDownload(taskID: Int, bytes: Int64, nowMs: Int64) throws {
    guard direction == .download, phase == .transferring, self.taskID == taskID else {
      throw LokalTransferError.invalidTransition
    }
    guard bytes > 0, expectedBytes == nil || bytes == expectedBytes,
          responseBytes == nil || bytes == responseBytes else { throw LokalTransferError.checksumMismatch }
    try touch(nowMs)
    phase = .received
  }

  mutating func acknowledgeDownload(taskID: Int, nowMs: Int64) throws {
    guard direction == .download, phase == .received, self.taskID == taskID else {
      throw LokalTransferError.invalidTransition
    }
    try touch(nowMs)
    self.taskID = nil
    phase = .downloaded
  }

  mutating func verifiedDownload(bytes: Int64, sha256: String, nowMs: Int64) throws {
    guard direction == .download, phase == .downloaded else { throw LokalTransferError.invalidTransition }
    guard bytes > 0, sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
          expectedBytes == nil || bytes == expectedBytes,
          responseBytes == nil || bytes == responseBytes,
          expectedSHA256 == nil || sha256 == expectedSHA256,
          responseSHA256 == nil || sha256 == responseSHA256 else {
      throw LokalTransferError.checksumMismatch
    }
    try touch(nowMs)
    receivedBytes = bytes
    receivedSHA256 = sha256
    phase = .staged
  }

  mutating func transition(to next: LokalTransferPhase, nowMs: Int64) throws {
    let allowed: [LokalTransferPhase: Set<LokalTransferPhase>] = [
      .queued: [.waiting, .failed], .waiting: [.queued, .failed],
      .transferring: [.interrupted, .failed], .received: [.interrupted, .failed],
      .downloaded: [.failed], .staged: [.validating, .failed],
      .validating: [.importing, .failed], .importing: [.complete, .failed],
    ]
    guard allowed[phase]?.contains(next) == true else { throw LokalTransferError.invalidTransition }
    try touch(nowMs)
    phase = next
    taskID = nil
  }

  mutating func acknowledgeUpload(taskID: Int, originalID: String, nowMs: Int64) throws {
    guard direction == .upload, phase == .transferring, self.taskID == taskID,
          !originalID.isEmpty, originalID.utf8.count <= 512,
          !originalID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
      throw LokalTransferError.invalidTransition
    }
    try touch(nowMs)
    resultOriginalID = originalID
    self.taskID = nil
    phase = .complete
  }

  mutating func fail(_ reason: LokalTransferFailure, retryable: Bool, nowMs: Int64) throws {
    guard !phase.isTerminal else { throw LokalTransferError.invalidTransition }
    try touch(nowMs)
    taskID = nil
    phase = retryable ? .interrupted : .failed
    lastFailure = reason
  }

  mutating func cancel(nowMs: Int64) throws {
    // Import is a short, acknowledged commit boundary. Its owner must finish
    // reconciliation before cancellation can promise no library insertion.
    guard phase != .complete, phase != .cancelled, phase != .importing else {
      throw LokalTransferError.invalidTransition
    }
    try touch(nowMs)
    revision += 1
    phase = .cancelled
    taskID = nil
  }

  /// Private cleanup driver only, after revocation/file drainage and a durable
  /// Isar retiring decision. Journal must compare the exact frozen custody in
  /// the same native transaction. Ordinary cancellation remains unchanged.
  mutating func retirePreparedImportAfterBarrier(nowMs: Int64) throws {
    guard direction == .download, [.validating, .importing].contains(phase),
          receivedBytes != nil, receivedSHA256 != nil else {
      throw LokalTransferError.invalidTransition
    }
    try touch(nowMs)
    revision += 1
    phase = .cancelled
    taskID = nil
  }

  mutating func retry(nowMs: Int64) throws {
    guard phase == .interrupted || phase == .failed else { throw LokalTransferError.invalidTransition }
    try touch(nowMs)
    revision += 1
    phase = .queued
    taskID = nil
    receivedBytes = nil
    receivedSHA256 = nil
    responseBytes = nil
    responseSHA256 = nil
    lastFailure = nil
  }
}
