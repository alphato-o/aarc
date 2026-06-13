import Foundation
import Observation
import CoreLocation
import AARCKit

/// Captures everything the post-run summary screen needs at the moment a
/// run ends — performance, the speed/HR series, the route + POIs (outdoor),
/// the lines the runner hearted — and kicks off one final whole-run roast
/// from Ricky or Jessica. Lives a single run; cleared when the runner
/// dismisses the summary.
@MainActor
@Observable
final class RunSummaryStore {
    static let shared = RunSummaryStore()
    private init() {}

    struct HeartedLine: Identifiable, Sendable {
        let id = UUID()
        let who: String      // "ricky" | "jessica"
        let text: String
        let voiceId: String
    }

    struct Summary {
        var runId: UUID
        var startedAt: Date
        var isOutdoor: Bool
        var isTest: Bool
        var distanceMeters: Double
        var durationSeconds: Double
        var avgPaceSecPerKm: Double
        var avgHR: Double?
        var maxHR: Double?
        var speedSeries: [Double]      // km/h per 100m bucket
        var hrSeries: [Double]         // bpm per 100m bucket
        var splits: [Double]           // per-km seconds
        // map (outdoor) — display space, ready to plot
        var trail: [CLLocationCoordinate2D]
        var pois: [PlaceContext.POIPin]
        var plannedRoute: [CLLocationCoordinate2D]
        var routeDescription: String?
        var hearted: [HeartedLine]
        var planTotalMeters: Double?      // the distance goal, if any
        /// Metres run beyond a distance goal (0 if none / under goal).
        var overageMeters: Double {
            guard let g = planTotalMeters, g > 0, distanceMeters > g else { return 0 }
            return distanceMeters - g
        }
    }

    private(set) var summary: Summary?
    /// The end-of-run roast about the whole run. nil while generating.
    private(set) var finalRoast: String?
    private(set) var finalRoastWho: String = "ricky"
    private(set) var finalRoastFailed = false

    var isPresenting: Bool { summary != nil }

    /// Build the summary from live state at run end. Safe to read
    /// PlaceContext / RunSimulator here — neither clears its map state on
    /// stop, so the trail and POIs are still intact.
    func capture() {
        let consumer = LiveMetricsConsumer.shared
        guard let runId = consumer.currentRunId else { return }
        let startedAt = consumer.startedAt ?? Date()
        let isOutdoor = consumer.pendingRunType == .outdoor

        let samples = LiveRunChartStore.shared.samples
        var speed: [Double] = [], hr: [Double] = []
        for s in samples {
            if let p = s.paceSecPerKm, p > 0 { speed.append(3600.0 / p) }
            if let h = s.heartRate, h > 0 { hr.append(h) }
        }
        let distance = consumer.latest?.distanceMeters
            ?? (samples.last.map { Double($0.bucketIndex) * 100 } ?? 0)
        let duration = consumer.latest?.elapsed ?? 0
        let avgPace = (distance > 0 && duration > 0) ? duration / (distance / 1000) : 0
        let avgHR = hr.isEmpty ? nil : hr.reduce(0, +) / Double(hr.count)
        let maxHR = hr.max()

        let place = PlaceContext.shared
        let liked = LikedLinesStore.shared.likedSince(startedAt).map { l in
            let who = l.personalityId == "jessica" ? "jessica" : "ricky"
            return HeartedLine(
                who: who,
                text: l.text,
                voiceId: who == "jessica" ? RemoteTTS.jessicaVoiceId : RemoteTTS.voiceId
            )
        }

        summary = Summary(
            runId: runId,
            startedAt: startedAt,
            isOutdoor: isOutdoor,
            isTest: RunOrchestrator.shared.isTestRun,
            distanceMeters: distance,
            durationSeconds: duration,
            avgPaceSecPerKm: avgPace,
            avgHR: avgHR,
            maxHR: maxHR,
            speedSeries: speed,
            hrSeries: hr,
            splits: Self.splits(from: samples),
            trail: isOutdoor ? place.displayTrail : [],
            pois: isOutdoor ? place.poiPins : [],
            plannedRoute: isOutdoor ? RunSimulator.shared.displayRouteCoords : [],
            routeDescription: place.routeDescriptionNow,
            hearted: liked,
            planTotalMeters: ScriptPreviewStore.shared.currentPlan.totalMeters
        )
        finalRoast = nil
        finalRoastFailed = false
        Task { await self.generateFinalRoast() }
    }

    func dismiss() {
        summary = nil
        finalRoast = nil
        finalRoastFailed = false
        Speaker.shared.stopActiveBackend()
    }

