import Foundation
import SQLite3
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Immutable work identity retained independently from a cancellable job's
/// current revision. This is not proof that a file or library row exists.
struct LokalTransferImportCustody: Codable, Equatable, Sendable {
  static let maximumJSONBytes = LokalTransferJob.maximumJSONBytes + 2048
  let schemaVersion: Int
  let job: LokalTransferJob
  let songID: Int64
  var location: LokalTransferLibraryLocation?
  var copyNonce: String?
  var publication: LokalTransferLibraryPublication?
  var stagingRetired: Bool?

  init(job: LokalTransferJob, songID: Int64) throws {
    schemaVersion = 1; self.job = job; self.songID = songID
    try validate()
  }

  func validate() throws {
    try job.validate()
    guard schemaVersion == 1, songID > 0, job.direction == .download,
          [.validating, .importing].contains(job.phase),
          job.receivedBytes != nil, job.receivedSHA256 != nil else {
      throw LokalTransferError.invalidRecord
    }
    guard (location == nil) == (copyNonce == nil), publication == nil || location != nil,
          stagingRetired != true || publication != nil else {
      throw LokalTransferError.invalidRecord
    }
    try location?.validate()
    if let copyNonce {
      guard UUID(uuidString: copyNonce)?.uuidString.lowercased() == copyNonce else { throw LokalTransferError.invalidRecord }
    }
    if let publication {
      try publication.validate()
      guard publication.nonce == copyNonce else { throw LokalTransferError.invalidRecord }
    }
    if let requested = job.identity.localSongID {
      guard requested == String(songID) else { throw LokalTransferError.invalidRecord }
    }
  }

  static func decode(_ data: Data) throws -> Self {
    guard !data.isEmpty, data.count <= maximumJSONBytes,
          let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(row.keys).isSubset(of: ["schemaVersion", "job", "songID", "location", "copyNonce", "publication", "stagingRetired"]),
          Set(["schemaVersion", "job", "songID"]).isSubset(of: Set(row.keys)),
          let job = row["job"] as? [String: Any] else { throw LokalTransferError.invalidRecord }
    for (key, allowed) in [("location", LokalTransferLibraryLocation.keys),
                           ("publication", LokalTransferLibraryPublication.keys)] {
      if let nested = row[key], !(nested is NSNull) {
        guard let fields = nested as? [String: Any], Set(fields.keys).isSubset(of: allowed) else {
          throw LokalTransferError.invalidRecord
        }
      }
    }
    _ = try LokalTransferJob.decodeDocument(JSONSerialization.data(withJSONObject: job))
    let value = try JSONDecoder().decode(Self.self, from: data)
    try value.validate()
    return value
  }

  func matches(_ current: LokalTransferJob) -> Bool {
    job.id == current.id && job.revision == current.revision &&
    job.direction == current.direction && job.identity == current.identity &&
    job.metadata == current.metadata && job.createdMs == current.createdMs &&
    job.expectedBytes == current.expectedBytes && job.expectedSHA256 == current.expectedSHA256 &&
    job.receivedBytes == current.receivedBytes && job.receivedSHA256 == current.receivedSHA256
  }
}

/// One native transaction owns each job mutation and its observable generation.
/// WAL commits update the affected job, rather than rewriting a library-sized
/// manifest on every transition. Dart never writes this database directly.
final class LokalTransferJournal: @unchecked Sendable {
  private struct Usage {
    var generation: Int64
    var count: Int64
    var bytes: Int64
    var custodyCount: Int64
    var custodyBytes: Int64
  }

  static let directoryName = "LokalTransfers-v1"
  static let databaseName = "jobs.sqlite3"
  static let maximumBytes = 16 * 1024 * 1024
  static let maximumJobs = 10_000
  static let schemaVersion: Int64 = 2
  private static let maximumJobBytes = LokalTransferJob.maximumJSONBytes
  private let directory: Int32
  private let root: URL
  private let database: OpaquePointer
  private let mutex = NSLock()
  private let testingCommitBoundary: (@Sendable (String) -> Void)?

