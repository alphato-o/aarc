import SwiftUI
import AARCKit

/// In-session UI on the watch. Three pages, NRC-style:
/// - swipe left: Controls (pause / resume / end)
/// - center (default): Live metrics
/// - swipe right: Diagnostics
struct WatchActiveRunView: View {
    @Environment(WorkoutSessionHost.self) private var host
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPage: Page = .metrics
    @State private var showEndConfirm = false

    private enum Page: Hashable { case controls, metrics, diagnostics }

    var body: some View {
        TabView(selection: $selectedPage) {
            controlsPage.tag(Page.controls)
            metricsPage.tag(Page.metrics)
            diagnosticsPage.tag(Page.diagnostics)
        }
        .tabViewStyle(.page)
        .navigationBarBackButtonHidden(true)
        .alert("End run?", isPresented: $showEndConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("End", role: .destructive) {
                Task {
                    _ = await host.endRun()
                    dismiss()
                }
            }
        } message: {
            Text(host.currentRunIsTestData
                 ? "This is a test run. It will be tagged in Apple Health for easy cleanup."
                 : "This run will be permanently saved to Apple Health.")
        }
    }

    // MARK: - Controls (swipe left)

    private var controlsPage: some View {
        ScrollView {
            VStack(spacing: 12) {
                modeBadge
                    .padding(.bottom, 4)

                if host.state == .running {
                    Button {
                        host.pause()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.yellow)
                    .controlSize(.small)
                } else if host.state == .paused {
                    Button {
                        host.resume()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)
                }

                Button(role: .destructive) {
                    showEndConfirm = true
                } label: {
                    Label("End", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)

                if host.state == .paused {
                    Text("PAUSED")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.yellow.opacity(0.3), in: Capsule())
                }
            }
            .padding()
        }
    }

    // MARK: - Metrics (default centre)

    private var metricsPage: some View {
        ScrollView {
            VStack(spacing: 8) {
                modeBadge
                    .padding(.bottom, 2)

                Text(formatElapsed(host.liveMetrics.elapsed))
                    .font(.system(.title, design: .rounded, weight: .heavy))
                    .monospacedDigit()

                Text(formatDistance(host.liveMetrics.distanceMeters))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    metric("Pace", value: formatPace(host.liveMetrics.currentPaceSecPerKm))
                    metric("HR", value: formatHR(host.liveMetrics.currentHeartRate))
                }
                .padding(.top, 4)

                HStack(spacing: 16) {
                    metric("Avg", value: formatPace(host.liveMetrics.avgPaceSecPerKm))
                    metric("kcal", value: "\(Int(host.liveMetrics.energyKcal))")
                }

                if host.state == .paused {
                    Text("PAUSED")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.yellow.opacity(0.3), in: Capsule())
                }
            }
            .padding()
        }
    }

    // MARK: - Diagnostics (swipe right)

    private var diagnosticsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Diagnostics")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                Group {
                    diagRow("Sample event",
                            value: host.lastSampleEventAt.map { "\(secondsAgo($0))s ago" } ?? "never")
                    diagRow("Last types",
                            value: host.lastCollectedTypeShortNames.isEmpty
                                ? "—"
                                : host.lastCollectedTypeShortNames.joined(separator: ", "))
                }

                Divider().padding(.vertical, 2)

                Text("Sample counts")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                ForEach(host.samplesPerType.sorted(by: { $0.key < $1.key }), id: \.key) { name, count in
                    diagRow(name, value: "\(count)")
                }
                if host.samplesPerType.isEmpty {
                    Text("none yet")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Divider().padding(.vertical, 2)

                Text("Auth at start")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                ForEach(host.hkAuthSnapshot.sorted(by: { $0.key < $1.key }), id: \.key) { name, status in
                    HStack {
                        Text(name).font(.caption2)
                        Spacer()
                        Text(status)
                            .font(.caption2)
                            .foregroundStyle(status == "sharingAuthorized" ? .green : .red)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var modeBadge: some View {
        let isIndoor = host.currentRunType == .treadmill
        Label(
            isIndoor ? "Treadmill" : "Outdoor",
            systemImage: isIndoor ? "figure.run.treadmill" : "figure.run"
        )
        .font(.caption2.bold())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.tint.opacity(0.25), in: Capsule())
    }

    @ViewBuilder
    private func metric(_ label: String, value: String) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.body.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func diagRow(_ name: String, value: String) -> some View {
        HStack {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption2).monospacedDigit()
        }
    }

    private func secondsAgo(_ date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date)))
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    private func formatDistance(_ meters: Double) -> String {
        meters >= 1000
            ? String(format: "%.2f km", meters / 1000)
            : String(format: "%.0f m", meters)
    }

    private func formatPace(_ secPerKm: Double?) -> String {
        guard let s = secPerKm, s.isFinite, s > 0 else { return "—" }
        let m = Int(s) / 60
        let r = Int(s) % 60
        return String(format: "%d:%02d", m, r)
    }

    private func formatHR(_ bpm: Double?) -> String {
        guard let bpm, bpm > 0 else { return "—" }
        return "\(Int(bpm))"
    }
}
