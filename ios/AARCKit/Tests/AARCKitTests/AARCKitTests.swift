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
    let msg = WCMessage.startWorkout(runId: id, runType: .treadmill, personalityId: "roast_coach")
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(WCMessage.self, from: data)
    if case .startWorkout(let runId, let runType, let personalityId) = decoded {
        #expect(runId == id)
        #expect(runType == .treadmill)
        #expect(personalityId == "roast_coach")
    } else {
        Issue.record("expected .startWorkout case")
    }
}
