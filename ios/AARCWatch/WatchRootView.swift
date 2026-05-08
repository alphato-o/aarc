import SwiftUI
import AARCKit

struct WatchRootView: View {
    @Environment(WatchSession.self) private var session
    @Environment(WorkoutSessionHost.self) private var host

    @State private var hkAuthorized = HealthKitClient.shared.canHostWorkouts
    @State private var requestingAuth = false
    @State private var startError: String?
    @State private var showActiveRun = false
    @State private var mode: RunType = .treadmill  // safer default for first runs

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    Image(systemName: "figure.run")
                        .font(.system(size: 32))
                        .foregroundStyle(.tint)

                    Text("AARC")
                        .font(.title3.bold())

                    if !hkAuthorized {
                        Button {
                            Task { await requestHK() }
                        } label: {
                            if requestingAuth {
                                ProgressView()
                            } else {
                                Text("Allow Health")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        // Two distinct buttons read better on watchOS than
                        // a picker. .segmented is unavailable on watchOS.
                        VStack(spacing: 6) {
                            Button {
                                mode = .treadmill
                                Task { await startRun() }
                            } label: {
                                Label("Treadmill", systemImage: "figure.run.treadmill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .controlSize(.small)

                            Button {
                                mode = .outdoor
                                Task { await startRun() }
                            } label: {
                                Label("Outdoor", systemImage: "figure.run")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    if let startError {
                        Text(startError)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    Divider()

                    Group {
                        LabeledContent("Phone reachable", value: session.isReachable ? "Yes" : "No")
                        if let last = session.lastInboundText {
                            Text("Last: \(last)")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .font(.footnote)
                }
                .padding()
            }
            .navigationDestination(isPresented: $showActiveRun) {
                WatchActiveRunView()
            }
        }
    }

    private func requestHK() async {
        requestingAuth = true
        defer { requestingAuth = false }
        do {
            try await HealthKitClient.shared.requestAuthorization()
            hkAuthorized = HealthKitClient.shared.canHostWorkouts
        } catch {
            startError = "Health access denied"
        }
    }

    private func startRun() async {
        startError = nil
        do {
            switch mode {
            case .outdoor:
                try await host.startOutdoorRun(isTestData: true, skipHealthKitWrite: false)
            case .treadmill:
                try await host.startTreadmillRun(isTestData: true, skipHealthKitWrite: false)
            }
            showActiveRun = true
        } catch {
            startError = error.localizedDescription
        }
    }
}

#Preview {
    WatchRootView()
        .environment(WatchSession.shared)
        .environment(WorkoutSessionHost.shared)
}
