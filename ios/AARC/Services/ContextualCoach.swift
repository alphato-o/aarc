import AVFoundation
import Foundation
import Observation
import OSLog
import AARCKit

/// In-run reactive coach. Watches the same 1Hz `LiveMetrics` stream the
/// `ScriptEngine` consumes, but instead of firing pre-generated lines
/// at fixed triggers, it detects in-run *events* (HR climbed sharply,
/// pace slowed, a long silence) and asks the proxy for a single
/// freshly-generated reactive line.
///
/// Lines flow through `ScriptEngine.tryInject` so they honor the same
/// global cooldown as scripted lines — the runner never hears two
/// voices on top of each other.
///
/// Triggers (with per-trigger cooldowns to prevent nagging):
///   - hr_spike      HR > rolling avg + 15bpm sustained 10s, cooldown 3 min
///   - pace_drop     pace > rolling avg + 30 s/km sustained 30s, cooldown 5 min
///   - pace_surge    pace < rolling avg - 20 s/km sustained 30s, cooldown 5 min
///   - quiet_stretch >4 min since last ScriptEngine dispatch, cooldown 4 min
///   - music_riff    every ~6 min while audio is detected, cooldown 6 min
///
/// Rolling averages use a 90s window so they react to "what's normal
/// right now" rather than "what's normal for the whole run."
@Observable
@MainActor
final class ContextualCoach {
    static let shared = ContextualCoach()

    // MARK: - Diagnostic state (read by SettingsView)

    private(set) var isRunning: Bool = false
    private(set) var lastFiredTrigger: String?
    private(set) var lastFiredAt: Date?
    private(set) var lastError: String?

    // MARK: - Tunables

    private let rollingWindow: TimeInterval = 90
    private let hrSpikeBpmThreshold: Double = 15
    private let hrSpikeSustainSeconds: TimeInterval = 10
    private let paceDropSecPerKmThreshold: Double = 30
    private let paceSurgeSecPerKmThreshold: Double = 20
    private let paceSustainSeconds: TimeInterval = 30
    private let quietStretchSilenceSeconds: TimeInterval = 240

    private let cooldownByTrigger: [AIClient.DynamicLineTrigger: TimeInterval] = [
        .hrSpike: 180,
        .paceDrop: 300,
        .paceSurge: 300,
        .quietStretch: 240,
    ]

    /// Don't even start firing reactive lines until the runner has been
    /// going long enough for averages to settle.
    private let warmupSeconds: TimeInterval = 120

    // MARK: - Internal state

    private struct Sample {
        let t: Date
        let value: Double
    }

    private var hrSamples: [Sample] = []
    private var paceSamples: [Sample] = []

    private var hrSpikeStartedAt: Date?
    private var paceDropStartedAt: Date?
    private var paceSurgeStartedAt: Date?

    private var lastFireByTrigger: [AIClient.DynamicLineTrigger: Date] = [:]
    private var lastMusicRiffAt: Date?
    /// Shorter than the 6-min cooldown of the original song-title-only
    /// riff because lyric-driven riffs are more interesting per dispatch.
    private let musicRiffCooldown: TimeInterval = 150
    /// Backoff between music probes when the last probe didn't yield a
    /// usable lyric (instrumental track, unsupported language, lyrics
    /// not found, audio not from Spotify, etc.). Short enough to catch
    /// the next song quickly.
    private let musicRiffMissBackoff: TimeInterval = 45
    /// "<artist>|<title>" of the song we riffed on last + the exact
    /// lyric line we picked. Used to dedupe: we won't riff on the same
    /// line of the same song twice in a row.
    private var lastMusicTrackKey: String?
    private var lastMusicLyric: String?
    /// Set while a /dynamic-line or /music-comment request is in flight
    /// so we don't double-fire.
    private var inFlight: Bool = false
    private var latestMetrics: LiveMetrics?

