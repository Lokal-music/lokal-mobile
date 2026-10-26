import Darwin
import Flutter
import Foundation
import UIKit

/// Explicit Bonjour discovery for the existing Desktop Link protocol. The OS
/// owns mDNS and its Local Network prompt; no raw multicast entitlement is used.
final class LokalDesktopDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
  private var browser: NetServiceBrowser?
  private var pending: FlutterResult?
  private var deadline: Timer?
  private var resolving: [String: NetService] = [:]
  private var found: [String: [String: Any]] = [:]
  private var backgroundObserver: NSObjectProtocol?

  override init() {
    super.init()
    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.finish(error: FlutterError(code: "LOCAL_DISCOVERY_PAUSED",
        message: "Desktop discovery paused. Return to Lokal and scan again.", details: nil))
    }
  }

  func discover(_ result: @escaping FlutterResult) {
    guard pending == nil else {
      result(FlutterError(code: "busy", message: "Desktop discovery is already running.", details: nil))
      return
    }
    pending = result
    found.removeAll()
    let search = NetServiceBrowser()
    browser = search
    search.delegate = self
    // Authorization is determined by this real browse operation, rather than
    // returning a fabricated permission grant from a preflight method.
    let timer = Timer(timeInterval: 8, repeats: false) { [weak self] _ in self?.finish() }
    deadline = timer
    RunLoop.main.add(timer, forMode: .common)
    search.searchForServices(ofType: "_lokal._tcp.", inDomain: "local.")
  }

  private func key(_ service: NetService) -> String {
    "\(service.domain)\u{0}\(service.type)\u{0}\(service.name)"
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    guard browser === self.browser, pending != nil, resolving.count + found.count < 64 else { return }
    let identifier = key(service)
    guard resolving[identifier] == nil, found[identifier] == nil else { return }
    resolving[identifier] = service
    service.delegate = self
    service.resolve(withTimeout: 4)
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
    guard browser === self.browser, pending != nil else { return }
    let identifier = key(service)
    found.removeValue(forKey: identifier)
    if let resolving = resolving.removeValue(forKey: identifier) {
      resolving.delegate = nil
      resolving.stop()
    }
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
    guard browser === self.browser else { return }
    finish(error: FlutterError(code: "LOCAL_DISCOVERY",
      message: "Local discovery could not start. Allow Local Network for Lokal in Settings, or enter the desktop address.",
      details: errorDict["NSNetServicesErrorCode"]?.intValue))
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    guard pending != nil, resolving[key(sender)] === sender else { return }
    defer {
      resolving.removeValue(forKey: key(sender))
      sender.delegate = nil
      sender.stop()
    }
    let text: [String: Data]
    if let data = sender.txtRecordData() { text = NetService.dictionary(fromTXTRecord: data) }
    else { text = [:] }
    func value(_ name: String) -> String? { text[name].flatMap { String(data: $0, encoding: .utf8) } }
    guard value("proto") == "1", sender.port > 0, sender.port <= 65535 else { return }
    let addresses = (sender.addresses ?? []).compactMap(Self.address)
    guard let host = (addresses.first { $0.family == AF_INET } ?? addresses.first)?.host else { return }
    found[key(sender)] = [
      "id": value("id") ?? sender.name,
      "name": value("name") ?? sender.name,
      "host": host,
      "port": sender.port,
    ]
  }

  func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    guard resolving[key(sender)] === sender else { return }
    resolving.removeValue(forKey: key(sender))
    sender.delegate = nil
    sender.stop()
  }

  private static func address(_ data: Data) -> (family: Int32, host: String)? {
    guard data.count >= MemoryLayout<sockaddr>.size,
          data.count <= MemoryLayout<sockaddr_storage>.size else { return nil }
    // Copy into aligned storage before passing the address to Darwin.
    var storage = sockaddr_storage()
    return withUnsafeMutablePointer(to: &storage) { pointer in
      _ = data.withUnsafeBytes { memcpy(pointer, $0.baseAddress!, data.count) }
      let family = Int32(pointer.pointee.ss_family)
      guard family == AF_INET || family == AF_INET6 else { return nil }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let capacity = socklen_t(host.count)
      let status = pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getnameinfo($0, socklen_t(data.count), &host, capacity, nil, 0, NI_NUMERICHOST)
      }
      guard status == 0 else { return nil }
      return (family, String(cString: host))
    }
  }

  private func finish(error: FlutterError? = nil) {
    guard let result = pending else { return }
    pending = nil
    let unique = found.values.reduce(into: [String: [String: Any]]()) { output, desktop in
      if let id = desktop["id"] as? String { output[id] = desktop }
    }
    let records = unique.values.sorted {
      ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "")
    }
    cleanup()
    if let error = error { result(error) } else { result(records) }
  }

  private func cleanup() {
    deadline?.invalidate()
    deadline = nil
    browser?.delegate = nil
    browser?.stop()
    browser = nil
    for service in resolving.values {
      service.delegate = nil
      service.stop()
    }
    resolving.removeAll()
    found.removeAll()
  }

  deinit {
    cleanup()
    if let observer = backgroundObserver { NotificationCenter.default.removeObserver(observer) }
  }
}
