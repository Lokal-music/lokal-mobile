import SwiftUI
import WidgetKit

@main
struct LokalWidgets: WidgetBundle {
  var body: some Widget {
    LokalNowPlayingWidget()
    LokalFlowRadioWidget()
    LokalCoverFlowWidget()
  }
}

private struct LokalNowPlayingWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "app.lokal.widgets.nowPlaying", provider: LokalWidgetTimelineProvider()) { entry in
      LokalWidgetFamilyView(configuration: .nowPlaying, entry: entry)
    }
    .configurationDisplayName(Text(lokalWidgetText("Now Playing")))
    .description(Text(lokalWidgetText("Your music, one tap away")))
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}

private struct LokalFlowRadioWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "app.lokal.widgets.flowRadio", provider: LokalWidgetTimelineProvider()) { entry in
      LokalWidgetFamilyView(configuration: .flowRadio, entry: entry)
    }
    .configurationDisplayName(Text(lokalWidgetText("Flow / Radio")))
    .description(Text(lokalWidgetText("Start Flow or radio in Lokal")))
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}

private struct LokalCoverFlowWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "app.lokal.widgets.coverFlow", provider: LokalWidgetTimelineProvider()) { entry in
      LokalWidgetFamilyView(configuration: .coverFlow, entry: entry)
    }
    .configurationDisplayName(Text(lokalWidgetText("Cover Flow")))
    .description(Text(lokalWidgetText("Your music, one tap away")))
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}

private struct LokalWidgetFamilyView: View {
  let configuration: LokalWidgetConfiguration
  let entry: LokalWidgetEntry
  @Environment(\.widgetFamily) private var family
  var body: some View {
    LokalWidgetView(configuration: configuration, model: entry.model, artwork: entry.artwork, family: family)
  }
}
