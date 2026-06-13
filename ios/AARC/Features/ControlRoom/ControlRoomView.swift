import SwiftUI
import WatchConnectivity
import AARCKit

/// Air-traffic-control view over the entire pipeline — reachable mid-run.
/// Dense, dark, scannable. Read-only: every row is a live mirror of an
/// `@Observable` singleton, plus one active probe (a 10s `/ping` loop
/// against the Worker proxy that runs only while the view is visible).
///
/// Sections: RUN PROGRESS / NETWORK INSPECTOR / WATCH LINK / DIRECTOR /
/// VOICE QUEUE / VOICES / MUSIC / EVENT TAIL. A `TimelineView` ticks the
/// whole body at 1 Hz so relative ages (queue item age, ETA countdowns)
/// stay live even when no observable state changes. The NETWORK INSPECTOR
/// rows that are in-flight tick faster (4 Hz) via their own nested
/// `TimelineView` so a synth's "awaiting the network" ms ticks smoothly.
struct ControlRoomView: View {
    /// When non-nil, the view is a REPLAY of a past run reconstructed from
    /// its recorded JSONL events instead of a live mirror of the singletons.
    /// nil = the original LIVE behavior, byte-for-byte unchanged.
    let replay: RunEventLog.ArchivedRun?

    /// Recorded events for the replayed run (loaded once, off-main). Empty
    /// in live mode and until the background load finishes in replay mode.
    @State private var replayEvents: [RunLogEvent] = []
    @State private var replayLoaded = false

    @State private var consumer = LiveMetricsConsumer.shared
    @State private var phoneSession = PhoneSession.shared
    @State private var mirror = MirroringReceiver.shared
    @State private var director = RunDirector.shared
    @State private var queue = VoiceFeedbackQueue.shared
    @State private var conversation = Conversation.shared
    @State private var nowPlaying = NowPlayingStore.shared
    @State private var eventLog = RunEventLog.shared
    @State private var simulator = RunSimulator.shared
    @State private var netMonitor = NetworkActivityMonitor.shared
    @State private var planStore = ScriptPreviewStore.shared

    /// Default initializer keeps the LIVE call sites (`ControlRoomView()`)
    /// unchanged; pass a `replay:` to reconstruct a historical run.
    init(replay: RunEventLog.ArchivedRun? = nil) {
        self.replay = replay
    }

    private var isReplay: Bool { replay != nil }

    // MARK: - Ping probe state

    /// Last measured /ping round-trip in ms. nil = failed or not yet probed.
    @State private var pingMs: Int?
    /// Last probe failure, if any.
    @State private var pingError: String?
    /// When the last probe completed (success or failure).
    @State private var lastProbeAt: Date?
    /// The 10s probe loop. Started onAppear, cancelled onDisappear.
    @State private var probeTask: Task<Void, Never>?

    private static let pingInterval: TimeInterval = 10
    private static let pingGreenBelowMs = 300
    private static let pingYellowBelowMs = 1000

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isReplay {
                        replayBody(now: timeline.date)
                    } else {
                        liveBody(now: timeline.date)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .background(Color(red: 0.03, green: 0.03, blue: 0.05).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            // Never start the live /ping probe in replay mode.
            if isReplay { loadReplayIfNeeded() } else { startProbe() }
        }
        .onDisappear { stopProbe() }
    }

    /// The original LIVE layout — every section a mirror of an @Observable
    /// singleton, plus the active probe. Unchanged from before replay mode.
    @ViewBuilder
    private func liveBody(now: Date) -> some View {
        header(now: now)
        if simulator.isActive { simControlSection }
        runProgressSection(now: now)
        networkInspectorSection(now: now)
        watchLinkSection
        directorSection(now: now)
        voiceQueueSection(now: now)
        voicesSection
        musicSection
        eventTailSection
    }

    // MARK: - Simulator controls (desk test)

