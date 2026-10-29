import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
@_silgen_name("flock")
private func flock(_ descriptor: Int32, _ operation: Int32) -> Int32
#endif

// The marker is written only to our newly created private copy, never to a
// caller/user file. Its random value is native bookkeeping, not a credential.
#if os(Linux)
@_silgen_name("fsetxattr")
private func importSetXattr(_ fd: Int32, _ name: UnsafePointer<CChar>, _ value: UnsafeRawPointer?, _ size: Int, _ flags: Int32) -> Int32
@_silgen_name("fgetxattr")
private func importGetXattr(_ fd: Int32, _ name: UnsafePointer<CChar>, _ value: UnsafeMutableRawPointer?, _ size: Int) -> Int
#endif

struct LokalTransferLibraryLocation: Codable, Equatable, Sendable {
  static let keys: Set<String> = ["rootDevice", "rootInode", "directoryDevice", "directoryInode"]
  let rootDevice, rootInode, directoryDevice, directoryInode: UInt64

  init(parent: Int32, directory: Int32) throws {
    var root = stat(), owned = stat()
    guard fstat(parent, &root) == 0, fstat(directory, &owned) == 0,
          root.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
          owned.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw LokalTransferError.unsafeFile }
    rootDevice = UInt64(truncatingIfNeeded: root.st_dev); rootInode = UInt64(root.st_ino)
    directoryDevice = UInt64(truncatingIfNeeded: owned.st_dev); directoryInode = UInt64(owned.st_ino)
    try validate()
  }
  func validate() throws {
    guard rootInode > 0, directoryInode > 0 else { throw LokalTransferError.invalidRecord }
  }
}

/// Native descriptor provenance, saved before linking a private copy into Music.
/// ctime is intentionally not durable identity: link/unlink updates it. Existing
/// content is still fully hashed and its ctime checked across the actual read.
struct LokalTransferLibraryPublication: Codable, Equatable, Sendable {
  static let keys: Set<String> = ["device", "inode", "generation", "modifiedSeconds", "modifiedNanos", "birthSeconds", "birthNanos", "nonce"]
  private static let marker = "user.app.lokal.import-owner"
  let device, inode, generation: UInt64
  let modifiedSeconds, modifiedNanos: Int64
  let birthSeconds, birthNanos: Int64?
  let nonce: String

  private init(info: stat, nonce: String) {
    device = UInt64(truncatingIfNeeded: info.st_dev); inode = UInt64(info.st_ino)
    self.nonce = nonce
    #if canImport(Darwin)
    generation = UInt64(info.st_gen)
    modifiedSeconds = Int64(info.st_mtimespec.tv_sec); modifiedNanos = Int64(info.st_mtimespec.tv_nsec)
    birthSeconds = Int64(info.st_birthtimespec.tv_sec); birthNanos = Int64(info.st_birthtimespec.tv_nsec)
    #else
    generation = 0
    modifiedSeconds = Int64(info.st_mtim.tv_sec); modifiedNanos = Int64(info.st_mtim.tv_nsec)
    birthSeconds = nil; birthNanos = nil
    #endif
  }

  func validate() throws {
    guard inode > 0, UUID(uuidString: nonce)?.uuidString.lowercased() == nonce,
          (0..<1_000_000_000).contains(modifiedNanos),
          (birthSeconds == nil) == (birthNanos == nil),
          birthNanos == nil || (0..<1_000_000_000).contains(birthNanos!) else {
      throw LokalTransferError.invalidRecord
    }
  }

  static func stamp(_ fd: Int32, nonce: String) throws -> Self {
    guard UUID(uuidString: nonce)?.uuidString.lowercased() == nonce else { throw LokalTransferError.invalidRecord }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          info.st_nlink == 1, info.st_size > 0 else { throw LokalTransferError.unsafeFile }
    let bytes = Array(nonce.utf8)
    let code = marker.withCString { name in bytes.withUnsafeBytes { value in
      #if canImport(Darwin)
      return fsetxattr(fd, name, value.baseAddress, value.count, 0, XATTR_CREATE)
      #else
      return importSetXattr(fd, name, value.baseAddress, value.count, 1)
      #endif
    } }
    guard code == 0 else { throw LokalTransferError.posix("mark_import_copy", errno) }
    guard fsync(fd) == 0, fstat(fd, &info) == 0 else { throw LokalTransferError.posix("sync_import_marker", errno) }
    let value = Self(info: info, nonce: nonce)
    try value.validate()
    return value
  }

