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
    /// `shared` drives the live post-run summary. History sharing builds its
    /// OWN detached instance (via `loadFromHistory`) so it never seeds the
    /// shared one — otherwise `isPresenting` would pop a stray summary sheet
    /// on the Run tab.
    init() {}

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
        var trail: [PlaceContext.TrailPoint]
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

    /// `.preparing` shows the interstitial; `.ready` reveals the full summary
    /// once the closing roast is in AND the run has synced to the cloud (or we
    /// hit the timeout). So the voice can play the instant the summary appears.
    enum Phase { case preparing, ready }
    private(set) var phase: Phase = .preparing
    private(set) var roastReady = false
    private(set) var synced = false

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
            trail: isOutdoor ? place.trail : [],
            pois: isOutdoor ? place.poiPins : [],
            plannedRoute: isOutdoor ? RunSimulator.shared.displayRouteCoords : [],
            routeDescription: place.routeDescriptionNow,
            hearted: liked,
            planTotalMeters: ScriptPreviewStore.shared.currentPlan.totalMeters
        )
        finalRoast = nil
        finalRoastFailed = false
        phase = .preparing
        roastReady = false
        synced = false
        Task { await self.generateFinalRoast() }
        Task { await self.awaitReadiness(runId: runId) }
    }

    /// Seed a DETACHED store from a finished run in History, so the share
    /// composer can re-generate an image/video for it later. Series come from
    /// the persisted blob (test/sim runs) or HealthKit (real runs). Unlike
    /// `capture()`, this never shows an interstitial or auto-plays — it lands
    /// in `.ready` and the share sheet drives playback on demand.
    func loadFromHistory(_ run: RunRecord) async {
        let isOutdoor = run.runTypeRaw == "outdoor"
        var speed: [Double] = [], hr: [Double] = []
        var trail: [PlaceContext.TrailPoint] = []

        if let blob = run.seriesBlob,
           let s = try? JSONDecoder().decode(StoredRunSeries.self, from: blob) {
            for p in s.pace where p.v > 0 { speed.append(3600.0 / p.v) }
            hr = s.hr.map(\.v)
            trail = s.trail.map {
                .init(coord: .init(latitude: $0.lat, longitude: $0.lon), kmh: $0.kmh, hr: $0.hr)
            }
        } else if let uuid = run.healthKitWorkoutUUID,
                  let workout = try? await HealthKitReader.shared.fetchWorkout(uuid: uuid) {
            // Real run — pull the richer series/route straight from HealthKit.
            async let hrPts = HealthKitReader.shared.fetchHeartRateSeries(during: workout)
            async let pacePts = HealthKitReader.shared.fetchPaceSeries(during: workout)
            async let route = HealthKitReader.shared.fetchRoute(for: workout)
            hr = ((try? await hrPts) ?? []).map(\.value)
            for p in ((try? await pacePts) ?? []) where p.value > 0 { speed.append(3600.0 / p.value) }
            // HealthKit is WGS-84; transform to display space (GCJ in China).
            let coords = ChinaCoordinateTransform.displayCoordinates(
                ((try? await route) ?? []).map(\.coordinate))
            trail = coords.map { .init(coord: $0, kmh: nil, hr: nil) }
        }

        let avgHR = hr.isEmpty ? nil : hr.reduce(0, +) / Double(hr.count)
        summary = Summary(
            runId: run.id,
            startedAt: run.startedAt,
            isOutdoor: isOutdoor,
            isTest: run.isTestData,
            distanceMeters: run.cachedDistanceMeters,
            durationSeconds: run.cachedDurationSeconds,
            avgPaceSecPerKm: run.cachedAvgPaceSecPerKm,
            avgHR: avgHR,
            maxHR: hr.max(),
            speedSeries: speed,
            hrSeries: hr,
            splits: [],
            trail: isOutdoor ? trail : [],
            pois: [],
            plannedRoute: [],
            routeDescription: nil,
            // Hearted lines aren't bounded to a past run's window, so skip
            // them here — the freshly-generated closing roast is the quote.
            hearted: [],
            planTotalMeters: nil
        )
        finalRoast = nil
        finalRoastFailed = false
        phase = .ready
        roastReady = false
        synced = true
        Task { await self.generateFinalRoast() }
    }

    /// Hold the interstitial until BOTH the closing roast is in and the run
    /// has synced to the cloud — but never longer than 60s, so a stuck
    /// upstream or upload can't trap the runner on the spinner.
    private func awaitReadiness(runId: UUID) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            // roastReady is set by generateFinalRoast ONLY after the audio is
            // cached — so we hold the interstitial until the voice can play
            // instantly on reveal (not just until the text arrived).
            synced = (RunEventLog.syncedRunId == runId)
            if (roastReady || finalRoastFailed) && synced { break }
            try? await Task.sleep(for: .milliseconds(300))
            if summary?.runId != runId { return }   // dismissed / superseded
        }
        guard summary?.runId == runId else { return }
        phase = .ready
        // Play the closer the moment the summary reveals (if it arrived).
        if let text = finalRoast {
            let voiceId = finalRoastWho == "jessica" ? RemoteTTS.jessicaVoiceId : RemoteTTS.voiceId
            await Speaker.shared.playSync(text: text, voiceId: voiceId)
        }
    }

    func dismiss() {
        summary = nil
        finalRoast = nil
        finalRoastFailed = false
        phase = .preparing
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
                    lengthMode: "summary"
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
            // Pre-render the AUDIO now so the interstitial holds until the
            // voice is actually CACHED — then reveal + playback are instant,
            // not "summary shows, then silence while TTS fetches".
            let voiceId = useJessica ? RemoteTTS.jessicaVoiceId : RemoteTTS.voiceId
            await RemoteTTS.shared.prefetch(result.text, voiceId: voiceId)
            guard summary?.runId == s.runId else { return }
            roastReady = true
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
