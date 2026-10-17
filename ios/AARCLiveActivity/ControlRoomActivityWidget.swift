import ActivityKit
import WidgetKit
import SwiftUI
import AARCKit

/// Lock screen and Dynamic Island while the mic is open for Control Room.
struct ControlRoomActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ControlRoomActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: icon(context.state.phase))
                    .font(.title2)
                    .foregroundStyle(tint(context.state.phase))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Control Room").font(.headline)
                    Text(caption(context.state.phase)).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if context.state.phase.hasPrefix("listening") {
                    Text(context.state.startedAt, style: .timer)
                        .font(.title3.monospacedDigit())
                        .frame(maxWidth: 70, alignment: .trailing)
                }
            }
            .padding(16)
            .activityBackgroundTint(.black.opacity(0.8))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: icon(context.state.phase)).foregroundStyle(tint(context.state.phase))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.phase.hasPrefix("listening") {
                        Text(context.state.startedAt, style: .timer).monospacedDigit().frame(maxWidth: 60)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(caption(context.state.phase)).font(.caption)
                }
            } compactLeading: {
                Image(systemName: icon(context.state.phase)).foregroundStyle(tint(context.state.phase))
            } compactTrailing: {
                if context.state.phase.hasPrefix("listening") {
                    Text(context.state.startedAt, style: .timer).monospacedDigit().frame(maxWidth: 44)
                }
            } minimal: {
                Image(systemName: icon(context.state.phase)).foregroundStyle(tint(context.state.phase))
            }
        }
    }

    private func icon(_ phase: String) -> String {
        switch phase {
        case "listening", "listening-siri": return "mic.fill"
        case "sending": return "arrow.up.circle"
        case "queued": return "clock"
        default: return "checkmark.circle"
        }
    }

    private func tint(_ phase: String) -> Color {
        phase.hasPrefix("listening") ? .red : .green
    }

    private func caption(_ phase: String) -> String {
        switch phase {
        case "listening": return "Listening. Press your earbud to send."
        case "listening-siri": return "Listening. Say \"send to Control Room\" when done."
        case "sending": return "Sending"
        case "queued": return "No signal. Sends when it's back."
        default: return "Sent"
        }
    }
}
