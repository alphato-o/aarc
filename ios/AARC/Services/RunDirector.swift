import Foundation
import Observation
import OSLog
import AARCKit

/// The "director" behind the run's audio. Where `ScriptEngine` owns the
/// TRUTH of when a milestone fires (the runner has actually crossed the
/// km), and `ContextualCoach` owns the reactive lines, the director owns
/// TIMING and SPACE: it predicts the run forward from the current pace,
/// knows when the next must-play performance line (km split, halfway,
/// near-finish, finish) is due, and uses that to
///
///   1. PRE-WARM the milestone's TTS audio ~25s ahead so the split lands
///      the instant the runner crosses, with no generation stall, and
///   2. PROTECT a ~15s window before each milestone — ContextualCoach
///      consults `isProtectedWindow` and holds lyric/music + reactive
///      banter so it never collides with (or gets cut off by) the split.
///
/// Between milestones there's open air, so banter flows freely. The net
/// effect is a producer's clock: performance feedback lands spot-on, and
/// ad-hoc commentary gets the gaps to itself.
///
/// Driven from `LiveMetricsConsumer.ingest` on every 1Hz tick, BEFORE
/// ScriptEngine/ContextualCoach so its state is fresh when they read it.
@Observable
@MainActor
final class RunDirector {
    static let shared = RunDirector()

    // MARK: - Tunables ("Balanced" cadence)

    /// Hold ad-hoc banter when the next must-play milestone is within
    /// this many seconds, so the split lands clean.
    private let protectLeadSeconds: TimeInterval = 15
    /// Warm a milestone's TTS audio this far ahead so it plays the
    /// instant the runner crosses, with no generation latency.
    private let prewarmLeadSeconds: TimeInterval = 25
    /// Below this smoothed speed we treat distance-based milestones as
    /// "not imminent" — the runner is basically stopped or walking and
    /// no km is about to land, so there's nothing to protect.
    private let minUsableSpeedMps: Double = 0.4
    /// EMA weight on the latest speed reading. Low enough to ride out
    /// 1Hz pace jitter, high enough to track a genuine pace change.
    private let speedEMAAlpha: Double = 0.3
    /// Default interval-roast cadence for time plans (matches the script
    /// prompt's suggested everySeconds: 300). Used only to predict the
    /// protect window; ScriptEngine still fires on the real trigger.
    private let timeIntervalSeconds: TimeInterval = 300
    /// Minimum clear air before the next must-play for Jessica to react.
    /// Jessica now runs a long erotic passage (~30–50s), so we reserve a
    /// big window: she only joins when there's genuinely room for the full
    /// indulgence before the next split — keeping km markers clean.
    private let exchangeRoomSeconds: TimeInterval = 45
    /// EMA weight on each freshly-measured pipeline latency sample.
    private let leadEMAAlpha: Double = 0.3
    /// Clamp for the measured pipeline lead so one slow/fast sample can't
    /// send the projection haywire. ~1.5s (warm cache) to ~18s (cold
    /// LLM + TTS + download on a bad connection).
    private let leadClamp: ClosedRange<TimeInterval> = 1.5...18

    // MARK: - Observable state (read by ContextualCoach + diagnostics)

    private(set) var isActive = false
    private(set) var smoothedSpeedMps: Double = 0
    /// When false, `processTick` skips the TTS pre-warm prefetch. The Coach
    /// Playground's dry Director simulator sets this so a sped-up mock run
    /// can exercise the real gating logic without firing network calls.
    var prewarmEnabled = true
    /// Seconds until the next must-play milestone, or nil if none is
    /// predictable right now (stopped, or an open plan with no km
    /// imminent because speed is unusable).
    private(set) var nextMustPlayETA: TimeInterval?

    /// Measured time from "we snapshot the run state to generate a line"
    /// to "the runner hears it" — LLM + TTS + download + queue wait. Fed
    /// by freshly-generated coach lines (see `recordPipelineLatency`).
    /// Bootstraps at 6s; converges on the real device/connection latency.
    private(set) var pipelineLeadSeconds: TimeInterval = 6

    /// True while a must-play milestone is within `protectLeadSeconds`.
    /// ContextualCoach consults this to hold lyric/music + reactive
    /// banter so the upcoming split/halfway/finish lands clean.
    var isProtectedWindow: Bool {
        guard let eta = nextMustPlayETA else { return false }
        return eta <= protectLeadSeconds
    }

    /// True when there's enough clear air before the next must-play to fit
    /// a full two-voice exchange (Ricky's line + Jessica's reaction ≈ 2×).
    /// `Conversation` consults this to decide whether Jessica reacts — so a
    /// km split never lands while the duo is still mid-banter.
    var hasRoomForExchange: Bool {
        guard let eta = nextMustPlayETA else { return true }
        return eta > exchangeRoomSeconds
    }

    /// Project the run state forward by the measured pipeline latency, so a
    /// dynamically-generated line that QUOTES the runner's progress is
    /// accurate at the moment it's actually heard — not stale by the time
    /// the gen + TTS + download finishes. Without this, "you're at 3.5k"
    /// lands when the runner is already at 3.6–3.7k. Distance advances at
    /// the smoothed current speed; elapsed advances by the lead directly.
    func projected(distance: Double, elapsed: TimeInterval) -> (distance: Double, elapsed: TimeInterval) {
        let lead = pipelineLeadSeconds
        return (distance + smoothedSpeedMps * lead, elapsed + lead)
    }

