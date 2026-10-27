import SwiftUI
import WidgetKit
import UIKit
import CryptoKit
import Darwin

/// A CI-only native app, never embedded in Runner or the widget product.
/// It renders the shared layout into PNGs, not a simulated Home Screen install.
@main
struct LokalWidgetPreview: App {
  var body: some Scene {
    WindowGroup {
      Color.clear.task { await LokalWidgetRenderProof.run() }
    }
  }
}

@MainActor
private enum LokalWidgetRenderProof {
  enum Failure: Error { case render(String) }
  static let kinds = LokalWidgetConfiguration.allCases
  static let families: [(String, WidgetFamily, CGSize)] = [
    ("small", .systemSmall, CGSize(width: 158, height: 158)),
    ("medium", .systemMedium, CGSize(width: 338, height: 158)),
    ("large", .systemLarge, CGSize(width: 338, height: 354)),
  ]

  static func run() async {
    guard Bundle.main.bundleIdentifier == "app.lokal.widgetPreview" else { return }
    do {
      // Let the real native scene connect before using the SwiftUI renderer.
      await Task.yield()
      let args = ProcessInfo.processInfo.arguments
      guard let index = args.firstIndex(of: "--render-locale"), args.indices.contains(index + 1) else {
        throw Failure.render("Missing render locale")
      }
      let locale = args[index + 1]
      guard Bundle.main.preferredLocalizations.first == locale else {
        throw Failure.render("Requested localization was not selected: \(locale), \(Bundle.main.preferredLocalizations)")
      }
      let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WidgetRenderProof", isDirectory: true)
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      let (snapshot, art) = fixture()
      var rows: [[String: Any]] = []
      for kind in kinds {
        for (familyName, family, size) in families {
          for dark in [false, true] {
            for accessibility in [false, true] {
              let name = "\(locale)-\(kind.rawValue)-\(familyName)-\(dark ? "dark" : "light")-\(accessibility ? "accessibility5" : "large")"
              try render(name: name, kind: kind, family: family, size: size,
                snapshot: snapshot, art: art, dark: dark, accessibility: accessibility, to: output)
              rows.append(["name": name, "kind": kind.rawValue, "family": familyName,
                "width": Int(size.width), "height": Int(size.height),
                "dark": dark, "accessibility5": accessibility, "state": "playing"])
            }
          }
          if locale == "en" {
            for state in ["paused", "buffering", "stale", "empty", "unavailable"] {
              var fields = snapshot.json
              if state == "paused" { fields["isPlaying"] = false }
              if state == "buffering" { fields["isBuffering"] = true }
              if state == "stale" {
                fields["updatedAtMs"] = (fields["updatedAtMs"] as? Int ?? 0) - 16 * 60 * 1000
              }
              if state == "empty" {
                fields["current"] = NSNull()
                fields["recommendations"] = []
                fields["flowKind"] = "none"
              }
              let name = "en-\(kind.rawValue)-\(familyName)-\(state)"
              try render(name: name, kind: kind, family: family, size: size,
                snapshot: LokalWidgetSnapshot(raw: fields), art: art, dark: true,
                accessibility: false, unavailable: state == "unavailable", to: output)
              rows.append(["name": name, "kind": kind.rawValue, "family": familyName,
                "width": Int(size.width), "height": Int(size.height),
                "dark": true, "accessibility5": false, "state": state])
            }
          }
        }
      }
      let report: [String: Any] = [
        "schemaVersion": 1, "locale": locale, "preferredLocalizations": Bundle.main.preferredLocalizations,
        "scope": "shared SwiftUI layout rendered in isolated native app, not installed WidgetKit",
        "scale": 2, "cases": rows,
      ]
      let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: output.appendingPathComponent("report-\(locale).json"), options: .atomic)
      print("PASS: \(locale) rendered \(rows.count) native layout cases")
      exit(0)
    } catch {
      print("FAIL: widget render proof: \(error)")
      exit(1)
    }
  }

  static func render(name: String, kind: LokalWidgetConfiguration, family: WidgetFamily,
      size: CGSize, snapshot: LokalWidgetSnapshot, art: [String: Data],
      dark: Bool, accessibility: Bool, unavailable: Bool = false, to directory: URL) throws {
    try autoreleasepool {
    let model = LokalWidgetPresentation(snapshot: snapshot, at: Date(), unavailable: unavailable)
    let theme = LokalWidgetTheme(argb: model.accentArgb)
    let layout = LokalWidgetView(configuration: kind, model: model, artwork: art, family: family)
      .layout.padding(16)
      .frame(width: size.width, height: size.height)
      .background(LokalWidgetSurface(accent: theme.accent, surface: theme.surface))
      .environment(\.colorScheme, dark ? .dark : .light)
      .environment(\.dynamicTypeSize, accessibility ? .accessibility5 : .large)
    let renderer = ImageRenderer(content: layout)
    renderer.scale = 2
    renderer.isOpaque = true
    guard let image = renderer.uiImage, let pixels = image.cgImage,
          pixels.width == Int(size.width * 2), pixels.height == Int(size.height * 2),
          let data = image.pngData(), data.count > 500 else {
      throw Failure.render("Missing or incorrect rendered dimensions: \(name)")
    }
    try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
  }

  static func fixture() -> (LokalWidgetSnapshot, [String: Data]) {
    var artwork: [String: Data] = [:]
    let tracks: [[String: Any]] = (0..<4).map { index in
      let colors: [UIColor] = [.systemBlue, .systemTeal, .systemOrange, .systemPink]
      let image = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96)).pngData { context in
        colors[index].setFill()
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        UIColor.label.withAlphaComponent(0.3).setFill()
        context.cgContext.fillEllipse(in: CGRect(x: 15, y: 15, width: 66, height: 66))
      }
      let digest = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined() + ".png"
      artwork[digest] = image
      return [
        "id": String(repeating: String(index, radix: 16), count: 64),
        "title": index == 0 ? "Late night listening — a long recording title" : "Recommendation \(index)",
        "artist": "Native layout fixture", "album": "Generated fixture", "artwork": digest,
      ]
    }
    return (LokalWidgetSnapshot(raw: [
      "schemaVersion": 1, "revision": 4,
      "updatedAtMs": LokalWidgetPresentation.milliseconds(Date()) ?? 0,
      "current": tracks[0], "recommendations": Array(tracks.dropFirst()),
      "isPlaying": true, "positionMs": 42_000, "durationMs": 240_000, "playbackRate": 1.0,
      "flowKind": "flow", "flowStatus": "Flow · Native layout fixture", "accentArgb": -3_604_649,
    ]), artwork)
  }
}
