import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct LokalTransferAuthorization: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  let desktopID: String
  let origin: String
  let pairingID: String?
  let desktopUserID: String?
  private let token: String
  private let apiKey: String
  var description: String { "LokalTransferAuthorization(redacted)" }
  var debugDescription: String { description }

  init(desktopID: String, origin: String, token: String, pairingID: String? = nil, apiKey: String = "",
       desktopUserID: String? = nil) throws {
    guard !token.isEmpty, [token, apiKey].allSatisfy({ value in
      value.utf8.count <= 4096 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }) else {
      throw LokalTransferError.invalidRecord
    }
    self.desktopID = desktopID
    self.origin = origin
    self.pairingID = pairingID
    self.desktopUserID = desktopUserID
    self.token = token
    self.apiKey = apiKey
    try LokalTransferIdentity(desktopID: desktopID, sourceID: "authorization", localSongID: nil,
      origin: origin, pairingID: pairingID, desktopUserID: desktopUserID).validate()
  }

  func downloadRequest(for job: LokalTransferJob) throws -> URLRequest {
    try job.validate()
    guard job.direction == .download, job.identity.desktopID == desktopID, job.identity.pairingID == pairingID,
          job.identity.desktopUserID == desktopUserID,
          try LokalTransferRequest.originKey(origin) == LokalTransferRequest.originKey(job.identity.origin) else {
      throw LokalTransferError.invalidRecord
    }
    var request = URLRequest(url: try LokalTransferRequest.downloadURL(job),
      cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
    request.setValue(token, forHTTPHeaderField: "x-remote-token")
    if !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
    return request
  }
  /// Pairing/account checks precede construction of any authenticated upload.
  /// No caller path, bearer value or signed URL enters the durable job.
  func uploadRequest(for job: LokalTransferJob) throws -> URLRequest {
    try job.validate()
    guard job.direction == .upload, pairingID != nil, job.identity.pairingID == pairingID,
          job.identity.localSongID != nil, job.identity.desktopID == desktopID,
          job.identity.desktopUserID == desktopUserID,
          // Retain the atomic credential record's exact scope spelling so a
          // semantically equivalent URL cannot escape its retirement tombstone.
          job.identity.origin == origin,
          let bytes = job.expectedBytes, bytes <= LokalTransferFiles.maximumUploadBytes,
          let hash = job.expectedSHA256,
          ["flac", "mp3", "m4a", "aac", "ogg", "opus", "wav", "aiff", "aif", "alac", "ape", "wv",
            "dsf", "dff", "webm"].contains(job.metadata.fileExtension) else { throw LokalTransferError.invalidRecord }
    var metadata = ["title": job.metadata.title, "artist": job.metadata.artist,
      "extension": job.metadata.fileExtension, "sha256": hash]
    if let album = job.metadata.album { metadata["album"] = album }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let header = try encoder.encode(metadata).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    guard header.utf8.count <= 8192,
          header.utf8.count + token.utf8.count + apiKey.utf8.count <= 12 * 1024 else {
      throw LokalTransferError.limitExceeded
    }
    var request = URLRequest(url: try LokalTransferRequest.uploadURL(job),
      cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
    request.httpMethod = "POST"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.setValue(String(bytes), forHTTPHeaderField: "Content-Length")
    request.setValue(header, forHTTPHeaderField: "x-link-metadata")
    request.setValue(token, forHTTPHeaderField: "x-remote-token")
    if !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
    return request
  }

  func uploadMatchRequest(for job: LokalTransferJob) throws -> URLRequest {
    var request = try uploadRequest(for: job)
    request.url = try LokalTransferRequest.uploadMatchURL(job)
    request.setValue(nil, forHTTPHeaderField: "x-link-metadata")
    let body = try JSONSerialization.data(withJSONObject:
      ["items": [["size": job.expectedBytes!, "sha256": job.expectedSHA256!]]])
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
    request.httpBody = body
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

  static let maximumUploadResponseBytes = 16 * 1024

  static func uploadURL(_ job: LokalTransferJob) throws -> URL {
    try job.validate()
    guard job.direction == .upload, var parts = URLComponents(string: job.identity.origin) else {
      throw LokalTransferError.invalidRecord
    }
    parts.percentEncodedPath = "/api/remote/files"
    guard let url = parts.url else { throw LokalTransferError.invalidRecord }
    return url
  }

  static func checkUploadResponse(_ response: HTTPURLResponse, job: LokalTransferJob) throws {
    guard response.url == (try uploadURL(job)), [200, 201].contains(response.statusCode),
          response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() == "application/json",
          response.expectedContentLength < 0 || response.expectedContentLength <= Int64(maximumUploadResponseBytes) else {
      throw LokalTransferError.invalidRecord
    }
  }

  static func uploadOriginalID(_ body: Data, response: HTTPURLResponse, job: LokalTransferJob) throws -> String {
    try checkUploadResponse(response, job: job)
    struct Receipt: Decodable {
      let ok: Bool
      let trackId: String
      let file_hash: String?
      let alreadyPresent: Bool?
    }
    guard !body.isEmpty, body.count <= maximumUploadResponseBytes else { throw LokalTransferError.limitExceeded }
    let receipt = try JSONDecoder().decode(Receipt.self, from: body)
    guard receipt.ok, !receipt.trackId.isEmpty, receipt.trackId.utf8.count <= 512,
          !receipt.trackId.contains("://"), !receipt.trackId.contains("?"), !receipt.trackId.contains("#"),
          !receipt.trackId.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
          receipt.file_hash != nil || receipt.alreadyPresent == true else { throw LokalTransferError.invalidRecord }
    if let hash = receipt.file_hash {
      guard hash == job.expectedSHA256 else { throw LokalTransferError.checksumMismatch }
    }
    return receipt.trackId
  }

  static func uploadMatchURL(_ job: LokalTransferJob) throws -> URL {
    let base = try uploadURL(job)
    return base.appendingPathComponent("match")
  }

  static func matchedUploadOriginalID(_ data: Data) throws -> String? {
    struct Page: Decodable {
      struct Match: Decodable { let index: Int; let trackId: String }
      let matches: [Match]
    }
    guard !data.isEmpty, data.count <= maximumUploadResponseBytes else { throw LokalTransferError.limitExceeded }
    let page = try JSONDecoder().decode(Page.self, from: data)
    guard page.matches.count <= 1 else { throw LokalTransferError.invalidRecord }
    guard let match = page.matches.first else { return nil }
    guard match.index == 0, !match.trackId.isEmpty, match.trackId.utf8.count <= 512,
          !match.trackId.contains("://"), !match.trackId.contains("?"), !match.trackId.contains("#"),
          !match.trackId.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
      throw LokalTransferError.invalidRecord
    }
    return match.trackId
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


/// Foreground read-only content query, deliberately separate from daemon audio
/// POSTs. Bound bytes while receiving, refuse redirects/cookies, and acknowledge
/// cancellation only after the ephemeral session invalidates its delegates.
final class LokalTransferUploadMatchProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private var session: URLSession!
  private var task: URLSessionDataTask!
  private var body = Data()
  private var failure: Error?
  private var acceptedResponse = false
  private var result: Result<String?, Error>?
  private var completion: LokalTransferCompletion<String?>?
  private let endpoint: URL

  init(request: URLRequest, queue: DispatchQueue, completion: @escaping LokalTransferCompletion<String?>) {
    endpoint = request.url!
    self.completion = completion
    super.init()
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil; config.httpShouldSetCookies = false
    config.urlCredentialStorage = nil; config.urlCache = nil
    config.allowsCellularAccess = false
    config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
    #if !os(Linux)
    config.allowsExpensiveNetworkAccess = false; config.allowsConstrainedNetworkAccess = false
    #endif
    let delegates = OperationQueue()
    delegates.maxConcurrentOperationCount = 1; delegates.underlyingQueue = queue
    session = URLSession(configuration: config, delegate: self, delegateQueue: delegates)
    task = session.dataTask(with: request)
  }
  func start() { task.resume() }
  func cancel() { task.cancel() }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    guard let http = response as? HTTPURLResponse, http.url == endpoint, http.statusCode == 200,
          http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() == "application/json",
          http.expectedContentLength < 0 || http.expectedContentLength <= Int64(LokalTransferRequest.maximumUploadResponseBytes) else {
      failure = LokalTransferError.invalidRecord; completionHandler(.cancel); return
    }
    acceptedResponse = true
    completionHandler(.allow)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard failure == nil else { return }
    guard acceptedResponse else { failure = LokalTransferError.invalidRecord; dataTask.cancel(); return }
    guard data.count <= LokalTransferRequest.maximumUploadResponseBytes - body.count else {
      failure = LokalTransferError.limitExceeded; dataTask.cancel(); return
    }
    body.append(data)
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    result = Result {
      if let failure { throw failure }
      if let error { throw error }
      guard acceptedResponse else { throw LokalTransferError.invalidRecord }
      return try LokalTransferRequest.matchedUploadOriginalID(body)
    }
    session.finishTasksAndInvalidate()
  }
  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
    let callback = completion
    completion = nil; task = nil; self.session = nil
    callback?(result ?? .failure(error ?? LokalTransferError.invalidRecord))
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}
