import Foundation

/// Live Activity shown while the app records a line for Control Room. iOS
/// requires one for a recording started by an AudioRecordingIntent; it is
/// also the only visual sign the mic is open while the phone is in a pocket.
public struct ControlRoomActivityAttributes: Codable, Sendable, Hashable {
    public struct ContentState: Codable, Sendable, Hashable {
        /// listening | sending | sent | queued
        public let phase: String
        public let startedAt: Date

        public init(phase: String, startedAt: Date) {
            self.phase = phase
            self.startedAt = startedAt
        }
    }

    public init() {}
}

#if canImport(ActivityKit)
import ActivityKit
extension ControlRoomActivityAttributes: ActivityAttributes {}
#endif
