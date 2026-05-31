import SwiftUI
import UIKit
import OSLog
import CoreMotion

/// Diagnostic panel for live debugging.
///
/// (1) **Pedometer one-shot test** — isolates the CMPedometer API
///     from the full workout flow. Press the button → we query
///     pedometer data for the last 5 minutes and dump the raw
///     response. If this returns nothing, the workout flow has no
///     chance either; the failure is at the API / permission layer.
///
/// (2) **PhoneWorkoutSession live state** — current isActive,
///     distanceMeters, currentCadenceSPM, lastError. Helps confirm
///     whether the chart sitting still is because no data arrived
///     vs. data arrived but the UI didn't update.
///
/// (3) **OSLog reader** — pulls our own subsystem's recent log
///     entries via OSLogStore and renders them in a scrollable view.
///     "Copy logs" copies the whole dump to the clipboard so the
///     runner can paste it back into a debugging chat.
@MainActor
struct DiagnosticsView: View {
    @State private var pedometerTestResult: String = "Not run yet."
    @State private var pedometerTestBusy: Bool = false
    @State private var workoutSession = PhoneWorkoutSession.shared
    @State private var logText: String = "Loading…"
    @State private var refreshingLogs: Bool = true

    var body: some View {
        Form {
            Section {
                Text("authorizationStatus: \(authStatusText)")
                Text("isStepCountingAvailable: \(boolText(CMPedometer.isStepCountingAvailable()))")
                Text("isDistanceAvailable: \(boolText(CMPedometer.isDistanceAvailable()))")
                Text("isCadenceAvailable: \(boolText(CMPedometer.isCadenceAvailable()))")
                Text("isPaceAvailable: \(boolText(CMPedometer.isPaceAvailable()))")
            } header: {
                Text("CMPedometer capabilities")
            }
            .font(.system(.footnote, design: .monospaced))

            Section {
                Button {
                    Task { await runPedometerTest() }
                } label: {
                    HStack {
                        Text("Run pedometer test (last 5 min)")
                        Spacer()
                        if pedometerTestBusy { ProgressView() }
                    }
                }
                .disabled(pedometerTestBusy)

                Text(pedometerTestResult)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } header: {
                Text("Pedometer one-shot")
            } footer: {
                Text("Asks CMPedometer for pedometer data over the last 5 minutes. If this returns 0 steps in your hand right now, the API isn't working for this app/device combination — fix the permission first.")
            }

            Section {
                row("isActive", value: boolText(workoutSession.isActive))
                row("distanceMeters", value: String(format: "%.1f", workoutSession.distanceMetersForDiagnostics))
                row("cadenceSPM", value: workoutSession.currentCadenceSPMForDiagnostics.map { String(format: "%.0f", $0) } ?? "nil")
                row("lastError", value: workoutSession.lastError ?? "—")
            } header: {
                Text("PhoneWorkoutSession state")
            }
            .font(.system(.footnote, design: .monospaced))

            Section {
                HStack {
                    Button("Refresh logs") {
                        Task { await refreshLogs() }
                    }
                    .disabled(refreshingLogs)
                    Spacer()
                    if refreshingLogs {
                        ProgressView()
                    }
                    Button("Copy logs") {
                        UIPasteboard.general.string = logText
                    }
                    .disabled(refreshingLogs)
                }
                ScrollView {
                    Text(logText)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                .frame(maxHeight: 340)
            } header: {
                Text("club.aarun.AARC log (last ~5 min)")
            } footer: {
                Text("Reads OSLog entries for our subsystem from this app's process. Paste into chat to share with the debugger.")
            }
        }
        .navigationTitle("Diagnostics")
        .task { await refreshLogs() }
    }

    // MARK: - Pedometer test

    private func runPedometerTest() async {
        pedometerTestBusy = true
        defer { pedometerTestBusy = false }
        guard CMPedometer.isStepCountingAvailable() else {
            pedometerTestResult = "isStepCountingAvailable=false. Either device unsupported or motion services off."
            return
        }
        let p = CMPedometer()
        let from = Date().addingTimeInterval(-5 * 60)
        let to = Date()
        let started = Date()
        // Marked @Sendable to strip the @MainActor isolation Swift 6 would
        // otherwise inherit from the enclosing function. CMPedometer fires
        // the callback on its own private dispatch queue; without this the
        // runtime traps with _dispatch_assert_queue_fail at entry.
        let result: String = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let handler: @Sendable (CMPedometerData?, Error?) -> Void = { data, error in
                let elapsed = Date().timeIntervalSince(started)
                var lines: [String] = []
                lines.append("queryPedometerData → \(String(format: "%.2f", elapsed))s")
                if let error {
                    lines.append("ERROR: \(error.localizedDescription)")
                } else if let data {
                    lines.append("steps: \(data.numberOfSteps.intValue)")
                    if let d = data.distance {
                        lines.append("distance: \(String(format: "%.2f", d.doubleValue)) m")
                    } else {
                        lines.append("distance: nil")
                    }
                    if let c = data.currentCadence {
                        lines.append("cadence (steps/sec): \(String(format: "%.2f", c.doubleValue))")
                    } else {
                        lines.append("cadence: nil")
                    }
                    if let pace = data.currentPace {
                        lines.append("currentPace (sec/m): \(String(format: "%.2f", pace.doubleValue))")
                    } else {
                        lines.append("currentPace: nil")
                    }
                } else {
                    lines.append("Both data and error nil — API bug")
                }
                cont.resume(returning: lines.joined(separator: "\n"))
            }
            p.queryPedometerData(from: from, to: to, withHandler: handler)
        }
        pedometerTestResult = result + "\nauthStatus: " + authStatusText
    }

    // MARK: - OSLog reader

    private func refreshLogs() async {
        refreshingLogs = true
        defer { refreshingLogs = false }
        // OSLogStore.getEntries is a synchronous scan over the process's
        // ring buffer and can take >1s with a noisy app. Run it on a
        // background thread so the navigation push isn't blocked and the
        // form renders immediately with a spinner in the log section.
        let result: String = await Task.detached(priority: .userInitiated) {
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let anchor = store.position(date: Date().addingTimeInterval(-5 * 60))
                let predicate = NSPredicate(format: "subsystem == %@", "club.aarun.AARC")
                let entries = try store.getEntries(at: anchor, matching: predicate)
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss.SSS"
                var collected: [String] = []
                for entry in entries {
                    guard let logEntry = entry as? OSLogEntryLog else { continue }
                    let ts = formatter.string(from: logEntry.date)
                    let cat = logEntry.category
                    collected.append("\(ts) [\(cat)] \(logEntry.composedMessage)")
                }
                if collected.isEmpty {
                    return "(no entries for subsystem club.aarun.AARC in the last 5 min — try reproducing now, then Refresh)"
                }
                return collected.reversed().joined(separator: "\n")
            } catch {
                return "OSLogStore failed: \(error.localizedDescription)"
            }
        }.value
        logText = result
    }

    // MARK: - Helpers

    private var authStatusText: String {
        switch CMPedometer.authorizationStatus() {
        case .authorized: return "authorized"
        case .denied: return "denied — Settings → AARC → Motion & Fitness"
        case .restricted: return "restricted (parental controls)"
        case .notDetermined: return "notDetermined (will prompt on first use)"
        @unknown default: return "unknown"
        }
    }

    private func boolText(_ b: Bool) -> String { b ? "true" : "false" }

    @ViewBuilder
    private func row(_ key: String, value: String) -> some View {
        HStack {
            Text(key)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }
}