    // MARK: - Per-km splits from 100m buckets

    private static func splits(from samples: [LiveRunChartSample]) -> [Double] {
        guard !samples.isEmpty else { return [] }
        var out: [Double] = []
        // Each bucket is 100m; sum 10 buckets' pace-seconds per 100m.
        var acc = 0.0, count = 0
        for s in samples {
            guard let p = s.paceSecPerKm, p > 0 else { continue }
            acc += p / 10.0   // seconds to cover this 100m at that pace
            count += 1
            if count == 10 { out.append(acc); acc = 0; count = 0 }
        }
        return out
    }

    // MARK: - Final whole-run roast

    private func generateFinalRoast() async {
        guard let s = summary else { return }
        // Coin-flip the closer between the two voices.
        let useJessica = Bool.random()
        let who = useJessica ? "jessica" : "ricky"
        let recap = Self.recapNote(s)
        do {
            let result: AIClient.DynamicLineResult
            if useJessica {
                let ctx = AIClient.ReactLineContext(
                    elapsedSeconds: s.durationSeconds,
                    distanceMeters: s.distanceMeters,
                    currentHR: s.avgHR,
                    currentPaceSecPerKm: s.avgPaceSecPerKm,
                    planKind: "open",
                    runType: s.isOutdoor ? "outdoor" : "treadmill",
                    place: PlaceContext.shared.llmInfo
                )
                let req = AIClient.ReactLineRequest(
                    personalityId: "jessica",
                    partnerLine: "The run's over. \(recap)",
                    partnerSource: "run.finish",
                    runContext: ctx,
                    personalNotes: PersonalContextStore.shared.bullets,
                    likedLineExamples: LikedLinesStore.shared.vibeExemplars(personalityId: "jessica"),
                    lengthMode: "medium"
                )
                result = try await AIClient.shared.reactLine(req)
            } else {
                let ctx = AIClient.DynamicLineContext(
                    elapsedSeconds: s.durationSeconds,
                    distanceMeters: s.distanceMeters,
                    currentHR: s.avgHR,
                    avgHR: s.avgHR,
                    currentPaceSecPerKm: s.avgPaceSecPerKm,
                    avgPaceSecPerKm: s.avgPaceSecPerKm,
                    planKind: "open",
                    runType: s.isOutdoor ? "outdoor" : "treadmill",
                    place: PlaceContext.shared.llmInfo
                )
                let req = AIClient.DynamicLineRequest(
                    personalityId: "roast_coach",
                    trigger: .custom,
                    runContext: ctx,
                    customNote: "THE RUN IS OVER — deliver ONE final sign-off line about the WHOLE run, not this instant. \(recap)",
                    personalNotes: PersonalContextStore.shared.bullets,
                    likedLineExamples: LikedLinesStore.shared.vibeExemplars(personalityId: "roast_coach")
                )
                result = try await AIClient.shared.generateDynamicLine(req)
            }
            guard summary?.runId == s.runId else { return }
            finalRoastWho = who
            finalRoast = result.text
            // Speak it — the run's done, the music's off, this is the closer.
            let voiceId = useJessica ? RemoteTTS.jessicaVoiceId : RemoteTTS.voiceId
            await Speaker.shared.playSync(text: result.text, voiceId: voiceId)
        } catch {
            guard summary?.runId == s.runId else { return }
            finalRoastFailed = true
        }
    }

    private static func recapNote(_ s: Summary) -> String {
        var parts: [String] = []
        parts.append("Distance \(String(format: "%.2f", s.distanceMeters / 1000)) km")
        parts.append("time \(fmtDur(s.durationSeconds))")
        if s.avgPaceSecPerKm > 0 { parts.append("avg pace \(fmtPace(s.avgPaceSecPerKm))/km") }
        if let hr = s.avgHR { parts.append("avg HR \(Int(hr))") }
        if let route = s.routeDescription { parts.append("route: \(route)") }
        var note = parts.joined(separator: ", ") + "."
        if s.overageMeters > 200, let g = s.planTotalMeters {
            note += " They blew PAST their \(String(format: "%.1f", g/1000))km goal by \(String(format: "%.1f", s.overageMeters/1000))km before stopping — acknowledge the overachieving."
        }
        return note
    }

    static func fmtDur(_ sec: Double) -> String {
        let s = Int(sec); return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
    static func fmtPace(_ secPerKm: Double) -> String {
        let s = Int(secPerKm.rounded()); return String(format: "%d:%02d", s / 60, s % 60)
    }
}
