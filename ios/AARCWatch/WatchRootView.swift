import SwiftUI

struct WatchRootView: View {
    @Environment(WatchSession.self) private var session
    @Environment(WorkoutSessionHost.self) private var host

    @State private var hkAuthorized = HealthKitClient.shared.canHostWorkouts
    @State private var requestingAuth = false
    @State private var startError: String?
    @State private var showActiveRun = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    Image(systemName: "figure.run")
                        .font(.system(size: 36))
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
                        Button("Start Run") {
                            Task { await startOutdoorRun() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.small)
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

    private func startOutdoorRun() async {
        startError = nil
        do {
            // §1.1 default: tag every watch-initiated run as test data.
            // §1.2 will override this from the phone via WCMessage.startWorkout.
            try await host.startOutdoorRun(isTestData: true, skipHealthKitWrite: false)
            showActiveRun = true
        } catch {
            startError = error.localizedDescription
        }
    }
}

#Preview {
    WatchRootView()
        .environment(WatchSession())
        .environment(WorkoutSessionHost())
}
