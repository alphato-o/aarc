import SwiftUI
import AARCKit

/// Settings: build the offline race pack the night before. It generates the
/// race script with the course in it and renders every line to audio, so the
/// first no-signal half hour of the marathon still has a coach.
struct RacePackSection: View {
    @State private var store = RacePackStore.shared
    @State private var orchestrator = RunOrchestrator.shared

    /// Which race the pack is for. The marathon is locked to 42.2 km; the
    /// training race uses the plan on the home screen.
    @State private var mode: RaceMode = RunOrchestrator.shared.raceMode == .training ? .training : .actual
    private var plan: RunPlan {
        mode == .actual ? .distance(km: RunOrchestrator.marathonKm) : ScriptPreviewStore.shared.currentPlan
    }
    private var runType: RunType { .outdoor }
    private var personalityId: String { LiveMetricsConsumer.shared.pendingPersonalityId }

    var body: some View {
        Section {
            Picker("Pack for", selection: $mode) {
                Text("Marathon").tag(RaceMode.actual)
                Text("Training race").tag(RaceMode.training)
            }
            .pickerStyle(.segmented)
            .disabled(store.isBuilding)
            LabeledContent("Plan", value: planText)
            if let pack = store.pack(for: mode) {
                LabeledContent("Built", value: pack.builtAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Lines", value: "\(pack.lineCount) scripted, \(pack.warmedLines) of \(pack.totalLines) rendered")
                LabeledContent("Jessica", value: "\(pack.jessicaLines?.count ?? 0) lines")
                LabeledContent("Home Base", value: "\(pack.homeLines?.count ?? 0) lines")
                if let err = store.voicesError {
                    Text("Jessica and Home Base lines failed: \(err). Rebuild to retry.")
                        .font(.caption2).foregroundStyle(.red)
                }
                if store.isStale(mode: mode, plan: plan, runType: runType, personalityId: personalityId) {
                    Text("Built for a different plan or coach. Rebuild before you run.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            } else {
                Text("No pack yet.").foregroundStyle(.secondary)
            }
            switch store.phase {
            case .generating:
                LabeledContent("Building", value: "writing the script…")
            case .rendering(let done, let total):
                ProgressView(value: Double(done), total: Double(max(1, total))) {
                    Text("Rendering voice lines \(done) of \(total)")
                }
            case .failed(let message):
                Text(message).font(.caption2).foregroundStyle(.red)
            case .idle:
                EmptyView()
            }
            if store.isBuilding {
                Button("Cancel") { store.cancelBuild() }
            } else {
                Button {
                    store.build(mode: mode, plan: plan, runType: runType, personalityId: personalityId)
                } label: {
                    Label(store.pack(for: mode) == nil ? "Build race pack" : "Rebuild race pack", systemImage: "shippingbox")
                }
                if store.pack(for: mode) != nil {
                    Button(role: .destructive) { store.delete(mode: mode) } label: {
                        Label("Delete pack", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("Race pack (offline)")
        } footer: {
            Text("One pack per race. The marathon pack is always 42.2 km on the Tianjin course; the training race pack is built for the plan on the home screen, with no course. Used only in that race mode and only for exactly the plan it was built for. Build on Wi‑Fi with the app open: it writes Ricky's script, Jessica's and Home Base's offline lines, and downloads every line. At the start the pack is the script; the live voices join when there is signal, and the pack covers any kilometre they cannot reach.")
        }
    }

    private var planText: String {
        let kind: String
        switch plan.kind {
        case .distance: kind = "\(plan.distanceKm ?? 0) km"
        case .time: kind = "\(Int(plan.timeMinutes ?? 0)) min"
        case .open: kind = "open"
        }
        return "\(kind), \(runType.rawValue), \(personalityId)"
    }
}
