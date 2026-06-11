import SwiftUI
import WatchConnectivity
import AARCKit

/// Air-traffic-control view over the entire pipeline — reachable mid-run.
/// Dense, dark, scannable. Read-only: every row is a live mirror of an
/// `@Observable` singleton, plus one active probe (a 10s `/ping` loop
/// against the Worker proxy that runs only while the view is visible).
///
/// Sections: NETWORK / WATCH LINK / DIRECTOR / VOICE QUEUE / VOICES /
/// MUSIC / EVENT TAIL. A `TimelineView` ticks the whole body at 1 Hz so
/// relative ages (queue item age, ETA countdowns) stay live even when no
/// observable state changes.
struct ControlRoomView: View {
    @State private var consumer = LiveMetricsConsumer.shared
    @State private var phoneSession = PhoneSession.shared
    @State private var mirror = MirroringReceiver.shared
    @State private var director = RunDirector.shared
    @State private var queue = VoiceFeedbackQueue.shared
    @State private var remoteTTS = RemoteTTS.shared
    @State private var conversation = Conversation.shared
    @State private var nowPlaying = NowPlayingStore.shared
    @State private var eventLog = RunEventLog.shared

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
                    header(now: timeline.date)
                    networkSection
                    watchLinkSection
                    directorSection(now: timeline.date)
                    voiceQueueSection(now: timeline.date)
                    voicesSection
                    musicSection
                    eventTailSection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .background(Color(red: 0.03, green: 0.03, blue: 0.05).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { startProbe() }
        .onDisappear { stopProbe() }
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

    // MARK: - NETWORK

    private var networkSection: some View {
        section("NETWORK", accent: .cyan) {
            row("Endpoint", Config.apiBaseURL.host ?? Config.apiBaseURL.absoluteString)
            HStack(spacing: 6) {
                Text("Ping")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 4)
                statusDot(pingColor)
                Text(pingLabel)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(pingColor)
                    .lineLimit(1)
            }
            row("TTS activity", describeActivity(remoteTTS.activity))
            row("TTS backend", remoteTTS.lastBackend ?? "—")
            row("TTS latency", remoteTTS.lastLatencyMs.map { "\($0) ms" } ?? "—")
            HStack(spacing: 6) {
                Text("TTS cache")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 4)
                statusDot(remoteTTS.lastWasCacheHit ? .green : .gray)
                Text(remoteTTS.lastWasCacheHit ? "HIT" : "MISS")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(remoteTTS.lastWasCacheHit ? .green : .white.opacity(0.6))
            }
            if let err = remoteTTS.lastError {
                errorRow("TTS error", err)
            }
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

    private func describeActivity(_ activity: RemoteTTS.Activity) -> String {
        switch activity {
        case .idle:
            return "idle"
        case .synthesizing(let chars):
            if let started = remoteTTS.synthStartedAt {
                return "synth \(chars)ch · \(Int(Date().timeIntervalSince(started)))s"
            }
            return "synth \(chars)ch"
        case .playing(let remote):
            return remote ? "playing (ElevenLabs)" : "playing (Apple)"
        }
    }

    private func prefix(_ text: String, _ n: Int) -> String {
        text.count > n ? String(text.prefix(n)) + "…" : text
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

#Preview {
    ControlRoomView()
}
