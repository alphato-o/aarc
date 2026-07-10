import Foundation
import Observation
import AARCKit

/// The in-run roast library (founder idea, 2026-07-10): one batched LLM call
/// at run start generates 12-20 SHORT stand-alone roasts, cached here. Filler
/// beats (quiet stretches) draw from the pool instead of paying a live LLM
/// round-trip per line — and because the whole set is written in ONE batch,
/// the model de-duplicates against itself, so pool lines can't rediscover the
/// same joke sixteen times. Live-data moments (pace, HR, lyrics, milestones)
/// still generate live; the pool is the banter shelf, not the whole coach.
/// Bonus: filler keeps flowing through a total LLM outage.
@MainActor
@Observable
final class RoastPool {
    static let shared = RoastPool()

    private(set) var lines: [String] = []
    private(set) var drawn = 0
    private var fetchTask: Task<Void, Never>?

    var remaining: Int { lines.count }

    /// Fire-and-forget fetch at run start. Non-blocking: the run proceeds
    /// normally and the pool arrives when it arrives (a quiet stretch before
    /// then just uses the live path).
    func fetchIfNeeded(runType: RunType, personalityId: String = "roast_coach") {
        guard !AppEnv.uiTest else { return }          // journeys stay offline
        guard lines.isEmpty, fetchTask == nil else { return }
        let plan = ScriptPreviewStore.shared.currentPlan
        fetchTask = Task { @MainActor [weak self] in
            defer { self?.fetchTask = nil }
            do {
                let fetched = try await AIClient.shared.generateRoastPool(
                    personalityId: personalityId,
                    planKind: plan.kind.rawValue,
                    planDistanceKm: plan.distanceKm,
                    planTimeMinutes: plan.timeMinutes,
                    runType: runType.rawValue,
                    ambient: PlaceContext.shared.ambientInfo,
                    personalNotes: PersonalContextStore.shared.bullets,
                    likedLineExamples: LikedLinesStore.shared.vibeExemplars(personalityId: personalityId)
                )
                guard let self, !fetched.isEmpty else { return }
                self.lines = fetched.shuffled()   // random dispatch order
                RunEventLog.shared.record("pool.ready", "\(fetched.count) roasts cached")
            } catch {
                RunEventLog.shared.record("pool.failed", String(describing: error).prefix(120).description)
            }
        }
    }

    /// Next pool line, or nil when empty/exhausted (caller falls back to the
    /// live generation path). Each line dispatches at most once per run.
    func draw() -> String? {
        guard !lines.isEmpty else { return nil }
        drawn += 1
        return lines.removeFirst()
    }

    func reset() {
        fetchTask?.cancel()
        fetchTask = nil
        lines = []
        drawn = 0
    }
}