    private let log = Logger(subsystem: "club.aarun.AARC", category: "ContextualCoach")

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        hrSamples.removeAll()
        paceSamples.removeAll()
        hrSpikeStartedAt = nil
        paceDropStartedAt = nil
        paceSurgeStartedAt = nil
        lastFireByTrigger.removeAll()
        lastMusicRiffAt = nil
        lastMusicTrackKey = nil
        lastMusicLyric = nil
        inFlight = false
        lastFiredTrigger = nil
        lastFiredAt = nil
        lastError = nil
        isRunning = true
        log.info("ContextualCoach started")
    }

    func stop() {
        isRunning = false
        hrSamples.removeAll()
        paceSamples.removeAll()
        inFlight = false
        log.info("ContextualCoach stopped")
    }

    // MARK: - Tick

    /// Called from LiveMetricsConsumer.ingest after ScriptEngine.processTick.
    func processTick(_ metrics: LiveMetrics) {
        guard isRunning else { return }
        latestMetrics = metrics
        let now = Date()

        if let hr = metrics.currentHeartRate, hr > 0 {
            hrSamples.append(Sample(t: now, value: hr))
            trimSamples(&hrSamples, before: now.addingTimeInterval(-rollingWindow))
        }
        if let pace = metrics.currentPaceSecPerKm, pace > 0, metrics.distanceMeters > 0 {
            paceSamples.append(Sample(t: now, value: pace))
            trimSamples(&paceSamples, before: now.addingTimeInterval(-rollingWindow))
        }

        guard metrics.elapsed >= warmupSeconds else { return }
        guard !inFlight else { return }

        if let trigger = evaluateTriggers(now: now, metrics: metrics) {
            fire(trigger: trigger, metrics: metrics)
            return
        }
        // Music riff is opportunistic — only check it if no priority
        // trigger fired this tick. The probe is async, so the call site
        // is a Task that re-locks `inFlight`.
        if shouldCheckMusicRiff(now: now) {
            inFlight = true
            lastMusicRiffAt = now
            checkAndFireMusicRiff(now: now, metrics: metrics)
        }
    }

    // MARK: - Trigger evaluation

    private func evaluateTriggers(now: Date, metrics: LiveMetrics) -> AIClient.DynamicLineTrigger? {
        // Priority order — most "interesting" first.
        if let trigger = checkHRSpike(now: now, metrics: metrics) { return trigger }
        if let trigger = checkPaceDrop(now: now, metrics: metrics) { return trigger }
        if let trigger = checkPaceSurge(now: now, metrics: metrics) { return trigger }
        if let trigger = checkQuietStretch(now: now) { return trigger }
        return nil
    }

    private func checkHRSpike(now: Date, metrics: LiveMetrics) -> AIClient.DynamicLineTrigger? {
        guard let hr = metrics.currentHeartRate,
              let avg = rollingAverage(hrSamples),
              hrSamples.count >= 10 else {
            hrSpikeStartedAt = nil
            return nil
        }
        if hr >= avg + hrSpikeBpmThreshold {
            if hrSpikeStartedAt == nil { hrSpikeStartedAt = now }
            if let started = hrSpikeStartedAt,
               now.timeIntervalSince(started) >= hrSpikeSustainSeconds,
               cooldownOk(.hrSpike, now: now) {
                hrSpikeStartedAt = nil
                return .hrSpike
            }
        } else {
            hrSpikeStartedAt = nil
        }
        return nil
    }

    private func checkPaceDrop(now: Date, metrics: LiveMetrics) -> AIClient.DynamicLineTrigger? {
        guard let pace = metrics.currentPaceSecPerKm,
              let avg = rollingAverage(paceSamples),
              paceSamples.count >= 15 else {
            paceDropStartedAt = nil
            return nil
        }
        // Higher sec/km == slower.
        if pace >= avg + paceDropSecPerKmThreshold {
            if paceDropStartedAt == nil { paceDropStartedAt = now }
            if let started = paceDropStartedAt,
               now.timeIntervalSince(started) >= paceSustainSeconds,
               cooldownOk(.paceDrop, now: now) {
                paceDropStartedAt = nil
                return .paceDrop
            }
        } else {
            paceDropStartedAt = nil
        }
        return nil
    }

    private func checkPaceSurge(now: Date, metrics: LiveMetrics) -> AIClient.DynamicLineTrigger? {
        guard let pace = metrics.currentPaceSecPerKm,
              let avg = rollingAverage(paceSamples),
              paceSamples.count >= 15 else {
            paceSurgeStartedAt = nil
            return nil
        }
        // Lower sec/km == faster.
        if pace <= avg - paceSurgeSecPerKmThreshold {
            if paceSurgeStartedAt == nil { paceSurgeStartedAt = now }
            if let started = paceSurgeStartedAt,
               now.timeIntervalSince(started) >= paceSustainSeconds,
               cooldownOk(.paceSurge, now: now) {
                paceSurgeStartedAt = nil
                return .paceSurge
            }
        } else {
            paceSurgeStartedAt = nil
        }
        return nil
    }

    private func checkQuietStretch(now: Date) -> AIClient.DynamicLineTrigger? {
        // Use ScriptEngine.lastDispatchAt as the source of truth — if a
        // scripted per-km roast just fired, "quiet" isn't quiet.
        let last = ScriptEngine.shared.lastDispatchAt ?? lastFiredAt
        if let last, now.timeIntervalSince(last) >= quietStretchSilenceSeconds,
           cooldownOk(.quietStretch, now: now) {
            return .quietStretch
        }
        // If nothing has fired yet at all (i.e., past warmup but no
        // scripted line has dispatched), treat as quiet too.
        if last == nil,
           latestMetrics?.elapsed ?? 0 >= warmupSeconds + quietStretchSilenceSeconds,
           cooldownOk(.quietStretch, now: now) {
            return .quietStretch
        }
        return nil
    }

    private func cooldownOk(_ trigger: AIClient.DynamicLineTrigger, now: Date) -> Bool {
        guard let last = lastFireByTrigger[trigger] else { return true }
        let cooldown = cooldownByTrigger[trigger] ?? 240
        return now.timeIntervalSince(last) >= cooldown
    }

    private func rollingAverage(_ samples: [Sample]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sum = samples.reduce(0.0) { $0 + $1.value }
        return sum / Double(samples.count)
    }

    private func trimSamples(_ samples: inout [Sample], before cutoff: Date) {
        while let first = samples.first, first.t < cutoff {
            samples.removeFirst()
        }
    }

    // MARK: - Fire

    private func fire(trigger: AIClient.DynamicLineTrigger, metrics: LiveMetrics) {
        inFlight = true
        lastFireByTrigger[trigger] = .now
        let plan = ScriptPreviewStore.shared.currentPlan
        let runType: String = {
            // We don't have RunType here; ScriptPreviewStore doesn't
            // track it. Default to "outdoor" — it's only used for
            // prompt color, not behavior.
            return "outdoor"
        }()
        let avgHR = rollingAverage(hrSamples)
        let avgPace = rollingAverage(paceSamples)
        let context = AIClient.DynamicLineContext(
            elapsedSeconds: metrics.elapsed,
            distanceMeters: metrics.distanceMeters,
            currentHR: metrics.currentHeartRate,
            avgHR: avgHR,
            currentPaceSecPerKm: metrics.currentPaceSecPerKm,
            avgPaceSecPerKm: avgPace,
            planKind: plan.kind.rawValue,
            planDistanceKm: plan.distanceKm,
            planTimeMinutes: plan.timeMinutes,
            runType: runType
        )
        let recent = ScriptEngine.shared.recentDispatchedLines
        let request = AIClient.DynamicLineRequest(
            personalityId: "roast_coach",
            trigger: trigger,
            runContext: context,
            recentDispatched: recent.isEmpty ? nil : recent,
            customNote: nil
        )

        log.info("ContextualCoach firing trigger=\(trigger.rawValue, privacy: .public)")

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inFlight = false }
            do {
                let result = try await AIClient.shared.generateDynamicLine(request)
                let injected = ScriptEngine.shared.tryInject(text: result.text, source: "coach:\(trigger.rawValue)")
                if injected {
                    self.lastFiredTrigger = trigger.rawValue
                    self.lastFiredAt = .now
                    self.lastError = nil
                } else {
                    // Suppressed by ScriptEngine cooldown — back off the
                    // per-trigger cooldown so we re-try sooner.
                    self.lastFireByTrigger[trigger] = .now.addingTimeInterval(-((self.cooldownByTrigger[trigger] ?? 240) - 30))
                    self.log.info("ContextualCoach injection suppressed by ScriptEngine cooldown")
                }
            } catch {
                self.lastError = error.localizedDescription
                self.log.error("ContextualCoach error: \(error.localizedDescription, privacy: .public)")
                // Back off so a transient failure doesn't lock the
                // trigger for its full cooldown.
                self.lastFireByTrigger[trigger] = .now.addingTimeInterval(-((self.cooldownByTrigger[trigger] ?? 240) - 30))
            }
        }
    }

    // MARK: - Music riff

    private func shouldCheckMusicRiff(now: Date) -> Bool {
        if let last = lastMusicRiffAt,
           now.timeIntervalSince(last) < musicRiffCooldown {
            return false
        }
        return true
    }

    private func checkAndFireMusicRiff(now: Date, metrics: LiveMetrics) {
        log.info("ContextualCoach probing music for riff")
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inFlight = false }
            let resolved = await MusicLyricResolver.resolveCurrent()
            switch resolved {
            case .lyric(let track, let selection):
                // Skip if we'd be repeating the same line of the same song.
                let key = Self.trackKey(track: track)
                if self.lastMusicTrackKey == key, self.lastMusicLyric == selection.line {
                    self.lastMusicRiffAt = .now.addingTimeInterval(-(self.musicRiffCooldown - self.musicRiffMissBackoff))
                    self.log.info("ContextualCoach music_riff: same lyric on same song, skipping")
                    return
                }
                self.lastMusicTrackKey = key
                self.lastMusicLyric = selection.line
                await self.fireMusicComment(track: track, selection: selection, metrics: metrics)

            case .songWithoutUsableLyric:
                // Track known but no English/Chinese lyric line we can
                // ride. Skip — try again sooner in case the next song
                // has lyrics.
                self.lastMusicRiffAt = .now.addingTimeInterval(-(self.musicRiffCooldown - self.musicRiffMissBackoff))
                self.log.info("ContextualCoach music_riff: no usable lyric, short backoff")

            case .unknownAudio, .silent:
                // No Spotify metadata or nothing playing. Per product spec
                // we don't fire riffs without a real lyric.
                self.lastMusicRiffAt = .now.addingTimeInterval(-(self.musicRiffCooldown - self.musicRiffMissBackoff))
            }
        }
    }

    private func fireMusicComment(
        track: SpotifyClient.Track,
        selection: LyricsClient.Selection,
        metrics: LiveMetrics
    ) async {
        let plan = ScriptPreviewStore.shared.currentPlan
        let context = AIClient.MusicCommentContext(
            elapsedSeconds: metrics.elapsed,
            distanceMeters: metrics.distanceMeters,
            currentHR: metrics.currentHeartRate,
            currentPaceSecPerKm: metrics.currentPaceSecPerKm,
            planKind: plan.kind.rawValue,
            runType: "outdoor"
        )
        let recent = ScriptEngine.shared.recentDispatchedLines
        let request = AIClient.MusicCommentRequest(
            personalityId: "roast_coach",
            track: AIClient.MusicTrack(
                title: track.title,
                artist: track.artist,
                album: track.album,
                isPlaying: track.isPlaying
            ),
            unknownAudio: false,
            currentLyric: selection.line,
            lyricContext: selection.context.isEmpty ? nil : selection.context,
            lyricLanguage: selection.language,
            runContext: context,
            recentDispatched: recent.isEmpty ? nil : recent
        )
        do {
            let result = try await AIClient.shared.generateMusicComment(request)
            let injected = ScriptEngine.shared.tryInject(text: result.text, source: "coach:music_riff")
            if injected {
                lastFiredTrigger = "music_riff"
                lastFiredAt = .now
                lastError = nil
            } else {
                // Suppressed by global cooldown — retry sooner.
                lastMusicRiffAt = .now.addingTimeInterval(-(musicRiffCooldown - 60))
                log.info("ContextualCoach music_riff suppressed by ScriptEngine cooldown")
            }
        } catch {
            lastError = error.localizedDescription
            log.error("ContextualCoach music_riff error: \(error.localizedDescription, privacy: .public)")
            lastMusicRiffAt = .now.addingTimeInterval(-(musicRiffCooldown - 60))
        }
    }

    private static func trackKey(track: SpotifyClient.Track) -> String {
        "\(track.artist)|\(track.title)"
    }
}

