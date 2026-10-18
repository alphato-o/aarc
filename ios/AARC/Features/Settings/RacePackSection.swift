import SwiftUI
import AARCKit

/// Settings: build the offline race pack the night before. It generates the
/// race script with the course in it and renders every line to audio, so the
/// first no-signal half hour of the marathon still has a coach.
struct RacePackSection: View {
    @State private var store = RacePackStore.shared
    @State private var orchestrator = RunOrchestrator.shared

    // Always the marathon, whatever the home screen is set to: Actual race
    // mode locks the start to this plan, so any other pack would never load.
    private var plan: RunPlan { .distance(km: RunOrchestrator.marathonKm) }
    private var runType: RunType { .outdoor }
    private var personalityId: String { LiveMetricsConsumer.shared.pendingPersonalityId }

    var body: some View {
        Section {
            LabeledContent("Plan", value: planText)
            if let pack = store.pack {
                LabeledContent("Built", value: pack.builtAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Lines", value: "\(pack.lineCount) scripted, \(pack.warmedLines) of \(pack.totalLines) rendered")
                if store.isStale(plan: plan, runType: runType, personalityId: personalityId) {
                    Text("Built for a different plan or coach. Rebuild before race day.")
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
                    store.build(plan: plan, runType: runType, personalityId: personalityId)
                } label: {
                    Label(store.pack == nil ? "Build race pack" : "Rebuild race pack", systemImage: "shippingbox")
                }
                if store.pack != nil {
                    Button(role: .destructive) { store.delete() } label: {
                        Label("Delete pack", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("Race pack (offline)")
        } footer: {
            Text("Used only in Actual race mode, for exactly the plan it was built for. Always built for the marathon (42.2 km, outdoor), whatever plan is on the home screen. Build on Wi‑Fi with the app open: it writes Ricky's course script and downloads every line. At the start the pack is the script; Home Base and Jessica still join when there is signal, and Ricky's scripted line covers any kilometre they cannot reach.")
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
