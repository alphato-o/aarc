import SwiftUI
import AARCKit

/// Serious bench for the voice engine. Three tools:
///
///   1. RUN SCRIPT PREVIEW — generate the full pre-warmed run script on the
///      SOTA model (Opus) and read / play the exact backbone a real run is
///      built from.
///   2. DIRECTOR SIMULATOR — dry-run the real RunDirector over a mock run and
///      visualise its protect / room gating, so you can see whether splits
///      stay clean and where Jessica gets space — no audio, no network.
///   3. LIVE LINE TESTERS — fire a single reactive line / music riff / Jessica
///      reaction through the real Speaker pipeline, from the couch.
struct CoachPlayground: View {
    // Testers
    @State private var spotifyAuth = SpotifyAuth.shared
    @State private var busy: String?
    @State private var lastFired: String?
    @State private var lastError: String?
    @State private var customNote: String = ""
    @State private var probedTrack: String?
    @State private var probedLyric: String?
    @State private var probedLanguage: String?
    @State private var probedSource: String?
    @State private var probedSynced: Bool = false

    // Script preview
    @State private var previewDistanceKm: Double = 5
    @State private var previewRunType: RunType = .treadmill
    @State private var scriptBusy = false
    @State private var previewScript: GeneratedScript?

    // Director simulator
    @State private var simDistanceKm: Double = 5
    @State private var simPaceSec: Double = 300   // 5:00 /km
    @State private var simResult: DirectorSim.Result?

    var body: some View {
        Form {
            scriptPreviewSection
            directorSimSection
            dynamicTriggersSection
            musicSection
            jessicaSection
            resultSection
        }
        .navigationTitle("Coach Playground")
    }

    // MARK: - 1. Run script preview (Opus)

    @ViewBuilder
    private var scriptPreviewSection: some View {
        Section {
            Stepper("Distance: \(Int(previewDistanceKm)) km",
                    value: $previewDistanceKm, in: 1...42, step: 1)
            Picker("Surface", selection: $previewRunType) {
                Text("Treadmill").tag(RunType.treadmill)
                Text("Outdoor").tag(RunType.outdoor)
            }
            .pickerStyle(.segmented)
            Button {
                generateScriptPreview()
            } label: {
                HStack {
                    Label(scriptBusy ? "Generating on Opus…" : "Generate run script (Opus)",
                          systemImage: "doc.text.magnifyingglass")
                    Spacer()
                    if scriptBusy { ProgressView() }
                }
            }
            .disabled(scriptBusy)

            if let script = previewScript {
                Text("\(script.messages.count) lines · \(script.model)")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(script.messages) { msg in
                    scriptLineRow(msg)
                }
            }
        } header: {
            Text("Run script preview")
        } footer: {
            Text("Generates the full pre-warmed run script on the SOTA model (Claude Opus 4.8) — the exact backbone a real run is built from: opener, per-km loop, halfway, near-finish, finish and surprise roasts. Tap any line to hear it in Ricky's voice.")
        }
    }