  func verify(_ fd: Int32) throws -> stat {
    try validate()
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          info.st_nlink == 1 || info.st_nlink == 2,
          Self(info: info, nonce: nonce) == self else { throw LokalTransferError.unsafeFile }
    var bytes = [UInt8](repeating: 0, count: 37)
    let count = Self.marker.withCString { name in bytes.withUnsafeMutableBytes { value in
      #if canImport(Darwin)
      return fgetxattr(fd, name, value.baseAddress, value.count, 0, 0)
      #else
      return importGetXattr(fd, name, value.baseAddress, value.count)
      #endif
    } }
    guard count == 36, String(decoding: bytes.prefix(36), as: UTF8.self) == nonce else {
      throw LokalTransferError.unsafeFile
    }
    return info
  }
}

struct LokalTransferLibraryReceipt: Codable, Equatable, Sendable {
  let relativePath: String
  let bytes: Int64
  let sha256: String
}

enum LokalTransferLibraryAbandonment: String, Codable, Sendable {
  case removedOwnedFile, missingFile, preservedUserFile
}

private final class LokalTransferAbandonmentResult: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Result<LokalTransferLibraryAbandonment, Error>?
  func set(_ result: Result<LokalTransferLibraryAbandonment, Error>) {
    lock.lock(); defer { lock.unlock() }; value = result
  }
  func get() -> Result<LokalTransferLibraryAbandonment, Error>? {
    lock.lock(); defer { lock.unlock() }; return value
  }
}

/// Filesystem boundary only: this does not acknowledge a playable Isar row.
/// The app supplies its own Music root; no Flutter-supplied path is accepted.
/// One deterministic name per frozen job/revision survives lost acknowledgments.
final class LokalTransferLibrary: @unchecked Sendable {
  static let directoryName = "Desktop Copies"
  private let root: URL
  private let parent: Int32
  private let directory: Int32
  private let writer: Int32
  private let mutex = NSLock()
  private let testingBoundary: (@Sendable (String) -> Void)?

  init(root: URL, testingBoundary: (@Sendable (String) -> Void)? = nil) throws {
    testingBoundary?("initializeRoot")
    guard root.isFileURL else { throw LokalTransferError.unsafeFile }
    let parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw LokalTransferError.posix("open_music_root", errno) }
    if mkdirat(parent, Self.directoryName, 0o700) != 0 && errno != EEXIST {
      close(parent); throw LokalTransferError.posix("create_copy_directory", errno)
    }
    testingBoundary?("initializeDirectory")
    let directory = openat(parent, Self.directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { close(parent); throw LokalTransferError.unsafeFile }
    testingBoundary?("initializeWriter")
    // Exactly one constructor creates the lock inode. Other constructors open
    // that existing name without creation semantics; never unlink/recreate a
    // lock that another process might already hold.
    let flags = O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    var writer = openat(directory, ".lokal-import.lock", flags | O_CREAT | O_EXCL, 0o600)
    if writer < 0 {
      let creationError = errno
      guard creationError == EEXIST else {
        close(directory); close(parent)
        throw LokalTransferError.posix("create_library_lock", creationError)
      }
      testingBoundary?("openExistingWriter")
      writer = openat(directory, ".lokal-import.lock", flags)
    }
    guard writer >= 0 else {
      let openError = errno
      close(directory); close(parent)
      throw LokalTransferError.posix("open_library_lock", openError)
    }
    testingBoundary?("writerOpened")
    var info = stat(), named = stat()
    guard fstat(writer, &info) == 0 else {
      let statError = errno
      close(writer); close(directory); close(parent)
      throw LokalTransferError.posix("stat_library_lock", statError)
    }
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1,
          fstatat(directory, ".lokal-import.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
          named.st_dev == info.st_dev, named.st_ino == info.st_ino,
          named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), named.st_nlink == 1 else {
      testingBoundary?("unsafeWriter:type=\(info.st_mode & mode_t(S_IFMT)):links=\(info.st_nlink)")
      close(writer); close(directory); close(parent)
      throw LokalTransferError.unsafeFile
    }
    guard fsync(parent) == 0, fsync(directory) == 0 else {
      close(writer); close(directory); close(parent)
      throw LokalTransferError.posix("sync_copy_directory_creation", errno)
    }
    self.root = root
    self.parent = parent
    self.directory = directory
    self.writer = writer
    self.testingBoundary = testingBoundary
  }