// MARK: - Music lyric resolver

/// Shared "what should the DJ riff on right now?" pipeline. Used by
/// ContextualCoach during live runs AND by CoachPlayground for off-the-
/// couch testing — same code path so the playground actually exercises
/// what production will do.
enum MusicLyricResolver {
    enum Resolved: Sendable {
        case lyric(SpotifyClient.Track, LyricsClient.Selection)
        case songWithoutUsableLyric(SpotifyClient.Track)
        case unknownAudio
        case silent
    }

    static func resolveCurrent() async -> Resolved {
        let track = await SpotifyClient.shared.currentlyPlaying()
        switch track {
        case .nothingPlaying:
            return .silent
        case .notConnected:
            // Fall back to checking system audio so we at least know
            // *something* is playing, even if we can't enrich it.
            let other = AVAudioSession.sharedInstance().isOtherAudioPlaying
            return other ? .unknownAudio : .silent
        case .track(let t):
            let lyricsTrack = LyricsClient.Track(
                artist: t.artist,
                title: t.title,
                album: t.album,
                durationSeconds: t.durationMs.map { Int(Double($0) / 1000.0) }
            )
            let lyrics = await LyricsClient.shared.fetch(track: lyricsTrack)
            let progressSec = t.progressMs.map { Double($0) / 1000.0 }
            let selection = await LyricsClient.shared.pickLine(
                for: lyricsTrack,
                lyrics: lyrics,
                progressSec: progressSec
            )
            if let selection {
                return .lyric(t, selection)
            }
            return .songWithoutUsableLyric(t)
        }
    }
}