    @ViewBuilder
    private func scriptLineRow(_ msg: ScriptMessage) -> some View {
        Button {
            Speaker.shared.speak(msg.text, priority: .milestone, source: "preview:\(msg.id)")
            lastFired = "[\(msg.triggerSpec.humanDescription)] \(msg.text)"
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(msg.triggerSpec.humanDescription.uppercased())
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.tint.opacity(0.2), in: Capsule())
                    if let v = msg.textVariants, !v.isEmpty {
                        Text("+\(v.count) variants")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Image(systemName: "play.circle").foregroundStyle(.tint)
                }
                Text(msg.text).font(.caption)
            }
        }
        .buttonStyle(.plain)
    }

    private func generateScriptPreview() {
        scriptBusy = true
        lastError = nil
        previewScript = nil
        let plan = RunPlan.distance(km: previewDistanceKm)
        var payload = AIClient.ScriptPlan.from(plan, runType: previewRunType, personalityId: "roast_coach")
        let bullets = PersonalContextStore.shared.bullets
        if !bullets.isEmpty { payload.userMemory = bullets }
        Task { @MainActor in
            defer { scriptBusy = false }
            do {
                previewScript = try await AIClient.shared.generateScript(plan: payload)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - 2. Director simulator

    @ViewBuilder
    private var directorSimSection: some View {
        Section {
            Stepper("Distance: \(Int(simDistanceKm)) km",
                    value: $simDistanceKm, in: 1...42, step: 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Pace: \(formatPace(simPaceSec)) /km")
                    .font(.caption).monospacedDigit()
                Slider(value: $simPaceSec, in: 180...540, step: 5)
            }
            Button {
                simResult = DirectorSim.run(distanceKm: simDistanceKm, paceSecPerKm: simPaceSec)
            } label: {
                Label("Run simulation", systemImage: "waveform.path.ecg")
            }

            if let r = simResult {
                DirectorTimelineView(result: r)
                    .padding(.vertical, 4)
                simSummary(r)
            }
        } header: {
            Text("Director simulator")
        } footer: {
            Text("Dry-runs the real RunDirector over a mock run at the chosen pace — no audio, no network. GREEN = open air where Jessica has room for a full passage. RED = a km split is imminent, so banter (incl. Jessica) is held to keep the split clean. Vertical lines are km markers.")
        }
    }

    @ViewBuilder
    private func simSummary(_ r: DirectorSim.Result) -> some View {
        let mins = r.totalSec / 60, secs = r.totalSec % 60
        VStack(alignment: .leading, spacing: 2) {
            Text("\(String(format: "%.0f", r.totalMeters / 1000)) km @ \(formatPace(r.paceSecPerKm))/km ≈ \(mins):\(String(format: "%02d", secs))")
                .font(.caption2.bold())
            Text("km splits: \(r.kmCrossings.count)  ·  protected windows: \(r.protectedWindows)")
                .font(.caption2).foregroundStyle(.secondary)
            Text("Jessica windows (open air): \(r.roomWindows)")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - 3. Live line testers

    @ViewBuilder
    private var dynamicTriggersSection: some View {
        Section {
            triggerButton(.hrSpike, label: "HR spike", icon: "heart.text.square")
            triggerButton(.paceDrop, label: "Pace drop (slower)", icon: "tortoise")
            triggerButton(.paceSurge, label: "Pace surge (faster)", icon: "hare")
            triggerButton(.quietStretch, label: "Quiet stretch", icon: "speaker.slash")
            triggerButton(.stationary, label: "Stationary", icon: "figure.stand")
            TextField("Custom note (optional)", text: $customNote, axis: .vertical)
                .lineLimit(1...3)
            customTriggerButton
        } header: {
            Text("Ricky — reactive line (/dynamic-line)")
        } footer: {
            Text("Fires one reactive line via /dynamic-line with a synthetic 10-min-in-5km state, spoken through the real Speaker pipeline.")
        }
    }

    @ViewBuilder
    private var musicSection: some View {
        Section {
            if spotifyAuth.isConnected {
                Label("Spotify connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
            } else {
                Label("Spotify NOT connected — probes AVAudioSession only", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption)
            }
            if let probedTrack {
                Text(probedTrack).font(.caption2).foregroundStyle(.secondary)
            }
            if let probedLyric {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Lyric line").font(.caption2).foregroundStyle(.secondary)
                        if let probedLanguage {
                            Text("· \(probedLanguage)").font(.caption2).foregroundStyle(.tertiary)
                        }
                        if let probedSource {
                            Text("· \(probedSource)\(probedSynced ? " (synced)" : "")")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Text("\u{201C}\(probedLyric)\u{201D}").font(.caption).italic()
                }
            }
            probeButton
            musicCommentButton
        } header: {
            Text("Ricky — music riff (/music-comment)")
        }
    }

    @ViewBuilder
    private var jessicaSection: some View {
        Section {
            jessicaButton
        } header: {
            Text("Jessica — second voice (/react-line)")
        } footer: {
            Text("Plays the last Ricky line above (or a sample) in his voice, then asks /react-line for Jessica's reaction and plays it in HER voice — the two-hander as it lands in a run. She now runs a long, explicit passage on Sonnet 4.5.")
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        Section {
            if let lastFired {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last line").font(.caption).foregroundStyle(.secondary)
                    Text(lastFired).font(.callout)
                }
            }
            if let lastError {
                Text("Error: \(lastError)").font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Result")
        }
    }

    // MARK: - Tester buttons

    @ViewBuilder
    private func triggerButton(_ trigger: AIClient.DynamicLineTrigger, label: String, icon: String) -> some View {
        Button {
            fireDynamic(trigger: trigger, note: nil)
        } label: {
            HStack {
                Label(label, systemImage: icon)
                Spacer()
                if busy == trigger.rawValue { ProgressView() }
            }
        }
        .disabled(busy != nil)
    }

    private var customTriggerButton: some View {
        Button {
            fireDynamic(trigger: .custom,
                        note: customNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "the runner just sneezed and nearly fell off the treadmill"
                            : customNote)
        } label: {
            HStack {
                Label("Fire custom trigger", systemImage: "sparkles")
                Spacer()
                if busy == "custom" { ProgressView() }
            }
        }
        .disabled(busy != nil)
    }

    private var probeButton: some View {
        Button {
            Task { @MainActor in
                probedLyric = nil; probedLanguage = nil; probedSource = nil; probedSynced = false
                let resolved = await MusicLyricResolver.resolveCurrent()
                switch resolved {
                case .lyric(let t, let sel):
                    probedTrack = "Now playing: \(t.title) — \(t.artist)"
                    probedLyric = sel.line; probedLanguage = sel.language
                    probedSource = sel.source; probedSynced = sel.synced
                case .songWithoutUsableLyric(let t):
                    probedTrack = "Now playing: \(t.title) — \(t.artist) (no usable lyric)"
                case .unknownAudio:
                    probedTrack = "Other audio is playing (no metadata)"
                case .silent:
                    probedTrack = "Nothing currently playing"
                }
            }
        } label: {
            Label("Probe current track", systemImage: "magnifyingglass")
        }
        .disabled(busy != nil)
    }

    private var musicCommentButton: some View {
        Button {
            fireMusic()
        } label: {
            HStack {
                Label("Fire music riff", systemImage: "music.note")
                Spacer()
                if busy == "music" { ProgressView() }
            }
        }
        .disabled(busy != nil)
    }

    private var jessicaButton: some View {
        Button {
            fireJessica()
        } label: {
            Label(busy == "jessica" ? "Generating…" : "Hear Jessica react",
                  systemImage: "person.2.wave.2.fill")
        }
        .disabled(busy != nil)
    }

    // MARK: - Tester actions

    private static let samplePartnerLine =
        "Three kilometres, and you're already breathing like a broken kettle. Genuinely heroic, in a tragic sort of way."

    private func fireJessica() {
        busy = "jessica"
        lastError = nil
        let rickyLine = lastFired ?? Self.samplePartnerLine
        let notes = PersonalContextStore.shared.bullets
        let request = AIClient.ReactLineRequest(
            personalityId: "jessica",
            partnerLine: rickyLine,
            partnerSource: "script:test",
            runContext: syntheticReactContext(),
            recentDispatched: nil,
            personalNotes: notes.isEmpty ? nil : notes,
            likedLineExamples: nil
        )
        Task { @MainActor in
            defer { busy = nil }
            do {
                Speaker.shared.speak(rickyLine, priority: .milestone, source: "script:test")
                let result = try await AIClient.shared.reactLine(request)
                Speaker.shared.speak(result.text, priority: .milestone,
                                     source: "jessica:react", voiceId: RemoteTTS.jessicaVoiceId)
                lastFired = "RICKY: \(rickyLine)\n\nJESSICA: \(result.text)"
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func fireDynamic(trigger: AIClient.DynamicLineTrigger, note: String?) {
        busy = trigger.rawValue
        lastError = nil
        let request = AIClient.DynamicLineRequest(
            personalityId: "roast_coach",
            trigger: trigger,
            runContext: syntheticDynamicContext(),
            recentDispatched: nil,
            customNote: note
        )
        Task { @MainActor in
            defer { busy = nil }
            do {
                let result = try await AIClient.shared.generateDynamicLine(request)
                Speaker.shared.speak(result.text)
                lastFired = result.text
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func fireMusic() {
        busy = "music"
        lastError = nil
        probedLyric = nil; probedLanguage = nil; probedSource = nil; probedSynced = false
        Task { @MainActor in
            defer { busy = nil }
            let resolved = await MusicLyricResolver.resolveCurrent()
            let request: AIClient.MusicCommentRequest
            switch resolved {
            case .silent:
                lastError = "Nothing playing — start Spotify and try again."
                return
            case .lyric(let t, let sel):
                probedTrack = "Now playing: \(t.title) — \(t.artist)"
                probedLyric = sel.line; probedLanguage = sel.language
                probedSource = sel.source; probedSynced = sel.synced
                request = AIClient.MusicCommentRequest(
                    personalityId: "roast_coach",
                    track: AIClient.MusicTrack(title: t.title, artist: t.artist, album: t.album, isPlaying: t.isPlaying),
                    unknownAudio: false,
                    currentLyric: sel.line,
                    lyricContext: sel.context.isEmpty ? nil : sel.context,
                    lyricLanguage: sel.language,
                    runContext: syntheticMusicContext(),
                    recentDispatched: nil
                )
            case .songWithoutUsableLyric(let t):
                probedTrack = "Now playing: \(t.title) — \(t.artist) (no usable lyric)"
                request = AIClient.MusicCommentRequest(
                    personalityId: "roast_coach",
                    track: AIClient.MusicTrack(title: t.title, artist: t.artist, album: t.album, isPlaying: t.isPlaying),
                    unknownAudio: false, currentLyric: nil, lyricContext: nil, lyricLanguage: nil,
                    runContext: syntheticMusicContext(), recentDispatched: nil
                )
            case .unknownAudio:
                probedTrack = "Other audio is playing (no metadata)"
                request = AIClient.MusicCommentRequest(
                    personalityId: "roast_coach", track: nil, unknownAudio: true,
                    currentLyric: nil, lyricContext: nil, lyricLanguage: nil,
                    runContext: syntheticMusicContext(), recentDispatched: nil
                )
            }
            do {
                let result = try await AIClient.shared.generateMusicComment(request)
                Speaker.shared.speak(result.text)
                lastFired = result.text
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Synthetic contexts

    private func syntheticDynamicContext() -> AIClient.DynamicLineContext {
        AIClient.DynamicLineContext(
            elapsedSeconds: 600, distanceMeters: 1500,
            currentHR: 175, avgHR: 152,
            currentPaceSecPerKm: 360, avgPaceSecPerKm: 330,
            planKind: "distance", planDistanceKm: 5, planTimeMinutes: nil,
            runType: "treadmill"
        )
    }

    private func syntheticMusicContext() -> AIClient.MusicCommentContext {
        AIClient.MusicCommentContext(
            elapsedSeconds: 600, distanceMeters: 1500,
            currentHR: 152, currentPaceSecPerKm: 330,
            planKind: "distance", runType: "treadmill"
        )
    }

    private func syntheticReactContext() -> AIClient.ReactLineContext {
        AIClient.ReactLineContext(
            elapsedSeconds: 600, distanceMeters: 1500,
            currentHR: 175, currentPaceSecPerKm: 360,
            planKind: "distance", runType: "treadmill"
        )
    }

    private func formatPace(_ secPerKm: Double) -> String {
        let s = Int(secPerKm.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Director simulator engine

/// Drives the REAL RunDirector over a synthetic constant-pace run and records
/// its gating decisions each simulated second. No audio, no network (the
/// director's pre-warm is disabled on this instance).
enum DirectorSim {
    struct Sample {
        let t: Int
        let isProtected: Bool
        let hasRoom: Bool
    }

    struct Result {
        let samples: [Sample]
        let totalSec: Int
        let totalMeters: Double
        let paceSecPerKm: Double
        let kmCrossings: [Int]      // sim-seconds at which each km is crossed
        let protectedWindows: Int
        let roomWindows: Int
    }

    @MainActor
    static func run(distanceKm: Double, paceSecPerKm: Double) -> Result {
        let plan = RunPlan.distance(km: distanceKm)
        let director = RunDirector()
        director.prewarmEnabled = false
        director.start(plan: plan)

        let speed = 1000.0 / paceSecPerKm           // m/s
        let totalMeters = distanceKm * 1000
        let totalSec = max(1, Int((totalMeters / speed).rounded()))

        var samples: [Sample] = []
        var kmCrossings: [Int] = []
        var lastKm = 0

        for s in 0...totalSec {
            let dist = min(totalMeters, speed * Double(s))
            let metrics = LiveMetrics(
                elapsed: Double(s),
                distanceMeters: dist,
                currentPaceSecPerKm: paceSecPerKm,
                avgPaceSecPerKm: paceSecPerKm,
                currentHeartRate: 150,
                energyKcal: 0,
                cadenceStepsPerMinute: nil,
                lastSplit: nil,
                state: .running
            )
            director.processTick(metrics)
            samples.append(Sample(t: s, isProtected: director.isProtectedWindow, hasRoom: director.hasRoomForExchange))
            let km = Int(dist / 1000)
            if km > lastKm { kmCrossings.append(s); lastKm = km }
        }
        director.stop()

        return Result(
            samples: samples,
            totalSec: totalSec,
            totalMeters: totalMeters,
            paceSecPerKm: paceSecPerKm,
            kmCrossings: kmCrossings,
            protectedWindows: countWindows(samples.map(\.isProtected)),
            roomWindows: countWindows(samples.map(\.hasRoom))
        )
    }

    /// Count contiguous true-runs (how many distinct windows).
    private static func countWindows(_ flags: [Bool]) -> Int {
        var count = 0, prev = false
        for f in flags { if f && !prev { count += 1 }; prev = f }
        return count
    }
}

/// Horizontal timeline of the director's decisions across a simulated run.
private struct DirectorTimelineView: View {
    let result: DirectorSim.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                legend(.green, "Jessica room")
                legend(.red, "split protected")
            }
            Canvas { ctx, size in
                guard result.totalSec > 0 else { return }
                let w = size.width, h = size.height
                let bandH = (h - 12) / 2
                let cw = max(1.0, w / CGFloat(result.totalSec + 1))

                for s in result.samples {
                    let x = CGFloat(s.t) / CGFloat(result.totalSec) * w
                    if s.hasRoom {
                        ctx.fill(Path(CGRect(x: x, y: 0, width: cw, height: bandH)),
                                 with: .color(.green.opacity(0.4)))
                    }
                    if s.isProtected {
                        ctx.fill(Path(CGRect(x: x, y: bandH + 4, width: cw, height: bandH)),
                                 with: .color(.red.opacity(0.55)))
                    }
                }
                for (i, t) in result.kmCrossings.enumerated() {
                    let x = CGFloat(t) / CGFloat(result.totalSec) * w
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: h))
                    ctx.stroke(line, with: .color(.white.opacity(0.45)), lineWidth: 1)
                    ctx.draw(
                        Text("\(i + 1)k").font(.system(size: 8, weight: .semibold)).foregroundColor(.white.opacity(0.75)),
                        at: CGPoint(x: x + 2, y: h - 1), anchor: .bottomLeading
                    )
                }
            }
            .frame(height: 60)
            .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(c.opacity(0.6)).frame(width: 10, height: 8)
            Text(t).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        CoachPlayground()
    }
}
