import WidgetKit
import SwiftUI
import ActivityKit

@main struct WakeWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WakeActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image("WakePortrait").resizable().scaledToFit().frame(width: 42, height: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("JARVIS XLV").font(.caption2.bold()).tracking(2).foregroundStyle(.cyan)
                        Text(context.state.phase).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 18) {
                    Label(context.state.stepsDate.map { Calendar.current.isDateInToday($0) } == true
                        ? (context.state.steps.map { "\($0) passos" } ?? "Sem contagem") : "Sem contagem",
                          systemImage: "figure.walk").privacySensitive()
                    if let b = context.state.battery { Label("\(b)%", systemImage: "battery.75percent") }
                }.font(.caption.monospacedDigit()).foregroundStyle(.white)
                if let date = context.state.received {
                    HStack {
                        Image(systemName: "bell")
                        Text(context.state.preview ?? "Prévia recebida").lineLimit(1).privacySensitive()
                        Spacer()
                        Text(date, style: .time)
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 16).padding(.vertical, 10)
             .activityBackgroundTint(.black).activitySystemActionForegroundColor(.white)
             .widgetURL(URL(string: "jarvisiphone://rosto"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image("WakePortrait").resizable().scaledToFit().frame(height: 42) }
                DynamicIslandExpandedRegion(.center) { Text(context.state.phase).font(.headline) }
            } compactLeading: { Image(systemName: "waveform").foregroundStyle(.cyan) }
              compactTrailing: { Text("XLV").font(.caption2) }
              minimal: { Image(systemName: "waveform") }
              .widgetURL(URL(string: "jarvisiphone://rosto"))
        }
    }
}
