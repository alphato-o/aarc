import Foundation

public enum RunMode: String, Codable, Sendable, CaseIterable {
    case free
    case training
    case race
}

public enum RunType: String, Codable, Sendable, CaseIterable {
    case outdoor
    case treadmill
}

public enum WorkoutState: String, Codable, Sendable {
    case idle
    case preparing
    case running
    case paused
    case ended
}
