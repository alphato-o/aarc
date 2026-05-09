import SwiftUI
import AARCKit

/// Diagnostic surface: hits POST /generate-script with a 5km treadmill
/// Roast Coach plan, displays each returned line, and offers a "Speak"
/// button per line plus "Speak all" for the whole sequence. Validates
/// the proxy → Anthropic → schema-validated JSON pipe end-to-end before
/// the script engine wires this into actual runs.
///
/// Plan inputs and the most-recent generated script are persisted via
/// `ScriptPreviewStore.shared` so navigating away and back doesn't
/// throw away results — they're only replaced when the user taps
/// Generate again.
struct ScriptPreviewView: View {
    @State private var store = ScriptPreviewStore.shared
    @State private var isGenerating = false
    @State private var error: String?

    var body: some View {
        @Bindable var store = store

        Form {
            Section("Plan") {
                Stepper(value: $store.distanceKm, in: 1...42, step: 0.5) {
                    HStack {
                        Text("Distance")
                        Spacer()
                        Text("\(formattedKm) km")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $store.paceMinPerKm, in: 3.0...10.0, step: 0.25) {
                    HStack {
                        Text("Target pace")
                        Spacer()
                        Text(formattedPace)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    Task { await generate() }
                } label: {
                    HStack {
                        if isGenerating {
                            ProgressView().controlSize(.small)
                        }
                        Text(isGenerating ? "Generating…" : "Generate Roast Coach script")
                    }
                }
                .disabled(isGenerating)
            }

            if let error {
                Section {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if let script = store.latest {
                Section {
                    HStack {
                        Text("Model").foregroundStyle(.secondary)
                        Spacer()
                        Text(script.model).font(.caption.monospacedDigit())
                    }
                    Button("Speak all (in order)") {
                        Task { await speakAll(script.messages) }
                    }
                    Button("Clear", role: .destructive) {
                        store.clear()
                    }
                } header: {
                    Text("Result")
                }

                Section("Lines (\(script.messages.count))") {
                    ForEach(script.messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(message.triggerSpec.humanDescription)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    Speaker.shared.speak(message.text)
                                } label: {
                                    Image(systemName: "speaker.wave.2.fill")
                                }
                                .buttonStyle(.borderless)
                            }
                            Text(message.text)
                                .font(.callout)
                            HStack {
                                Text("priority \(message.priority)")
                                if !message.playOnce { Text("· loops") }
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Script Preview")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var formattedKm: String {
        store.distanceKm.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", store.distanceKm)
            : String(format: "%.1f", store.distanceKm)
    }

    private var formattedPace: String {
        let total = Int(store.paceMinPerKm * 60)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d /km", m, s)
    }

    private func generate() async {
        isGenerating = true
        error = nil
        defer { isGenerating = false }
        let plan = AIClient.ScriptPlan(
            goal: "free",
            distanceKm: store.distanceKm,
            targetPaceSecPerKm: store.paceMinPerKm * 60,
            personalityId: "roast_coach",
            runType: "treadmill"
        )
        do {
            // Replace, not append — each Generate overwrites the cached
            // script per the founder's spec.
            store.latest = try await AIClient.shared.generateScript(plan: plan)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func speakAll(_ messages: [ScriptMessage]) async {
        for message in messages {
            Speaker.shared.speak(message.text)
            try? await Task.sleep(for: .seconds(5))
        }
    }
}
