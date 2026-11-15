import WidgetKit
import SwiftUI
import ActivityKit

@main struct WakeWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WakeActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image("WakePortrait").resizable().scaledToFit().frame(width: 62, height: 68)
                VStack(alignment: .leading, spacing: 4) {
                    Text("J.A.R.V.I.S.  /  XLV").font(.caption.monospaced()).foregroundStyle(.cyan)
                    Text(context.state.phase).font(.headline).foregroundStyle(.white)
                }
                Spacer()
                Image(systemName: "waveform").foregroundStyle(.cyan)
            }.padding(.horizontal, 18).padding(.vertical, 8)
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
