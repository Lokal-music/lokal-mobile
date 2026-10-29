import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
@_silgen_name("flock")
private func flock(_ descriptor: Int32, _ operation: Int32) -> Int32
#endif

struct LokalTransferLibraryReceipt: Codable, Equatable, Sendable {
  let relativePath: String
  let bytes: Int64
  let sha256: String
}

/// Immediate cancellation is independent of the utility/file queues. Publication
/// and revocation share this short lock; long copying/hashing never holds it.
/// A published file still needs the reservation/cleanup barrier before retiring
/// its database intent. This token alone does not implement that app barrier.
final class LokalTransferCopyCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  func check() throws {
    try whileCurrent {}
  }

  func whileCurrent<T>(_ operation: () throws -> T) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled else { throw LokalTransferError.invalidTransition }
    return try operation()
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
    guard root.isFileURL else { throw LokalTransferError.unsafeFile }
    let parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw LokalTransferError.posix("open_music_root", errno) }
    if mkdirat(parent, Self.directoryName, 0o700) != 0 && errno != EEXIST {
      close(parent); throw LokalTransferError.posix("create_copy_directory", errno)
    }
    let directory = openat(parent, Self.directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { close(parent); throw LokalTransferError.unsafeFile }
    let writer = openat(directory, ".lokal-import.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
    var info = stat()
    guard writer >= 0, fstat(writer, &info) == 0,
          info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else {
      if writer >= 0 { close(writer) }
      close(directory); close(parent); throw LokalTransferError.unsafeFile
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
    let visibleParent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard visibleParent >= 0 else { throw LokalTransferError.unsafeFile }
    defer { close(visibleParent) }
    let visibleDirectory = openat(visibleParent, Self.directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard visibleDirectory >= 0 else { throw LokalTransferError.unsafeFile }
    defer { close(visibleDirectory) }
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
    let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard file >= 0 else {
      if errno == ENOENT { return nil }
      throw LokalTransferError.unsafeFile
    }
    defer { close(file) }
    var before = stat()
    guard fstat(file, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
      throw LokalTransferError.unsafeFile
    }
    // linkat publishes without overwriting a user's file. A process can die
    // between publication and unlinking its own part; recover only that exact
    // same-inode pair. Unrelated hard links remain refused.
    if before.st_nlink == 2 {
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
    let digest = try LokalTransferFiles.digest(file, checkCancellation: cancellation.check)
    var after = stat(), named = stat()
    guard fstat(file, &after) == 0, after.st_nlink == 1, after.st_size == before.st_size,
          fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
          named.st_ino == after.st_ino, named.st_dev == after.st_dev else { throw LokalTransferError.unsafeFile }
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

  func install(_ job: LokalTransferJob, from files: LokalTransferFiles,
               cancellation: LokalTransferCopyCancellation = LokalTransferCopyCancellation()) throws -> LokalTransferLibraryReceipt {
    try cancellation.check()
    try job.validate()
    guard job.direction == .download, job.phase == .validating || job.phase == .importing,
          job.receivedBytes != nil, job.receivedSHA256 != nil else { throw LokalTransferError.invalidTransition }
    let name = try Self.fileName(job), part = "." + name + ".part"
    mutex.lock()
    defer { mutex.unlock() }
    while flock(writer, LOCK_EX) != 0 {
      if errno != EINTR { throw LokalTransferError.posix("lock_library_copy", errno) }
    }
    defer { _ = flock(writer, LOCK_UN) }
    try cancellation.check()
    try checkRoot()
    if let receipt = try existing(job, name: name, part: part, cancellation: cancellation) { return receipt }
    var oldPart = stat()
    if fstatat(directory, part, &oldPart, AT_SYMLINK_NOFOLLOW) == 0 {
      guard oldPart.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), oldPart.st_nlink == 1,
            unlinkat(directory, part, 0) == 0 else { throw LokalTransferError.unsafeFile }
    } else if errno != ENOENT { throw LokalTransferError.unsafeFile }
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
    guard unlinkat(directory, part, 0) == 0 else { throw LokalTransferError.posix("retire_library_part", errno) }
    try syncDirectory()
    testingBoundary?("afterPromotion")
    guard let receipt = try existing(job, name: name, part: part, cancellation: cancellation) else {
      throw LokalTransferError.unsafeFile
    }
    return receipt
  }
}
