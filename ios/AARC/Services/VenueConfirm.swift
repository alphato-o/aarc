import Foundation
import Observation

/// Drives the in-run venue confirmation.
///
/// v2 (founder feedback 2026-07-21): one-at-a-time yes/no was too slow to rule
/// out wrong answers mid-stride, and the buttons were too small. Now the card
/// offers a COHORT of up to 3 candidates as big tap targets — "Are you at one
/// of these?" — plus a full-width "None of these". Tapping a venue makes it
/// FACT for the coaches (`PlaceContext.setConfirmedVenue`); "None of these"
/// advances to the next cohort; exhausting all cohorts asserts nothing — no
/// fabricated context is better than wrong context.
@MainActor
@Observable
final class VenueConfirm {
    static let shared = VenueConfirm()

    static let cohortSize = 3
    /// Deterministic candidates for UI-test journeys/screenshots (the sim has
    /// no location; the card must still be sim-verifiable per founder rule).
    static let uiTestSeed = ["The Grand Mock Hotel", "Mockingbird Fitness Club", "Placeholder Hotel Beijing"]

    private(set) var candidates: [String] = []
    private(set) var cohortStart = 0
    private(set) var resolved = false   // confirmed OR exhausted → stop asking
    private(set) var paused = false     // brief beat between cohorts after "none"

    /// The venues currently on offer (up to 3), empty when there's nothing to
    /// ask (resolved, mid-beat, or no candidates). The popup binds to this.
    var cohort: [String] {
        guard !resolved, !paused, cohortStart < candidates.count else { return [] }
        return Array(candidates[cohortStart..<min(cohortStart + Self.cohortSize, candidates.count)])
    }

    /// Seed from the treadmill one-shot. No candidates → immediately resolved
    /// (nothing to confirm; the server then simply won't assert a venue).
    func begin(candidates: [String]) {
        self.candidates = candidates
        self.cohortStart = 0
        self.resolved = candidates.isEmpty
        self.paused = false
        PlaceContext.shared.clearVenue()   // assert nothing until a tap
        RunEventLog.shared.record(
            "venue.candidates",
            candidates.isEmpty ? "(none found)" : candidates.joined(separator: " | "))
    }

    /// The runner tapped a venue — it's where they are. Fact.
    func confirmVenue(_ name: String) {
        guard cohort.contains(name) else { return }
        PlaceContext.shared.setConfirmedVenue(name)
        resolved = true
        RunEventLog.shared.record("venue.confirmed", name)
    }

    /// "None of these" — advance to the next cohort after a short beat, or
    /// give up (and assert nothing) when the candidates run out.
    func rejectCohort() {
        guard !resolved else { return }
        cohortStart += Self.cohortSize
        if cohortStart >= candidates.count {
            resolved = true
            PlaceContext.shared.clearVenue()
            RunEventLog.shared.record("venue.exhausted", "all \(candidates.count) candidates rejected")
            return
        }
        paused = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.0))
            paused = false
        }
    }

    /// End-of-run / new-run reset.
    func reset() {
        candidates = []
        cohortStart = 0
        resolved = false
        paused = false
    }
}
