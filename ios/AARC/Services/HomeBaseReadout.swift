import Foundation
import AARCKit
import os

/// Race mode: Home Base calls every kilometre in its own voice. Numbers first
/// (split, average, heart rate), then whatever the proxy found worth saying:
/// history, surroundings, weather, a flash from the control room. The script
/// engine hands the kilometre here instead of to Ricky or Jessica.
@MainActor
@Observable
final class HomeBaseReadout {
    static let shared = HomeBaseReadout()
    private let log = Logger(subsystem: "club.aarun.AARC", category: "HomeBaseReadout")

    private(set) var isProducing = false
    private(set) var lastKm = 0
    private var task: Task<Void, Never>?
    private var recentLines: [String] = []

    func reset() {
        task?.cancel(); task = nil
        isProducing = false
        lastKm = 0
        recentLines = []
    }

    /// `fallback` speaks the pre-baked scripted line for this kilometre when
    /// the proxy cannot be reached (race day: the first half hour has no
    /// signal). Online, Home Base calls the kilometre; offline, Ricky does.
    func deliver(km: Int, metrics: LiveMetrics, fallback: (@MainActor () -> Void)? = nil) {
        guard km > lastKm else { return }
        lastKm = km
        task?.cancel()
        // Dark: no request at all. Home Base briefs the ground from the pack,
        // and Ricky's pack line still carries the kilometre.
        if EndpointManager.shared.isDark, let fallback {
            RunEventLog.shared.record("milestone.owner", "ricky:dark", data: ["km": String(km)])
            fallback()
            speakPackLine(km: km)
            return
        }
        isProducing = true
        let projected = RunDirector.shared.projected(distance: metrics.distanceMeters, elapsed: metrics.elapsed)
        let plan = ScriptPreviewStore.shared.currentPlan
        let runType = LiveMetricsConsumer.shared.pendingRunType
        let context = AIClient.DynamicLineContext(
            elapsedSeconds: projected.elapsed,
            distanceMeters: projected.distance,
            currentHR: metrics.currentHeartRate,
            avgHR: nil,
            currentPaceSecPerKm: metrics.currentPaceSecPerKm,
            avgPaceSecPerKm: metrics.avgPaceSecPerKm,
            planKind: plan.kind.rawValue,
            planDistanceKm: plan.distanceKm,
            planTimeMinutes: plan.timeMinutes,
            runType: runType.rawValue,
            stationarySeconds: nil,
            progressFraction: RunDirector.shared.progressFraction,
            place: PlaceContext.shared.llmInfo,
            ambient: PlaceContext.shared.ambientInfo
        )
        let request = AIClient.HomeBaseReadoutRequest(
            km: km,
            runContext: context,
            lastSplitSecPerKm: metrics.lastSplit?.paceSecPerKm,
            avgHR: metrics.lastSplit?.avgHeartRate,
            recentLines: recentLines.isEmpty ? nil : recentLines,
            camera: RaceCameraDirector.shared.readoutInfo
        )
        RunEventLog.shared.record("home.readout.request", "km \(km)")
        let decisionAt = AppClock.now
        // A slow network must not leave the marker unspoken: 15 s, then Ricky's
        // pack line, and a late readout is dropped.
        let gate = Gate()
        if let fallback {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                guard !gate.settled, self.lastKm == km, LiveMetricsConsumer.shared.isRunActive else { return }
                gate.settled = true
                RunEventLog.shared.record("milestone.owner", "ricky:slow", data: ["km": String(km)])
                fallback()
                self.speakPackLine(km: km)
            }
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isProducing = false; self.task = nil }
            do {
                let result = try await AIClient.shared.homeBaseReadout(request)
                guard !Task.isCancelled, LiveMetricsConsumer.shared.isRunActive, !gate.settled else { return }
                gate.settled = true
                self.recentLines.append(result.text)
                if self.recentLines.count > 6 { self.recentLines.removeFirst() }
                RunEventLog.shared.record("home.readout", String(result.text.prefix(80)), data: ["km": String(km)])
                // Milestone priority: it belongs on the marker, and it may
                // preempt banter. Expires if the queue is somehow jammed past
                // the next kilometre; a stale readout is worse than none.
                Speaker.shared.speak(result.text, priority: .milestone, source: "home:readout:km\(km)",
                                     expiresAfter: 240, voiceId: RemoteTTS.homeVoiceId, decisionAt: decisionAt)
            } catch {
                self.log.error("readout km \(km) failed: \(error.localizedDescription, privacy: .public)")
                RunEventLog.shared.record("home.readout.failed", error.localizedDescription, data: ["km": String(km)])
                guard !Task.isCancelled, LiveMetricsConsumer.shared.isRunActive, !gate.settled, let fallback else { return }
                gate.settled = true
                RunEventLog.shared.record("milestone.owner", "ricky:offline", data: ["km": String(km)])
                fallback()
                self.speakPackLine(km: km)
            }
        }
    }

    private func speakPackLine(km: Int) {
        guard let text = RacePackStore.shared.homeLine(km: km) else { return }
        RunEventLog.shared.record("home.pack", String(text.prefix(80)), data: ["km": String(km)])
        Speaker.shared.speak(text, priority: .milestone, source: "home:pack:km\(km)",
                             expiresAfter: 240, voiceId: RemoteTTS.homeVoiceId)
    }
}

/// Whichever of the readout and the deadline lands first speaks the kilometre.
@MainActor private final class Gate { var settled = false }