    /// Record one observed pipeline latency (audible time − snapshot time)
    /// from a freshly-generated line, smoothed into `pipelineLeadSeconds`.
    /// Cached / pre-warmed lines must NOT call this (they'd drag the
    /// estimate to ~0); only fresh-generation coach lines do.
    func recordPipelineLatency(_ seconds: TimeInterval) {
        let clamped = min(leadClamp.upperBound, max(leadClamp.lowerBound, seconds))
        pipelineLeadSeconds = leadEMAAlpha * clamped + (1 - leadEMAAlpha) * pipelineLeadSeconds
    }

    // MARK: - Internal

    private var plan: RunPlan = .open
    private var lastDistance: Double = 0
    private var lastTickAt: Date?
    /// Milestones whose audio we've already warmed, keyed by identity
    /// ("km:3", "finish") so we prefetch each one exactly once.
    private var prewarmed: Set<String> = []
    private let log = Logger(subsystem: "club.aarun.AARC", category: "RunDirector")

    // MARK: - Lifecycle

    func start(plan: RunPlan) {
        self.plan = plan
        isActive = true
        smoothedSpeedMps = 0
        nextMustPlayETA = nil
        lastDistance = 0
        lastTickAt = nil
        prewarmed.removeAll()
        log.info("RunDirector started plan=\(plan.humanDescription, privacy: .public)")
    }

    func stop() {
        isActive = false
        nextMustPlayETA = nil
        prewarmed.removeAll()
        log.info("RunDirector stopped")
    }

    // MARK: - Tick

    func processTick(_ metrics: LiveMetrics) {
        guard isActive else { return }
        updateSpeed(metrics)
        let candidates = upcomingMilestones(metrics: metrics)
        let wasProtected = isProtectedWindow
        nextMustPlayETA = candidates.map(\.eta).filter { $0 >= 0 }.min()
        if isProtectedWindow != wasProtected {
            RunEventLog.shared.record("director.protect", isProtectedWindow ? "enter" : "exit",
                                      data: ["eta": String(Int(nextMustPlayETA ?? -1))])
        }
        prewarmImminent(candidates)
    }

    // MARK: - Speed

    private func updateSpeed(_ metrics: LiveMetrics) {
        let now = Date()
        var instant: Double?
        if let pace = metrics.currentPaceSecPerKm, pace > 0 {
            instant = 1000.0 / pace
        } else if let last = lastTickAt {
            // No pace reading — derive from the raw distance delta.
            let dt = now.timeIntervalSince(last)
            let dd = metrics.distanceMeters - lastDistance
            if dt > 0.5, dd >= 0 { instant = dd / dt }
        }
        if let instant {
            smoothedSpeedMps = smoothedSpeedMps == 0
                ? instant
                : speedEMAAlpha * instant + (1 - speedEMAAlpha) * smoothedSpeedMps
        }
        lastDistance = metrics.distanceMeters
        lastTickAt = now
    }

    // MARK: - Prediction

    private struct Milestone {
        let key: String
        let eta: TimeInterval
        /// Deterministic announcement text to warm, if any. Halfway /
        /// near-finish announcements are plan-shaped and already warmed
        /// up front by RunOrchestrator, so only km splits + finish carry
        /// text here.
        let announcement: String?
    }

    private func upcomingMilestones(metrics: LiveMetrics) -> [Milestone] {
        var out: [Milestone] = []
        let dist = metrics.distanceMeters
        let elapsed = metrics.elapsed
        let speed = smoothedSpeedMps
        let speedUsable = speed >= minUsableSpeedMps

        // Distance-axis milestones. The per-km loop fires on every plan
        // (runners cross km marks regardless); halfway / near-finish /
        // finish only on distance plans.
        if speedUsable {
            let nextKm = Int(dist / 1000) + 1
            let metersToKm = Double(nextKm) * 1000 - dist
            out.append(Milestone(
                key: "km:\(nextKm)",
                eta: metersToKm / speed,
                announcement: MilestoneAnnouncement.kilometreText(km: nextKm)
            ))

            if let total = plan.totalMeters {
                let half = total / 2
                if dist < half {
                    out.append(Milestone(key: "halfway", eta: (half - dist) / speed, announcement: nil))
                }
                let near = total - 100
                if dist < near {
                    out.append(Milestone(key: "near_finish", eta: (near - dist) / speed, announcement: nil))
                }
                if dist < total {
                    out.append(Milestone(key: "finish", eta: (total - dist) / speed, announcement: "Run complete."))
                }
            }
        }

        // Time-axis milestones — pure clock, independent of speed.
        if let total = plan.totalSeconds {
            let half = total / 2
            if elapsed < half {
                out.append(Milestone(key: "halfway_t", eta: half - elapsed, announcement: nil))
            }
            let near = total - 60
            if elapsed < near {
                out.append(Milestone(key: "near_finish_t", eta: near - elapsed, announcement: nil))
            }
            if elapsed < total {
                out.append(Milestone(key: "finish_t", eta: total - elapsed, announcement: "Run complete."))
            }
            let nextInterval = (Int(elapsed / timeIntervalSeconds) + 1) * Int(timeIntervalSeconds)
            out.append(Milestone(
                key: "interval:\(nextInterval)",
                eta: TimeInterval(nextInterval) - elapsed,
                announcement: nil
            ))
        }

        return out
    }

    private func prewarmImminent(_ candidates: [Milestone]) {
        guard prewarmEnabled else { return }
        for m in candidates where m.eta >= 0 && m.eta <= prewarmLeadSeconds {
            guard !prewarmed.contains(m.key) else { continue }
            prewarmed.insert(m.key)
            guard let text = m.announcement else { continue }
            log.info("RunDirector pre-warming \(m.key, privacy: .public) eta=\(Int(m.eta), privacy: .public)s")
            RunEventLog.shared.record("director.prewarm", m.key, data: ["eta": String(Int(m.eta))])
            Task { await RemoteTTS.shared.prefetch(text) }
        }
    }
}
