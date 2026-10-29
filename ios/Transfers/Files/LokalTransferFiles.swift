import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct LokalTransferFileReceipt: Sendable {
  let bytes: Int64
  let sha256: String
}

/// Only UUID/revision-derived names are eligible for retention or deletion.
/// Downloaded OS files are retained before their delegate callback returns;
/// hashing happens separately and does not hold background-event completion.
final class LokalTransferFiles: @unchecked Sendable {
  static let maximumBytes: Int64 = 8 * 1024 * 1024 * 1024
  private let directory: Int32
  private let root: URL
  private let mutex = NSLock()

  init(container: URL) throws {
    root = container.appendingPathComponent(LokalTransferJournal.directoryName, isDirectory: true)
    let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw LokalTransferError.posix("open_owned_files", errno) }
    directory = fd
  }

  deinit { close(directory) }

  static func temporaryDownloadSize(_ source: URL) throws -> Int64 {
    guard source.isFileURL else { throw LokalTransferError.unsafeFile }
    let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw LokalTransferError.posix("open_os_download", errno) }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          info.st_nlink == 1, info.st_size > 0, info.st_size <= maximumBytes else {
      throw LokalTransferError.unsafeFile
    }
    return Int64(info.st_size)
  }

  private func locked<T>(_ operation: () throws -> T) rethrows -> T {
    mutex.lock()
    defer { mutex.unlock() }
    return try operation()
  }

  private func openDownload(_ job: LokalTransferJob, writable: Bool = false) throws -> Int32 {
    try checkRoot()
    try job.validate()
    guard job.direction == .download else { throw LokalTransferError.invalidRecord }
    let fd = openat(directory, job.stagedName, (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw LokalTransferError.posix("open_download", errno) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          info.st_nlink == 1, info.st_size > 0, info.st_size <= Self.maximumBytes else {
      close(fd)
      throw LokalTransferError.unsafeFile
    }
    return fd
  }

  private func checkRoot() throws {
    let current = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard current >= 0 else { throw LokalTransferError.unsafeFile }
    defer { close(current) }
    var held = stat(), visible = stat()
    guard fstat(directory, &held) == 0, fstat(current, &visible) == 0,
          held.st_ino == visible.st_ino, held.st_dev == visible.st_dev else {
      throw LokalTransferError.unsafeFile
    }
  }

  func retainedSize(_ job: LokalTransferJob) throws -> Int64? {
    try locked { () throws -> Int64? in
      let fd: Int32
      do { fd = try openDownload(job) }
      catch LokalTransferError.posix(_, ENOENT) { return nil }
      defer { close(fd) }
      var info = stat()
      guard fstat(fd, &info) == 0 else { throw LokalTransferError.posix("stat_download", errno) }
      return Int64(info.st_size)
    }
  }

  func retainTemporaryDownload(_ source: URL, for job: LokalTransferJob) throws -> Int64 {
    try locked {
      try checkRoot()
      try job.validate()
      guard job.direction == .download, job.phase == .transferring, source.isFileURL else {
        throw LokalTransferError.invalidTransition
      }
      let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard fd >= 0 else { throw LokalTransferError.posix("open_os_download", errno) }
      defer { close(fd) }
      var before = stat()
      guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            before.st_nlink == 1, before.st_size > 0, before.st_size <= Self.maximumBytes else {
        throw LokalTransferError.unsafeFile
      }
      guard job.expectedBytes == nil || Int64(before.st_size) == job.expectedBytes,
            job.responseBytes == nil || Int64(before.st_size) == job.responseBytes else {
        throw LokalTransferError.checksumMismatch
      }
      // Foundation's no-overwrite move retains the OS-owned temporary file.
      // Replayed callbacks never overwrite a prior retained revision.
      try FileManager.default.moveItem(at: source, to: root.appendingPathComponent(job.stagedName))
      #if os(iOS) && !targetEnvironment(simulator)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: root.appendingPathComponent(job.stagedName).path)
      #endif
      let retained = try openDownload(job, writable: true)
      defer { close(retained) }
      var after = stat()
      guard fstat(retained, &after) == 0, after.st_size == before.st_size,
            after.st_ino == before.st_ino, after.st_dev == before.st_dev else {
        throw LokalTransferError.unsafeFile
      }
      guard fsync(retained) == 0 else { throw LokalTransferError.posix("sync_download", errno) }
      guard fsync(directory) == 0 else { throw LokalTransferError.posix("sync_download_directory", errno) }
      return Int64(after.st_size)
    }
  }

  func inspect(_ job: LokalTransferJob) throws -> LokalTransferFileReceipt {
    try locked {
      let fd = try openDownload(job)
      defer { close(fd) }
      var before = stat()
      guard fstat(fd, &before) == 0 else { throw LokalTransferError.posix("stat_hash_input", errno) }
      let digest = try Self.digest(fd)
      var after = stat()
      guard fstat(fd, &after) == 0, after.st_size == before.st_size else {
        throw LokalTransferError.unsafeFile
      }
      #if canImport(Darwin)
      guard before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw LokalTransferError.unsafeFile }
      #else
      guard before.st_mtim.tv_sec == after.st_mtim.tv_sec,
            before.st_mtim.tv_nsec == after.st_mtim.tv_nsec,
            before.st_ctim.tv_sec == after.st_ctim.tv_sec,
            before.st_ctim.tv_nsec == after.st_ctim.tv_nsec else { throw LokalTransferError.unsafeFile }
      #endif
      return LokalTransferFileReceipt(bytes: Int64(after.st_size), sha256: digest)
    }
  }

  /// Resolve only while a validated import owns this revision. Dart receives
  /// a current container path, never a persisted absolute sandbox location.
  func importURL(_ job: LokalTransferJob) throws -> URL {
    try locked {
      guard job.phase == .validating || job.phase == .importing else { throw LokalTransferError.invalidTransition }
      let fd = try openDownload(job)
      close(fd)
      return root.appendingPathComponent(job.stagedName)
    }
  }

  /// Copy from an already-open owned source into a caller-owned exclusive part
  /// file. Cancelling may unlink staging while this runs; it cannot redirect
  /// the open descriptor. The caller must still fence its later library commit.
  func copyForLibrary(_ job: LokalTransferJob, to destination: Int32,
                      checkCancellation: () throws -> Void = {}) throws -> LokalTransferFileReceipt {
    try checkCancellation()
    try job.validate()
    guard job.phase == .validating || job.phase == .importing,
          let expectedBytes = job.receivedBytes, let expectedHash = job.receivedSHA256 else {
      throw LokalTransferError.invalidTransition
    }
    let source = try locked { try openDownload(job) }
    defer { close(source) }
    var before = stat(), output = stat()
    guard fstat(source, &before) == 0, fstat(destination, &output) == 0,
          output.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), output.st_nlink == 1,
          output.st_size == 0, lseek(destination, 0, SEEK_CUR) == 0 else { throw LokalTransferError.unsafeFile }
    var buffer = [UInt8](repeating: 0, count: 256 * 1024)
    var total: Int64 = 0
    while true {
      try checkCancellation()
      let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        throw LokalTransferError.posix("read_library_source", errno)
      }
      if count == 0 { break }
      total += Int64(count)
      guard total <= expectedBytes, total <= Self.maximumBytes else { throw LokalTransferError.checksumMismatch }
      try buffer.withUnsafeBytes { bytes in
        var offset = 0
        while offset < count {
          try checkCancellation()
          let written = write(destination, bytes.baseAddress!.advanced(by: offset), count - offset)
          if written < 0, errno == EINTR { continue }
          guard written > 0 else { throw LokalTransferError.posix("write_library_part", errno) }
          offset += written
        }
      }
    }
    var after = stat()
    guard fstat(source, &after) == 0, after.st_nlink == 1,
          before.st_size == after.st_size else { throw LokalTransferError.unsafeFile }
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
    guard total == expectedBytes, fsync(destination) == 0,
          lseek(destination, 0, SEEK_SET) == 0 else { throw LokalTransferError.checksumMismatch }
    let digest = try Self.digest(destination, checkCancellation: checkCancellation)
    guard digest == expectedHash else { throw LokalTransferError.checksumMismatch }
    return LokalTransferFileReceipt(bytes: total, sha256: digest)
  }

  func discard(_ job: LokalTransferJob) throws {
    try locked {
      let fd: Int32
      do { fd = try openDownload(job) }
      catch LokalTransferError.posix(_, ENOENT) { return }
      defer { close(fd) }
      guard unlinkat(directory, job.stagedName, 0) == 0 else {
        throw LokalTransferError.posix("discard_download", errno)
      }
      guard fsync(directory) == 0 else { throw LokalTransferError.posix("sync_discard", errno) }
    }
  }

  static func digest(_ fd: Int32, checkCancellation: () throws -> Void = {}) throws -> String {
    try checkCancellation()
    #if canImport(CryptoKit)
    var hash = SHA256()
    #elseif os(Linux)
    // Linux contract testing hashes real bytes with the system SHA-256 tool.
    // Apple builds use CryptoKit; their tests run on the hosted SDK workflow.
    let process = Process()
    let input = Pipe(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sha256sum")
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    #else
    throw LokalTransferError.invalidRecord
    #endif
    var buffer = [UInt8](repeating: 0, count: 256 * 1024)
    var total: Int64 = 0
    do {
      while true {
        try checkCancellation()
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count < 0 {
          if errno == EINTR { continue }
          throw LokalTransferError.posix("read_hash_input", errno)
        }
        if count == 0 { break }
        total += Int64(count)
        guard total <= maximumBytes else { throw LokalTransferError.limitExceeded }
        let bytes = Data(buffer.prefix(count))
        #if canImport(CryptoKit)
        hash.update(data: bytes)
        #elseif os(Linux)
        try input.fileHandleForWriting.write(contentsOf: bytes)
        #endif
      }
      try checkCancellation()
    } catch {
      #if os(Linux) && !canImport(CryptoKit)
      try? input.fileHandleForWriting.close()
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
      #endif
      throw error
    }
    #if canImport(CryptoKit)
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
    #elseif os(Linux)
    try input.fileHandleForWriting.close()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try checkCancellation()
    guard process.terminationStatus == 0,
          let text = String(data: bytes, encoding: .utf8),
          let result = text.split(separator: " ").first, result.count == 64 else {
      throw LokalTransferError.invalidRecord
    }
    return String(result)
    #endif
  }
}
