import SwiftUI
import AARCKit

/// Diagnostic surface: hits POST /generate-script with the user's
/// current plan (distance / time / open), displays each returned line,
/// and offers a "Speak" button per line plus "Speak all" for the whole
/// sequence. Validates the proxy → LLM → schema-validated JSON pipe
/// end-to-end.
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
                Picker("Plan", selection: $store.planKind) {
                    Text("Distance").tag(RunPlan.Kind.distance)
                    Text("Time").tag(RunPlan.Kind.time)
                    Text("Open").tag(RunPlan.Kind.open)
                }
                .pickerStyle(.segmented)

                switch store.planKind {
                case .distance:
                    Stepper(value: $store.distanceKm, in: 0.5...42, step: 0.5) {
                        HStack {
                            Text("Distance")
                            Spacer()
                            Text("\(formattedKm) km")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                case .time:
                    Stepper(value: $store.timeMinutes, in: 5...720, step: 5) {
                        HStack {
                            Text("Duration")
                            Spacer()
                            Text("\(Int(store.timeMinutes)) min")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                case .open:
                    Label("Open run — no target", systemImage: "infinity")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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

                            if let variants = message.textVariants, !variants.isEmpty {
                                DisclosureGroup("\(variants.count) variants") {
                                    ForEach(Array(variants.enumerated()), id: \.offset) { idx, variant in
                                        HStack(alignment: .top, spacing: 6) {
                                            Text("\(idx + 1).")
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.tertiary)
                                            Text(variant)
                                                .font(.caption)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Button {
                                                Speaker.shared.speak(variant)
                                            } label: {
                                                Image(systemName: "speaker.wave.2.fill")
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                    }
                                }
                                .font(.caption.bold())
                            }

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

    private func generate() async {
        isGenerating = true
        error = nil
        defer { isGenerating = false }
        let plan = AIClient.ScriptPlan.from(
            store.currentPlan,
            runType: .treadmill,
            personalityId: "roast_coach"
        )
        do {
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