  init(container: URL, testingCommitBoundary: (@Sendable (String) -> Void)? = nil) throws {
    guard container.isFileURL else { throw LokalTransferError.unsafeFile }
    let base = open(container.standardizedFileURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard base >= 0 else { throw LokalTransferError.posix("open_container", errno) }
    defer { close(base) }
    // Apple exposes /var as an OS alias for /private/var. SQLite NOFOLLOW
    // rejects aliases anywhere in the full pathname, including that trusted
    // parent. Resolve parents only after refusing a final-container symlink,
    // and prove the canonical pathname identifies our already opened directory.
    // Use the POSIX pathname verbatim. Foundation's URL standardization on
    // Apple platforms can reintroduce OS aliases after resolving a file URL.
    guard let canonicalBytes = realpath(container.path, nil) else {
      throw LokalTransferError.posix("resolve_container", errno)
    }
    let canonicalPath = String(cString: canonicalBytes)
    free(canonicalBytes)
    let resolved = open(canonicalPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard resolved >= 0 else { throw LokalTransferError.unsafeFile }
    defer { close(resolved) }
    var originalInfo = stat(), resolvedInfo = stat()
    guard fstat(base, &originalInfo) == 0, fstat(resolved, &resolvedInfo) == 0,
          originalInfo.st_dev == resolvedInfo.st_dev, originalInfo.st_ino == resolvedInfo.st_ino else {
      throw LokalTransferError.unsafeFile
    }
    if mkdirat(base, Self.directoryName, 0o700) != 0 && errno != EEXIST {
      throw LokalTransferError.posix("create_directory", errno)
    }
    let owned = openat(base, Self.directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard owned >= 0 else { throw LokalTransferError.posix("open_directory", errno) }
    let rootPath = canonicalPath + "/" + Self.directoryName
    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
    do {
      for name in [Self.databaseName, Self.databaseName + "-wal", Self.databaseName + "-shm", "jobs.json"] {
        try Self.checkRegular(directory: owned, name: name)
      }
      var legacy = stat()
      if fstatat(owned, "jobs.json", &legacy, AT_SYMLINK_NOFOLLOW) == 0 {
        // The unreleased JSON prototype is never silently replaced by an empty DB.
        throw LokalTransferError.unsupportedSchema
      }
      #if os(iOS) && !targetEnvironment(simulator)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: rootPath)
      #endif
    } catch { close(owned); throw error }
    var opened: OpaquePointer?
    let code = sqlite3_open_v2(rootPath + "/" + Self.databaseName, &opened,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
    guard code == SQLITE_OK, let opened else {
      let detail = opened.map { sqlite3_extended_errcode($0) } ?? code
      if let opened { sqlite3_close_v2(opened) }
      close(owned)
      throw LokalTransferError.database(detail)
    }
    directory = owned
    self.root = root
    database = opened
    self.testingCommitBoundary = testingCommitBoundary
    do {
      try check(sqlite3_busy_timeout(database, 10_000))
      try execute("PRAGMA synchronous=FULL")
      let version = try scalar("PRAGMA user_version")
      guard (0...Self.schemaVersion).contains(version) else { throw LokalTransferError.unsupportedSchema }
      if version < Self.schemaVersion {
        try execute("BEGIN IMMEDIATE")
        do {
          if try scalar("PRAGMA user_version") == 0 {
            guard try scalar("SELECT count(*) FROM sqlite_master WHERE type='table'") == 0 else {
              throw LokalTransferError.unsupportedSchema
            }
            try execute("CREATE TABLE metadata (id INTEGER PRIMARY KEY CHECK(id=1), generation INTEGER NOT NULL CHECK(typeof(generation)='integer' AND generation>=0), job_count INTEGER NOT NULL CHECK(typeof(job_count)='integer' AND job_count>=0), byte_count INTEGER NOT NULL CHECK(typeof(byte_count)='integer' AND byte_count>=0))")
            try execute("INSERT INTO metadata VALUES (1,0,0,0)")
            try execute("CREATE TABLE jobs (id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>0), document BLOB NOT NULL CHECK(typeof(document)='blob'))")
            try execute("CREATE TABLE pauses (desktop_id TEXT NOT NULL, origin TEXT NOT NULL, pairing_id TEXT NOT NULL, reason TEXT NOT NULL, PRIMARY KEY(desktop_id,origin,pairing_id))")
            try execute("PRAGMA user_version=1")
          }
          let migrating = try scalar("PRAGMA user_version")
          guard migrating == 1 || migrating == Self.schemaVersion else {
            throw LokalTransferError.unsupportedSchema
          }
          if migrating == 1 {
            try execute("ALTER TABLE metadata ADD COLUMN custody_count INTEGER NOT NULL DEFAULT 0 CHECK(typeof(custody_count)='integer' AND custody_count>=0)")
            try execute("ALTER TABLE metadata ADD COLUMN custody_bytes INTEGER NOT NULL DEFAULT 0 CHECK(typeof(custody_bytes)='integer' AND custody_bytes>=0)")
            try execute("CREATE TABLE import_custody (id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>0), document BLOB NOT NULL CHECK(typeof(document)='blob'), PRIMARY KEY(id,revision))")
            try execute("PRAGMA user_version=2")
          }
          testingCommitBoundary?("beforeMigrationCommit")
          try execute("COMMIT")
          testingCommitBoundary?("afterMigrationCommit")
        } catch { try? execute("ROLLBACK"); throw error }
      }
      guard try scalar("PRAGMA user_version") == Self.schemaVersion else { throw LokalTransferError.unsupportedSchema }
      try execute("PRAGMA trusted_schema=OFF")
      let mode = try statement("PRAGMA journal_mode=WAL")
      defer { sqlite3_finalize(mode) }
      guard sqlite3_step(mode) == SQLITE_ROW, try text(mode, 0) == "wal" else {
        throw LokalTransferError.invalidRecord
      }
      try execute("PRAGMA synchronous=FULL")
      try execute("PRAGMA wal_autocheckpoint=256")
      guard fchmodat(directory, Self.databaseName, 0o600, 0) == 0 else {
        throw LokalTransferError.posix("protect_database", errno)
      }
    } catch {
      sqlite3_close_v2(database)
      close(directory)
      throw error
    }
  }

  deinit { sqlite3_close_v2(database); close(directory) }

  private func check(_ code: Int32) throws {
    guard code == SQLITE_OK else { throw LokalTransferError.database(code) }
  }

  private func execute(_ sql: String) throws {
    try check(sqlite3_exec(database, sql, nil, nil, nil))
  }

  private func statement(_ sql: String) throws -> OpaquePointer {
    var result: OpaquePointer?
    try check(sqlite3_prepare_v2(database, sql, -1, &result, nil))
    guard let result else { throw LokalTransferError.invalidRecord }
    return result
  }

  private func scalar(_ sql: String) throws -> Int64 {
    let query = try statement(sql)
    defer { sqlite3_finalize(query) }
    guard sqlite3_step(query) == SQLITE_ROW, sqlite3_column_type(query, 0) == SQLITE_INTEGER else {
      throw LokalTransferError.invalidRecord
    }
    return sqlite3_column_int64(query, 0)
  }

  private func bind(_ text: String, at index: Int32, to query: OpaquePointer) throws {
    try check(text.withCString { sqlite3_bind_text(query, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) })
  }

  private func bind(_ data: Data, at index: Int32, to query: OpaquePointer) throws {
    try check(data.withUnsafeBytes { sqlite3_bind_blob(query, index, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) })
  }

  private func usage() throws -> Usage {
    guard try scalar("PRAGMA user_version") == Self.schemaVersion else { throw LokalTransferError.unsupportedSchema }
    let query = try statement("SELECT generation,job_count,byte_count,custody_count,custody_bytes FROM metadata WHERE id=1")
    defer { sqlite3_finalize(query) }
    guard sqlite3_step(query) == SQLITE_ROW,
          (0...4).allSatisfy({ sqlite3_column_type(query, Int32($0)) == SQLITE_INTEGER }) else {
      throw LokalTransferError.invalidRecord
    }
    let value = Usage(generation: sqlite3_column_int64(query, 0), count: sqlite3_column_int64(query, 1),
      bytes: sqlite3_column_int64(query, 2), custodyCount: sqlite3_column_int64(query, 3),
      custodyBytes: sqlite3_column_int64(query, 4))
    guard value.generation >= 0, value.generation < Int64.max,
          value.count >= 0, value.count <= Self.maximumJobs,
          value.bytes >= 0, value.bytes <= Self.maximumBytes,
          value.custodyCount >= 0, value.custodyCount <= Self.maximumJobs,
          value.custodyBytes >= 0, value.custodyBytes <= Self.maximumBytes,
          value.bytes + value.custodyBytes <= Self.maximumBytes else { throw LokalTransferError.invalidRecord }
    return value
  }

  private static func checkRegular(directory: Int32, name: String) throws {
    // SQLite's POSIX locks are process-scoped. Opening then closing another
    // descriptor for its database/SHM inode can release those locks while a
    // live connection still owns a transaction. Inspect metadata without an
    // extra descriptor; SQLite retains sole ownership of its file handles.
    var info = stat()
    if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
      if errno == ENOENT { return }
      throw LokalTransferError.posix("inspect_database_file", errno)
    }
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else {
      throw LokalTransferError.unsafeFile
    }
  }

  private func preflight() throws {
    let current = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard current >= 0 else { throw LokalTransferError.unsafeFile }
    defer { close(current) }
    var held = stat(), path = stat()
    guard fstat(directory, &held) == 0, fstat(current, &path) == 0,
          held.st_dev == path.st_dev, held.st_ino == path.st_ino else { throw LokalTransferError.unsafeFile }
    for name in [Self.databaseName, Self.databaseName + "-wal", Self.databaseName + "-shm"] {
      try Self.checkRegular(directory: directory, name: name)
    }
  }

  private func locked<T>(_ operation: () throws -> T) rethrows -> T {
    mutex.lock()
    defer { mutex.unlock() }
    return try operation()
  }

  private func transaction<T>(_ operation: (inout Usage) throws -> T) throws -> T {
    try locked {
      try preflight()
      try execute("BEGIN IMMEDIATE")
      do {
        var current = try usage()
        let result = try operation(&current)
        guard current.count <= Self.maximumJobs, current.custodyCount <= Self.maximumJobs,
              current.bytes + current.custodyBytes <= Self.maximumBytes else {
          throw LokalTransferError.limitExceeded
        }
        let query = try statement("UPDATE metadata SET generation=?,job_count=?,byte_count=?,custody_count=?,custody_bytes=? WHERE id=1")
        defer { sqlite3_finalize(query) }
        try check(sqlite3_bind_int64(query, 1, current.generation + 1))
        try check(sqlite3_bind_int64(query, 2, current.count))
        try check(sqlite3_bind_int64(query, 3, current.bytes))
        try check(sqlite3_bind_int64(query, 4, current.custodyCount))
        try check(sqlite3_bind_int64(query, 5, current.custodyBytes))
        guard sqlite3_step(query) == SQLITE_DONE else { throw LokalTransferError.database(sqlite3_errcode(database)) }
        testingCommitBoundary?("beforeCommit")
        try execute("COMMIT")
        testingCommitBoundary?("afterCommit")
        return result
      } catch { try? execute("ROLLBACK"); throw error }
    }
  }

  private func encoded(_ job: LokalTransferJob) throws -> Data {
    try job.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(job)
    guard data.count <= Self.maximumJobBytes else { throw LokalTransferError.limitExceeded }
    return data
  }

  private func decoded(_ query: OpaquePointer, blobColumn: Int32 = 2) throws -> (LokalTransferJob, Int) {
    guard let idBytes = sqlite3_column_text(query, 0),
          sqlite3_column_bytes(query, 0) == 36,
          let id = String(data: Data(bytes: idBytes, count: 36), encoding: .utf8),
          sqlite3_column_type(query, 1) == SQLITE_INTEGER,
          sqlite3_column_type(query, blobColumn) == SQLITE_BLOB else { throw LokalTransferError.invalidRecord }
    let count = Int(sqlite3_column_bytes(query, blobColumn))
    guard count > 0, count <= Self.maximumJobBytes,
          let bytes = sqlite3_column_blob(query, blobColumn) else { throw LokalTransferError.invalidRecord }
    let data = Data(bytes: bytes, count: count)
    let job = try LokalTransferJob.decodeDocument(data)
    guard job.id == id, job.revision == sqlite3_column_int64(query, 1) else { throw LokalTransferError.invalidRecord }
    return (job, count)
  }

  func snapshot() throws -> (generation: Int, jobs: [LokalTransferJob], pauses: [LokalTransferPause], custodies: [LokalTransferImportCustody]) {
    try locked {
      try preflight()
      try execute("BEGIN")
      do {
        let current = try usage()
        let query = try statement("SELECT id,revision,document FROM jobs ORDER BY rowid")
        defer { sqlite3_finalize(query) }
        var jobs: [LokalTransferJob] = [], bytes = 0
        while true {
          let code = sqlite3_step(query)
          if code == SQLITE_DONE { break }
          guard code == SQLITE_ROW else { throw LokalTransferError.database(code) }
          let (job, size) = try decoded(query)
          jobs.append(job)
          bytes += size
          guard jobs.count <= Self.maximumJobs, bytes <= Self.maximumBytes else { throw LokalTransferError.limitExceeded }
        }
        guard jobs.count == current.count, bytes == current.bytes else { throw LokalTransferError.invalidRecord }
        let custodies = try readCustodies()
        guard custodies.values.count == current.custodyCount, custodies.bytes == current.custodyBytes else {
          throw LokalTransferError.invalidRecord
        }
        let pauses = try readPauses()
        try execute("COMMIT")
        return (Int(current.generation), jobs, pauses, custodies.values)
      } catch { try? execute("ROLLBACK"); throw error }
    }
  }

  func create(_ jobs: [LokalTransferJob]) throws {
    guard !jobs.isEmpty else { return }
    guard Set(jobs.map(\.id)).count == jobs.count else { throw LokalTransferError.duplicateJob }
    let documents = try jobs.map { job -> Data in
      guard job.phase == .queued, job.revision == 1 else { throw LokalTransferError.invalidRecord }
      return try encoded(job)
    }
    try transaction { current in
      current.count += Int64(jobs.count)
      current.bytes += Int64(documents.reduce(0) { $0 + $1.count })
      guard current.count <= Self.maximumJobs, current.custodyCount <= Self.maximumJobs,
              current.bytes + current.custodyBytes <= Self.maximumBytes else { throw LokalTransferError.limitExceeded }
      let insert = try statement("INSERT INTO jobs(id,revision,document) VALUES(?,?,?)")
      defer { sqlite3_finalize(insert) }
      for (index, job) in jobs.enumerated() {
        try check(sqlite3_reset(insert))
        try bind(job.id, at: 1, to: insert)
        try check(sqlite3_bind_int64(insert, 2, Int64(job.revision)))
        try bind(documents[index], at: 3, to: insert)
        let code = sqlite3_step(insert)
        if code == SQLITE_CONSTRAINT { throw LokalTransferError.duplicateJob }
        guard code == SQLITE_DONE else { throw LokalTransferError.database(code) }
      }
    }
  }

  @discardableResult
  func update(id: String, revision: Int, pausingScope: LokalTransferPause? = nil,
              acknowledging expectedCustody: LokalTransferImportCustody? = nil,
              _ operation: (inout LokalTransferJob) throws -> Void) throws -> LokalTransferJob {
    try transaction { current in
      let select = try statement("SELECT id,revision,document FROM jobs WHERE id=?")
      defer { sqlite3_finalize(select) }
      try bind(id, at: 1, to: select)
      let code = sqlite3_step(select)
      if code == SQLITE_DONE { throw LokalTransferError.missingJob }
      guard code == SQLITE_ROW else { throw LokalTransferError.database(code) }
      let (previous, oldBytes) = try decoded(select)
      guard previous.revision == revision else { throw LokalTransferError.staleRevision }
      if let expectedCustody {
        // The completion transition and exact frozen publication witness are
        // checked in one native writer transaction. Never infer an Isar commit.
        guard let (stored, _) = try selectCustody(id: id, revision: revision),
              stored == expectedCustody, stored.matches(previous),
              stored.publication != nil, [.importing, .complete].contains(previous.phase) else {
          throw LokalTransferError.staleRevision
        }
      }
      var job = previous
      try operation(&job)
      guard job.id == previous.id, job.direction == previous.direction,
            job.identity == previous.identity, job.metadata == previous.metadata,
            job.createdMs == previous.createdMs, job.expectedBytes == previous.expectedBytes,
            job.expectedSHA256 == previous.expectedSHA256, job.revision >= previous.revision,
            job.revision <= previous.revision + 1, job.updatedMs >= previous.updatedMs else {
        throw LokalTransferError.invalidRecord
      }
      let data = try encoded(job)
      current.bytes += Int64(data.count - oldBytes)
      let change = try statement("UPDATE jobs SET revision=?,document=? WHERE id=? AND revision=?")
      defer { sqlite3_finalize(change) }
      try check(sqlite3_bind_int64(change, 1, Int64(job.revision)))
      try bind(data, at: 2, to: change)
      try bind(id, at: 3, to: change)
      try check(sqlite3_bind_int64(change, 4, Int64(revision)))
      guard sqlite3_step(change) == SQLITE_DONE else { throw LokalTransferError.database(sqlite3_errcode(database)) }
      guard sqlite3_changes(database) == 1 else { throw LokalTransferError.staleRevision }
      if let pausingScope {
        guard pausingScope.scope.desktopID == job.identity.desktopID,
              pausingScope.scope.origin == job.identity.origin,
              pausingScope.scope.pairingID == job.identity.pairingID,
              job.lastFailure == pausingScope.reason else { throw LokalTransferError.invalidRecord }
        try writePause(pausingScope)
      }
      return job
    }
  }

  private func decodedCustody(_ query: OpaquePointer) throws -> (LokalTransferImportCustody, Int) {
    let id = try text(query, 0)
    guard sqlite3_column_type(query, 1) == SQLITE_INTEGER,
          sqlite3_column_type(query, 2) == SQLITE_BLOB else { throw LokalTransferError.invalidRecord }
    let size = Int(sqlite3_column_bytes(query, 2))
    guard size > 0, size <= LokalTransferImportCustody.maximumJSONBytes,
          let bytes = sqlite3_column_blob(query, 2) else { throw LokalTransferError.invalidRecord }
    let value = try LokalTransferImportCustody.decode(Data(bytes: bytes, count: size))
    guard value.job.id == id, value.job.revision == sqlite3_column_int64(query, 1) else {
      throw LokalTransferError.invalidRecord
    }
    return (value, size)
  }

  private func readCustodies() throws -> (values: [LokalTransferImportCustody], bytes: Int64) {
    let query = try statement("SELECT id,revision,document FROM import_custody ORDER BY id,revision")
    defer { sqlite3_finalize(query) }
    var values: [LokalTransferImportCustody] = [], bytes: Int64 = 0
    while true {
      let code = sqlite3_step(query)
      if code == SQLITE_DONE { return (values, bytes) }
      guard code == SQLITE_ROW else { throw LokalTransferError.database(code) }
      let (value, size) = try decodedCustody(query)
      values.append(value); bytes += Int64(size)
      guard values.count <= Self.maximumJobs, bytes <= Self.maximumBytes else {
        throw LokalTransferError.limitExceeded
      }
    }
  }

  private func selectCustody(id: String, revision: Int) throws -> (LokalTransferImportCustody, Int)? {
    guard UUID(uuidString: id)?.uuidString.lowercased() == id, revision > 0 else {
      throw LokalTransferError.invalidRecord
    }
    let query = try statement("SELECT id,revision,document FROM import_custody WHERE id=? AND revision=?")
    defer { sqlite3_finalize(query) }
    try bind(id, at: 1, to: query)
    try check(sqlite3_bind_int64(query, 2, Int64(revision)))
    let code = sqlite3_step(query)
    if code == SQLITE_DONE { return nil }
    guard code == SQLITE_ROW else { throw LokalTransferError.database(code) }
    return try decodedCustody(query)
  }

  /// Keyset pagination is independent of deletion/insertion before the cursor.
  /// Read at most limit rows plus one lookahead; never encode the whole journal.
  func custodyPage(after: String?, limit: Int) throws ->
      (generation: Int, values: [LokalTransferImportCustody], nextCursor: String?) {
    guard (1...100).contains(limit), after == nil || LokalTransferTaskBinding(after!) != nil else {
      throw LokalTransferError.invalidRecord
    }
    let cursor = after.flatMap(LokalTransferTaskBinding.init)
    return try locked {
      try preflight(); try execute("BEGIN")
      do {
        let current = try usage()
        let sql = cursor == nil ?
          "SELECT id,revision,document FROM import_custody ORDER BY id,revision LIMIT ?" :
          "SELECT id,revision,document FROM import_custody WHERE (id,revision)>(?,?) ORDER BY id,revision LIMIT ?"
        let query = try statement(sql)
        defer { sqlite3_finalize(query) }
        var parameter: Int32 = 1
        if let cursor {
          try bind(cursor.id, at: 1, to: query)
          try check(sqlite3_bind_int64(query, 2, Int64(cursor.revision))); parameter = 3
        }
        try check(sqlite3_bind_int(query, parameter, Int32(limit + 1)))
        var values: [LokalTransferImportCustody] = [], more = false
        while true {
          let code = sqlite3_step(query)
          if code == SQLITE_DONE { break }
          guard code == SQLITE_ROW else { throw LokalTransferError.database(code) }
          if values.count == limit { more = true; break }
          values.append(try decodedCustody(query).0)
        }
        let next = more ? values.last.map { $0.job.id + ":" + String($0.job.revision) } : nil
        try execute("COMMIT")
        return (Int(current.generation), values, next)
      } catch { try? execute("ROLLBACK"); throw error }
    }
  }

  /// Reserve before any library publication. A cancelled/retried job cannot
  /// erase this frozen revision's proof or silently adopt a different song ID.
  /// Only the private native publisher calls this after writer validation;
  /// product import remains disabled until its root coordinator is accepted.
  func reserveImport(id: String, revision: Int, songID: Int64) throws -> LokalTransferImportCustody {
    try transaction { current in
      let query = try statement("SELECT id,revision,document FROM jobs WHERE id=?")
      defer { sqlite3_finalize(query) }
      try bind(id, at: 1, to: query)
      let code = sqlite3_step(query)
      if code == SQLITE_DONE { throw LokalTransferError.missingJob }
      guard code == SQLITE_ROW else { throw LokalTransferError.database(code) }
      let (job, _) = try decoded(query)
      guard job.revision == revision else { throw LokalTransferError.staleRevision }
      let value = try LokalTransferImportCustody(job: job, songID: songID)
      if let (previous, _) = try selectCustody(id: id, revision: revision) {
        guard previous.songID == songID, previous.matches(job) else { throw LokalTransferError.staleRevision }
        return previous
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(value)
      guard data.count <= LokalTransferImportCustody.maximumJSONBytes else { throw LokalTransferError.limitExceeded }
      current.custodyCount += 1; current.custodyBytes += Int64(data.count)
      let insert = try statement("INSERT INTO import_custody(id,revision,document) VALUES(?,?,?)")
      defer { sqlite3_finalize(insert) }
      try bind(id, at: 1, to: insert)
      try check(sqlite3_bind_int64(insert, 2, Int64(revision)))
      try bind(data, at: 3, to: insert)
      guard sqlite3_step(insert) == SQLITE_DONE else { throw LokalTransferError.database(sqlite3_errcode(database)) }
      return value
    }
  }

  /// Caller holds the library writer lock and has validated native write
  /// authority. Neither these methods nor the proof document accept Dart paths.
  func bindImportLocation(_ expected: LokalTransferImportCustody,
                          location: LokalTransferLibraryLocation) throws -> LokalTransferImportCustody {
    try mutateImportCustody(expected) { value in
      if let previous = value.location {
        guard previous == location else { throw LokalTransferError.unsafeFile }
      } else {
        value.location = location
        value.copyNonce = UUID().uuidString.lowercased()
      }
    }
  }

  func recordImportPublication(_ expected: LokalTransferImportCustody,
                               proof: LokalTransferLibraryPublication) throws -> LokalTransferImportCustody {
    try mutateImportCustody(expected) { value in
      guard value.location != nil, proof.nonce == value.copyNonce else { throw LokalTransferError.invalidRecord }
      value.publication = proof
    }
  }

  /// Only after actual private file cleanup. This is separate from the earlier
  /// app-attested library commit, so a crash between them remains recoverable.
  func recordImportStagingRetired(_ expected: LokalTransferImportCustody) throws -> LokalTransferImportCustody {
    guard expected.publication != nil else { throw LokalTransferError.invalidRecord }
    return try mutateImportCustody(expected, phase: .complete) { $0.stagingRetired = true }
  }

  private func mutateImportCustody(_ expected: LokalTransferImportCustody,
                                  phase: LokalTransferPhase = .validating,
                                  _ operation: (inout LokalTransferImportCustody) throws -> Void) throws -> LokalTransferImportCustody {
    try expected.validate()
    return try transaction { current in
      guard let (previous, oldSize) = try selectCustody(id: expected.job.id, revision: expected.job.revision),
            previous == expected else { throw LokalTransferError.staleRevision }
      let query = try statement("SELECT id,revision,document FROM jobs WHERE id=?")
      defer { sqlite3_finalize(query) }
      try bind(expected.job.id, at: 1, to: query)
      guard sqlite3_step(query) == SQLITE_ROW else { throw LokalTransferError.missingJob }
      let (job, _) = try decoded(query)
      guard previous.matches(job), job.phase == phase else { throw LokalTransferError.staleRevision }
      var next = previous
      try operation(&next)
      try next.validate()
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(next)
      guard data.count <= LokalTransferImportCustody.maximumJSONBytes else { throw LokalTransferError.limitExceeded }
      let change = try statement("UPDATE import_custody SET document=? WHERE id=? AND revision=?")
      defer { sqlite3_finalize(change) }
      try bind(data, at: 1, to: change)
      try bind(expected.job.id, at: 2, to: change)
      try check(sqlite3_bind_int64(change, 3, Int64(expected.job.revision)))
      guard sqlite3_step(change) == SQLITE_DONE, sqlite3_changes(database) == 1 else {
        throw LokalTransferError.database(sqlite3_errcode(database))
      }
      current.custodyBytes += Int64(data.count - oldSize)
      return next
    }
  }

  func importCustody(id: String, revision: Int) throws -> LokalTransferImportCustody? {
    try locked {
      try preflight()
      _ = try usage()
      return try selectCustody(id: id, revision: revision)?.0
    }
  }

  /// Read-only cleanup preflight, separate from publication authority. A caller
  /// must also own the current root cleanup token and an Isar retiring receipt.
  /// Missing/changed custody and completed/current writable jobs are refused.
  func validateAbandonment(_ expected: LokalTransferImportCustody) throws {
    try expected.validate()
    try locked {
      try preflight()
      try execute("BEGIN")
      do {
        guard let (stored, _) = try selectCustody(id: expected.job.id, revision: expected.job.revision),
              stored == expected else { throw LokalTransferError.staleRevision }
        let query = try statement("SELECT id,revision,document FROM jobs WHERE id=?")
        defer { sqlite3_finalize(query) }
        try bind(expected.job.id, at: 1, to: query)
        guard sqlite3_step(query) == SQLITE_ROW else { throw LokalTransferError.missingJob }
        let (current, _) = try decoded(query)
        guard current.phase != .complete, current.revision > expected.job.revision,
              current.direction == expected.job.direction,
              current.identity == expected.job.identity,
              current.metadata == expected.job.metadata,
              current.createdMs == expected.job.createdMs,
              current.expectedBytes == expected.job.expectedBytes,
              current.expectedSHA256 == expected.job.expectedSHA256 else {
          throw LokalTransferError.invalidTransition
        }
        try execute("COMMIT")
      } catch { try? execute("ROLLBACK"); throw error }
    }
  }

  /// Caller must first drain native file work and serialize behind the Isar
  /// writer to decide whether an owned copy committed. This removes bookkeeping
  /// only, never a file or Song; a revoked UI lease is neither needed nor enough.
  func removeImportCustody(_ expected: LokalTransferImportCustody) throws {
    try expected.validate()
    try transaction { current in
      guard let (existing, size) = try selectCustody(id: expected.job.id, revision: expected.job.revision) else { return }
      guard existing == expected else { throw LokalTransferError.staleRevision }
      let query = try statement("DELETE FROM import_custody WHERE id=? AND revision=?")
      defer { sqlite3_finalize(query) }
      try bind(expected.job.id, at: 1, to: query)
      try check(sqlite3_bind_int64(query, 2, Int64(expected.job.revision)))
      guard sqlite3_step(query) == SQLITE_DONE, sqlite3_changes(database) == 1 else {
        throw LokalTransferError.database(sqlite3_errcode(database))
      }
      current.custodyCount -= 1; current.custodyBytes -= Int64(size)
    }
  }

  private func text(_ query: OpaquePointer, _ column: Int32, allowEmpty: Bool = false) throws -> String {
    let count = Int(sqlite3_column_bytes(query, column))
    guard sqlite3_column_type(query, column) == SQLITE_TEXT, (allowEmpty || count > 0), count <= 4096,
          let pointer = sqlite3_column_text(query, column),
          let value = String(data: Data(bytes: pointer, count: count), encoding: .utf8) else {
      throw LokalTransferError.invalidRecord
    }
    return value
  }

  private func readPauses() throws -> [LokalTransferPause] {
    let query = try statement("SELECT desktop_id,origin,pairing_id,reason FROM pauses ORDER BY desktop_id,origin,pairing_id")
    defer { sqlite3_finalize(query) }
    var result: [LokalTransferPause] = []
    while true {
      let code = sqlite3_step(query)
      if code == SQLITE_DONE { return result }
      guard code == SQLITE_ROW, result.count < 64 else { throw LokalTransferError.invalidRecord }
      let pairing = try text(query, 2, allowEmpty: true)
      let scope = LokalTransferScope(desktopID: try text(query, 0), origin: try text(query, 1),
        pairingID: pairing.isEmpty ? nil : pairing)
      try scope.validate()
      guard let reason = LokalTransferFailure(rawValue: try text(query, 3)) else { throw LokalTransferError.invalidRecord }
      result.append(LokalTransferPause(scope: scope, reason: reason))
    }
  }

  private func writePause(_ pause: LokalTransferPause) throws {
    try pause.scope.validate()
    guard pause.scope.origin.utf8.count <= 4096 else { throw LokalTransferError.invalidRecord }
    let query = try statement("INSERT INTO pauses(desktop_id,origin,pairing_id,reason) VALUES(?,?,?,?) ON CONFLICT(desktop_id,origin,pairing_id) DO UPDATE SET reason=excluded.reason")
    defer { sqlite3_finalize(query) }
    try bind(pause.scope.desktopID, at: 1, to: query)
    try bind(pause.scope.origin, at: 2, to: query)
    try bind(pause.scope.pairingID ?? "", at: 3, to: query)
    try bind(pause.reason.rawValue, at: 4, to: query)
    guard sqlite3_step(query) == SQLITE_DONE else { throw LokalTransferError.database(sqlite3_errcode(database)) }
    guard try scalar("SELECT count(*) FROM pauses") <= 64 else { throw LokalTransferError.limitExceeded }
  }

  func clearPause(_ scope: LokalTransferScope) throws {
    try scope.validate()
    try transaction { _ in
      let query = try statement("DELETE FROM pauses WHERE desktop_id=? AND origin=? AND pairing_id=?")
      defer { sqlite3_finalize(query) }
      try bind(scope.desktopID, at: 1, to: query)
      try bind(scope.origin, at: 2, to: query)
      try bind(scope.pairingID ?? "", at: 3, to: query)
      guard sqlite3_step(query) == SQLITE_DONE else { throw LokalTransferError.database(sqlite3_errcode(database)) }
    }
  }
}
