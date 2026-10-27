import SwiftUI
import WidgetKit
import UIKit

/// Native shared palette: system surfaces/contrast and the captured app accent.
/// Accent is decorative; readable labels always use system primary/secondary.
private struct LokalWidgetTheme {
  let accent: Color
  let surface = Color(uiColor: .secondarySystemBackground)

  init(argb: Int) {
    let value = argb == 0 ? UInt32(0xFFC8FF57) : UInt32(truncatingIfNeeded: argb)
    accent = Color(.sRGB, red: Double((value >> 16) & 255) / 255,
                   green: Double((value >> 8) & 255) / 255,
                   blue: Double(value & 255) / 255, opacity: 1)
  }
}

func lokalWidgetText(_ key: String) -> String {
  NSLocalizedString(key, comment: "Lokal Home Screen widget")
}

struct LokalWidgetView: View {
  let configuration: LokalWidgetConfiguration
  let model: LokalWidgetPresentation
  let artwork: [String: Data]
  let family: WidgetFamily
  @Environment(\.dynamicTypeSize) private var typeSize

  private var theme: LokalWidgetTheme { LokalWidgetTheme(argb: model.accentArgb) }
  private var heading: String {
    switch configuration {
    case .nowPlaying: return lokalWidgetText("Now Playing")
    case .flowRadio: return lokalWidgetText("Flow / Radio")
    case .coverFlow: return lokalWidgetText("Cover Flow")
    }
  }
  private var primary: LokalWidgetTrackPresentation? {
    configuration == .coverFlow ? model.recommendations.first : model.current
  }
  private var hasContent: Bool {
    if model.availability == .unavailable { return false }
    if configuration == .flowRadio && model.flowKind == "none" { return false }
    return primary != nil
  }

  var body: some View {
    ViewThatFits(in: .vertical) {
      content(compact: false).fixedSize(horizontal: false, vertical: true)
      content(compact: true).fixedSize(horizontal: false, vertical: true)
      // Accessibility sizes can outgrow the smallest family. Preserve the full
      // VoiceOver metadata while prioritizing the recording and open action.
      VStack(alignment: .leading, spacing: 6) {
        Text(hasContent ? (primary.map { title($0) } ?? "") : lokalWidgetText("Your music, one tap away"))
          .font(.headline).lineLimit(2)
        Text(lokalWidgetText("Open Lokal")).font(.caption)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .tint(theme.accent)
    .widgetURL(URL(string: "konnekted://widget"))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text(accessibilitySummary))
    .modifier(LokalWidgetBackground(accent: theme.accent, surface: theme.surface))
  }

  @ViewBuilder private func content(compact: Bool) -> some View {
    VStack(alignment: .leading, spacing: compact ? 5 : 10) {
      HStack {
        Text(heading).font(.caption.weight(.semibold)).lineLimit(1)
        Spacer(minLength: 4)
        Image(systemName: "music.note").foregroundStyle(.secondary).accessibilityHidden(true)
      }
      if hasContent, let track = primary {
        if configuration == .coverFlow && family != .systemSmall && !compact && !typeSize.isAccessibilitySize {
          HStack(alignment: .top, spacing: 10) {
            ForEach(model.recommendations) { item in
              VStack(alignment: .leading, spacing: 5) {
                cover(item.artwork).frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit).clipped()
                Text(title(item)).font(.caption.weight(.semibold)).lineLimit(1)
              }.frame(maxWidth: .infinity)
            }
          }
        } else {
          HStack(alignment: .center, spacing: 10) {
            if !compact && !typeSize.isAccessibilitySize {
              cover(track.artwork ?? (configuration == .coverFlow ? nil : model.lastArtwork))
                .frame(width: family == .systemSmall ? 44 : 64,
                       height: family == .systemSmall ? 44 : 64).clipped()
            }
            VStack(alignment: .leading, spacing: 3) {
              Text(title(track)).font(.headline).lineLimit(2)
              if !compact {
                Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
              }
            }
          }
        }
        if configuration == .nowPlaying && !compact && model.durationMs > 0 {
          if let interval = model.progressInterval {
            ProgressView(timerInterval: interval, countsDown: false)
              .labelsHidden().accessibilityHidden(true)
          } else {
            ProgressView(value: Double(model.positionMs), total: Double(model.durationMs))
              .accessibilityLabel(Text(lokalWidgetText("Playback progress")))
          }
        }
        if configuration == .flowRadio && !model.flowStatus.isEmpty && !compact {
          Text(model.flowStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        Text(lokalWidgetText(model.availability == .stale ? "Open Lokal to refresh" :
          (model.isBuffering ? "Buffering" : "Open Lokal")))
          .font(.caption).foregroundStyle(.secondary).lineLimit(2)
      } else {
        if !compact && !typeSize.isAccessibilitySize {
          Image(systemName: configuration == .coverFlow ? "square.stack" : "music.note")
            .font(.title2).foregroundStyle(theme.accent).accessibilityHidden(true)
        }
        Text(lokalWidgetText(configuration == .flowRadio ? "Start Flow or radio in Lokal" :
          "Your music, one tap away")).font(.headline).lineLimit(3)
        Text(lokalWidgetText("Open Lokal")).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private func cover(_ name: String?) -> some View {
    if let name, let bytes = artwork[name], let image = UIImage(data: bytes) {
      Image(uiImage: image).resizable().scaledToFill()
        .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
    } else {
      RoundedRectangle(cornerRadius: 10).fill(theme.accent.opacity(0.12))
        .overlay(Image(systemName: "music.note").foregroundStyle(.primary))
        .accessibilityHidden(true)
    }
  }

  private func title(_ track: LokalWidgetTrackPresentation) -> String {
    track.title.isEmpty ? lokalWidgetText("Unknown track") : track.title
  }

  private var accessibilitySummary: String {
    var parts = [heading]
    if hasContent, let track = primary {
      parts += [title(track), track.artist]
      if configuration == .coverFlow {
        parts += model.recommendations.dropFirst().map { "\(title($0)), \($0.artist)" }
      }
      if model.isBuffering { parts.append(lokalWidgetText("Buffering")) }
      if model.availability == .stale { parts.append(lokalWidgetText("Open Lokal to refresh")) }
    }
    parts.append(lokalWidgetText("Open Lokal"))
    return parts.filter { !$0.isEmpty }.joined(separator: ". ")
  }
}

private struct LokalWidgetBackground: ViewModifier {
  let accent: Color
  let surface: Color
  private var background: some View {
    LinearGradient(colors: [surface, accent.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
  }
  @ViewBuilder func body(content: Content) -> some View {
    if #available(iOS 17.0, *) {
      content.containerBackground(for: .widget) { background }
    } else {
      content.padding(14).background(background)
    }
  }
}