    @ViewBuilder
    private var simControlSection: some View {
        section("SIMULATOR", accent: .pink) {
            HStack {
                Text(String(format: "%.0f m", simulator.simDistance))
                    .font(.callout.bold().monospacedDigit())
                Text(formatElapsed(simulator.simElapsed))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Text(simulator.paused ? "PAUSED" : "\(Int(simulator.speedMultiplier))×")
                    .font(.caption.bold())
                    .foregroundStyle(simulator.paused ? .yellow : .pink)
            }
            if !simulator.autoEventLabel.isEmpty {
                Text(simulator.autoEventLabel)
                    .font(.caption2).foregroundStyle(.teal)
            }
            HStack(spacing: 8) {
                Text("Pace").font(.caption2).foregroundStyle(.secondary)
                Button { simulator.paceSecPerKm = min(900, simulator.paceSecPerKm + 15) } label: { Image(systemName: "minus") }
                Text(simPaceText).font(.caption.monospacedDigit()).frame(width: 52)
                Button { simulator.paceSecPerKm = max(150, simulator.paceSecPerKm - 15) } label: { Image(systemName: "plus") }
                Spacer()
                ForEach([1, 2, 4, 8], id: \.self) { m in
                    Button("\(m)×") { simulator.speedMultiplier = Double(m) }
                        .tint(Int(simulator.speedMultiplier) == m ? .pink : .gray)
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
            HStack(spacing: 6) {
                Button(simulator.paused ? "Resume" : "Pause") { simulator.paused.toggle() }.tint(.yellow)
                Button("Stand still") { simulator.injectStationary() }
                Button("HR↑") { simulator.injectHRSpike() }
                Button("Surge") { simulator.injectPaceSurge() }
            }
            .buttonStyle(.bordered).controlSize(.small)
            HStack(spacing: 6) {
                Text("Jump").font(.caption2).foregroundStyle(.secondary)
                Button("+500 m") { simulator.jump(meters: 500) }
                Button("+1 km") { simulator.jump(meters: 1000) }
                Button("+2 km") { simulator.jump(meters: 2000) }
            }
            .buttonStyle(.bordered).controlSize(.small)
            placeAwarenessRows
        }
    }

    /// Live diagnosis of the place-awareness pipeline during a simulated
    /// outdoor run: the synthetic route, what geocoding/POI resolved, the
    /// detected route shape, and whether the LLM payload is non-nil.
    @ViewBuilder
    private var placeAwarenessRows: some View {
        let place = PlaceContext.shared
        if place.isActive {
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("PLACE").font(.caption2.bold()).foregroundStyle(.teal)
                    Spacer()
                    Text(place.llmInfo != nil ? "feeding LLM" : "no payload yet")
                        .font(.caption2)
                        .foregroundStyle(place.llmInfo != nil ? .teal : .secondary)
                }
                if !place.trail.isEmpty || !simulator.displayRouteCoords.isEmpty {
                    RunMapView(
                        points: place.trail,
                        current: place.displayCurrent,
                        pois: place.poiPins,
                        plannedRoute: simulator.displayRouteCoords,
                        follow: true,
                        showsColorToggle: true
                    )
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else if !simulator.routeStatus.isEmpty {
                    Text(simulator.routeStatus)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let s = place.snapshot {
                    Text([s.road, s.area].compactMap { $0 }.joined(separator: ", "))
                        .font(.caption.bold())
                }
                ForEach(place.poiPins.prefix(4)) { poi in
                    HStack(spacing: 6) {
                        Image(systemName: poi.symbol)
                            .font(.caption2)
                            .foregroundStyle(poi.isHotel ? .pink : .teal)
                            .frame(width: 14)
                        Text(poi.name).font(.caption2).lineLimit(1)
                        Spacer()
                        Text("\(poi.meters)m").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let route = place.routeDescriptionNow {
                    Text(route).font(.caption2.italic()).foregroundStyle(.teal)
                }
            }
        }
    }

    private var simPaceText: String {
        let p = Int(simulator.paceSecPerKm)
        return String(format: "%d:%02d", p / 60, p % 60)
    }

    /// The REPLAY layout — the SAME sections reconstructed from recorded
    /// events. Purely-live gauges (watch link, director, voice queue,
    /// voices, music, ping probe) are replaced by a derived RUN SUMMARY.
    @ViewBuilder
    private func replayBody(now: Date) -> some View {
        replayHeader()
        if !replayLoaded {
            replayLoadingHint()
        } else {
            replayRunProgressSection()
            replayNetworkInspectorSection(now: now)
            replayRunSummarySection()
            replayEventTailSection()
        }
    }

    /// Load the replayed run's events once, off the main actor.
    private func loadReplayIfNeeded() {
        guard isReplay, !replayLoaded else { return }
        guard let runId = replay?.runId else { return }
        Task {
            let events = await Task.detached(priority: .userInitiated) {
                RunEventLog.loadEvents(runId: runId)
            }.value
            replayEvents = events
            replayLoaded = true
        }
    }

    @ViewBuilder
    private func replayLoadingHint() -> some View {
        section("LOADING", accent: .teal) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.teal)
                Text("Reconstructing run from on-device log…")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(now: Date) -> some View {
        HStack(spacing: 10) {
            Text("CONTROL ROOM")
                .font(.caption.weight(.heavy))
                .tracking(2.0)
                .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 0)
            if consumer.isRunActive, let metrics = consumer.latest {
                Text(metrics.state.rawValue.uppercased())
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(
                        (metrics.state == .running ? Color.green : Color.yellow).opacity(0.22),
                        in: Capsule()
                    )
                    .foregroundStyle(metrics.state == .running ? .green : .yellow)
                Text(formatElapsed(metrics.elapsed))
                    .font(.system(.callout, design: .monospaced).weight(.bold))
                    .foregroundStyle(.white)
            } else {
                Text("NO ACTIVE RUN")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    // MARK: - REPLAY: header

    /// Replay header: run date + duration + a clear REPLAY badge, instead of
    /// the live elapsed clock.
    @ViewBuilder
    private func replayHeader() -> some View {
        HStack(spacing: 10) {
            Text("CONTROL ROOM")
                .font(.caption.weight(.heavy))
                .tracking(2.0)
                .foregroundStyle(.white.opacity(0.9))
            Text("REPLAY")
                .font(.caption2.weight(.heavy))
                .tracking(1.5)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.purple.opacity(0.28), in: Capsule())
                .foregroundStyle(.purple)
                .overlay(Capsule().stroke(.purple.opacity(0.6), lineWidth: 1))
            Spacer(minLength: 0)
            if let run = replay {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(run.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .foregroundStyle(.white)
                    Text(run.duration.map { formatElapsed($0) } ?? "—")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
    }

    // MARK: - REPLAY: run progress

    /// Replay progress: derived purely from recorded `metrics` events. The
    /// end value is the last metrics d/t, so the track shows the run's full
    /// extent (filled to 100%) with voice markers overlaid by elapsed time.
    @ViewBuilder
    private func replayRunProgressSection() -> some View {
        let metrics = replayMetricsEvents()
        let lastDistance = metrics.compactMap { Double($0.data["d"] ?? "") }.last
        let lastElapsed = metrics.last.map { max(0, $0.t) }
            ?? replay?.duration
        section("RUN PROGRESS", accent: .teal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(formatElapsed(lastElapsed ?? 0))
                        .font(.system(.callout, design: .monospaced).weight(.bold))
                        .foregroundStyle(.white)
                    Text("elapsed")
                        .font(.caption2).foregroundStyle(.white.opacity(0.4))
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(lastDistance.map { String(format: "%.2f km", $0 / 1000) } ?? "—")
                        .font(.system(.callout, design: .monospaced).weight(.bold))
                        .foregroundStyle(.white)
                    Text("distance")
                        .font(.caption2).foregroundStyle(.white.opacity(0.4))
                }
            }
            // Completed run: a fully-filled teal track with voice markers
            // placed by their elapsed-time fraction over the run span.
            progressTrack(
                frac: lastElapsed != nil ? 1 : nil,
                accent: .teal,
                markerFracs: replayVoiceMarkerFracs(totalElapsed: lastElapsed)
            )
            row("Metrics samples", "\(metrics.count)")
        }
    }

    /// Fractions (0..1) along the replay track where voice lines played,
    /// from `speech` / `voice.play` events mapped by elapsed-time over the
    /// run span. Robust for any plan kind (recorded speech carries `t` but
    /// not distance).
    private func replayVoiceMarkerFracs(totalElapsed: Double?) -> [Double] {
        guard let total = totalElapsed, total > 0 else { return [] }
        return replayEvents.filter {
            let l = $0.type.lowercased()
            return l == "speech" || l == "voice.play"
        }.compactMap { $0.t >= 0 ? min(1, max(0, $0.t / total)) : nil }
    }

    // MARK: - REPLAY: network inspector

    /// Replay network inspector: reconstruct rows from recorded `net.req`
    /// events. All historical → all rendered as completed rows (no pulsing,
    /// no in-flight), newest first, plus a per-service / latency summary.
    @ViewBuilder
    private func replayNetworkInspectorSection(now: Date) -> some View {
        let entries = replayNetEntries()
        section("NETWORK INSPECTOR", accent: .cyan) {
            replayNetSummary(entries)
                .padding(.bottom, 2)
            if entries.isEmpty {
                row("Requests", "none recorded")
            } else {
                ForEach(entries) { entry in
                    inspectorRow(entry, now: now)
                }
            }
        }
    }

    /// Summary line: counts per service, # failed, avg/median ms.
    @ViewBuilder
    private func replayNetSummary(_ entries: [NetworkActivityMonitor.Entry]) -> some View {
        let elevenlabs = entries.filter { $0.service == "11Labs" }.count
        let llm = entries.filter { $0.service == "LLM" }.count
        let failed = entries.filter { $0.phase == .failed }.count
        let mss = entries.map { $0.elapsedMs(now: $0.endedAt ?? $0.startedAt) }.sorted()
        let avg = mss.isEmpty ? 0 : mss.reduce(0, +) / mss.count
        let median = mss.isEmpty ? 0 : mss[mss.count / 2]
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                inspectorSummaryPill("11L", count: elevenlabs, color: .orange)
                inspectorSummaryPill("LLM", count: llm, color: .cyan)
                inspectorSummaryPill("FAIL", count: failed, color: failed > 0 ? .red : .white.opacity(0.3))
                Spacer(minLength: 0)
            }
            if !mss.isEmpty {
                Text("avg \(avg) ms · median \(median) ms")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    @ViewBuilder
    private func inspectorSummaryPill(_ label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(.caption2, design: .monospaced).weight(.bold))
            Text("\(count)").font(.system(.caption2, design: .monospaced).weight(.bold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
    }

    /// Rebuild `NetworkActivityMonitor.Entry` rows from recorded `net.req`
    /// events so we can reuse `inspectorRow` / `phaseChip` verbatim. Newest
    /// first. Phase comes from `data["phase"]`; ms back-dates `startedAt`
    /// from a synthetic `endedAt` so `elapsedMs` reports the recorded ms.
    private func replayNetEntries() -> [NetworkActivityMonitor.Entry] {
        let reqs = replayEvents.filter { $0.type.lowercased() == "net.req" }
        let rows: [NetworkActivityMonitor.Entry] = reqs.map { e in
            let svc = e.data["svc"] ?? "LLM"
            let ms = Int(e.data["ms"] ?? "") ?? 0
            let end = Date()
            let start = end.addingTimeInterval(-Double(ms) / 1000)
            var entry = NetworkActivityMonitor.Entry(
                service: svc,
                label: e.detail,
                chars: e.data["chars"].flatMap { Int($0) },
                phase: replayPhase(e.data["phase"]),
                startedAt: start
            )
            entry.endedAt = end
            entry.bytes = e.data["bytes"].flatMap { Int($0) }
            entry.detail = e.data["info"]
            return entry
        }
        // Recorded oldest-first; the inspector wants newest-first.
        return rows.reversed()
    }

    /// Map a recorded `data["phase"]` string to a monitor Phase. Historical
    /// rows are always terminal, so an unknown/missing phase is treated as
    /// `received` (a completed, non-error row).
    private func replayPhase(_ raw: String?) -> NetworkActivityMonitor.Phase {
        switch raw {
        case "failed":   return .failed
        case "cached":   return .cached
        case "received": return .received
        case "cancelled": return .cancelled
        default:         return .received
        }
    }

    // MARK: - REPLAY: run summary (replaces the live-only gauges)

    /// A derived overview shown in place of the purely-live gauges (watch
    /// link, director, voice queue, voices, music). Everything is counted
    /// straight off the recorded event stream.
    @ViewBuilder
    private func replayRunSummarySection() -> some View {
        let types = replayTypeCounts()
        let netEntries = replayNetEntries()
        let synthMs = netEntries
            .filter { $0.service == "11Labs" && $0.phase != .cached }
            .map { $0.elapsedMs(now: $0.endedAt ?? $0.startedAt) }
        let avgSynth = synthMs.isEmpty ? nil : synthMs.reduce(0, +) / synthMs.count
        let netFails = netEntries.filter { $0.phase == .failed }.count
        section("RUN SUMMARY", accent: .purple) {
            row("Voice lines", "\(types["speech", default: 0] + types["voice.play", default: 0])")
            row("Jessica ready", "\(types["jessica.ready", default: 0])")
            row("Coach triggers", "\(types["coach.trigger", default: 0])")
            row("Script dispatches", "\(types["script.dispatch", default: 0])")
            row("TTS fallbacks", "\(types["tts.fallback", default: 0])")
            row("Stale / preempt drops",
                "\(types["voice.dropStale", default: 0]) / \(types["voice.preempt", default: 0])")
            row("Endpoint switches", "\(types["endpoint.switch", default: 0])")
            if let avgSynth {
                row("Avg synth", "\(avgSynth) ms")
            }
            if netFails > 0 {
                errorRow("Network failures", "\(netFails) request(s) failed")
            } else {
                row("Network failures", "0")
            }
            row("Total events", "\(replayEvents.count)")
        }
    }

    // MARK: - REPLAY: event tail (full stream)

    /// In replay the tail shows the FULL recorded stream (scrollable),
    /// newest first, not just the last 30.
    @ViewBuilder
    private func replayEventTailSection() -> some View {
        section("EVENT TAIL", accent: .gray) {
            let rows = replayEventRows()
            if rows.isEmpty {
                row("Events", "none")
            } else {
                ForEach(rows.indices, id: \.self) { i in
                    let r = rows[i]
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(r.time)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.35))
                        Text(r.type)
                            .font(.system(.caption2, design: .monospaced).weight(.semibold))
                            .foregroundStyle(r.isError ? .red : .white.opacity(0.6))
                        Text(r.message)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(r.isError ? .red : .white.opacity(0.85))
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - REPLAY: event-stream helpers

    private func replayMetricsEvents() -> [RunLogEvent] {
        replayEvents.filter { $0.type.lowercased() == "metrics" }
    }

    /// Count of each event `type` across the whole replayed stream.
    private func replayTypeCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for e in replayEvents { counts[e.type, default: 0] += 1 }
        return counts
    }

    /// Full stream, newest-first, mapped to the tail's row model. Mirrors
    /// the live `eventRows()` formatting but without the 30-event cap.
    private func replayEventRows() -> [EventRowModel] {
        replayEvents.reversed().map { e in
            let lowered = e.type.lowercased()
            return EventRowModel(
                time: e.t >= 0 ? String(format: "%5.0fs", e.t) : "  pre",
                type: e.type,
                message: e.detail,
                isError: lowered.contains("error") || lowered.contains("fallback") || lowered.contains("drop")
            )
        }
    }

    // MARK: - RUN PROGRESS

    /// Web-dashboard-style timeline: a thin dark track with a bright
    /// position dot. Distance plans render against totalMeters, time plans
    /// against totalSeconds, open plans just count up with no fixed end.
    /// Small ticks mark where voice lines have played this run.
    @ViewBuilder
    private func runProgressSection(now: Date) -> some View {
        let metrics = consumer.latest
        let plan = planStore.currentPlan
        section("RUN PROGRESS", accent: .teal) {
            switch plan.kind {
            case .distance:
                distanceProgress(plan: plan, metrics: metrics)
            case .time:
                timeProgress(plan: plan, metrics: metrics)
            case .open:
                openProgress(metrics: metrics)
            }
        }
    }

    @ViewBuilder
    private func distanceProgress(plan: RunPlan, metrics: LiveMetrics?) -> some View {
        let total = plan.totalMeters ?? 0
        let current = metrics?.distanceMeters ?? 0
        let frac = total > 0 ? min(1, max(0, current / total)) : 0
        HStack(alignment: .firstTextBaseline) {
            Text(String(format: "%.2f", current / 1000))
                .font(.system(.callout, design: .monospaced).weight(.bold))
                .foregroundStyle(.white)
            Text("/ \(formatKm(total)) km")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 4)
            Text("\(Int((frac * 100).rounded()))%")
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(.teal)
        }
        progressTrack(frac: frac, accent: .teal, markerFracs: voiceMarkerFracs(axis: .distance, total: total))
        row("Distance left", total > current ? String(format: "%.2f km", (total - current) / 1000) : "0.00 km")
    }

    @ViewBuilder
    private func timeProgress(plan: RunPlan, metrics: LiveMetrics?) -> some View {
        let total = plan.totalSeconds ?? 0
        let current = metrics?.elapsed ?? 0
        let frac = total > 0 ? min(1, max(0, current / total)) : 0
        HStack(alignment: .firstTextBaseline) {
            Text(formatElapsed(current))
                .font(.system(.callout, design: .monospaced).weight(.bold))
                .foregroundStyle(.white)
            Text("/ \(formatElapsed(total))")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 4)
            Text("\(Int((frac * 100).rounded()))%")
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(.teal)
        }
        progressTrack(frac: frac, accent: .teal, markerFracs: voiceMarkerFracs(axis: .time, total: total))
        row("Time left", total > current ? formatElapsed(total - current) : "0:00")
        if let m = metrics { row("Distance", String(format: "%.2f km", m.distanceMeters / 1000)) }
    }

    @ViewBuilder
    private func openProgress(metrics: LiveMetrics?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(formatElapsed(metrics?.elapsed ?? 0))
                    .font(.system(.callout, design: .monospaced).weight(.bold))
                    .foregroundStyle(.white)
                Text("elapsed")
                    .font(.caption2).foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.2f km", (metrics?.distanceMeters ?? 0) / 1000))
                    .font(.system(.callout, design: .monospaced).weight(.bold))
                    .foregroundStyle(.white)
                Text("distance")
                    .font(.caption2).foregroundStyle(.white.opacity(0.4))
            }
        }
        // No fixed end — an indeterminate teal track that just states "open".
        progressTrack(frac: nil, accent: .teal, markerFracs: [])
        row("Plan", "open run · no target")
    }

    private enum ProgressAxis { case distance, time }

    /// Fractions along the track where "speech" events fired this run, so
    /// the founder can see when the coach actually spoke. Cheap: reads the
    /// last 80 events from the ring and maps t (sec) / distance to 0..1.
    private func voiceMarkerFracs(axis: ProgressAxis, total: Double) -> [Double] {
        guard total > 0 else { return [] }
        let speech = eventLog.recent.suffix(80).filter { $0.type.lowercased() == "speech" }
        switch axis {
        case .time:
            return speech.compactMap { $0.t >= 0 ? min(1, max(0, $0.t / total)) : nil }
        case .distance:
            return speech.compactMap { e in
                guard let d = e.data["d"], let meters = Double(d) else { return nil }
                return min(1, max(0, meters / total))
            }
        }
    }

    /// A thin dark track with a bright position dot, web-dashboard style.
    /// `frac == nil` renders an indeterminate (no-end) track.
    @ViewBuilder
    private func progressTrack(frac: Double?, accent: Color, markerFracs: [Double]) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let dotX = (frac ?? 0) * w
            ZStack(alignment: .leading) {
                // Track.
                Capsule()
                    .fill(.white.opacity(0.08))
                    .frame(height: 4)
                if let frac {
                    // Filled portion.
                    Capsule()
                        .fill(accent.opacity(0.55))
                        .frame(width: max(0, dotX), height: 4)
                    // Voice-line markers.
                    ForEach(markerFracs.indices, id: \.self) { i in
                        Rectangle()
                            .fill(.white.opacity(0.55))
                            .frame(width: 1.5, height: 9)
                            .offset(x: markerFracs[i] * w - 0.75)
                    }
                    // Position dot.
                    Circle()
                        .fill(accent)
                        .frame(width: 11, height: 11)
                        .shadow(color: accent.opacity(0.9), radius: 4)
                        .offset(x: min(max(0, dotX - 5.5), w - 11))
                } else {
                    // Indeterminate: a soft accent wash + a label dot at the head.
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.30), accent.opacity(0.05)],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(height: 4)
                    Circle()
                        .fill(accent)
                        .frame(width: 9, height: 9)
                        .shadow(color: accent.opacity(0.8), radius: 3)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 14)
        .padding(.vertical, 2)
    }

    // MARK: - NETWORK INSPECTOR

    /// Verbose 11Labs / LLM request inspector. Header carries live
    /// in-flight counts per service; the body is a newest-first list of
    /// recent requests with a phase chip (awaiting PULSES so an in-flight
    /// synth waiting on the network is unmistakable) and live ms.
    @ViewBuilder
    private func networkInspectorSection(now: Date) -> some View {
        section("NETWORK INSPECTOR", accent: .cyan) {
            // Endpoint + ping + in-flight header.
            HStack(spacing: 8) {
                Text(Config.apiBaseURL.host ?? "proxy")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                statusDot(pingColor)
                Text(pingLabel)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(pingColor)
                    .lineLimit(1)
                Spacer(minLength: 4)
                inFlightBadge(service: "11Labs", color: .orange)
                inFlightBadge(service: "LLM", color: .cyan)
            }
            .padding(.bottom, 2)

            let entries = Array(netMonitor.entries.prefix(12))
            if entries.isEmpty {
                row("Requests", "none yet")
            } else {
                ForEach(entries) { entry in
                    inspectorRow(entry, now: now)
                }
            }
        }
    }

    /// Live per-service in-flight pill, e.g. "11Labs ●2". Dimmed at zero.
    @ViewBuilder
    private func inFlightBadge(service: String, color: Color) -> some View {
        let count = netMonitor.inFlight[service] ?? 0
        HStack(spacing: 3) {
            Text(service)
                .font(.system(.caption2, design: .monospaced).weight(.bold))
            Circle()
                .fill(count > 0 ? color : .white.opacity(0.25))
                .frame(width: 6, height: 6)
            Text("\(count)")
                .font(.system(.caption2, design: .monospaced).weight(.bold))
        }
        .foregroundStyle(count > 0 ? color : .white.opacity(0.3))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background((count > 0 ? color : .white).opacity(0.10), in: Capsule())
    }

    /// One request row. Open requests tick their elapsed ms at 4 Hz via a
    /// nested TimelineView so the synth-wait counter visibly climbs; closed
    /// requests are static at their final ms.
    @ViewBuilder
    private func inspectorRow(_ entry: NetworkActivityMonitor.Entry, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.service == "11Labs" ? "11L" : "LLM")
                    .font(.system(.caption2, design: .monospaced).weight(.heavy))
                    .foregroundStyle(entry.service == "11Labs" ? .orange : .cyan)
                    .frame(width: 28, alignment: .leading)
                phaseChip(entry.phase)
                Text(prefix(entry.label, 34))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 4)
                elapsedReadout(entry, now: now)
            }
            // Meta line: chars + bytes when present.
            if entry.chars != nil || entry.bytes != nil {
                HStack(spacing: 8) {
                    if let c = entry.chars {
                        Text("\(c) ch")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    if let b = entry.bytes {
                        Text(formatBytes(b))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 34)
            }
            // Error detail in red on failure.
            if entry.phase == .failed, let detail = entry.detail {
                Text(prefix(detail, 90))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.leading, 34)
            }
        }
        .padding(.vertical, 1)
    }

