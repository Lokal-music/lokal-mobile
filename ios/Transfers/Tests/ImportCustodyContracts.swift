import Foundation
import SQLite3

private func custodyDisk(_ root: URL) -> URL {
  root.appendingPathComponent(LokalTransferJournal.directoryName)
    .appendingPathComponent(LokalTransferJournal.databaseName)
}

private func custodyChild(_ arguments: [String]) throws -> Process {
  let child = Process()
  child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
  child.arguments = arguments
  try child.run()
  return child
}

/// Construct an independent v1 database, not a v2 database with its version
/// number relabelled. Migration must preserve the original job BLOB verbatim.
private func legacyCustodyFixture(_ root: URL) throws -> LokalTransferJob {
  let directory = root.appendingPathComponent(LokalTransferJournal.directoryName)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let disk = custodyDisk(root)
  try Data().write(to: disk)
  let job = try makeJob()
  let document = try JSONEncoder().encode(job)
  try rawExecute(disk, """
    CREATE TABLE metadata (id INTEGER PRIMARY KEY CHECK(id=1), generation INTEGER NOT NULL CHECK(typeof(generation)='integer' AND generation>=0), job_count INTEGER NOT NULL CHECK(typeof(job_count)='integer' AND job_count>=0), byte_count INTEGER NOT NULL CHECK(typeof(byte_count)='integer' AND byte_count>=0));
    CREATE TABLE jobs (id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>0), document BLOB NOT NULL CHECK(typeof(document)='blob'));
    CREATE TABLE pauses (desktop_id TEXT NOT NULL, origin TEXT NOT NULL, pairing_id TEXT NOT NULL, reason TEXT NOT NULL, PRIMARY KEY(desktop_id,origin,pairing_id));
    INSERT INTO metadata VALUES (1,7,1,\(document.count));
    INSERT INTO pauses VALUES ('paired-pc','http://192.168.1.2:5443','','unauthorized');
    PRAGMA user_version=1;
    """)
  try rawDatabase(disk) { database in
    var query: OpaquePointer?
    try require(sqlite3_prepare_v2(database, "INSERT INTO jobs VALUES(?,1,?)", -1, &query, nil) == SQLITE_OK,
      "prepare independent legacy job")
    defer { sqlite3_finalize(query) }
    try require(job.id.withCString { sqlite3_bind_text(query, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } == SQLITE_OK,
      "bind independent legacy job ID")
    try require(document.withUnsafeBytes { sqlite3_bind_blob(query, 2, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } == SQLITE_OK,
      "bind independent legacy job document")
    try require(sqlite3_step(query) == SQLITE_DONE, "write independent legacy job")
  }
  return job
}

private func rawCustody(_ disk: URL, id: String, replacement: Data? = nil) throws -> Data {
  try rawDatabase(disk) { database in
    var query: OpaquePointer?
    let sql = replacement == nil ? "SELECT document FROM import_custody WHERE id=? AND revision=1" :
      "UPDATE import_custody SET document=? WHERE id=? AND revision=1 RETURNING document"
    try require(sqlite3_prepare_v2(database, sql, -1, &query, nil) == SQLITE_OK, "prepare independent custody query")
    defer { sqlite3_finalize(query) }
    if let replacement {
      try require(replacement.withUnsafeBytes { sqlite3_bind_blob(query, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } == SQLITE_OK,
        "bind independent custody document")
    }
    try require(id.withCString { sqlite3_bind_text(query, replacement == nil ? 1 : 2, $0, -1,
      unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } == SQLITE_OK, "bind independent custody ID")
    try require(sqlite3_step(query) == SQLITE_ROW, "read independent custody document")
    guard let bytes = sqlite3_column_blob(query, 0) else { throw TestFailure.failed("custody bytes") }
    let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0)))
    try require(sqlite3_step(query) == SQLITE_DONE, "finish independent custody mutation")
    return data
  }
}

func runImportCustodyContracts(container: URL) throws {
  let manager = FileManager.default
  func root(_ name: String) throws -> URL {
    let value = container.appendingPathComponent("custody-" + name)
    try manager.createDirectory(at: value, withIntermediateDirectories: false)
    return value
  }
  func validating(_ store: LokalTransferJournal) throws -> LokalTransferJob {
    let job = try makeJob()
    try store.create([job])
    try store.update(id: job.id, revision: 1) { try $0.bind(taskID: 1, nowMs: 1010) }
    try store.update(id: job.id, revision: 1) {
      try $0.retainDownload(taskID: 1, bytes: 12, sha256: String(repeating: "a", count: 64), nowMs: 1020)
    }
    return try store.update(id: job.id, revision: 1) { try $0.transition(to: .validating, nowMs: 1030) }
  }

  for boundary in ["none", "beforeMigrationCommit", "afterMigrationCommit"] {
    let directory = try root("migration-" + boundary)
    let original = try legacyCustodyFixture(directory)
    let originalBytes = try rawDocument(custodyDisk(directory), id: original.id)
    if boundary != "none" {
      let child = try custodyChild(["--migration-crash", directory.path, boundary])
      child.waitUntilExit()
      try require(child.terminationStatus == 98, "migration process exited at exact boundary")
    }
    let migrated = try LokalTransferJournal(container: directory).snapshot()
    try require(migrated.generation == 7 && migrated.jobs == [original] && migrated.custodies.isEmpty,
      "v1 migration and both crash boundaries preserve complete prior identity and generation")
    try require(migrated.pauses == [LokalTransferPause(scope: LokalTransferScope(
      desktopID: "paired-pc", origin: "http://192.168.1.2:5443"), reason: .unauthorized)],
      "v1 authentication pause survives migration")
    try require(rawDocument(custodyDisk(directory), id: original.id) == originalBytes,
      "v1 migration does not re-encode the original job BLOB")
  }

  let concurrentMigration = try root("concurrent-migration")
  let legacy = try legacyCustodyFixture(concurrentMigration)
  let migrationChildren = try (0..<6).map { _ in
    try custodyChild(["--migration-open", concurrentMigration.path])
  }
  for child in migrationChildren { child.waitUntilExit() }
  try require(migrationChildren.allSatisfy { $0.terminationStatus == 0 }, "six migration processes finish without duplicate ALTER")
  try require(LokalTransferJournal(container: concurrentMigration).snapshot().jobs == [legacy],
    "concurrent additive migration retains the original job")

  let directory = try root("identity")
  let store = try LokalTransferJournal(container: directory)
  let pages = try LokalTransferJournal(container: root("pages"))
  var pagedReservations: [LokalTransferImportCustody] = []
  for _ in 0..<5 {
    let pending = try validating(pages)
    pagedReservations.append(try pages.reserveImport(id: pending.id, revision: 1, songID: 42))
  }
  pagedReservations.sort { $0.job.id < $1.job.id }
  let firstPage = try pages.custodyPage(after: nil, limit: 2)
  try require(firstPage.values == Array(pagedReservations.prefix(2)) && firstPage.nextCursor != nil,
    "actual SQLite keyset page is bounded and ordered")
  try pages.removeImportCustody(pagedReservations[0])
  let inserted = try validating(pages)
  _ = try pages.reserveImport(id: inserted.id, revision: 1, songID: 42)
  var cursor = firstPage.nextCursor, seen = Set<String>()
  while let after = cursor {
    let next = try pages.custodyPage(after: after, limit: 2)
    try require(next.values.count <= 2, "each page keeps its hard row bound")
    for work in next.values {
      try require(seen.insert(work.job.id).inserted, "keyset pages do not repeat frozen work")
    }
    cursor = next.nextCursor
  }
  try require(Set(pagedReservations.dropFirst(2).map { $0.job.id }).isSubset(of: seen),
    "removing/inserting earlier work cannot offset-skip original later reservations")
  for limit in [0, 101] {
    try rejects("unbounded native recovery pages are refused") { _ = try pages.custodyPage(after: nil, limit: limit) }
  }
  try rejects("noncanonical native cursors are refused") { _ = try pages.custodyPage(after: pagedReservations[0].job.id + ":01", limit: 1) }
  let job = try validating(store)
  let reservation = try store.reserveImport(id: job.id, revision: 1, songID: 42)
  try require(reservation.job == job && reservation.songID == 42, "reserve full immutable import identity")
  try store.update(id: job.id, revision: 1) { try $0.transition(to: .importing, nowMs: 1040) }
  try require(store.reserveImport(id: job.id, revision: 1, songID: 42) == reservation,
    "import phase advance and lost acknowledgements reuse the same reservation")
  try rejects("different local song cannot inherit a reservation") {
    _ = try store.reserveImport(id: job.id, revision: 1, songID: 43)
  }
  try store.update(id: job.id, revision: 1) { try $0.transition(to: .complete, nowMs: 1050) }
  try require(LokalTransferJournal(container: directory).importCustody(id: job.id, revision: 1) == reservation,
    "completed native job retains frozen receipt until cleanup acknowledges it")

  let cancelled = try validating(store)
  let old = try store.reserveImport(id: cancelled.id, revision: 1, songID: 42)
  let next = try store.update(id: cancelled.id, revision: 1) { try $0.cancel(nowMs: 1040) }
  try require(next.revision == 2 && next.receivedBytes == job.receivedBytes && next.receivedSHA256 == job.receivedSHA256,
    "real cancellation retires live revision while preserving received history")
  try require(LokalTransferJournal(container: directory).importCustody(id: cancelled.id, revision: 1) == old,
    "old revision keeps exact proof for safe reconciliation after process replacement")
  try rejects("late reservation cannot revive cancelled revision") {
    _ = try store.reserveImport(id: cancelled.id, revision: 1, songID: 42)
  }

  let retryRoot = try root("retry")
  let retryStore = try LokalTransferJournal(container: retryRoot)
  let retryJob = try validating(retryStore)
  let retryProof = try retryStore.reserveImport(id: retryJob.id, revision: 1, songID: 42)
  try retryStore.update(id: retryJob.id, revision: 1) { try $0.fail(.storage, retryable: false, nowMs: 1040) }
  let retried = try retryStore.update(id: retryJob.id, revision: 1) { try $0.retry(nowMs: 1050) }
  try require(retried.revision == 2 && retried.receivedBytes == nil && retried.receivedSHA256 == nil,
    "real retry clears the live revision's byte proof")
  try require(LokalTransferJournal(container: retryRoot).importCustody(id: retryJob.id, revision: 1) == retryProof,
    "retry cannot erase previous reserved copy proof")

  let disk = custodyDisk(directory)
  let saved = try rawCustody(disk, id: cancelled.id)
  try rawExecute(disk, "PRAGMA user_version=3")
  try rejects("future schema cannot open existing custody") { _ = try LokalTransferJournal(container: directory) }
  try rejects("future schema blocks custody readers") { _ = try store.importCustody(id: cancelled.id, revision: 1) }
  try rejects("future schema blocks custody retirement") { try store.removeImportCustody(old) }
  try rawExecute(disk, "PRAGMA user_version=2")
  try require(rawCustody(disk, id: cancelled.id) == saved, "future schema leaves frozen copy proof untouched")
  var document = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
  document["headers"] = ["authorization": "synthetic-forbidden"]
  let altered = try JSONSerialization.data(withJSONObject: document)
  _ = try rawCustody(disk, id: cancelled.id, replacement: altered)
  try rejects("unknown custody payload must block snapshot") { _ = try store.snapshot() }
  try rejects("unknown custody payload must not be silently retired") { try store.removeImportCustody(old) }
  try require(rawCustody(disk, id: cancelled.id) == altered, "unrecognized custody BLOB is preserved")
  _ = try rawCustody(disk, id: cancelled.id, replacement: saved)
  try rawExecute(disk, "UPDATE metadata SET custody_bytes=custody_bytes+1")
  try rejects("custody byte accounting corruption is refused") { _ = try store.snapshot() }
  try rawExecute(disk, "UPDATE metadata SET custody_bytes=custody_bytes-1")
  try require(store.snapshot().custodies.count == 2, "strict failures preserve both reservations")
  try store.removeImportCustody(old)
  try store.removeImportCustody(old)
  try require(store.importCustody(id: cancelled.id, revision: 1) == nil && store.snapshot().custodies == [reservation],
    "exact cleanup is idempotent and preserves other work")

  for boundary in ["beforeCommit", "afterCommit"] {
    let directory = try root("reserve-" + boundary)
    let store = try LokalTransferJournal(container: directory)
    let job = try validating(store)
    let before = try store.snapshot()
    let child = try custodyChild(["--custody-worker", directory.path, job.id, boundary])
    child.waitUntilExit()
    try require(child.terminationStatus == 97, "reservation process exited at exact commit boundary")
    let after = try LokalTransferJournal(container: directory).snapshot()
    let delta = boundary == "beforeCommit" ? 0 : 1
    try require(after.custodies.count == delta && after.generation == before.generation + delta && after.jobs == before.jobs,
      "reservation crash leaves complete old or new work record, with unchanged job")
  }
  let concurrent = try root("concurrent")
  let concurrentStore = try LokalTransferJournal(container: concurrent)
  let concurrentJob = try validating(concurrentStore)
  let children = try (0..<6).map { _ in
    try custodyChild(["--custody-worker", concurrent.path, concurrentJob.id, "none"])
  }
  for child in children { child.waitUntilExit() }
  try require(children.allSatisfy { $0.terminationStatus == 0 }, "all concurrent custody writers finish")
  try require(concurrentStore.snapshot().custodies.count == 1, "six actual processes reserve exactly one immutable work record")

  for boundary in ["beforeCommit", "afterCommit", "none"] {
    let directory = try root("resolution-" + boundary)
    let store = try LokalTransferJournal(container: directory)
    let job = try validating(store)
    let work = try store.reserveImport(id: job.id, revision: 1, songID: 42)
    let resolution = LokalTransferImportResolution(mode: .abandoned, abandonment: .missingFile)
    try rejects("current writable work cannot record a cleanup resolution") {
      _ = try store.recordImportResolution(work, resolution: resolution)
    }
    _ = try store.update(id: job.id, revision: 1) { try $0.cancel(nowMs: 1060) }
    try rejects("unpublished work cannot claim historical Isar completion") {
      _ = try store.recordImportResolution(work,
        resolution: LokalTransferImportResolution(mode: .committed, abandonment: nil))
    }
    let before = try store.snapshot()
    let process = try custodyChild(["--resolution-worker", directory.path, job.id, boundary])
    process.waitUntilExit()
    try require(process.terminationStatus == (boundary == "none" ? 0 : 96),
      "resolution child reaches the actual SQLite commit edge")
    let reopened = try LokalTransferJournal(container: directory)
    let after = try reopened.snapshot()
    let committed = boundary != "beforeCommit"
    try require(after.jobs == before.jobs && after.custodies.count == 1 &&
      after.custodies[0].resolution == (committed ? resolution : nil) &&
      after.generation == before.generation + (committed ? 1 : 0),
      "cleanup resolution crash keeps complete old/new provenance and unchanged live job")
    let recorded = try reopened.recordImportResolution(work, resolution: resolution)
    let generation = try reopened.snapshot().generation
    try require(reopened.recordImportResolution(work, resolution: resolution) == recorded &&
      reopened.snapshot().generation == generation,
      "lost resolution reply is idempotent without another observable generation")
    try rejects("recorded resolution cannot authorize public abandonment again") {
      try reopened.validateAbandonment(recorded)
    }
    try rejects("a contradictory resolution cannot rewrite the cleanup decision") {
      _ = try reopened.recordImportResolution(work,
        resolution: LokalTransferImportResolution(mode: .committed, abandonment: nil))
    }
    let document = try JSONEncoder().encode(recorded)
    var future = try JSONSerialization.jsonObject(with: document) as! [String: Any]
    future["resolution"] = ["mode": "abandoned", "abandonment": "missingFile", "future": true]
    try rejects("unknown resolution fields cannot be discarded during decoding") {
      _ = try LokalTransferImportCustody.decode(JSONSerialization.data(withJSONObject: future))
    }
  }

  let boundedRoot = try root("bounded")
  let boundedStore = try LokalTransferJournal(container: boundedRoot)
  let text = String(repeating: "a", count: 4096)
  let bulkyJobs = try (0..<740).map { index in
    try LokalTransferJob(direction: .download, identity: LokalTransferIdentity(desktopID: "paired-pc",
      sourceID: "bounded-\(index)", localSongID: String(index + 1), origin: "http://192.168.1.2:5443"),
      metadata: LokalTransferMetadata(title: text, artist: text, album: text, fileExtension: "flac",
        albumArtist: text, genre: text), nowMs: 1000, expectedBytes: 12,
      expectedSHA256: String(repeating: "a", count: 64))
  }
  try boundedStore.create(bulkyJobs)
  var reachedLimit = false, reserved = 0
  for (index, job) in bulkyJobs.enumerated() {
    try boundedStore.update(id: job.id, revision: 1) { try $0.bind(taskID: 1, nowMs: 1010) }
    try boundedStore.update(id: job.id, revision: 1) {
      try $0.retainDownload(taskID: 1, bytes: 12, sha256: String(repeating: "a", count: 64), nowMs: 1020)
    }
    try boundedStore.update(id: job.id, revision: 1) { try $0.transition(to: .validating, nowMs: 1030) }
    do {
      _ = try boundedStore.reserveImport(id: job.id, revision: 1, songID: Int64(index + 1))
      reserved += 1
    } catch LokalTransferError.limitExceeded {
      reachedLimit = true
      try require(boundedStore.importCustody(id: job.id, revision: 1) == nil,
        "capacity refusal rolls back the entire reservation")
      break
    }
  }
  let bounded = try LokalTransferJournal(container: boundedRoot).snapshot()
  try require(reachedLimit && reserved > 0 && bounded.custodies.count == reserved && bounded.jobs.count == bulkyJobs.count,
    "actual job and custody bytes share one bounded journal budget without losing prior work")
  print("Native import-custody contracts passed: actual v1 migration and two migration crash boundaries, reservation crashes, six-process migration/reservation, immutable song binding, cancel/retry proof retention, actual shared byte limit and corrupt/future preservation. File identity/publication and Isar coordination remain pending.")
}
