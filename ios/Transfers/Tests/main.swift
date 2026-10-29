import Foundation
import SQLite3
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum TestFailure: Error { case failed(String) }

func require(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
  if try !condition() { throw TestFailure.failed(reason) }
}

func rejects(_ reason: String, _ operation: () throws -> Void) throws {
  do { try operation() }
  catch is TestFailure { throw TestFailure.failed(reason + ": test failed") }
  catch { return }
  throw TestFailure.failed(reason + ": unexpectedly accepted")
}

func makeJob(direction: LokalTransferDirection = .download) throws -> LokalTransferJob {
  try LokalTransferJob(direction: direction,
    identity: LokalTransferIdentity(desktopID: "paired-pc", sourceID: "original-7",
      localSongID: "42", origin: "http://192.168.1.2:5443"),
    metadata: LokalTransferMetadata(title: "曲 — Café", artist: "Artist", album: "Album",
      fileExtension: "flac"), nowMs: 1000, expectedBytes: 12,
    expectedSHA256: String(repeating: "a", count: 64))
}


func rawDatabasePath(_ url: URL) throws -> String {
  guard let parent = realpath(url.deletingLastPathComponent().path, nil) else {
    throw TestFailure.failed("resolve independent database parent")
  }
  defer { free(parent) }
  return String(cString: parent) + "/" + url.lastPathComponent
}

func rawDatabase<T>(_ url: URL, _ work: (OpaquePointer) throws -> T) throws -> T {
  var database: OpaquePointer?
  let code = sqlite3_open_v2(try rawDatabasePath(url), &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
  guard code == SQLITE_OK, let database else { throw TestFailure.failed("open independent SQLite connection") }
  defer { sqlite3_close_v2(database) }
  return try work(database)
}

func rawExecute(_ url: URL, _ sql: String) throws {
  try rawDatabase(url) { database in
    try require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK, "independent database mutation")
  }
}

