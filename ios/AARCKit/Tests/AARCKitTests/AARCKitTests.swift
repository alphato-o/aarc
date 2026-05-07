import Foundation
import Testing
@testable import AARCKit

@Test func liveMetricsRoundTrip() throws {
    let original = LiveMetrics(
        elapsed: 120,
        distanceMeters: 350,
        currentPaceSecPerKm: 342,
        avgPaceSecPerKm: 358,
        currentHeartRate: 158,
        energyKcal: 28,
        lastSplit: nil,
        state: .running
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(LiveMetrics.self, from: data)
    #expect(decoded == original)
}

@Test func wcMessageEnumRoundTrip() throws {
    let id = UUID()
    let msg = WCMessage.startWorkout(runId: id, personalityId: "roast_coach", mode: .training)
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(WCMessage.self, from: data)
    if case .startWorkout(let runId, let personalityId, let mode) = decoded {
        #expect(runId == id)
        #expect(personalityId == "roast_coach")
        #expect(mode == .training)
    } else {
        Issue.record("expected .startWorkout case")
    }
}
