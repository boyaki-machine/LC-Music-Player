import WidgetKit
import SwiftUI
import ControlSurfaces

/// The home screen widgets (small and medium). The app reloads them when the state changes.
struct PlayerWidget: Widget {
    static let kind = SharedTransportStore.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: Provider()) { entry in
            PlayerWidgetView(state: entry.state)
        }
        .configurationDisplayName("LC Music Player")
        .description("LCMPの再生を操作します。曲名は表示しません。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }

    struct Entry: TimelineEntry {
        let date: Date
        /// nil without an App Group: the widget cannot know the state.
        let state: TransportState?
    }

    struct Provider: TimelineProvider {
        func placeholder(in context: Context) -> Entry { Entry(date: .now, state: .stopped) }
        func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
            completion(Entry(date: .now, state: SharedTransportStore.appGroup().state))
        }
        func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
            completion(Timeline(entries: [Entry(date: .now, state: SharedTransportStore.appGroup().state)], policy: .never))
        }
    }
}

struct PlayerWidgetView: View {
    let state: TransportState?
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .systemMedium: MediumWidgetLayout(state: state) { ControlSurfaceButton(command: $0, glyph: $1) }
            default: SmallWidgetLayout(state: state) { ControlSurfaceButton(command: $0, glyph: $1) }
            }
        }
        .containerBackground(ControlSurfaceColors.plate, for: .widget)
    }
}