    /// Live-ticking elapsed ms. Open requests get a 4 Hz nested timeline so
    /// the counter climbs in real time; closed requests show the final ms.
    @ViewBuilder
    private func elapsedReadout(_ entry: NetworkActivityMonitor.Entry, now: Date) -> some View {
        if entry.isOpen {
            TimelineView(.periodic(from: .now, by: 0.25)) { tl in
                Text("\(entry.elapsedMs(now: tl.date)) ms")
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.yellow)
                    .contentTransition(.numericText())
            }
        } else {
            Text("\(entry.elapsedMs(now: now)) ms")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    /// Phase chip. `awaiting` pulses (opacity animation) so an in-flight
    /// synth that is waiting on the network is visually unmistakable.
    @ViewBuilder
    private func phaseChip(_ phase: NetworkActivityMonitor.Phase) -> some View {
        let (label, color): (String, Color) = {
            switch phase {
            case .sending:  return ("SEND", .gray)
            case .awaiting: return ("WAIT", .yellow)
            case .received: return ("RECV", .green)
            case .failed:   return ("FAIL", .red)
            case .cached:   return ("CACHE", .blue)
            case .cancelled: return ("HEDGE", .secondary)
            }
        }()
        if phase == .awaiting {
            PulsingChip(label: label, color: color)
        } else {
            Text(label)
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .foregroundStyle(color)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(color.opacity(0.18), in: Capsule())
                .frame(width: 52, alignment: .leading)
        }
    }

    private var pingColor: Color {
        guard let ms = pingMs else { return lastProbeAt == nil ? .gray : .red }
        if ms < Self.pingGreenBelowMs { return .green }
        if ms < Self.pingYellowBelowMs { return .yellow }
        return .red
    }

    private var pingLabel: String {
        if let ms = pingMs { return "\(ms) ms" }
        if let err = pingError { return err }
        return "probing…"
    }

    // MARK: - WATCH LINK

    private var watchLinkSection: some View {
        section("WATCH LINK", accent: .orange) {
            boolRow("Reachable", phoneSession.isReachable)
            boolRow("Paired", phoneSession.isPaired)
            boolRow("App installed", phoneSession.isWatchAppInstalled)
            row("Activation", activationLabel(phoneSession.activationState))
            row("Watch build", phoneSession.counterpartBuild ?? "—")
            if phoneSession.buildMismatch {
                errorRow("Build drift", "watch ≠ phone — schema decode at risk")
            }
            boolRow("HK mirroring", mirror.isMirroring)
            row("Mirror run", mirror.currentRunId.map { String($0.uuidString.prefix(8)) } ?? "—")
        }
    }

    private func activationLabel(_ state: WCSessionActivationState) -> String {
        switch state {
        case .activated: return "activated (2)"
        case .inactive: return "inactive (1)"
        case .notActivated: return "notActivated (0)"
        @unknown default: return "unknown (\(state.rawValue))"
        }
    }

    // MARK: - DIRECTOR

    private func directorSection(now: Date) -> some View {
        section("DIRECTOR", accent: .mint) {
            row("Speed", String(format: "%.1f km/h", director.smoothedSpeedMps * 3.6))
            row("Next must-play", director.nextMustPlayETA.map { String(format: "T-%.0fs", $0) } ?? "—")
            boolRow("Protected window", director.isProtectedWindow, trueColor: .yellow, falseColor: .white.opacity(0.6))
            row("Pipeline lead", String(format: "%.1fs", director.pipelineLeadSeconds))
            boolRow("Room for exchange", director.hasRoomForExchange)
        }
    }

    // MARK: - VOICE QUEUE

    private func voiceQueueSection(now: Date) -> some View {
        section("VOICE QUEUE", accent: .pink) {
            if let cur = queue.currentlyPlaying {
                row("Playing", "\(cur.source) · \(prefix(cur.text, 36))")
            } else {
                row("Playing", "—")
            }
            if queue.pending.isEmpty {
                row("Pending", "empty")
            } else {
                ForEach(queue.pending.prefix(8)) { item in
                    HStack(spacing: 6) {
                        Text(priorityLabel(item.priority))
                            .font(.system(.caption2, design: .monospaced).weight(.bold))
                            .foregroundStyle(priorityColor(item.priority))
                            .frame(width: 28, alignment: .leading)
                        Text(item.source)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(Int(now.timeIntervalSince(item.createdAt)))s")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                if queue.pending.count > 8 {
                    row("…", "+\(queue.pending.count - 8) more")
                }
            }
            row("Counters",
                "ok \(queue.dispatched) · stale \(queue.droppedStale) · dup \(queue.droppedDuplicate) · preempt \(queue.preempted)")
        }
    }

    private func priorityLabel(_ p: VoicePriority) -> String {
        switch p {
        case .banter: return "BAN"
        case .coaching: return "CCH"
        case .milestone: return "MLS"
        }
    }

    private func priorityColor(_ p: VoicePriority) -> Color {
        switch p {
        case .banter: return .white.opacity(0.5)
        case .coaching: return .cyan
        case .milestone: return .pink
        }
    }

    // MARK: - VOICES

    private var voicesSection: some View {
        section("VOICES", accent: .purple) {
            boolRow("Jessica enabled", conversation.enabled)
            row("Last reaction", conversation.lastReaction.map { prefix($0, 60) } ?? "—")
            if let err = conversation.lastError {
                errorRow("Reaction error", err)
            }
        }
    }

    // MARK: - MUSIC

    private var musicSection: some View {
        section("MUSIC", accent: .green) {
            if let track = nowPlaying.track {
                row("Track", prefix(track.title, 40))
                row("Artist", prefix(track.artist, 40))
                boolRow("Playing", track.isPlaying)
            } else {
                row("Track", "nothing playing")
            }
        }
    }

    // MARK: - EVENT TAIL

    private var eventTailSection: some View {
        section("EVENT TAIL", accent: .gray) {
            let rows = eventRows()
            if rows.isEmpty {
                row("Events", "none")
            } else {
                ForEach(rows.indices, id: \.self) { i in
                    let r = rows[i]
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(r.time)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.35))
                        Text(r.type)
                            .font(.system(.caption2, design: .monospaced).weight(.semibold))
                            .foregroundStyle(r.isError ? .red : .white.opacity(0.6))
                        Text(r.message)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(r.isError ? .red : .white.opacity(0.85))
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private struct EventRowModel {
        let time: String
        let type: String
        let message: String
        let isError: Bool
    }

    /// ALL shape assumptions about RunEventLog live here. Real API:
    /// recent: [RunLogEvent] oldest-first; fields t (sec since run
    /// start, -1 pre-run), type: String, detail: String.
    private func eventRows() -> [EventRowModel] {
        let newest = Array(eventLog.recent.suffix(30).reversed())
        return newest.map { e in
            let lowered = e.type.lowercased()
            return EventRowModel(
                time: e.t >= 0 ? String(format: "%5.0fs", e.t) : "  pre",
                type: e.type,
                message: e.detail,
                isError: lowered.contains("error") || lowered.contains("fallback") || lowered.contains("drop")
            )
        }
    }

    // MARK: - Ping probe

    /// 10s `/ping` loop against the Worker proxy. Lives only while the
    /// view is on screen. Everything runs inside one `@MainActor` task —
    /// the only suspension points are `URLSession.data` and `Task.sleep`,
    /// so no escaping closures and no @Sendable hazards; all @State
    /// writes happen on the main actor by construction.
    private func startProbe() {
        probeTask?.cancel()
        probeTask = Task { @MainActor in
            while !Task.isCancelled {
                await runPingProbe()
                try? await Task.sleep(for: .seconds(Self.pingInterval))
            }
        }
    }

    private func stopProbe() {
        probeTask?.cancel()
        probeTask = nil
    }

    @MainActor
    private func runPingProbe() async {
        let url = Config.apiBaseURL.appendingPathComponent("ping")
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let started = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if Task.isCancelled { return }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                pingMs = ms
                pingError = nil
            } else {
                pingMs = nil
                pingError = "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            }
        } catch {
            if Task.isCancelled { return }
            pingMs = nil
            pingError = prefix(error.localizedDescription, 40)
        }
        lastProbeAt = Date()
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func section(_ title: String, accent: Color, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(accent)
                    .frame(width: 3, height: 10)
                Text(title)
                    .font(.caption2.weight(.heavy))
                    .tracking(1.8)
                    .foregroundStyle(accent.opacity(0.9))
            }
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 4)
            Text(value)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    private func boolRow(
        _ label: String,
        _ value: Bool,
        trueColor: Color = .green,
        falseColor: Color = .red
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 4)
            statusDot(value ? trueColor : falseColor)
            Text(value ? "YES" : "NO")
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(value ? trueColor : falseColor)
        }
    }

    private func errorRow(_ label: String, _ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.red.opacity(0.7))
            Spacer(minLength: 4)
            Text(prefix(message, 80))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.red)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
        }
    }

    private func statusDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.7), radius: 3)
    }

    // MARK: - Formatting

    private func prefix(_ text: String, _ n: Int) -> String {
        text.count > n ? String(text.prefix(n)) + "…" : text
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    /// km from meters, trimming a trailing ".0" for whole-km targets.
    private func formatKm(_ meters: Double) -> String {
        let km = meters / 1000
        return km.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", km)
            : String(format: "%.1f", km)
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// A "WAIT" phase chip that pulses its background so an in-flight request
/// blocked on the network is unmistakable at a glance. Self-animating via a
/// repeating `withAnimation` driven by `onAppear` — no parent timeline
/// needed and the animation stops when the row scrolls off / re-resolves.
private struct PulsingChip: View {
    let label: String
    let color: Color
    @State private var on = false

    var body: some View {
        Text(label)
            .font(.system(.caption2, design: .monospaced).weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(on ? 0.45 : 0.12), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(on ? 0.9 : 0.3), lineWidth: 1))
            .frame(width: 52, alignment: .leading)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}

#Preview {
    ControlRoomView()
}