  deinit { close(writer); close(directory); close(parent) }

  static func fileName(_ job: LokalTransferJob) throws -> String {
    try job.validate()
    let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\\/:*?\"<>|"))
    let cleaned = (job.metadata.artist + " - " + job.metadata.title).unicodeScalars.map {
      forbidden.contains($0) ? " " : String($0)
    }.joined().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    var stem = ""
    for character in cleaned {
      guard stem.utf8.count + character.utf8.count <= 120 else { break }
      stem.append(character)
    }
    if stem.isEmpty { stem = "Song" }
    return stem + " - " + job.id + "-r" + String(job.revision) + "." + job.metadata.fileExtension
  }

  private func checkRoot() throws {
    testingBoundary?("visibleRoot")
    let visibleParent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard visibleParent >= 0 else { throw LokalTransferError.unsafeFile }
    defer { close(visibleParent) }
    testingBoundary?("visibleDirectory")
    let visibleDirectory = openat(visibleParent, Self.directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard visibleDirectory >= 0 else { throw LokalTransferError.unsafeFile }
    defer { close(visibleDirectory) }
    testingBoundary?("rootAndWriterIdentity")
    var held = stat(), visible = stat(), heldParent = stat(), currentParent = stat(), lockInfo = stat(), lockPath = stat()
    guard fstat(directory, &held) == 0, fstat(visibleDirectory, &visible) == 0,
          fstat(parent, &heldParent) == 0, fstat(visibleParent, &currentParent) == 0,
          held.st_dev == visible.st_dev, held.st_ino == visible.st_ino,
          heldParent.st_dev == currentParent.st_dev, heldParent.st_ino == currentParent.st_ino,
          fstat(writer, &lockInfo) == 0,
          fstatat(directory, ".lokal-import.lock", &lockPath, AT_SYMLINK_NOFOLLOW) == 0,
          lockInfo.st_nlink == 1, lockPath.st_dev == lockInfo.st_dev, lockPath.st_ino == lockInfo.st_ino else {
      throw LokalTransferError.unsafeFile
    }
  }

  private func syncDirectory() throws {
    guard fsync(directory) == 0 else { throw LokalTransferError.posix("sync_music_directory", errno) }
  }

  private func existing(_ job: LokalTransferJob, name: String, part: String,
                        cancellation: LokalTransferCopyCancellation) throws -> LokalTransferLibraryReceipt? {
    try cancellation.check()
    testingBoundary?("existingOpen")
    let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard file >= 0 else {
      if errno == ENOENT { return nil }
      throw LokalTransferError.unsafeFile
    }
    defer { close(file) }
    testingBoundary?("existingStat")
    var before = stat()
    guard fstat(file, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
      throw LokalTransferError.unsafeFile
    }
    // linkat publishes without overwriting a user's file. A process can die
    // between publication and unlinking its own part; recover only that exact
    // same-inode pair. Unrelated hard links remain refused.
    if before.st_nlink == 2 {
      testingBoundary?("recoverPublishedLink")
      var partial = stat()
      guard fstatat(directory, part, &partial, AT_SYMLINK_NOFOLLOW) == 0,
            partial.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), partial.st_nlink == 2,
            partial.st_dev == before.st_dev, partial.st_ino == before.st_ino,
            unlinkat(directory, part, 0) == 0 else { throw LokalTransferError.unsafeFile }
      try syncDirectory()
      guard fstat(file, &before) == 0 else { throw LokalTransferError.unsafeFile }
    }
    guard before.st_nlink == 1, before.st_size > 0,
          Int64(before.st_size) == job.receivedBytes, before.st_size <= LokalTransferFiles.maximumBytes else {
      throw LokalTransferError.checksumMismatch
    }
    testingBoundary?("existingHash")
    let digest = try LokalTransferFiles.digest(file, checkCancellation: cancellation.check)
    testingBoundary?("existingAfterHash")
    var after = stat(), named = stat()
    guard fstat(file, &after) == 0, after.st_nlink == 1, after.st_size == before.st_size,
          fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
          named.st_ino == after.st_ino, named.st_dev == after.st_dev else { throw LokalTransferError.unsafeFile }
    testingBoundary?("existingTimestamp")
    #if canImport(Darwin)
    guard before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
          before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
      throw LokalTransferError.unsafeFile
    }
    #else
    guard before.st_mtim.tv_sec == after.st_mtim.tv_sec, before.st_mtim.tv_nsec == after.st_mtim.tv_nsec,
          before.st_ctim.tv_sec == after.st_ctim.tv_sec, before.st_ctim.tv_nsec == after.st_ctim.tv_nsec else {
      throw LokalTransferError.unsafeFile
    }
    #endif
    guard digest == job.receivedSHA256 else { throw LokalTransferError.checksumMismatch }
    try checkRoot()
    return LokalTransferLibraryReceipt(relativePath: Self.directoryName + "/" + name,
      bytes: Int64(after.st_size), sha256: digest)
  }

  private func trackedExisting(_ work: LokalTransferImportCustody, files: LokalTransferFiles,
                               cancellation: LokalTransferCopyCancellation,
                               onVerified: ((Int32, stat) throws -> Void)? = nil) throws -> LokalTransferLibraryReceipt? {
    try checkRoot(); try cancellation.check()
    guard work.location == (try LokalTransferLibraryLocation(parent: parent, directory: directory)) else {
      throw LokalTransferError.unsafeFile
    }
    let name = try Self.fileName(work.job)
    let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else {
      if errno == ENOENT { return nil }
      throw LokalTransferError.posix("open_tracked_import", errno)
    }
    defer { close(fd) }
    guard let proof = work.publication, let nonce = work.copyNonce else { throw LokalTransferError.unsafeFile }
    var before = try proof.verify(fd)
    guard let expectedBytes = work.job.receivedBytes, Int64(before.st_size) == expectedBytes else {
      throw LokalTransferError.checksumMismatch
    }
    if before.st_nlink == 2 {
      try files.retirePublishedLibraryPart(work.job, nonce: nonce, publicDescriptor: fd)
      before = try proof.verify(fd)
    }
    guard before.st_nlink == 1 else { throw LokalTransferError.unsafeFile }
    let hash = try LokalTransferFiles.digest(fd, checkCancellation: cancellation.check)
    let after = try proof.verify(fd)
    var named = stat()
    guard after.st_nlink == 1, fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
          named.st_dev == after.st_dev, named.st_ino == after.st_ino,
          named.st_nlink == 1 else { throw LokalTransferError.unsafeFile }
    #if canImport(Darwin)
    guard before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
          before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw LokalTransferError.unsafeFile }
    #else
    guard before.st_ctim.tv_sec == after.st_ctim.tv_sec,
          before.st_ctim.tv_nsec == after.st_ctim.tv_nsec else { throw LokalTransferError.unsafeFile }
    #endif
    guard hash == work.job.receivedSHA256 else { throw LokalTransferError.checksumMismatch }
    try checkRoot(); try cancellation.check()
    try onVerified?(fd, after)
    return LokalTransferLibraryReceipt(relativePath: Self.directoryName + "/" + name,
      bytes: Int64(after.st_size), sha256: hash)
  }

  /// Filesystem half of abandonment only. Caller first revokes publication,
  /// drains the file worker and marks the exact Isar receipt retiring under a
  /// separate current-root cleanup authority. No runtime/channel exposes this
  /// helper until that authority/barrier is implemented. Linux refuses public
  /// deletion; its portable tests cannot qualify Apple's file coordination.
  func abandonTracked(_ work: LokalTransferImportCustody, journal: LokalTransferJournal,
                      files: LokalTransferFiles, cancellation: LokalTransferCopyCancellation,
                      validateCleanupAuthority: @escaping @Sendable () throws -> Void) throws -> LokalTransferLibraryAbandonment {
    try work.validate(); try cancellation.check(); try validateCleanupAuthority()
    try journal.validateAbandonment(work)
    #if canImport(Darwin)
    try checkRoot(); try cancellation.check(); try validateCleanupAuthority()
    try journal.validateAbandonment(work)
    if let location = work.location {
      guard location == (try LokalTransferLibraryLocation(parent: parent, directory: directory)) else {
        throw LokalTransferError.unsafeFile
      }
    }
    let name = try Self.fileName(work.job)
    var visible = stat()
    if fstatat(directory, name, &visible, AT_SYMLINK_NOFOLLOW) != 0 {
      if errno == ENOENT { return .missingFile }
      throw LokalTransferError.posix("stat_abandon_import", errno)
    }
    let target = root.appendingPathComponent(Self.directoryName).appendingPathComponent(name)
    var coordinationError: NSError?
    let result = LokalTransferAbandonmentResult()
    let coordinator = NSFileCoordinator(filePresenter: nil)
    coordinator.coordinate(writingItemAt: target, options: .forDeleting, error: &coordinationError) { url in
      result.set(Result {
        guard url.standardizedFileURL == target.standardizedFileURL else { throw LokalTransferError.unsafeFile }
        // Coordinate before taking our own writer lock. Waiting for another
        // file presenter while holding that lock would invert the lock order.
        self.mutex.lock(); defer { self.mutex.unlock() }
        while flock(self.writer, LOCK_EX) != 0 {
          if errno != EINTR { throw LokalTransferError.posix("lock_abandon_copy", errno) }
        }
        defer { _ = flock(self.writer, LOCK_UN) }
        try self.checkRoot(); try cancellation.check(); try validateCleanupAuthority()
        try journal.validateAbandonment(work)
        self.testingBoundary?("coordinatedAbandonment")
        do {
          let receipt = try self.trackedExisting(work, files: files, cancellation: cancellation) { fd, verified in
            // Do not call registry/SQLite while holding the short cancellation
            // lock. The registry revokes this cleanup token before handoff.
            try validateCleanupAuthority(); try journal.validateAbandonment(work)
            self.testingBoundary?("beforeCoordinatedUnlink")
            try self.checkRoot()
            try cancellation.whileCurrent {
              guard let proof = work.publication else { throw LokalTransferError.unsafeFile }
              let held = try proof.verify(fd)
              var named = stat()
              guard held.st_nlink == 1,
                    held.st_ctimespec.tv_sec == verified.st_ctimespec.tv_sec,
                    held.st_ctimespec.tv_nsec == verified.st_ctimespec.tv_nsec,
                    fstatat(self.directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                    named.st_dev == held.st_dev, named.st_ino == held.st_ino,
                    named.st_nlink == 1 else { throw LokalTransferError.unsafeFile }
              guard unlinkat(self.directory, name, 0) == 0 else {
                throw LokalTransferError.posix("unlink_coordinated_import", errno)
              }
            }
            self.testingBoundary?("afterCoordinatedUnlink")
            try self.syncDirectory()
          }
          return receipt == nil ? .missingFile : .removedOwnedFile
        } catch LokalTransferError.unsafeFile {
          // A proof/root failure never authorizes deletion. Recheck the root
          // so a moved Music tree remains unresolved rather than retired.
          try self.checkRoot(); try cancellation.check(); try validateCleanupAuthority()
          return .preservedUserFile
        } catch LokalTransferError.checksumMismatch {
          try self.checkRoot(); try cancellation.check(); try validateCleanupAuthority()
          return .preservedUserFile
        }
      })
    }
    if let coordinationError { throw coordinationError }
    guard let outcome = result.get() else { throw LokalTransferError.invalidTransition }
    return try outcome.get()
    #else
    throw LokalTransferError.invalidTransition
    #endif
  }

  /// Private tracked publication. Caller supplies the actual registry writer
  /// validation; no bridge/product capability exposes this helper yet. Long
  /// copy/hash and journal I/O happen outside Isar and the cancellation lock.
  func installTracked(_ job: LokalTransferJob, songID: Int64, journal: LokalTransferJournal,
                      files: LokalTransferFiles, cancellation: LokalTransferCopyCancellation,
                      validateOwnership: () throws -> Void) throws -> LokalTransferLibraryReceipt {
    try job.validate(); try validateOwnership(); try cancellation.check()
    mutex.lock(); defer { mutex.unlock() }
    while flock(writer, LOCK_EX) != 0 {
      if errno != EINTR { throw LokalTransferError.posix("lock_tracked_copy", errno) }
    }
    defer { _ = flock(writer, LOCK_UN) }
    try checkRoot(); try validateOwnership(); try cancellation.check()
    var work = try journal.reserveImport(id: job.id, revision: job.revision, songID: songID)
    let location = try LokalTransferLibraryLocation(parent: parent, directory: directory)
    if work.location == nil {
      guard job.phase == .validating else { throw LokalTransferError.invalidTransition }
      work = try journal.bindImportLocation(work, location: location)
    }
    guard work.location == location else { throw LokalTransferError.unsafeFile }
    if let receipt = try trackedExisting(work, files: files, cancellation: cancellation) {
      try validateOwnership()
      return receipt
    }
    // Importing is a commit/reconciliation boundary. Missing public bytes may
    // not be recreated while an Isar commit could already have succeeded.
    guard job.phase == .validating, let nonce = work.copyNonce else { throw LokalTransferError.invalidTransition }
    return try files.withPrivateLibraryPart(job, nonce: nonce) { descriptor in
      _ = try files.copyForLibrary(job, to: descriptor, checkCancellation: {
        try cancellation.check()
        self.testingBoundary?("trackedCopyCheckpoint")
      })
      try checkRoot(); try validateOwnership(); try cancellation.check()
      let proof = try LokalTransferLibraryPublication.stamp(descriptor, nonce: nonce)
      work = try journal.recordImportPublication(work, proof: proof)
      testingBoundary?("trackedProofCommitted")
      try validateOwnership(); try cancellation.check(); try checkRoot()
      testingBoundary?("beforeTrackedPublication")
      try files.publishPrivateLibraryPart(job, nonce: nonce, descriptor: descriptor,
        to: directory, cancellation: cancellation)
      testingBoundary?("afterTrackedPublication")
      try syncDirectory()
      testingBoundary?("afterTrackedDirectorySync")
      guard let receipt = try trackedExisting(work, files: files, cancellation: cancellation) else {
        throw LokalTransferError.unsafeFile
      }
      testingBoundary?("afterTrackedVerification")
      try validateOwnership()
      return receipt
    }
  }

  func install(_ job: LokalTransferJob, from files: LokalTransferFiles,
               cancellation: LokalTransferCopyCancellation = LokalTransferCopyCancellation()) throws -> LokalTransferLibraryReceipt {
    try cancellation.check()
    try job.validate()
    guard job.direction == .download, job.phase == .validating || job.phase == .importing,
          job.receivedBytes != nil, job.receivedSHA256 != nil else { throw LokalTransferError.invalidTransition }
    let name = try Self.fileName(job), part = "." + name + ".part"
    mutex.lock()
    defer { mutex.unlock() }
    testingBoundary?("writerLock")
    while flock(writer, LOCK_EX) != 0 {
      if errno != EINTR { throw LokalTransferError.posix("lock_library_copy", errno) }
    }
    defer { _ = flock(writer, LOCK_UN) }
    try cancellation.check()
    try checkRoot()
    if let receipt = try existing(job, name: name, part: part, cancellation: cancellation) { return receipt }
    testingBoundary?("discardInterruptedPart")
    var oldPart = stat()
    if fstatat(directory, part, &oldPart, AT_SYMLINK_NOFOLLOW) == 0 {
      guard oldPart.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), oldPart.st_nlink == 1,
            unlinkat(directory, part, 0) == 0 else { throw LokalTransferError.unsafeFile }
    } else if errno != ENOENT { throw LokalTransferError.unsafeFile }
    testingBoundary?("createExclusivePart")
    let output = openat(directory, part, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard output >= 0 else { throw LokalTransferError.posix("create_library_part", errno) }
    defer {
      var held = stat(), visible = stat()
      if fstat(output, &held) == 0, fstatat(directory, part, &visible, AT_SYMLINK_NOFOLLOW) == 0,
         held.st_ino == visible.st_ino, held.st_dev == visible.st_dev { _ = unlinkat(directory, part, 0) }
      close(output)
    }
    #if os(iOS) && !targetEnvironment(simulator)
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: root.appendingPathComponent(Self.directoryName).appendingPathComponent(part).path)
    #endif
    testingBoundary?("copyOwnedBytes")
    _ = try files.copyForLibrary(job, to: output, checkCancellation: {
      try cancellation.check()
      self.testingBoundary?("copyCheckpoint")
      try cancellation.check()
    })
    try checkRoot()
    testingBoundary?("beforePublication")
    try cancellation.whileCurrent {
      guard linkat(directory, part, directory, name, 0) == 0 else { throw LokalTransferError.unsafeFile }
    }
    testingBoundary?("afterPublication")
    testingBoundary?("retirePublishedPart")
    guard unlinkat(directory, part, 0) == 0 else { throw LokalTransferError.posix("retire_library_part", errno) }
    try syncDirectory()
    testingBoundary?("afterPromotion")
    guard let receipt = try existing(job, name: name, part: part, cancellation: cancellation) else {
      throw LokalTransferError.unsafeFile
    }
    return receipt
  }
}