func rawDocument(_ url: URL, id: String, replacement: Data? = nil) throws -> Data {
  try rawDatabase(url) { database in
    var query: OpaquePointer?
    let sql = replacement == nil ? "SELECT document FROM jobs WHERE id=?" : "UPDATE jobs SET document=? WHERE id=? RETURNING document"
    try require(sqlite3_prepare_v2(database, sql, -1, &query, nil) == SQLITE_OK, "prepare independent query")
    guard let query else { throw TestFailure.failed("no statement") }
    defer { sqlite3_finalize(query) }
    let index: Int32
    if let replacement {
      try require(replacement.withUnsafeBytes {
        sqlite3_bind_blob(query, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
      } == SQLITE_OK, "bind corrupted record")
      index = 2
    } else { index = 1 }
    try require(id.withCString {
      sqlite3_bind_text(query, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    } == SQLITE_OK, "bind independent identity")
    try require(sqlite3_step(query) == SQLITE_ROW, "independent record exists")
    guard let pointer = sqlite3_column_blob(query, 0) else { throw TestFailure.failed("no record bytes") }
    let result = Data(bytes: pointer, count: Int(sqlite3_column_bytes(query, 0)))
    // Finish UPDATE RETURNING before closing: this commits the independent write.
    try require(sqlite3_step(query) == SQLITE_DONE, "independent statement finished")
    return result
  }
}

var contractStage = "startup"
do {
  if CommandLine.arguments.count == 6 && CommandLine.arguments[1] == "--tracked-copy" {
    let container = URL(fileURLWithPath: CommandLine.arguments[2])
    let store = try LokalTransferJournal(container: container)
    guard let job = try store.snapshot().jobs.first(where: { $0.id == CommandLine.arguments[4] }) else {
      throw LokalTransferError.missingJob
    }
    let boundary = CommandLine.arguments[5]
    let library = try LokalTransferLibrary(root: URL(fileURLWithPath: CommandLine.arguments[3]),
      testingBoundary: { if $0 == boundary { exit(98) } })
    _ = try library.installTracked(job, songID: 42, journal: store,
      files: LokalTransferFiles(container: container), cancellation: LokalTransferCopyCancellation(),
      validateOwnership: {})
    exit(0)
  }
  if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--migration-open" {
    _ = try LokalTransferJournal(container: URL(fileURLWithPath: CommandLine.arguments[2])).snapshot()
    exit(0)
  }
  if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--custody-worker" {
    let boundary = CommandLine.arguments[4]
    let store = try LokalTransferJournal(container: URL(fileURLWithPath: CommandLine.arguments[2]),
      testingCommitBoundary: { if $0 == boundary { exit(97) } })
    _ = try store.reserveImport(id: CommandLine.arguments[3], revision: 1, songID: 42)
    exit(0)
  }
  if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--migration-crash" {
    let boundary = CommandLine.arguments[3]
    _ = try LokalTransferJournal(container: URL(fileURLWithPath: CommandLine.arguments[2]),
      testingCommitBoundary: { if $0 == boundary { exit(98) } })
    throw TestFailure.failed("migration crash boundary was not reached")
  }
  if [6, 7].contains(CommandLine.arguments.count) && CommandLine.arguments[1] == "--library-copy" {
    let container = URL(fileURLWithPath: CommandLine.arguments[2])
    let root = URL(fileURLWithPath: CommandLine.arguments[3])
    let job = try LokalTransferJob.decodeDocument(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[4])))
    let boundary = CommandLine.arguments[5]
    let trace = LibraryChildTrace()
    do {
      let library = try LokalTransferLibrary(root: root, testingBoundary: {
        trace.record($0)
        if $0 == "initializeWriter", CommandLine.arguments.count == 7 {
          do { try libraryConstructorRendezvous(URL(fileURLWithPath: CommandLine.arguments[6])) }
          catch { FileHandle.standardError.write(Data("Native constructor rendezvous failed\n".utf8)); exit(99) }
        }
        if $0 == boundary { exit(96) }
      })
      let files = try LokalTransferFiles(container: container)
      _ = try library.install(job, from: files)
    } catch {
      FileHandle.standardError.write(Data("Native library child failed at \(trace.last): \(error)\n".utf8))
      throw error
    }
    exit(0)
  }
  if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--probe-write-lock" {
    let path = URL(fileURLWithPath: CommandLine.arguments[2])
      .appendingPathComponent(LokalTransferJournal.directoryName)
      .appendingPathComponent(LokalTransferJournal.databaseName)
    var database: OpaquePointer?
    guard sqlite3_open_v2(try rawDatabasePath(path), &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
          let database else { exit(94) }
    sqlite3_busy_timeout(database, 150)
    let result = sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil)
    if result == SQLITE_OK { _ = sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
    sqlite3_close_v2(database)
    exit(result == SQLITE_BUSY || result == SQLITE_LOCKED ? 0 : 93)
  }
  if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--crash" {
    let boundary = CommandLine.arguments[3]
    let store = try LokalTransferJournal(container: URL(fileURLWithPath: CommandLine.arguments[2]),
      testingCommitBoundary: { if $0 == boundary { exit(95) } })
    try store.create([makeJob()])
    throw TestFailure.failed("Crash boundary was not reached")
  }
  if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--worker" {
    let store = try LokalTransferJournal(container: URL(fileURLWithPath: CommandLine.arguments[2]))
    for _ in 0..<8 { try store.create([makeJob()]) }
    exit(0)
  }
  let manager = FileManager.default
  let root = manager.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("lokal-transfer-test-" + UUID().uuidString)
  try manager.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? manager.removeItem(at: root) }
  contractStage = "initial journal"
  let store = try LokalTransferJournal(container: root)
  try require(store.snapshot().jobs.isEmpty, "fresh journal")
  contractStage = "durable import custody and migration"
  try runImportCustodyContracts(container: root)
  contractStage = "process lock ownership"
  let lockRoot = root.appendingPathComponent("write-lock-probe")
  try manager.createDirectory(at: lockRoot, withIntermediateDirectories: false)
  let initialLockStore = try LokalTransferJournal(container: lockRoot)
  try initialLockStore.create([makeJob()])
  let probeResult = lockRoot.appendingPathComponent("probe-result")
  let executable = URL(fileURLWithPath: CommandLine.arguments[0])
  let lockedStore = try LokalTransferJournal(container: lockRoot, testingCommitBoundary: { boundary in
    guard boundary == "beforeCommit" else { return }
    do {
      // An independent connection must be able to inspect the old snapshot
      // without the file-safety checks dropping our live writer lock.
      let inspector = try LokalTransferJournal(container: lockRoot)
      _ = try inspector.snapshot()
      let child = Process()
      child.executableURL = executable
      child.arguments = ["--probe-write-lock", lockRoot.path]
      try child.run(); child.waitUntilExit()
      try Data(String(child.terminationStatus).utf8).write(to: probeResult)
    } catch { try? Data("-1".utf8).write(to: probeResult) }
  })
  try lockedStore.create([makeJob()])
  try require(String(contentsOf: probeResult, encoding: .utf8) == "0",
    "independent inspection preserves the active SQLite writer lock against a different process")
  contractStage = "parent alias identity"
  let systemAlias = root.appendingPathComponent("system-parent-alias")
  let actualContainer = root.appendingPathComponent("alias-container")
  try manager.createDirectory(at: actualContainer, withIntermediateDirectories: false)
  try manager.createSymbolicLink(at: systemAlias, withDestinationURL: root)
  let aliasedContainer = systemAlias.appendingPathComponent("alias-container")
  let aliasJournal = try LokalTransferJournal(container: aliasedContainer)
  try aliasJournal.create([makeJob()])
  try require(LokalTransferJournal(container: actualContainer).snapshot().jobs.count == 1,
    "OS parent aliases resolve to the same owned journal without following a final container symlink")
  let finalAlias = root.appendingPathComponent("final-container-alias")
  try manager.createSymbolicLink(at: finalAlias, withDestinationURL: actualContainer)
  try rejects("a final app container symlink remains forbidden") {
    _ = try LokalTransferJournal(container: finalAlias)
  }
  contractStage = "typed protocol and credentials"
  let original = try makeJob()
  let intentData = try Data(contentsOf: URL(fileURLWithPath: "test/fixtures/ios_transfer_intents_v1.json"))
  let intents = try LokalTransferProtocol.intents(intentData)
  try require(intents.count == 1 && intents[0].phase == .queued && intents[0].revision == 1,
    "shared user intent cannot assign native task state")
  try require(intents[0].identity.localSongID == "42" && intents[0].metadata.title == "曲 — Café",
    "protocol preserves frozen library identity and Unicode metadata")
  let intentRows = try JSONSerialization.jsonObject(with: intentData) as! [[String: Any]]
  for (key, value) in [("phase", "complete" as Any), ("revision", 900 as Any),
      ("headers", ["authorization": "synthetic-forbidden-token"] as Any),
      ("destinationPath", "/outside/music.flac" as Any)] {
    var row = intentRows[0]; row[key] = value
    try rejects("intent cannot supply task, credential or filesystem state") {
      _ = try LokalTransferProtocol.intents(JSONSerialization.data(withJSONObject: [row]))
    }
  }
  var nested = intentRows[0]
  var nestedIdentity = nested["identity"] as! [String: Any]
  nestedIdentity["token"] = "synthetic-forbidden-token"
  nested["identity"] = nestedIdentity
  try rejects("nested arbitrary credentials are rejected") {
    _ = try LokalTransferProtocol.intents(JSONSerialization.data(withJSONObject: [nested]))
  }
  try rejects("repeated frozen intent is not duplicated inside one batch") {
    _ = try LokalTransferProtocol.intents(JSONSerialization.data(withJSONObject: intentRows + intentRows))
  }
  for document in ["{\"offset\":false,\"limit\":20}", "{\"offset\":0,\"limit\":101}",
      "{\"offset\":0,\"limit\":1,\"headers\":{}}"] {
    try rejects("bounded typed page request") { _ = try LokalTransferProtocol.page(Data(document.utf8)) }
  }
  try require(LokalTransferProtocol.page(Data("{\"offset\":0,\"limit\":100}".utf8)).limit == 100,
    "bounded page request accepted")
  let contractClient = "b7d96b93-6526-4f1f-a1af-688ffb5c799d"
  let recoveryRequest: [String: Any] = ["limit": 2, "clientID": contractClient]
  try require(LokalTransferProtocol.importWorkPage(JSONSerialization.data(withJSONObject: recoveryRequest)).limit == 2,
    "bounded client-bound recovery request accepted")
  for invalid: Any in [false, 0, 101, "2", 1.5] {
    var row = recoveryRequest; row["limit"] = invalid
    try rejects("recovery requires a bounded integer limit") {
      _ = try LokalTransferProtocol.importWorkPage(JSONSerialization.data(withJSONObject: row))
    }
  }
  for invalid in ["../file", original.id + ":01", original.id.uppercased() + ":1"] {
    var row = recoveryRequest; row["after"] = invalid
    try rejects("recovery requires a canonical keyset cursor") {
      _ = try LokalTransferProtocol.importWorkPage(JSONSerialization.data(withJSONObject: row))
    }
  }
  var injectedRecovery = recoveryRequest; injectedRecovery["sourcePath"] = "/caller"
  try rejects("recovery cannot accept a caller's private path") {
    _ = try LokalTransferProtocol.importWorkPage(JSONSerialization.data(withJSONObject: injectedRecovery))
  }
  let claimDocument: [String: Any] = ["id": original.id, "revision": 1, "reconcileOnly": false, "clientID": contractClient]
  let leaseDocument: [String: Any] = ["id": original.id, "revision": 1,
    "leaseID": "a7d96b93-6526-4f1f-a1af-688ffb5c799d", "clientID": contractClient]
  try require(!LokalTransferProtocol.importClaim(JSONSerialization.data(withJSONObject: claimDocument)).reconcileOnly,
    "bounded typed native import claim accepted")
  try require(LokalTransferProtocol.importLease(JSONSerialization.data(withJSONObject: leaseDocument)).revision == 1,
    "bounded typed native lease guard accepted")
  var publicationDocument = leaseDocument
  publicationDocument["songID"] = 42
  try require(LokalTransferProtocol.importPublication(JSONSerialization.data(withJSONObject: publicationDocument)).songID == 42,
    "publication accepts only the current lease and positive prepared Song identity")
  for invalid: Any in [false, 0, -1, 1.5, "42", NSNull()] {
    var row = publicationDocument; row["songID"] = invalid
    try rejects("publication requires a real positive integer Song identity") {
      _ = try LokalTransferProtocol.importPublication(JSONSerialization.data(withJSONObject: row))
    }
  }
  for (key, value) in [("sourcePath", "/tmp/caller.wav"), ("targetRelativePath", "caller.wav"),
      ("owner", "caller"), ("headers", "caller")] {
    var injectedClaim = claimDocument, injectedLease = leaseDocument
    injectedClaim[key] = value; injectedLease[key] = value
    try rejects("caller cannot inject path/owner/headers into an import claim") {
      _ = try LokalTransferProtocol.importClaim(JSONSerialization.data(withJSONObject: injectedClaim))
    }
    try rejects("caller cannot inject path/owner/headers into the direct lease guard") {
      _ = try LokalTransferProtocol.importLease(JSONSerialization.data(withJSONObject: injectedLease))
    }
    var injectedPublication = publicationDocument; injectedPublication[key] = value
    try rejects("publication destination and provenance are never supplied by a caller") {
      _ = try LokalTransferProtocol.importPublication(JSONSerialization.data(withJSONObject: injectedPublication))
    }
  }
  for invalid: Any in [1, "false", NSNull()] {
    var row = claimDocument; row["reconcileOnly"] = invalid
    try rejects("import recovery role must be an explicit JSON Boolean") {
      _ = try LokalTransferProtocol.importClaim(JSONSerialization.data(withJSONObject: row))
    }
  }
  for invalid: Any in [false, 0, -1, 1.5, "1"] {
    var row = leaseDocument; row["revision"] = invalid
    try rejects("direct import guard requires a positive integer revision") {
      _ = try LokalTransferProtocol.importLease(JSONSerialization.data(withJSONObject: row))
    }
  }
  for invalid in ["caller", "A7D96B93-6526-4F1F-A1AF-688FFB5C799D", ""] {
    var row = leaseDocument; row["leaseID"] = invalid
    try rejects("native lease identity must be a canonical UUID") {
      _ = try LokalTransferProtocol.importLease(JSONSerialization.data(withJSONObject: row))
    }
  }
  let credentialBytes = try Data(contentsOf: URL(fileURLWithPath: "test/fixtures/ios_transfer_credentials_v2.json"))
  guard let atomicAuthorization = try LokalTransferCredentials.decode(credentialBytes) else {
    throw TestFailure.failed("Shared credential contract did not authorize")
  }
  let grantJob = try LokalTransferJob(direction: .download,
    identity: LokalTransferIdentity(desktopID: "contract-desktop", sourceID: "original", localSongID: nil,
      origin: "http://192.0.2.20:5443", pairingID: "14093104-64d4-44f7-8c8b-8b4b14399067",
      desktopUserID: "contract-user", localServerID: 3),
    metadata: original.metadata, nowMs: 1000)
  try require(atomicAuthorization.downloadRequest(for: grantJob).value(forHTTPHeaderField: "x-remote-token") ==
    "synthetic-transfer-contract-token", "shared atomic Keychain wire contract")
  try require(atomicAuthorization.downloadRequest(for: grantJob).value(forHTTPHeaderField: "x-api-key") ==
    "synthetic-transfer-contract-key", "paired original endpoint retains the optional API key")
  try require(!atomicAuthorization.debugDescription.contains("synthetic-transfer-contract-key"), "API key remains redacted")
  try rejects("same desktop after re-pairing cannot inherit earlier queued authority") {
    _ = try LokalTransferAuthorization(desktopID: "contract-desktop", origin: "http://192.0.2.20:5443",
      token: "synthetic-new-pairing-token", pairingID: UUID().uuidString.lowercased(),
      desktopUserID: "contract-user").downloadRequest(for: grantJob)
  }
  try rejects("same origin and pairing cannot authorize another desktop account") {
    _ = try LokalTransferAuthorization(desktopID: "contract-desktop", origin: "http://192.0.2.20:5443",
      token: "synthetic-account-token", pairingID: grantJob.identity.pairingID,
      desktopUserID: "another-account").downloadRequest(for: grantJob)
  }
  try rejects("legacy split credentials cannot start background networking") {
    _ = try LokalTransferCredentials.decode(Data("{\"version\":1,\"remoteToken\":\"synthetic-old-token\"}".utf8))
  }
  let authorization = try LokalTransferAuthorization(desktopID: original.identity.desktopID,
    origin: original.identity.origin, token: "synthetic-contract-token")
  let request = try authorization.downloadRequest(for: original)
  try require(request.url?.path == "/api/remote/files/original-7", "stable original endpoint")
  try require(request.url?.query == nil, "no credentials in URL")
  try require(request.value(forHTTPHeaderField: "x-remote-token") == "synthetic-contract-token", "request-only authorization")
  try require(!authorization.description.contains("synthetic-contract-token"), "redacted authorization descriptions")
  try require(!String(decoding: JSONEncoder().encode(original), as: UTF8.self).contains("synthetic-contract-token"),
    "job wire metadata excludes the request token")
  try rejects("another desktop cannot authorize this job") {
    _ = try LokalTransferAuthorization(desktopID: "other", origin: original.identity.origin, token: "other-token")
      .downloadRequest(for: original)
  }
  try rejects("changed origin cannot inherit authorization") {
    _ = try LokalTransferAuthorization(desktopID: original.identity.desktopID, origin: "http://192.168.1.99", token: "other-token")
      .downloadRequest(for: original)
  }
  try require(LokalTransferTaskBinding(original.taskBinding)?.revision == 1, "native task revision decoding")
  for binding in [original.id + ":+1", original.id + ":01", original.id + ":-1", original.id + ":1:extra", "not-a-job:1"] {
    try require(LokalTransferTaskBinding(binding) == nil, "reject malformed task binding")
  }
  let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
    headerFields: ["CONTENT-LENGTH": "12", "X-CONTENT-SHA256": String(repeating: "A", count: 64)])!
  let responseMetadata = try LokalTransferRequest.checkResponse(response, job: original, fileBytes: 12)
  try require(responseMetadata.sha256 == original.expectedSHA256, "case-insensitive response checksum")
  let resumed = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil,
    headerFields: ["Content-Range": "bytes 6-11/12", "Content-Length": "6"])!
  try require(LokalTransferRequest.checkResponse(resumed, job: original, fileBytes: 12).bytes == 12,
    "OS-assembled full response keeps whole-file integrity after continuation")
  try rejects("a received range fragment cannot be treated as a full recording") {
    _ = try LokalTransferRequest.checkResponse(resumed, job: original, fileBytes: 6)
  }
  for range in ["bytes 6-10/12", "bytes 12-11/12", "bytes 0-11/*", "bytes 0-999999999999999999999999/12"] {
    try rejects("malformed/incomplete continuation is refused") {
      let invalid = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil,
        headerFields: ["Content-Range": range])!
      _ = try LokalTransferRequest.checkResponse(invalid, job: original, fileBytes: 12)
    }
  }
  for (status, url, bytes) in [(401, request.url!, Int64(12)), (302, request.url!, Int64(12)),
      (200, URL(string: "http://192.168.1.99/api/remote/files/original-7")!, Int64(12)),
      (200, request.url!, Int64(11))] {
    let invalid = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    try rejects("response status/origin/length policy") {
      _ = try LokalTransferRequest.checkResponse(invalid, job: original, fileBytes: bytes)
    }
  }
  for origin in ["https://secret@example.com", "https://pc.test/?token=secret", "file:///music", "http://pc.test:65536"] {
    try rejects("credential-bearing/unsupported origin") {
      try LokalTransferIdentity(desktopID: "pc", sourceID: "7", localSongID: nil, origin: origin).validate()
    }
  }
  try rejects("signed URL in source identity") {
    try LokalTransferIdentity(desktopID: "pc", sourceID: "https://pc/file?token=secret", localSongID: nil,
      origin: "http://pc.local").validate()
  }
  try store.create([original])
  let disk = root.appendingPathComponent(LokalTransferJournal.directoryName).appendingPathComponent(LokalTransferJournal.databaseName)
  let initial = try store.snapshot()
  try rejects("duplicate creation") { try store.create([original]) }
  try require(store.snapshot().generation == initial.generation && store.snapshot().jobs == initial.jobs, "rejected creation preserves committed records")
  try require(LokalTransferJournal(container: root).snapshot().jobs == [original], "reopen actual file")

  try store.update(id: original.id, revision: 1) { try $0.bind(taskID: 17, nowMs: 1010) }
  let transferring = try store.snapshot()
  try rejects("wrong native task") {
    try store.update(id: original.id, revision: 1) {
      try $0.retainDownload(taskID: 18, bytes: 12, sha256: String(repeating: "a", count: 64), nowMs: 1020)
    }
  }
  try rejects("truncated response") {
    try store.update(id: original.id, revision: 1) {
      try $0.retainDownload(taskID: 17, bytes: 11, sha256: String(repeating: "a", count: 64), nowMs: 1020)
    }
  }
  try rejects("changed content") {
    try store.update(id: original.id, revision: 1) {
      try $0.retainDownload(taskID: 17, bytes: 12, sha256: String(repeating: "b", count: 64), nowMs: 1020)
    }
  }
  try require(store.snapshot().generation == transferring.generation && store.snapshot().jobs == transferring.jobs, "failed callbacks do not change journal")
  try store.update(id: original.id, revision: 1) { try $0.cancel(nowMs: 1030) }
  try rejects("late completion after cancel") {
    try store.update(id: original.id, revision: 1) {
      try $0.retainDownload(taskID: 17, bytes: 12, sha256: String(repeating: "a", count: 64), nowMs: 1040)
    }
  }
  try require(store.snapshot().jobs[0].phase == .cancelled, "cancel cannot resurrect")

  let completed = try makeJob()
  try store.create([completed])
  try store.update(id: completed.id, revision: 1) { try $0.bind(taskID: 21, nowMs: 1010) }
  try store.update(id: completed.id, revision: 1) {
    try $0.retainDownload(taskID: 21, bytes: 12, sha256: String(repeating: "a", count: 64), nowMs: 1020)
  }
  try rejects("networking is not a completed library import") {
    try store.update(id: completed.id, revision: 1) { try $0.transition(to: .complete, nowMs: 1030) }
  }
  try store.update(id: completed.id, revision: 1) { try $0.transition(to: .validating, nowMs: 1030) }
  try store.update(id: completed.id, revision: 1) { try $0.transition(to: .importing, nowMs: 1040) }
  try rejects("cancel across import commit boundary") {
    try store.update(id: completed.id, revision: 1) { try $0.cancel(nowMs: 1050) }
  }
  try store.update(id: completed.id, revision: 1) { try $0.transition(to: .complete, nowMs: 1050) }
  try require(store.snapshot().jobs[1].phase == .complete, "import acknowledgment")

  let retried = try makeJob()
  try store.create([retried])
  try store.update(id: retried.id, revision: 1) { try $0.bind(taskID: 23, nowMs: 1100) }
  try store.update(id: retried.id, revision: 1) { try $0.transition(to: .interrupted, nowMs: 1090) }
  try store.update(id: retried.id, revision: 1) { try $0.retry(nowMs: 1200) }
  let current = try store.snapshot().jobs[2]
  try require(current.revision == 2 && current.phase == .queued, "retry retires native binding")
  try require(current.stagedName != retried.stagedName, "retry has distinct staging ownership")
  try rejects("late old task after retry") {
    try store.update(id: retried.id, revision: 1) { try $0.bind(taskID: 23, nowMs: 1300) }
  }
  let upload = try makeJob(direction: .upload)
  try store.create([upload])
  try store.update(id: upload.id, revision: 1) { try $0.bind(taskID: 31, nowMs: 1100) }
  try store.update(id: upload.id, revision: 1) { try $0.acknowledgeUpload(taskID: 31, originalID: "desktop-original", nowMs: 1200) }
  try require(store.snapshot().jobs[3].resultOriginalID == "desktop-original", "upload receipt retained")
  let authJob = try makeJob()
  try store.create([authJob])
  try store.update(id: authJob.id, revision: 1) { try $0.bind(taskID: 41, nowMs: 1100) }
  let scope = LokalTransferScope(desktopID: authJob.identity.desktopID, origin: authJob.identity.origin)
  let pause = LokalTransferPause(scope: scope, reason: .unauthorized)
  try store.update(id: authJob.id, revision: 1, pausingScope: pause) {
    try $0.fail(.unauthorized, retryable: false, nowMs: 0)
  }
  try require(LokalTransferJournal(container: root).snapshot().pauses == [pause], "authentication pause survives process replacement")
  let paused = try store.snapshot().jobs.first { $0.id == authJob.id }!
  try require(paused.updatedMs == 1100, "clock rollback does not prevent retiring a failed task")
  try require(paused.phase == .failed && paused.lastFailure == .unauthorized, "failure and pause commit together")
  try store.clearPause(scope)
  try require(store.snapshot().pauses.isEmpty, "explicit verified reconnect can clear the pause")

  // Real retained bytes and hashing, not a checksum stub. The OS temporary
  // file is no longer needed once retained; verification/import stay separate.
  contractStage = "retained real bytes"
  let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  let binaryJob = try LokalTransferJob(direction: .download, identity: original.identity,
    metadata: original.metadata, nowMs: 1000, expectedBytes: 3, expectedSHA256: digest)
  try store.create([binaryJob])
  var transfer = try store.update(id: binaryJob.id, revision: 1) { try $0.bind(taskID: 77, nowMs: 1010) }
  transfer = try store.update(id: binaryJob.id, revision: 1) {
    try $0.rememberDownloadResponse(taskID: 77, bytes: 3, sha256: digest, nowMs: 1020)
  }
  let temporary = root.appendingPathComponent("os-temporary-download")
  try Data("abc".utf8).write(to: temporary)
  let files = try LokalTransferFiles(container: root)
  let retained = try files.retainTemporaryDownload(temporary, for: transfer)
  transfer = try store.update(id: binaryJob.id, revision: 1) {
    try $0.retainedDownload(taskID: 77, bytes: retained, nowMs: 1030)
  }
  try require(transfer.phase == .received && transfer.receivedSHA256 == nil,
    "network completion has not claimed verified media")
  try rejects("body receipt cannot bypass final request completion") {
    try store.update(id: binaryJob.id, revision: 1) {
      try $0.verifiedDownload(bytes: 3, sha256: digest, nowMs: 1030)
    }
  }
  transfer = try store.update(id: binaryJob.id, revision: 1) { try $0.acknowledgeDownload(taskID: 77, nowMs: 1030) }
  try require(!manager.fileExists(atPath: temporary.path), "OS temporary ownership transferred")
  let receipt = try files.inspect(transfer)
  try require(receipt.bytes == 3 && receipt.sha256 == digest, "actual SHA-256 of retained bytes")
  transfer = try store.update(id: binaryJob.id, revision: 1) {
    try $0.verifiedDownload(bytes: receipt.bytes, sha256: receipt.sha256, nowMs: 1040)
  }
  try rejects("staged bytes alone do not grant an importer path") { _ = try files.importURL(transfer) }
  transfer = try store.update(id: binaryJob.id, revision: 1) { try $0.transition(to: .validating, nowMs: 1050) }
  try require(Data(contentsOf: files.importURL(transfer)) == Data("abc".utf8), "current owned import path")
  contractStage = "ephemeral native import ownership"
  try runImportOwnershipContracts(job: transfer)
  contractStage = "deterministic library file promotion"
  try runLibraryContracts(container: root, job: transfer, files: files)
  contractStage = "tracked private-part library publication"
  try runTrackedLibraryContracts(container: root, template: transfer)
  try store.update(id: binaryJob.id, revision: 1) { try $0.cancel(nowMs: 1060) }
  try files.discard(transfer)
  try require(files.retainedSize(transfer) == nil, "cancel cleanup uses the retired file revision")
  let foreign = root.appendingPathComponent("user-original")
  try Data("user audio".utf8).write(to: foreign)
  let ownedName = root.appendingPathComponent(LokalTransferJournal.directoryName).appendingPathComponent(transfer.stagedName)
  try manager.createSymbolicLink(at: ownedName, withDestinationURL: foreign)
  try rejects("symlink media inspection") { _ = try files.inspect(transfer) }
  try rejects("symlink media cleanup") { try files.discard(transfer) }
  try require(String(contentsOf: foreign, encoding: .utf8) == "user audio", "user original never deleted")
  try manager.removeItem(at: ownedName)
  let ownedDirectory = root.appendingPathComponent(LokalTransferJournal.directoryName)
  let retiredDirectory = root.appendingPathComponent("retired-directory")
  try manager.moveItem(at: ownedDirectory, to: retiredDirectory)
  try manager.createDirectory(at: ownedDirectory, withIntermediateDirectories: false)
  try rejects("replaced directory cannot supply an import file") { _ = try files.importURL(transfer) }
  try manager.removeItem(at: ownedDirectory)
  try manager.moveItem(at: retiredDirectory, to: ownedDirectory)


  contractStage = "strict SQLite records"
  let committed = try store.snapshot()
  try rawExecute(disk, "PRAGMA user_version=3")
  try rejects("future database read") { _ = try store.snapshot() }
  try rejects("future database write") { try store.create([makeJob()]) }
  try rawExecute(disk, "PRAGMA user_version=2")
  try require(store.snapshot().jobs == committed.jobs && store.snapshot().generation == committed.generation,
    "future schema never replaces committed records")
  let originalDocument = try rawDocument(disk, id: original.id)
  var payload = try JSONSerialization.jsonObject(with: originalDocument) as! [String: Any]
  payload["authorization"] = "not-a-real-token"
  _ = try rawDocument(disk, id: original.id, replacement: JSONSerialization.data(withJSONObject: payload))
  try rejects("unexpected credential/payload field") { _ = try store.snapshot() }
  try rejects("unexpected record is not overwritten") {
    try store.update(id: original.id, revision: 2) { try $0.retry(nowMs: 2000) }
  }
  try require(rawDocument(disk, id: original.id) != originalDocument, "unknown record retained")
  _ = try rawDocument(disk, id: original.id, replacement: originalDocument)

  // Foundation's UTF-8 initializer is available at the iOS 16 deployment floor
  // and must remain strict: replacement characters would hide corrupt storage.
  let invalidUTF8 = "80" + String(repeating: "61", count: 35)
  try rawExecute(disk, "UPDATE jobs SET id=CAST(x'\(invalidUTF8)' AS TEXT) WHERE id='\(original.id)'")
  try rejects("malformed UTF-8 database identity is not repaired silently") { _ = try store.snapshot() }
  try rawExecute(disk, "UPDATE jobs SET id='\(original.id)' WHERE id=CAST(x'\(invalidUTF8)' AS TEXT)")
  try rawExecute(disk, "INSERT INTO pauses VALUES (CAST(x'80' AS TEXT),'http://192.0.2.20:5443','','unauthorized')")
  try rejects("malformed UTF-8 pause text is not repaired silently") { _ = try store.snapshot() }
  try rawExecute(disk, "DELETE FROM pauses WHERE desktop_id=CAST(x'80' AS TEXT)")
  try require(store.snapshot().jobs == committed.jobs, "strict UTF-8 validation preserves every original job")

  contractStage = "unsafe storage preservation"
  let unsafeRoot = root.appendingPathComponent("unsafe")
  let unsafeDirectory = unsafeRoot.appendingPathComponent(LokalTransferJournal.directoryName)
  try manager.createDirectory(at: unsafeDirectory, withIntermediateDirectories: true)
  let unsafeDatabase = unsafeDirectory.appendingPathComponent(LokalTransferJournal.databaseName)
  let outside = root.appendingPathComponent("outside")
  try Data("preserve".utf8).write(to: outside)
  try manager.createSymbolicLink(at: unsafeDatabase, withDestinationURL: outside)
  try rejects("symlink database") { _ = try LokalTransferJournal(container: unsafeRoot) }
  try require(String(contentsOf: outside, encoding: .utf8) == "preserve", "external target unchanged")
  try manager.removeItem(at: unsafeDatabase)
  let corrupt = Data("not a database".utf8)
  try corrupt.write(to: unsafeDatabase)
  try rejects("damaged database") { _ = try LokalTransferJournal(container: unsafeRoot) }
  try require(Data(contentsOf: unsafeDatabase) == corrupt, "damaged database retained")
  try manager.removeItem(at: unsafeDatabase)
  let legacy = unsafeDirectory.appendingPathComponent("jobs.json")
  let legacyBytes = Data("{\"schemaVersion\":99,\"jobs\":[]}".utf8)
  try legacyBytes.write(to: legacy)
  try rejects("unmigrated JSON prototype") { _ = try LokalTransferJournal(container: unsafeRoot) }
  try require(Data(contentsOf: legacy) == legacyBytes, "legacy data never silently reset")

  contractStage = "concurrent process writers"
  let before = try store.snapshot()
  let children = try (0..<6).map { _ -> Process in
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--worker", root.path]
    try process.run()
    return process
  }
  for process in children {
    process.waitUntilExit()
    try require(process.terminationStatus == 0, "concurrent child succeeds")
  }
  let after = try store.snapshot()
  try require(after.jobs.count == before.jobs.count + 48, "concurrent creates retain all jobs")
  try require(after.generation == before.generation + 48, "cross-process generation is ordered")
  for boundary in ["beforeCommit", "afterCommit"] {
    let before = try store.snapshot()
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["--crash", root.path, boundary]
    try child.run()
    child.waitUntilExit()
    try require(child.terminationStatus == 95, "process ended at exact commit boundary")
    let after = try LokalTransferJournal(container: root).snapshot()
    let delta = boundary == "beforeCommit" ? 0 : 1
    try require(after.jobs.count == before.jobs.count + delta, "crash leaves complete old/new journal")
    try require(after.generation == before.generation + delta, "crash never splits job/generation")
  }
  // Start from a truncated WAL so its growth measures this one real transaction,
  // rather than previously allocated checkpoint space. A manifest rewrite of
  // this queue would be hundreds of KB; one affected job stays bounded.
  contractStage = "single job WAL budget"
  let largeQueue = try (0..<1000).map { _ in try makeJob() }
  try store.create(largeQueue)
  let largeBefore = try store.snapshot()
  try rawExecute(disk, "PRAGMA wal_checkpoint(TRUNCATE)")
  let subject = largeQueue[500]
  try store.update(id: subject.id, revision: 1) { try $0.bind(taskID: 888, nowMs: 1100) }
  let wal = disk.deletingLastPathComponent()
    .appendingPathComponent(LokalTransferJournal.databaseName + "-wal")
  let walBytes = (try manager.attributesOfItem(atPath: wal.path)[.size] as! NSNumber).int64Value
  try require(walBytes <= 128 * 1024, "one update does not rewrite a 1,000-track manifest")
  let largeAfter = try store.snapshot()
  try require(largeAfter.jobs.filter { $0.id != subject.id } == largeBefore.jobs.filter { $0.id != subject.id },
    "single update leaves unrelated jobs unchanged")
  print("Native transfer journal single-update WAL bytes with 1,000 queued tracks: \(walBytes)")
  if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--network-fixture",
     let length = Int64(CommandLine.arguments[3]) {
    contractStage = "external HTTP and host owner"
    try runNetworkContracts(origin: CommandLine.arguments[2], length: length, checksum: CommandLine.arguments[4])
  }
  print("Native transfer journal: lifecycle, revision, declared integrity, corrupt/future preservation, symlink, 6×8 process writes and both transaction crash boundaries passed. No installed-app, iOS suspension or power-loss acceptance claim.")
} catch {
  FileHandle.standardError.write(Data("Native transfer journal failed at \(contractStage): \(error)\n".utf8))
  exit(1)
}
