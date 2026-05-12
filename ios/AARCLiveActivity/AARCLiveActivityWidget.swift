import ActivityKit
import WidgetKit
import SwiftUI
import AARCKit

struct AARCLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveActivityAttributes.self) { context in
            LockScreenView(state: context.state, attributes: context.attributes)
                .padding(14)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedLeading(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailing(state: context.state)
                }
                DynamicIslandExpandedRegion(.center) {
                    ExpandedCenter(state: context.state, attributes: context.attributes)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottom(state: context.state)
                }
            } compactLeading: {
                Image(systemName: "figure.run")
                    .foregroundStyle(Color.green)
            } compactTrailing: {
                Text(LiveActivityAttributes.ContentState.formatDistance(context.state.distanceMeters))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: "figure.run")
                    .foregroundStyle(Color.green)
            }
            .widgetURL(URL(string: "aarc://run/active"))
            .keylineTint(Color.green)
        }
    }
}

// MARK: - Lock screen

private struct LockScreenView: View {
    let state: LiveActivityAttributes.ContentState
    let attributes: LiveActivityAttributes

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "figure.run")
                    .foregroundStyle(state.isPaused ? Color.orange : Color.green)
                    .font(.caption)
                Text(state.isPaused ? "Paused" : "Running")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(attributes.runType == .treadmill ? "Treadmill" : "Outdoor")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                StatColumn(
                    label: "Elapsed",
                    value: LiveActivityAttributes.ContentState.formatElapsed(state.elapsedSeconds)
                )
                StatColumn(
                    label: "Distance",
                    value: LiveActivityAttributes.ContentState.formatDistance(state.distanceMeters)
                )
                StatColumn(
                    label: "Pace",
                    value: LiveActivityAttributes.ContentState.formatPace(state.currentPaceSecPerKm),
                    suffix: "/km"
                )
            }

            if let progress = state.planProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Color.green)
                    .padding(.top, 2)
            }
        }
    }
}

private struct StatColumn: View {
    let label: String
    let value: String
    var suffix: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                if let suffix {
                    Text(suffix)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
    }
}

// MARK: - Dynamic Island

private struct ExpandedLeading: View {
    let state: LiveActivityAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ELAPSED")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
            Text(LiveActivityAttributes.ContentState.formatElapsed(state.elapsedSeconds))
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
        }
    }
}

private struct ExpandedTrailing: View {
    let state: LiveActivityAttributes.ContentState
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("DISTANCE")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
            Text(LiveActivityAttributes.ContentState.formatDistance(state.distanceMeters))
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
        }
    }
}

private struct ExpandedCenter: View {
    let state: LiveActivityAttributes.ContentState
    let attributes: LiveActivityAttributes
    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "figure.run")
                    .foregroundStyle(state.isPaused ? Color.orange : Color.green)
                Text("AARC")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            if let progress = state.planProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Color.green)
                    .padding(.horizontal, 6)
            }
        }
    }
}

private struct ExpandedBottom: View {
    let state: LiveActivityAttributes.ContentState
    var body: some View {
        HStack {
            Label {
                Text(LiveActivityAttributes.ContentState.formatPace(state.currentPaceSecPerKm))
                    .monospacedDigit()
                + Text(" /km").font(.caption)
            } icon: {
                Image(systemName: "gauge.with.dots.needle.50percent")
            }
            .foregroundStyle(.white.opacity(0.85))
            Spacer()
            if let hr = state.currentHR {
                Label {
                    Text(String(Int(hr.rounded())))
                        .monospacedDigit()
                    + Text(" bpm").font(.caption)
                } icon: {
                    Image(systemName: "heart.fill")
                }
                .foregroundStyle(.white.opacity(0.85))
            }
        }
        .font(.caption)
    }
}
