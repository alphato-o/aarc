import Foundation
import Observation

/// Drives the in-run "Are you at X?" venue confirmation.
///
/// Treadmill location only resolves to a city; MapKit offers nearby venue
/// candidates but they're frequently wrong (run BFDD0366: the runner was at
/// Park Hyatt Beijing, the model confabulated Kerry Hotel / The Opposite House
/// 11×). Rather than assert a guess — a wrong venue kills the vibe and there's
/// no way to correct it mid-run — we ASK the runner, one yes/no at a time, big
/// buttons, in the dynamic-chart slot. Only a "yes" becomes fact for the
/// coaches (`PlaceContext.setConfirmedVenue`). If every candidate is rejected
/// we assert nothing — no fabricated context is better than wrong context.
@MainActor
@Observable
final class VenueConfirm {
    static let shared = VenueConfirm()

    private(set) var candidates: [String] = []
    private(set) var index = 0
    private(set) var resolved = false   // confirmed OR exhausted → stop asking
    private(set) var paused = false     // brief beat between questions after a "no"

    /// The venue currently being asked about, or nil when there's nothing to
    /// ask (resolved, mid-beat, or no candidates). The popup binds to this.
    var pending: String? {
        guard !resolved, !paused, index < candidates.count else { return nil }
        return candidates[index]
    }

    /// Seed from the treadmill one-shot. No candidates → immediately resolved
    /// (nothing to confirm; the server then simply won't assert a venue).
    func begin(candidates: [String]) {
        self.candidates = candidates
        self.index = 0
        self.resolved = candidates.isEmpty
        self.paused = false
        PlaceContext.shared.clearVenue()   // assert nothing until a "yes"
    }

    /// "Yes" — this candidate is where they are. It becomes fact.
    func confirmYes() {
        guard let v = pending else { return }
        PlaceContext.shared.setConfirmedVenue(v)
        resolved = true
        RunEventLog.shared.record("venue.confirmed", v)
    }

    /// "No" — advance to the next candidate after a short beat, or give up if
    /// we've run out (and then assert nothing).
    func confirmNo() {
        guard !resolved else { return }
        index += 1
        if index >= candidates.count {
            resolved = true
            PlaceContext.shared.clearVenue()
            RunEventLog.shared.record("venue.exhausted", "all \(candidates.count) candidates rejected")
            return
        }
        paused = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            paused = false
        }
    }

    /// End-of-run / new-run reset.
    func reset() {
        candidates = []
        index = 0
        resolved = false
        paused = false
    }
}
