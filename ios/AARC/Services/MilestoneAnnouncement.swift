import Foundation
import AARCKit

/// Builds the short, factual distance / time announcement that prefixes a
/// per-km roast (or halfway / near-finish / finish riff). Strings here are
/// deterministic and short so the same text gets re-used across every run —
/// AudioCache.key hashes (voiceId, text), so the second time the founder
/// hits 3km it plays instantly from disk.
///
/// Examples:
///   per-km @ 3km    → "3 kilometres."
///   per-km @ 0.5km  → "Half a kilometre."
///   per-km @ 1.5km  → "1 and a half kilometres."
///   halfway @ 21k   → "Halfway. 21 kilometres in."
///   halfway @ time  → "Halfway through."
///   near-finish 1k  → "1 kilometre to go."
///   near-finish 5m  → "5 minutes to go."
///   finish          → "Run complete."
///   time intro      → nil (use the script's own line)
enum MilestoneAnnouncement {
    /// Produce the announcement string for a triggered message, or nil if
    /// no separate announcement is warranted (intro lines, custom triggers).
    static func text(
        for message: ScriptMessage,
        plan: RunPlan,
        distanceMeters: Double,
        elapsedSeconds: TimeInterval
    ) -> String? {
        let trigger = message.triggerSpec
        switch trigger.type {
        case .distance:
            // Looping per-km roast: announce the km we just crossed.
            if let every = trigger.everyMeters, every > 0 {
                let epoch = Int(distanceMeters / every)
                let crossedMeters = Double(epoch) * every
                return distanceText(meters: crossedMeters)
            }
            // One-shot distance trigger (a "surprise roast" the model
            // scattered at an off-grid distance like 2800m). These are
            // NOT km milestones, so they get no announcement — otherwise
            // distanceText would snap 2800m → "3 kilometres." and the
            // runner hears a phantom "3km" before the real per-km split
            // fires at 3000m. The line speaks for itself.
            return nil

        case .time:
            // Intro / atSeconds: no announcement — the line itself is the moment.
            // everySeconds (interval scripts): announce elapsed minutes.
            if let every = trigger.everySeconds, every > 0 {
                let epoch = Int(elapsedSeconds / TimeInterval(every))
                let crossedSeconds = Int(Double(epoch) * Double(every))
                return timeText(seconds: crossedSeconds)
            }
            return nil

        case .halfway:
            if let totalM = plan.totalMeters {
                return "Halfway. \(distanceText(meters: totalM / 2)) in."
            }
            if plan.totalSeconds != nil {
                return "Halfway through."
            }
            return "Halfway."

        case .nearFinish:
            if let m = trigger.remainingMeters, m > 0 {
                return "\(distanceText(meters: m)) to go."
            }
            if let s = trigger.remainingSeconds, s > 0 {
                return "\(timeText(seconds: s)) to go."
            }
            return "Nearly there."

        case .finish:
            return "Run complete."
        }
    }

    /// The announcement the per-km loop speaks when the runner crosses a
    /// whole-km boundary ("3 kilometres."). Exposed so RunDirector can
    /// warm the TTS cache a few seconds ahead of the split, so it lands
    /// with zero generation latency.
    static func kilometreText(km: Int) -> String {
        distanceText(meters: Double(km) * 1000)
    }

    // MARK: - Formatting helpers
    //
    // Stays deterministic and small so the cache hit rate stays high.
    // No pace, no HR, no current-elapsed — those would vary per run and
    // bust the cache. The personality riff that follows can carry that.

    private static func distanceText(meters: Double) -> String {
        let km = meters / 1000.0
        // Snap to nearest 0.5 to keep the announcement vocabulary tiny.
        let halfSteps = Int((km * 2).rounded())
        let whole = halfSteps / 2
        let hasHalf = (halfSteps % 2) == 1

        if whole == 0 && hasHalf {
            return "Half a kilometre."
        }
        if whole == 0 {
            // Shouldn't happen in normal milestone triggers, but be safe.
            return "\(Int(meters)) metres."
        }
        let unit = whole == 1 ? "kilometre" : "kilometres"
        if hasHalf {
            return "\(whole) and a half \(unit)."
        }
        return "\(whole) \(unit)."
    }

    private static func timeText(seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes == 0 {
            return "\(seconds) seconds"
        }
        if minutes == 1 {
            return "1 minute"
        }
        return "\(minutes) minutes"
    }

    /// All texts likely to be needed by a given plan. Used by
    /// RunOrchestrator to warm AudioCache at run start so the first time
    /// the founder hits each km, playback is instant.
    static func prefetchTexts(for plan: RunPlan) -> [String] {
        var texts: [String] = ["Run complete.", "Halfway through.", "Halfway."]

        // Cover km splits up to the plan distance, or 10km for open / time
        // plans (most outdoor runs are under 10k; if the founder goes
        // longer, the late kms pay the network cost once and then cache).
        let maxKm: Int
        if let km = plan.distanceKm {
            maxKm = max(1, Int(ceil(km)))
        } else {
            maxKm = 10
        }
        for n in 1...maxKm {
            texts.append(distanceText(meters: Double(n) * 1000))
        }
        // Halfway-with-distance variants for round distance plans.
        if let totalM = plan.totalMeters {
            texts.append("Halfway. \(distanceText(meters: totalM / 2)) in.")
        }
        return Array(Set(texts))
    }
}
