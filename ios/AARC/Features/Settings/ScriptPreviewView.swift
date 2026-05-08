import SwiftUI
import AARCKit

/// Diagnostic surface: hits POST /generate-script with a 5km treadmill
/// Roast Coach plan, displays each returned line, and offers a "Speak"
/// button per line plus "Speak all" for the whole sequence. Validates
/// the proxy → Anthropic → schema-validated JSON pipe end-to-end before
/// the script engine wires this into actual runs.
struct ScriptPreviewView: View {
    @State private var script: GeneratedScript?
    @State private var isGenerating = false
    @State private var error: String?

    @State private var distanceKm: Double = 5
    @State private var paceMinPerKm: Double = 5.5

    var body: some View {
        Form {
            Section("Plan") {
                LabeledContent("Distance") {
                    Stepper("\(formattedKm) km", value: $distanceKm, in: 1...42, step: 0.5)
                        .labelsHidden()
                }
                LabeledContent("Target pace") {
                    Stepper(formattedPace, value: $paceMinPerKm, in: 3.0...10.0, step: 0.25)
                        .labelsHidden()
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

            if let script {
                Section {
                    HStack {
                        Text("Model").foregroundStyle(.secondary)
                        Spacer()
                        Text(script.model).font(.caption.monospacedDigit())
                    }
                    Button("Speak all (in order)") {
                        Task { await speakAll(script.messages) }
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
                                    LocalTTS.shared.speak(message.text)
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
        distanceKm.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", distanceKm)
            : String(format: "%.1f", distanceKm)
    }

    private var formattedPace: String {
        let total = Int(paceMinPerKm * 60)
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
            distanceKm: distanceKm,
            targetPaceSecPerKm: paceMinPerKm * 60,
            personalityId: "roast_coach",
            runType: "treadmill"
        )
        do {
            script = try await AIClient.shared.generateScript(plan: plan)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func speakAll(_ messages: [ScriptMessage]) async {
        for message in messages {
            LocalTTS.shared.speak(message.text)
            // Crude pacing — give each line time to play before queuing
            // the next.  AVSpeechSynthesizer queues internally so this
            // mostly affects perceived sequencing.
            try? await Task.sleep(for: .seconds(3))
        }
    }
}
