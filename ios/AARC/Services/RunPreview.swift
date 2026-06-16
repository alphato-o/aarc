import Foundation
import AARCKit

/// Records every line the generation pipeline PRODUCES during a headless
/// preview run, instead of synthesising + queueing audio. The whole-run
/// feedback simulator (`SimRunDriver`) flips `active` on, drives a virtual
/// run through the real pipeline, and reads `lines` back out as a transcript.
///
/// Content mode (Harness A, v1): captures what's SAID + the director's
/// decision context at production. Timing fidelity (what actually PLAYS,
/// drops, late lands) is a v2 concern — see docs/feedback-sim-harness-spec.html.
@MainActor
final class RunPreview {
    static let shared = RunPreview()
    private init() {}

    struct Line: Codable {
        var t: Double            // virtual elapsed seconds at production
        var voice: String        // "ricky" | "jessica"
        var source: String       // "jessica:react", "script:every_km", "coach:quiet_stretch", …
        var priority: String
        var milestone: Bool
        var km: Int
        var chars: Int
        var lengthMode: String   // inferred bucket: quip / medium / indulgent
        var text: String
        // director decision context, snapshotted at production
        var progress: Double
        var etaNextMustPlay: Double?
        var ownerJessica: Bool   // who the director assigned this km's milestone
        var protected: Bool
    }

    private(set) var active = false
    private(set) var lines: [Line] = []
    /// The virtual clock the driver advances; stamped onto each recorded line.
    var virtualElapsed: Double = 0

    func begin() { active = true; lines = []; virtualElapsed = 0 }
    func end() { active = false }

    /// Called from `Speaker.speak` when active — record the line and skip the
    /// real queue + TTS entirely.
    func record(text: String, source: String, priority: VoicePriority, voiceId: String?) {
        let jessica = (voiceId == RemoteTTS.jessicaVoiceId)
        let n = text.count
        let mode = n <= 160 ? "quip" : (n <= 420 ? "medium" : "indulgent")
        let d = RunDirector.shared
        let dist = LiveMetricsConsumer.shared.latest?.distanceMeters ?? 0
        let km = Int(dist / 1000)
        let isMilestone = ["milestone", "every_km", "halfway", "near_finish", "finish"]
            .contains { source.contains($0) }
        lines.append(Line(
            t: virtualElapsed,
            voice: jessica ? "jessica" : "ricky",
            source: source,
            priority: "\(priority)",
            milestone: isMilestone,
            km: km,
            chars: n,
            lengthMode: mode,
            text: text,
            progress: d.progressFraction,
            etaNextMustPlay: d.nextMustPlayETA,
            ownerJessica: d.milestoneOwnerIsJessica(km: max(1, km)),
            protected: d.isProtectedWindow
        ))
    }

    /// Serialise the transcript for writing to disk.
    func transcriptJSON(plan: String, pace: Double) -> Data? {
        struct Out: Codable {
            var plan: String
            var paceSecPerKm: Double
            var lineCount: Int
            var lines: [Line]
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(Out(plan: plan, paceSecPerKm: pace, lineCount: lines.count, lines: lines))
    }
}
