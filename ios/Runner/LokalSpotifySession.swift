import Flutter
import UIKit
import WebKit

/// The same listener-owned Spotify web session as Android. All cookies stay in
/// a nonpersistent WK store; Dart persists only the selected session in Keychain.
/// The script bridge accepts only main-frame messages from open.spotify.com.
final class LokalSpotifySession: NSObject, WKNavigationDelegate, WKScriptMessageHandler, UIAdaptivePresentationControllerDelegate {
  private let channel: FlutterMethodChannel
  private let presenter: () -> UIViewController?
  private let store = WKWebsiteDataStore.nonPersistent()
  private var webView: WKWebView?
  private var loginController: UINavigationController?
  private var completion: FlutterResult?
  private var harvesting = false
  private var timer: Timer?
  private var deadline = Date()
  private var readyAt: Date?
  private var accessToken: String?
  private var clientToken: String?
  private var expiresAt = Date()
  private var clientExpiresAt = Date()
  private var hashes: [String: String] = [:]

  init(messenger: FlutterBinaryMessenger, presenter: @escaping () -> UIViewController?) {
    self.presenter = presenter
    channel = FlutterMethodChannel(name: "konnekted/spotify_auth", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "authenticate": self.authenticate(result)
      case "mintTokens":
        let args = call.arguments as? [String: Any] ?? [:]
        self.mint(args["sessionCookie"] as? String ?? "", result)
      case "cancel": self.finish(nil); result(nil)
      case "clearSession":
        self.finish(nil)
        self.store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { result(nil) }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func makeWebView() -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = store
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = self
    return view
  }

  private func authenticate(_ result: @escaping FlutterResult) {
    guard completion == nil, let controller = presenter() else {
      result(FlutterError(code: "SPOTIFY_BUSY", message: "Another sign-in is open.", details: nil)); return
    }
    completion = result
    harvesting = false
    let web = makeWebView()
    webView = web
    let content = UIViewController()
    content.view = web
    content.title = "Spotify"
    content.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelLogin))
    let navigation = UINavigationController(rootViewController: content)
    loginController = navigation
    navigation.presentationController?.delegate = self
    controller.present(navigation, animated: true)
    web.load(URLRequest(url: URL(string: "https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F")!))
  }

  @objc private func cancelLogin() { finish(nil) }
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish(nil) }

  private func mint(_ cookie: String, _ result: @escaping FlutterResult) {
    guard completion == nil else {
      result(FlutterError(code: "SPOTIFY_BUSY", message: "Another session is active.", details: nil)); return
    }
    guard !cookie.isEmpty, !cookie.contains(";"), !cookie.contains("\n"),
          let sessionCookie = HTTPCookie(properties: [.domain: ".spotify.com", .path: "/", .name: "sp_dc", .value: cookie, .secure: "TRUE"]) else {
      result(FlutterError(code: "SPOTIFY_SESSION_ERROR", message: "Paste only the sp_dc cookie value.", details: nil)); return
    }
    let key = FlutterDartProject.lookupKey(forAsset: "assets/spotify/session_hook.js")
    guard let path = Bundle.main.path(forResource: key, ofType: nil),
          let hook = try? String(contentsOfFile: path, encoding: .utf8) else {
      result(FlutterError(code: "SPOTIFY_SESSION_ERROR", message: "The Spotify session helper is unavailable.", details: nil)); return
    }
    completion = result
    harvesting = true
    accessToken = nil; clientToken = nil; hashes = [:]; readyAt = nil
    expiresAt = Date().addingTimeInterval(2700); clientExpiresAt = expiresAt
    deadline = Date().addingTimeInterval(35)
    let web = makeWebView()
    webView = web
    let script = """
    if (location.origin === 'https://open.spotify.com') {
      window.KonnektedSpotifyTokenBridge = { postMessage: value => window.webkit.messageHandlers.lokalSpotify.postMessage(value) };
      \(hook)
    }
    """
    web.configuration.userContentController.add(self, name: "lokalSpotify")
    web.configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    // Keep the web player attached so WebKit executes it; it cannot capture focus
    // or play audio and is removed as soon as the bounded request completes.
    if let host = presenter()?.view {
      web.frame = host.bounds
      web.isUserInteractionEnabled = false
      web.accessibilityElementsHidden = true
      host.insertSubview(web, at: 0)
    }
    store.httpCookieStore.getAllCookies { [weak self, weak web] cookies in
      guard let self = self, let web = web, self.webView === web else { return }
      let group = DispatchGroup()
      for previous in cookies where previous.name == "sp_dc" && previous.domain.hasSuffix("spotify.com") {
        group.enter(); self.store.httpCookieStore.delete(previous) { group.leave() }
      }
      group.notify(queue: .main) {
        guard self.webView === web else { return }
        self.store.httpCookieStore.setCookie(sessionCookie) {
          guard self.webView === web else { return }
          web.load(URLRequest(url: URL(string: "https://open.spotify.com/")!))
        }
      }
    }
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkReady() }
  }

  private func checkReady() {
    if let access = accessToken, let client = clientToken {
      if readyAt == nil { readyAt = Date() }
      if hashes["home"] != nil && hashes["canvas"] != nil || Date().timeIntervalSince(readyAt!) >= 3 {
        finish(["accessToken": access, "clientToken": client, "expiresAtMs": Int(min(expiresAt, clientExpiresAt).timeIntervalSince1970 * 1000), "queryHashes": hashes])
        return
      }
    }
    if Date() >= deadline {
      finish(FlutterError(code: "SPOTIFY_SESSION_ERROR", message: "Spotify did not finish starting its web session. Check your connection and try again.", details: nil))
    }
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard harvesting, message.frameInfo.isMainFrame,
          message.frameInfo.securityOrigin.protocol == "https", message.frameInfo.securityOrigin.host == "open.spotify.com",
          let text = message.body as? String, text.utf8.count <= 65536,
          let bytes = text.data(using: .utf8), let root = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { return }
    switch root["kind"] as? String {
    case "headers":
      if let authorization = root["authorization"] as? String, authorization.hasPrefix("Bearer ") { accessToken = String(authorization.dropFirst(7)) }
      if let token = root["clientToken"] as? String, !token.isEmpty, token != "null" { clientToken = token }
    case "access":
      guard let data = root["data"] as? [String: Any] else { return }
      if data["isAnonymous"] as? Bool == true {
        finish(FlutterError(code: "SPOTIFY_SESSION_ERROR", message: "Spotify did not recognize this session. Sign in again.", details: nil)); return
      }
      if let token = data["accessToken"] as? String, !token.isEmpty { accessToken = token }
      if let expiry = data["accessTokenExpirationTimestampMs"] as? NSNumber { expiresAt = Date(timeIntervalSince1970: expiry.doubleValue / 1000) }
    case "client":
      if let data = root["data"] as? [String: Any], let token = data["granted_token"] as? [String: Any], let value = token["token"] as? String, !value.isEmpty {
        clientToken = value
        clientExpiresAt = Date().addingTimeInterval((token["expires_after_seconds"] as? NSNumber)?.doubleValue ?? 3600)
      }
    case "hash":
      if let operation = root["operation"] as? String, let hash = root["hash"] as? String,
         ["home", "canvas", "searchTracks", "fetchPlaylist", "fetchLibraryTracks", "libraryV3", "addToLibrary"].contains(operation),
         hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil { hashes[operation] = hash }
    default: break
    }
  }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = action.request.url, url.scheme == "https", let host = url.host?.lowercased() else { decisionHandler(.cancel); return }
    let hosts = harvesting ? ["open.spotify.com"] : ["spotify.com", "scdn.co", "google.com", "gstatic.com", "facebook.com", "apple.com"]
    decisionHandler(hosts.contains { host == $0 || (!harvesting && host.hasSuffix("." + $0)) } ? .allow : .cancel)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !harvesting, webView.url?.host == "open.spotify.com" else { return }
    store.httpCookieStore.getAllCookies { [weak self, weak webView] cookies in
      guard let self = self, let webView = webView, self.webView === webView, !self.harvesting else { return }
      if let cookie = cookies.first(where: { $0.name == "sp_dc" && ($0.domain == "spotify.com" || $0.domain == ".spotify.com" || $0.domain == "open.spotify.com") && !$0.value.isEmpty }) { self.finish(cookie.value) }
    }
  }

  private func finish(_ value: Any?) {
    let callback = completion; completion = nil
    timer?.invalidate(); timer = nil
    webView?.stopLoading()
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "lokalSpotify")
    webView?.removeFromSuperview(); webView = nil
    loginController?.dismiss(animated: true); loginController = nil
    callback?(value)
  }
}
