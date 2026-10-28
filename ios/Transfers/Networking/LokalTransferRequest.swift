import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct LokalTransferAuthorization: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  let desktopID: String
  let origin: String
  let pairingID: String?
  private let token: String
  var description: String { "LokalTransferAuthorization(redacted)" }
  var debugDescription: String { description }

  init(desktopID: String, origin: String, token: String, pairingID: String? = nil) throws {
    guard !token.isEmpty, token.utf8.count <= 4096,
          !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
      throw LokalTransferError.invalidRecord
    }
    self.desktopID = desktopID
    self.origin = origin
    self.pairingID = pairingID
    self.token = token
    try LokalTransferScope(desktopID: desktopID, origin: origin, pairingID: pairingID).validate()
  }

  func downloadRequest(for job: LokalTransferJob) throws -> URLRequest {
    try job.validate()
    guard job.direction == .download, job.identity.desktopID == desktopID, job.identity.pairingID == pairingID,
          try LokalTransferRequest.originKey(origin) == LokalTransferRequest.originKey(job.identity.origin) else {
      throw LokalTransferError.invalidRecord
    }
    var request = URLRequest(url: try LokalTransferRequest.downloadURL(job),
      cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
    request.setValue(token, forHTTPHeaderField: "x-remote-token")
    return request
  }
}

struct LokalTransferTaskBinding: Equatable, Sendable {
  let id: String
  let revision: Int

  init?(_ text: String?) {
    guard let text, text.utf8.count < 80 else { return nil }
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2,
          let uuid = UUID(uuidString: String(parts[0])),
          uuid.uuidString.lowercased() == parts[0],
          let revision = Int(parts[1]), revision > 0, revision < Int.max,
          String(revision) == parts[1] else { return nil }
    id = String(parts[0])
    self.revision = revision
  }
}

enum LokalTransferRequest {
  static func originKey(_ raw: String) throws -> String {
    try LokalTransferIdentity(desktopID: "origin-check", sourceID: "origin-check",
      localSongID: nil, origin: raw).validate()
    guard let parts = URLComponents(string: raw), let scheme = parts.scheme, let host = parts.host else {
      throw LokalTransferError.invalidRecord
    }
    return scheme.lowercased() + "://" + host.lowercased() + ":" + String(parts.port ?? (scheme == "https" ? 443 : 80))
  }

  static func downloadURL(_ job: LokalTransferJob) throws -> URL {
    try job.validate()
    guard job.direction == .download, ![".", ".."].contains(job.identity.sourceID),
          var parts = URLComponents(string: job.identity.origin),
          let source = job.identity.sourceID.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")) else {
      throw LokalTransferError.invalidRecord
    }
    parts.percentEncodedPath = "/api/remote/files/" + source
    guard let url = parts.url else { throw LokalTransferError.invalidRecord }
    return url
  }

  /// Actual retained length is recorded even for a chunked response. Encoded
  /// Content-Length is compared only when the body has no content encoding.
  static func checkResponse(_ response: HTTPURLResponse, job: LokalTransferJob,
                            fileBytes: Int64) throws -> (bytes: Int64, sha256: String?) {
    guard [200, 206].contains(response.statusCode), response.url == (try downloadURL(job)),
          fileBytes > 0, fileBytes <= LokalTransferFiles.maximumBytes,
          job.expectedBytes == nil || fileBytes == job.expectedBytes else {
      throw LokalTransferError.invalidRecord
    }
    let coding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
    let hash = response.value(forHTTPHeaderField: "x-content-sha256")?.lowercased() ?? job.responseSHA256
    if let hash {
      guard hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
            job.expectedSHA256 == nil || hash == job.expectedSHA256 else {
        throw LokalTransferError.checksumMismatch
      }
    }
    var declaredBytes = fileBytes
    if response.statusCode == 206 {
      // A resumed OS download may finish with a 206 response and an assembled
      // full file. A standalone range fragment is never eligible for import.
      guard coding == nil || coding == "identity",
            let range = response.value(forHTTPHeaderField: "Content-Range"),
            let regex = try? NSRegularExpression(pattern: "^bytes ([0-9]+)-([0-9]+)/([0-9]+)$"),
            let match = regex.firstMatch(in: range, range: NSRange(range.startIndex..., in: range)),
            let startRange = Range(match.range(at: 1), in: range), let start = Int64(range[startRange]),
            let endRange = Range(match.range(at: 2), in: range), let end = Int64(range[endRange]),
            let totalRange = Range(match.range(at: 3), in: range), let total = Int64(range[totalRange]),
            start <= end, end < total, total == fileBytes, end == total - 1,
            job.expectedSHA256 != nil || hash != nil else {
        throw LokalTransferError.invalidRecord
      }
      declaredBytes = end - start + 1
    }
    if (coding == nil || coding == "identity"),
       let declared = response.value(forHTTPHeaderField: "Content-Length") {
      guard let bytes = Int64(declared), bytes == declaredBytes else { throw LokalTransferError.checksumMismatch }
    }
    return (fileBytes, hash)
  }
}
