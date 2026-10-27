import Foundation
import Darwin
import CryptoKit
import ImageIO

enum LokalWidgetStoreError: Error, Equatable {
  case unavailable
  case unsafeFile
  case invalidSnapshot
  case invalidImage
  case missingArtwork
  case staleRevision
  case limitExceeded
  case posix(operation: String, code: Int32)
}

struct LokalWidgetArtwork: Sendable {
  let name: String
  fileprivate let data: Data
  fileprivate init(name: String, data: Data) { self.name = name; self.data = data }
}

/// Flat, descriptor-relative storage inside an explicitly supplied container.
/// All instance I/O is locked; writer flock also serializes separate instances
/// and processes. The extension reader never creates a second playback owner.
/// Image preparation belongs on a utility queue, never the main render pass.
final class LokalWidgetStore: @unchecked Sendable {
  static let directoryName = "LokalWidgets-v1"
  static let maximumInputImageBytes = 12 * 1024 * 1024
  static let maximumArtworkBytes = 2 * 1024 * 1024
  static let maximumCacheBytes = 16 * 1024 * 1024
  static let maximumArtworkFiles = 32
  private static let artworkGraceSeconds: TimeInterval = 600
  #if os(iOS) && !targetEnvironment(simulator)
  /// Ask Foundation for the public protection policy, then read its descriptor
  /// class. Do not guess private keybag constants absent from the public SDK.
  private static func afterFirstUnlockClass() throws -> Int32 {
    let probe = FileManager.default.temporaryDirectory.appendingPathComponent("lokal-widget-protection-" + UUID().uuidString)
    try Data([0]).write(to: probe, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
    defer { try? FileManager.default.removeItem(at: probe) }
    let descriptor = Darwin.open(probe.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { let code = errno; throw LokalWidgetStoreError.posix(operation: "open_protection_probe", code: code) }
    defer { Darwin.close(descriptor) }
    let attributes = try FileManager.default.attributesOfItem(atPath: probe.path)
    let policy = (attributes[.protectionKey] as? FileProtectionType)?.rawValue ?? attributes[.protectionKey] as? String
    guard policy == FileProtectionType.completeUntilFirstUserAuthentication.rawValue else {
      throw LokalWidgetStoreError.unavailable
    }
    let value = fcntl(descriptor, F_GETPROTECTIONCLASS)
    guard value != -1 else { let code = errno; throw LokalWidgetStoreError.posix(operation: "get_protection_class", code: code) }
    guard value > 0 else { throw LokalWidgetStoreError.unavailable }
    return value
  }
  #endif
  private let directory: Int32
  private let mutex = NSLock()
  private let afterReadOpenForTesting: (@Sendable (String) -> Void)?

  init(container: URL, createIfMissing: Bool = false,
       afterReadOpenForTesting: (@Sendable (String) -> Void)? = nil) throws {
    guard container.isFileURL else { throw LokalWidgetStoreError.unavailable }
    let base = Darwin.open(container.standardizedFileURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard base >= 0 else { let code = errno; throw LokalWidgetStoreError.posix(operation: "open_container", code: code) }
    defer { Darwin.close(base) }
    if createIfMissing && mkdirat(base, Self.directoryName, 0o700) != 0 && errno != EEXIST {
      let code = errno; throw LokalWidgetStoreError.posix(operation: "create_owned_directory", code: code)
    }
    let owned = openat(base, Self.directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard owned >= 0 else { let code = errno; throw LokalWidgetStoreError.posix(operation: "open_owned_directory", code: code) }
    directory = owned
    self.afterReadOpenForTesting = afterReadOpenForTesting
  }

  deinit { Darwin.close(directory) }

  #if os(iOS)
  /// Nil/missing entitlement is an explicit capability failure. Nothing calls
  /// this until the optional host/extension profile has actually been enabled.
  static func provisioned(groupIdentifier: String, createIfMissing: Bool = false) throws -> LokalWidgetStore {
    guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else {
      throw LokalWidgetStoreError.unavailable
    }
    return try LokalWidgetStore(container: root, createIfMissing: createIfMissing)
  }
  #endif

  static func prepareArtwork(_ input: Data) throws -> LokalWidgetArtwork {
    guard !input.isEmpty, input.count <= maximumInputImageBytes else { throw LokalWidgetStoreError.limitExceeded }
    guard let source = CGImageSourceCreateWithData(input as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          CGImageSourceGetCount(source) == 1,
          CGImageSourceGetStatus(source) == .statusComplete,
          let type = CGImageSourceGetType(source) as String?,
          type == "public.png" || type == "public.jpeg",
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
      throw LokalWidgetStoreError.invalidImage
    }
    let w = width.doubleValue, h = height.doubleValue
    guard w.isFinite, h.isFinite, w > 0, h > 0, w <= 12_000, h <= 12_000, w * h <= 40_000_000 else {
      throw LokalWidgetStoreError.limitExceeded
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 600,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw LokalWidgetStoreError.invalidImage
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
      throw LokalWidgetStoreError.invalidImage
    }
    // Re-encoding applies orientation, bounds pixels and removes source metadata.
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination), output.length > 0, output.length <= maximumArtworkBytes else {
      throw LokalWidgetStoreError.limitExceeded
    }
    let bytes = output as Data
    return LokalWidgetArtwork(name: digest(bytes) + ".png", data: bytes)
  }

  func readSnapshot() throws -> LokalWidgetSnapshot? {
    try locked { try snapshot(named: "snapshot.json") }
  }

  func readArtwork(named name: String) throws -> Data {
    try locked { try artwork(named: name) }
  }

  /// Publication acknowledges only the renamed complete snapshot. Superseded
  /// writers fail before touching assets; a failed commit retains the old one.
  @discardableResult
  func publish(_ candidate: LokalWidgetSnapshot, artwork prepared: [LokalWidgetArtwork] = []) throws -> Int {
    try locked {
      let writer = try openRegular("writer.lock", flags: O_RDWR | O_CREAT)
      defer { Darwin.close(writer) }
      while flock(writer, LOCK_EX) != 0 {
        if errno != EINTR { let code = errno; throw LokalWidgetStoreError.posix(operation: "lock_writer", code: code) }
      }
      defer { flock(writer, LOCK_UN) }
      let fields = candidate.json
      let revision = fields["revision"] as? Int ?? 0
      guard revision > 0 else { throw LokalWidgetStoreError.invalidSnapshot }
      let previous = try snapshot(named: "snapshot.json")
      let priorRevision = previous?.json["revision"] as? Int ?? 0
      guard revision > priorRevision else { throw LokalWidgetStoreError.staleRevision }
      let required = Self.references(candidate)
      guard prepared.count <= 14, Set(prepared.map(\.name)).count == prepared.count,
            prepared.allSatisfy({ required.contains($0.name) }) else {
        throw LokalWidgetStoreError.invalidSnapshot
      }
      let encoded = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
      guard encoded.count <= LokalWidgetSnapshot.maximumBytes else { throw LokalWidgetStoreError.limitExceeded }
      let retained = Self.references(previous).union(Self.references(try snapshot(named: "previous.json")))
      try prune(excluding: retained.union(required))
      var usage = try cacheUsage()
      for item in prepared {
        if let old = try readBounded(item.name, limit: Self.maximumArtworkBytes), old == item.data { continue }
        let oldSize = try readBounded(item.name, limit: Self.maximumArtworkBytes)?.count ?? 0
        guard usage.files + (oldSize == 0 ? 1 : 0) <= Self.maximumArtworkFiles,
              usage.bytes - oldSize + item.data.count <= Self.maximumCacheBytes else {
          throw LokalWidgetStoreError.limitExceeded
        }
        try atomicWrite(item.data, named: item.name)
        usage = (usage.files + (oldSize == 0 ? 1 : 0), usage.bytes - oldSize + item.data.count)
      }
      for name in required { _ = try artwork(named: name) }
      if let previous {
        try atomicWrite(try JSONSerialization.data(withJSONObject: previous.json, options: [.sortedKeys]), named: "previous.json")
      }
      try atomicWrite(encoded, named: "snapshot.json")
      return revision
    }
  }

  private func locked<T>(_ work: () throws -> T) rethrows -> T {
    mutex.lock()
    defer { mutex.unlock() }
    return try work()
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func isArtwork(_ name: String) -> Bool {
    name.utf8.count == 68 && name.range(of: "^[a-f0-9]{64}\\.(jpg|png)$", options: .regularExpression) != nil
  }

  private static func references(_ snapshot: LokalWidgetSnapshot?) -> Set<String> {
    guard let fields = snapshot?.json else { return [] }
    var result = Set<String>()
    if let last = fields["lastArtwork"] as? String { result.insert(last) }
    if let current = fields["current"] as? [String: Any], let art = current["artwork"] as? String { result.insert(art) }
    for row in fields["recommendations"] as? [[String: Any]] ?? [] {
      if let art = row["artwork"] as? String { result.insert(art) }
    }
    return result
  }

  private func snapshot(named name: String) throws -> LokalWidgetSnapshot? {
    guard let data = try readBounded(name, limit: LokalWidgetSnapshot.maximumBytes) else { return nil }
    let value = LokalWidgetSnapshot(document: data)
    guard value.json["revision"] as? Int ?? 0 > 0 else { throw LokalWidgetStoreError.invalidSnapshot }
    return value
  }

  private func artwork(named name: String) throws -> Data {
    guard Self.isArtwork(name) else { throw LokalWidgetStoreError.unsafeFile }
    guard let data = try readBounded(name, limit: Self.maximumArtworkBytes) else { throw LokalWidgetStoreError.missingArtwork }
    guard !data.isEmpty, Self.digest(data) == String(name.prefix(64)) else { throw LokalWidgetStoreError.unsafeFile }
    return data
  }

  private func openRegular(_ name: String, flags: Int32, allowUnlinkedRead: Bool = false) throws -> Int32 {
    let fd = openat(directory, name, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
    guard fd >= 0 else { let code = errno; throw LokalWidgetStoreError.posix(operation: "open_regular", code: code) }
    if allowUnlinkedRead { afterReadOpenForTesting?(name) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          info.st_nlink == 1 || (allowUnlinkedRead && info.st_nlink == 0) else {
      Darwin.close(fd)
      throw LokalWidgetStoreError.unsafeFile
    }
    return fd
  }

  private func readBounded(_ name: String, limit: Int) throws -> Data? {
    let fd: Int32
    // An atomic rename can unlink the old regular file immediately after
    // openat. Its held read descriptor still owns the complete old bytes.
    // Accept zero links only for this bounded read; hard links (>1), writers,
    // cleanup paths and all nonregular/symlink targets remain rejected.
    do { fd = try openRegular(name, flags: O_RDONLY, allowUnlinkedRead: true) }
    catch LokalWidgetStoreError.posix(_, ENOENT) { return nil }
    defer { Darwin.close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { let code = errno; throw LokalWidgetStoreError.posix(operation: "stat_read", code: code) }
    guard info.st_size >= 0, info.st_size <= limit else { throw LokalWidgetStoreError.limitExceeded }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: min(limit + 1, 16_384))
    while result.count <= limit {
      let size = min(buffer.count, limit + 1 - result.count)
      let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, size) }
      if count < 0 {
        if errno == EINTR { continue }
        let code = errno; throw LokalWidgetStoreError.posix(operation: "read_bytes", code: code)
      }
      if count == 0 { break }
      result.append(contentsOf: buffer.prefix(count))
    }
    guard result.count <= limit else { throw LokalWidgetStoreError.limitExceeded }
    return result
  }

  private func atomicWrite(_ data: Data, named name: String) throws {
    // Validate an existing destination without following links or opening FIFOs.
    if let _ = try readBounded(name, limit: max(Self.maximumArtworkBytes, LokalWidgetSnapshot.maximumBytes)) {}
    let temporary = "pending-" + UUID().uuidString
    let fd = try openRegular(temporary, flags: O_WRONLY | O_CREAT | O_EXCL)
    defer { Darwin.close(fd); unlinkat(directory, temporary, 0) }
    #if os(iOS) && !targetEnvironment(simulator)
    // NSFileProtectionCompleteUntilFirstUserAuthentication permits lock-screen
    // reads after the user's first unlock, including widgets during playback.
    guard fcntl(fd, F_SETPROTECTIONCLASS, try Self.afterFirstUnlockClass()) != -1 else { let code = errno; throw LokalWidgetStoreError.posix(operation: "set_protection_class", code: code) }
    #endif
    try data.withUnsafeBytes { bytes in
      var written = 0
      while written < bytes.count {
        let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
        if count < 0 {
          if errno == EINTR { continue }
          let code = errno; throw LokalWidgetStoreError.posix(operation: "write_bytes", code: code)
        }
        guard count > 0 else { let code = EIO; throw LokalWidgetStoreError.posix(operation: "write_zero", code: code) }
        written += count
      }
    }
    guard fsync(fd) == 0 else { let code = errno; throw LokalWidgetStoreError.posix(operation: "sync_file", code: code) }
    guard renameat(directory, temporary, directory, name) == 0 else { let code = errno; throw LokalWidgetStoreError.posix(operation: "rename_commit", code: code) }
  }

  private func names() throws -> [String] {
    let copied = dup(directory)
    guard copied >= 0 else { let code = errno; throw LokalWidgetStoreError.posix(operation: "dup_directory", code: code) }
    guard let stream = fdopendir(copied) else {
      Darwin.close(copied)
      let code = errno; throw LokalWidgetStoreError.posix(operation: "open_directory_stream", code: code)
    }
    defer { closedir(stream) }
    rewinddir(stream) // dup shares a directory offset with the original fd.
    var result: [String] = []
    while true {
      errno = 0
      guard let entry = readdir(stream) else {
        if errno != 0 { let code = errno; throw LokalWidgetStoreError.posix(operation: "read_directory_entry", code: code) }
        break
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
      }
      result.append(name)
      guard result.count <= 256 else { throw LokalWidgetStoreError.limitExceeded }
    }
    return result
  }

  private func cacheUsage() throws -> (files: Int, bytes: Int) {
    var count = 0, size = 0
    for name in try names() where Self.isArtwork(name) {
      let fd = try openRegular(name, flags: O_RDONLY)
      defer { Darwin.close(fd) }
      var info = stat()
      guard fstat(fd, &info) == 0 else { let code = errno; throw LokalWidgetStoreError.posix(operation: "stat_cache_file", code: code) }
      guard info.st_size >= 0, info.st_size <= Self.maximumArtworkBytes else { throw LokalWidgetStoreError.limitExceeded }
      count += 1
      size += Int(info.st_size)
      guard size <= Self.maximumCacheBytes, count <= Self.maximumArtworkFiles else { throw LokalWidgetStoreError.limitExceeded }
    }
    return (count, size)
  }

  private func prune(excluding retained: Set<String>) throws {
    let deadline = Date().timeIntervalSince1970 - Self.artworkGraceSeconds
    for name in try names() {
      // Every writer holds the process lock while using a temporary. Once that
      // lock is ours, leftover temporaries can only belong to a dead writer.
      if name.hasPrefix("pending-"), UUID(uuidString: String(name.dropFirst(8))) != nil {
        let fd = try openRegular(name, flags: O_RDONLY)
        Darwin.close(fd)
        guard unlinkat(directory, name, 0) == 0 else { let code = errno; throw LokalWidgetStoreError.posix(operation: "unlink_abandoned_temporary", code: code) }
        continue
      }
      if !Self.isArtwork(name) || retained.contains(name) { continue }
      let fd = try openRegular(name, flags: O_RDONLY)
      defer { Darwin.close(fd) }
      var info = stat()
      guard fstat(fd, &info) == 0 else { let code = errno; throw LokalWidgetStoreError.posix(operation: "stat_prunable_artwork", code: code) }
      if TimeInterval(info.st_mtimespec.tv_sec) < deadline && unlinkat(directory, name, 0) != 0 {
        let code = errno; throw LokalWidgetStoreError.posix(operation: "unlink_old_artwork", code: code)
      }
    }
  }
}
