import SwiftUI
import AARCKit

struct RunHomeView: View {
    @State private var selectedPersonality: Personality = .roastCoach
    @State private var settings = TestDataSettings.shared
    @State private var orchestrator = RunOrchestrator.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if settings.isAnySafetyModeOn {
                    TestRunBanner(skipHealthKit: settings.skipHealthKitWrite)
                }

                VStack(spacing: 24) {
                    LiveRunTile()

                    if !LiveMetricsConsumer.shared.isRunActive {
                        Image(systemName: "figure.run.circle.fill")
                            .font(.system(size: 96))
                            .foregroundStyle(Theme.accent)

                        startSection
                    }

                    Spacer()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Companion")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Personality", selection: $selectedPersonality) {
                            ForEach(Personality.allDefaults) { p in
                                Text(p.displayName).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(selectedPersonality.tagline)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .padding()
            }
            .navigationTitle("AARC")
        }
    }

    @ViewBuilder
    private var startSection: some View {
        let phase = orchestrator.phase
        let isBusy = phase == .generating

        VStack(spacing: 10) {
            if isBusy {
                ProgressView()
                Text("Coach loading…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Generating script + ready your watch")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Start a run")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        Task { await orchestrator.startFromPhone(runType: .treadmill, personalityId: selectedPersonality.id) }
                    } label: {
                        Label("Treadmill", systemImage: "figure.run.treadmill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    Button {
                        Task { await orchestrator.startFromPhone(runType: .outdoor, personalityId: selectedPersonality.id) }
                    } label: {
                        Label("Outdoor", systemImage: "figure.run")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                }

                if phase == .sentToWatch {
                    Text("Sent to watch — confirm Start there.")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            if let err = orchestrator.lastError {
                VStack(spacing: 6) {
                    Text("Couldn't start: \(err)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Dismiss") { orchestrator.clearError() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }
}

#Preview {
    RunHomeView()
        .preferredColorScheme(.dark)
}
